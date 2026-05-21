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


---
Why there are multiple allocator implementations

Each allocator makes different tradeoffs between speed, memory use, and allocation quality (how fragmented the resulting free space becomes):

┌─────────────────┬─────────────────────────────────────┬───────────────────────────────────────────────────────────────────────────────┐
│    Allocator    │           Data structure            │                                 Key tradeoff                                  │
├─────────────────┼─────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────┤
│ StupidAllocator │ Simple bucket list                  │ Fast, low memory, poor fragmentation handling — legacy/fallback               │
├─────────────────┼─────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────┤
│ BitmapAllocator │ Bit array                           │ O(1) ops, but memory scales with device size (1 bit per block)                │
├─────────────────┼─────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────┤
│ AvlAllocator    │ Two AVL trees (by offset + by size) │ Good allocation quality, memory scales with free extent count not device size │
├─────────────────┼─────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────┤
│ BtreeAllocator  │ B-tree variant                      │ Similar to AVL, different balancing/cache behavior                            │
├─────────────────┼─────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────┤
│ Btree2Allocator │ Newer B-tree variant                │ Experimental successor to BtreeAllocator                                      │
├─────────────────┼─────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────┤
│ HybridAllocator │ AVL/Btree + Bitmap fallback         │ Caps memory: keeps hot extents in tree, spills rest to bitmap                 │
└─────────────────┴─────────────────────────────────────┴───────────────────────────────────────────────────────────────────────────────┘

AvlAllocator is currently the production default. It keeps two intrusive AVL trees (you can see offset_hook and size_hook in AvlAllocator.h:32-44): one sorted by offset
(for fast range lookups) and one sorted by size (to quickly find a best-fit free extent). Memory cost is proportional to the number of free extents, not total device size
— important for multi-TB drives.

HybridAllocator exists because even AVL trees can use too much RAM on very fragmented, large devices. It puts a cap (bluestore_hybrid_alloc_mem_cap) on tree entries and
overflows the rest to a bitmap, trading allocation quality for bounded memory.

---

## Who selects the allocator?

It is a **user-configurable option** — specifically the `bluestore_allocator` config key. You set it in `ceph.conf` or via `ceph config set`:

```ini
[osd]
bluestore_allocator = avl
```

The default (as of this codebase) is `hybrid`. BlueStore reads it at OSD startup in `BlueStore::_create_alloc()` (`BlueStore.cc:7464`) and passes the string straight to `Allocator::create()`. The allocator type is **fixed for the lifetime of that OSD** — changing it requires a restart and a full device re-init (the free space structure is rebuilt from the RocksDB freelist on startup, so the on-disk format is allocator-agnostic).

---

## Which allocator for which use case?

| Allocator | When to use |
|---|---|
| `hybrid` **(default)** | General purpose. Keeps the best free extents in an AVL tree and spills the rest to a bitmap once RAM exceeds `bluestore_hybrid_alloc_mem_cap` (default 64 MB). Good balance across HDD and SSD. |
| `avl` | If your OSD has plenty of RAM and you want the best allocation quality (least fragmentation). Memory grows with extent count — on a heavily fragmented multi-TB device this can run into hundreds of MB. |
| `btree` / `hybrid_btree2` | Experimental successors to `avl`/`hybrid`. `hybrid_btree2` adds a `bluestore_btree2_alloc_weight_factor` that biases allocation toward large contiguous extents — useful when you want to aggressively avoid fragmentation on write-heavy workloads. |
| `bitmap` | Predictable, fixed memory (1 bit per block). Useful when RAM is severely constrained and you don't care about fragmentation quality. Memory scales with **device size**, not free extent count. |
| `stupid` | **Testing only** — the config description says so explicitly. Simple bucket list, poor behavior under real workloads. |

---

## The second dimension: `bluestore_allocator_lookup_policy`

There is a second config — `bluestore_allocator_lookup_policy` — that controls *where* the allocator starts its search for a free extent within the chosen allocator:

