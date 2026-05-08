# What the Allocator Does in BlueStore

The `Allocator` answers one question on every write: **"Where on the raw block device should I put this data?"**

When BlueStore needs to write a new blob, it has a raw block device (say, a 4TB NVMe) and needs to find free space on it. The Allocator tracks which byte ranges are free and hands out physical addresses on demand.

---

## The Two-Tier Design

This is the most important thing to understand — there are **two separate systems** tracking free space, and they serve different purposes:

```
┌─────────────────────────────────────────────────────────────┐
│              TIER 1: Allocator  (lives in RAM)              │
│                                                             │
│  AvlAllocator / BitmapAllocator / HybridAllocator           │
│                                                             │
│  Fast in-memory data structure (AVL tree or bitmap)        │
│  Answers: "give me 64KB of free space" in microseconds     │
│  Lost on every restart — rebuilt from Tier 2 on mount      │
└─────────────────────────────────────────────────────────────┘
                          ▲
                          │ rebuilt on mount
                          │ init_add_free() called for each free range
                          │
┌─────────────────────────────────────────────────────────────┐
│         TIER 2: BitmapFreelistManager  (lives in RocksDB)   │
│                                                             │
│  Persistent XOR bitmap stored under PREFIX_ALLOC_BITMAP    │
│  Source of truth — survives crashes and restarts           │
│  Updated atomically inside every RocksDB transaction       │
└─────────────────────────────────────────────────────────────┘
```

They are kept in sync but serve opposite masters: the Allocator serves **speed** (the write path needs an address right now), the FreelistManager serves **durability** (the bitmap must reflect reality after a crash).

---

## The Allocator Interface (Allocator.h)

```cpp
// Core operations:

int64_t allocate(uint64_t want_size,      // how many bytes you want
                 uint64_t block_size,     // alignment granularity
                 uint64_t max_alloc_size, // max size of a single extent
                 int64_t  hint,           // preferred disk offset (locality hint)
                 PExtentVector *extents); // OUTPUT: list of {offset, length}

void release(const release_set_t& release_set); // mark ranges as free again

// Called only at mount time to populate from FreelistManager:
void init_add_free(uint64_t offset, uint64_t length); // "this range is free"
void init_rm_free(uint64_t offset, uint64_t length);  // "this range is used"
```

`allocate()` returns a `PExtentVector` — a list of `{disk_offset, length}` pairs. It can return **multiple extents** if the requested size isn't available as one contiguous run. For example, asking for 1MB might return:

```
[{offset=0x10000, length=512KB}, {offset=0x500000, length=512KB}]
```

BlueStore stores all of these in the blob's `PExtentVector` and issues multiple AIOs to fill them.

---

## The Implementations

### AvlAllocator — the default

Uses **two AVL trees simultaneously** on the same set of `range_seg_t` nodes:

```cpp
struct range_seg_t {
    uint64_t start;
    uint64_t end;
    avl_set_member_hook offset_hook; // hook for tree #1
    avl_set_member_hook size_hook;   // hook for tree #2
};

range_tree_t       range_tree;       // sorted by offset  → find neighbours for merging
range_size_tree_t  range_size_tree;  // sorted by size    → find best-fit quickly
```

**Why two trees?** Different operations need different orderings:
- When **releasing** space, you need to find adjacent free segments to merge with (coalesce) — requires the offset tree.
- When **allocating**, you want to find a segment that fits a given size quickly — requires the size tree.

The allocator switches strategies based on pressure:
- **First-fit**: when plenty of space is available, scan forward from a cursor (`_pick_block_after`) — good for locality
- **Best-fit**: when space is tight, find the smallest segment that fits (`_pick_block_fits`) — reduces fragmentation

```cpp
uint64_t lbas[64]; // per-power-of-2 "last block address" cursors
                   // locality hint: try to allocate near where you last allocated
```

### BitmapAllocator

Uses a **hierarchical bitmap** for extremely fast scans. The device is divided into fixed-size chunks; each level of the hierarchy summarizes the level below. Finding free space becomes a top-down scan of the hierarchy rather than a tree traversal. Good for sequential workloads where the free space is large and contiguous.

### HybridAllocator

Wraps either `AvlAllocator` or `Btree2Allocator` as the primary, with a `BitmapAllocator` as overflow:

```cpp
template <typename PrimaryAllocator>
class HybridAllocatorBase : public PrimaryAllocator {
    std::unique_ptr<BitmapAllocator> bmap_alloc; // the overflow bucket
};
```

The primary allocator has a `range_count_cap` — a maximum number of free range segments it will hold in RAM. On very large devices with heavy fragmentation, the number of tiny free fragments could exceed available RAM. When the cap is hit, the smallest fragments are **spilled over** to the BitmapAllocator instead of being dropped. Allocations check the primary first, then fall back to the BitmapAllocator.

---

## How It Fits Into the Write Path

```
BlueStore::_do_alloc_write()
    │
    ├── alloc->allocate(want_size, block_size, hint, &extents)
    │     └── returns PExtentVector: [{disk_offset_1, len_1}, {disk_offset_2, len_2}]
    │               (purely in-memory — no disk I/O yet)
    │
    ├── Fill blob's pextents with these addresses
    ├── bdev->aio_write(disk_offset_1, data_buf_1, ...)  ← schedule AIO
    ├── bdev->aio_write(disk_offset_2, data_buf_2, ...)  ← schedule AIO
    │
    └── fm->allocate(offset, length, kv_txn)
          └── XOR the bitmap in RocksDB txn
              (marks these blocks as "used" persistently)
```

`alloc->allocate()` is purely in-memory and instant. The persistent record (`fm->allocate()`) goes into the same RocksDB transaction as the onode update — so both "object now points here" and "this space is now used" are committed atomically.

---

## The Mount Sequence

Every time BlueStore mounts, the in-memory Allocator is **empty**. It gets rebuilt from the FreelistManager:

```
_open_fm()    → load BitmapFreelistManager from RocksDB
_init_alloc() → iterate the bitmap:
    for each free range {offset, length}:
        alloc->init_add_free(offset, length)

    for each range used by BlueFS (shared device):
        alloc->init_rm_free(offset, length)
```

This can be slow on large devices (iterating a terabyte-scale bitmap). There's an optimization called the **allocation file** (`bluestore_bluefs_alloc_tracker`) that snapshots the allocator state so it can be loaded directly instead of reconstructed.

---

## Space Release Timing — A Subtle but Important Detail

When a write transaction frees space (e.g. overwriting an old extent), the freed extents are **not immediately returned to the Allocator**. They sit in `txc->released` until `_txc_release_alloc()` runs in `STATE_FINISHING`:

```
Transaction commits to RocksDB
    │
    │  (deferred block writes may still be in flight for this txc)
    │
    ▼
STATE_FINISHING:  _txc_release_alloc()
    └── alloc->release(txc->released)
```

The delay is intentional: a **deferred write** from transaction N might be writing into a block that transaction N+1 has already freed and re-allocated. If N+1's space release reached the allocator before N's deferred write finished, a third transaction N+2 could allocate that same block and start writing to it — while N's deferred write is still in flight. Holding the release until after all deferred I/O completes prevents this race.

---

## Summary Table

| Component | Lives in | Rebuilt on restart? | Purpose |
|---|---|---|---|
| `Allocator` (AvlAllocator etc.) | RAM | Yes (from FreelistManager) | Fast in-memory free space lookup for the write path |
| `BitmapFreelistManager` | RocksDB | No (source of truth) | Persistent free space bitmap, updated atomically with metadata |