- `hdd_optimized` — searches from where the last allocation landed, promoting sequential writes. Good for HDDs and QLC SSDs.
- `ssd_optimized` — always searches from the start of the device, spreading writes across the device to aid SSD firmware wear-leveling / housekeeping.
- `auto` *(default)* — BlueStore detects whether the device is rotational and picks the right policy automatically.

This is independent of the allocator type — you can combine any allocator with either lookup policy.

## Does the allocator manage both HDD and SSD?

No. A single allocator instance manages **one block device**. It doesn't straddle two devices.

BlueStore can be configured with **multiple devices** — a fast device (NVMe SSD) for RocksDB metadata and WAL, and a slow device (HDD) for bulk object data. In that case it creates separate allocator instances, one per device. BlueFS (the internal filesystem BlueStore uses for RocksDB) manages the fast device separately with its own allocation logic.

The allocator can sit on top of any block device — HDD, SSD, or NVMe. A typical all-flash cluster would have:
- An NVMe SSD as the main data device
- The `avl` or `hybrid` allocator managing its free extents
- `bluestore_allocator_lookup_policy = auto` detecting it is non-rotational and picking `ssd_optimized`

## How the HybridAllocator works

### The core problem it solves

**AvlAllocator** is great at finding large, contiguous free extents — but its memory usage grows with the number of free extent entries, not device size. On a heavily fragmented multi-TB device, the AVL tree can hold millions of tiny extents and consume hundreds of MB of RAM.

**BitmapAllocator** uses fixed memory (1 bit per block), but is poor at finding the best free extent quickly — it just scans bits.

HybridAllocator takes the best of both: use the AVL/Btree tree for as long as RAM allows, then spill overflow into the bitmap.

---

### Architecture

```
HybridAllocatorBase<AvlAllocator>    (= "hybrid")
HybridAllocatorBase<Btree2Allocator> (= "hybrid_btree2")

┌─────────────────────────────────────────────────────┐
│                 HybridAllocator                     │
│                                                     │
│  ┌─────────────────────────┐                        │
│  │   Primary Allocator     │  ← AVL or Btree2       │
│  │   (tree, in RAM)        │                        │
│  │                         │  max_mem = 64 MB cap   │
│  │  offset-tree + size-tree│                        │
│  │  (best-fit, fast)       │                        │
│  └──────────┬──────────────┘                        │
│             │ overflow via _spillover_range()        │
│             ▼                                        │
│  ┌─────────────────────────┐                        │
│  │   BitmapAllocator       │  ← created lazily      │
│  │   (fallback, in RAM)    │                        │
│  │                         │  1 bit per block        │
│  │  fixed memory, lower    │  fixed memory cost     │
│  │  allocation quality     │                        │
│  └─────────────────────────┘                        │
└─────────────────────────────────────────────────────┘
```

---

### What "spillover" means

The primary AVL/Btree tracks how many entries it holds. When that count exceeds the `max_mem` threshold (default 64 MB worth of entries), it calls `_spillover_range()` on the excess entries — the smallest, least-useful extents get evicted from the tree and handed to the bitmap.

```
Device free space (conceptual):

Offset:  0    1G    2G    3G    4G    5G    6G    7G    8G
         |    |     |     |     |     |     |     |     |
         [free][used][  free  ][u][free][used][       free       ]

Primary tree holds (large/important extents):
  → (2G, 1G)       ← 1 GB extent
  → (4G, 512M)     ← 512 MB extent
  → (6G, 2G)       ← 2 GB extent

Bitmap holds (small/spilled extents):
  → bit 0 = 1      ← tiny 4K fragment at offset 0
  → bit N = 1      ← another tiny fragment
  → ...
```

The tree keeps the large extents because those are the ones that matter for allocation quality. Tiny fragments that can't satisfy most requests anyway get demoted to the cheaper bitmap.

---

### Allocation flow

```
allocate(want) called
        │
        ▼
  want < lowest_size_in_tree?
        │
   YES  │  NO
        │  └──► try Primary tree first
        │              │
        │         found enough?──YES──► done ✓
        │              │NO
        │              └──► try Bitmap for remainder
        │                         │
        │                    found?──YES──► done ✓
        │                         │NO
        │                         └──► return -ENOSPC
        │
        └──► try Bitmap first  ← avoids splitting a large tree extent
                   │             for a tiny request
              found enough?──YES──► done ✓
                   │NO
                   └──► try Primary tree for remainder
```

The key decision at `HybridAllocator_impl.h:42`:
```cpp
bool primary_first = !(bmap_alloc &&
                       bmap_alloc->get_free() &&
                       want < T::_lowest_size_available());
```
If the request is smaller than the smallest extent in the tree, try the bitmap first — no point fragmenting a 1 GB tree extent to satisfy a 4 KB write.

---

### Release and merge-back flow

When an extent is freed, HybridAllocator tries to absorb adjacent bitmap entries back into the tree (`HybridAllocator.h:101`):

```cpp
void _add_to_tree(uint64_t start, uint64_t size) override {
  if (bmap_alloc) {
    uint64_t head = bmap_alloc->claim_free_to_left(start);
    uint64_t tail = bmap_alloc->claim_free_to_right(start + size);
    start -= head;
    size  += head + tail;
  }
  PrimaryAllocator::_add_to_tree(start, size);
}
```

Example:
```
Before release of extent at offset 500M, length 100M:

  Bitmap: [free: 480M~20M]        [free: 600M~50M]
  Tree:   (nothing at this region — it was spilled)

After release:
  claim_free_to_left(500M)  → absorbs 480M~20M from bitmap
  claim_free_to_right(600M) → absorbs 600M~50M from bitmap
  merged extent: (480M, 170M) → promoted into primary tree

  Tree: (480M, 170M)  ← one large merged extent, now searchable
```

Freed space naturally coalesces back into the tree, preventing the bitmap from accumulating large free regions that the tree would be better at serving.

---

### The Btree2 variant adds a lockless cache

`hybrid_btree2` adds an `OpportunisticExtentCache` (`AllocatorBase.h:179`) — 16 buckets of 16 slots each, covering extent sizes 4K, 8K, 12K ... 64K. Recently freed small extents are stashed here without taking the main allocator lock, and allocation checks this cache first.

```
allocate(want=4K)
    │
    ▼
check OpportunisticExtentCache[bucket for 4K]
    │
  hit?──YES──► return cached offset (no lock needed!) ✓
    │NO
    └──► fall through to normal AVL/Bitmap path (takes lock)
```

This matters for write-heavy small-IO workloads where the same 4K–64K extents are constantly allocated and freed — cache hits avoid lock contention entirely.

---

### Why Hybrid beats the alternatives

| Scenario | Pure AVL | Pure Bitmap | Hybrid |
|---|---|---|---|
| Fresh device, low fragmentation | Good | OK | Good (tree handles it all) |
| Heavy fragmentation, millions of tiny extents | RAM blows up | Fixed RAM, slow allocation | Tree keeps large extents, bitmap absorbs tiny ones |
| Tiny IO (4K writes), high concurrency | Lock contention on tree | Lock contention on bitmap | Cache hits bypass lock entirely (btree2 variant) |
| Multi-TB device, low RAM OSD | Unusable | Fixed cost, works | Bounded by `max_mem`, degrades gracefully |
| Request smaller than smallest tree extent | Splits a large extent (wasteful) | Scans bits | Tries bitmap first, preserves large extents |

The core insight: **not all free extents are equal**. Large extents are precious — they satisfy any allocation and should live in the fast tree. Tiny fragments are mostly noise — they belong in the cheap bitmap. Hybrid sorts them accordingly.
