## What is BlueStore, and Where Does It Fit?

Ceph stores data on physical machines using **OSDs** (Object Storage Daemons). Each OSD needs a **backend storage engine** — a piece of code that takes "write this object" and actually puts bytes on a disk. BlueStore is that engine. It replaced the older FileStore backend and became the default in Ceph Luminous (2017).

The key architectural decision: **BlueStore bypasses the OS filesystem entirely**. Instead of writing files on ext4/xfs, it writes object data directly to a raw block device and stores metadata in its own embedded RocksDB instance. This gives it full control over I/O, enabling features like checksums, compression, and copy-on-write clones without double-writing.

---

## The Ceph Storage Stack (Top to Bottom)

```
Client (librados / RBD / CephFS / RGW)
         │
    RADOS (Ceph's distributed object layer)
         │
    OSD daemon (one per disk)
         │
    ObjectStore API  ← BlueStore implements this
         │
    BlueStore
    ├── RocksDB (metadata: onode, extents, freelist)
    │     └── BlueFS (RocksDB's private mini-filesystem)
    │           └── Block Device (raw disk, NVMe, etc.)
    └── Block Device (raw disk for object data)
```

The `ObjectStore` API (in `src/os/ObjectStore.h`) is the contract BlueStore implements. It speaks in terms of *collections* (= Ceph placement groups / PGs) and *objects* (identified by `ghobject_t`), and supports *transactions* — atomic batches of reads/writes/deletes.

---

## Key Concepts

### 1. Objects, Onodes, and Extents

Every Ceph object has an **Onode** (Object Node) — the in-memory + on-disk descriptor for one object. Think of it as the inode in a regular filesystem.

```
Onode (bluestore_onode_t)
 ├── logical size, xattrs, omap flags
 └── ExtentMap: logical_offset → Extent
       └── Extent: {logical_offset, blob_offset, length, Blob}
             └── Blob (bluestore_blob_t)
                   └── PExtentVector: [{disk_offset, length}, ...]
```

The chain is: **logical byte range** → **Blob** → **physical extents on disk**. A blob can optionally be compressed, checksummed, or shared (for clones).

### 2. Blobs — The Core Unit of Storage

A **Blob** (`bluestore_blob_t`) is the unit BlueStore allocates and tracks. It holds:
- A list of physical extents (where on disk the data lives)
- Optional compression metadata
- Per-chunk checksums
- An `unused` bitmap (which allocation-unit chunks have never been written)
- A `shared` flag (for clone/snapshot scenarios)

### 3. Transactions — The Write Unit

All writes go through an `ObjectStore::Transaction`, which BlueStore wraps in a `TransContext`. A single transaction atomically:
- Writes object data to the block device (via Linux AIO)
- Updates the onode (extent map, size, xattrs) in RocksDB
- Updates the free-space bitmap in RocksDB

The two-phase nature is intentional: data hits disk first (AIO), then RocksDB commits the metadata. If the system crashes between those two, fsck finds orphaned data (no onode points to it) and cleans it up.

### 4. The Small-Write Trick: Deferred Writes

Writes smaller than `min_alloc_size` (typically 4KB or 64KB) can't allocate a new block cleanly. Instead, BlueStore uses a **WAL-style deferred write**: the data payload goes *into* the RocksDB transaction under the `PREFIX_DEFERRED` key prefix. After RocksDB commits (making the data durable), a background thread writes it to the actual block device. This avoids a read-modify-write cycle for small writes.

---

## Major Subsystems in `src/os/bluestore/`

| File(s) | What it does |
|---|---|
| `BlueStore.h/.cc` | The whole engine (~25k lines). All main classes nested inside. |
| `bluestore_types.h/.cc` | On-disk serializable structs: `bluestore_onode_t`, `bluestore_blob_t`, `bluestore_pextent_t` |
| `BlueFS.h/.cc` | A tiny private filesystem that lives inside the block device, used exclusively by RocksDB |
| `bluefs_types.h/.cc` | BlueFS on-disk types: `bluefs_fnode_t`, `bluefs_extent_t`, journal records |
| `BlueRocksEnv.h/.cc` | Glue layer: implements `rocksdb::Env` so RocksDB's file I/O goes through BlueFS |
| `FreelistManager.h`, `BitmapFreelistManager.h/.cc` | Persistent free-space tracking stored in RocksDB (XOR bitmap using merge operators) |
| `Allocator.h`, `AvlAllocator`, `BitmapAllocator`, etc. | In-memory free-space allocator (rebuilt from FreelistManager on every mount) |
| `bluestore_tool.cc` | The `ceph-bluestore-tool` CLI for offline repair/inspection |

---

## Data Flow: A Write End-to-End

```
queue_transactions()
  │
  ├─ _txc_add_transaction()   ← decode op stream
  │    └─ _do_write()
  │         ├─ fault_range()  ← load extent map shards from RocksDB
  │         ├─ _do_write_small()  ← sub-alloc-unit: deferred write path
  │         └─ _do_write_big()   ← full blocks: direct AIO path
  │               └─ _do_alloc_write()  ← allocate space, submit AIO
  │
  ├─ _txc_write_nodes()   ← serialize dirty onodes into KV txn
  ├─ _txc_finalize_kv()   ← update freelist bitmap in KV txn
  │
  ├─ [AIO completes]   ← data is on disk
  │
  ├─ kv_sync_thread    ← submit + fsync RocksDB (metadata durable)
  ├─ on_commit() fires ← caller's callback (transaction "committed")
  │
  └─ kv_finalize_thread ← deferred write block I/O, release allocations
```

---

## Data Flow: A Read End-to-End

```
read()
  │
  ├─ get_onode()          ← RocksDB lookup (or cache hit)
  ├─ wait if flushing     ← ensures in-flight writes are visible
  ├─ _read_cache()        ← check BufferSpace (per-object data cache)
  │    ├─ cache hit  → data ready
  │    └─ cache miss → build blobs2read list
  ├─ _prepare_read_ioc()  ← translate logical → physical, submit AIO
  ├─ [AIO completes]
  └─ _generate_read_result_bl()
       ├─ decompress if needed (must read entire compressed blob)
       ├─ verify checksums
       └─ populate BufferSpace cache
```

---

## BlueFS: Why Does BlueStore Have Its Own Filesystem?

RocksDB needs a filesystem to store its SSTables and WAL. Rather than using the OS filesystem (which would layer: OS FS → raw disk), BlueStore implements **BlueFS** — a minimal append-only log-structured filesystem that sits directly on top of the same block device (or a separate faster device like NVMe).

BlueFS supports up to 3 tiers:
- `BDEV_WAL` — fastest (NVMe); holds RocksDB WAL files
- `BDEV_DB` — medium; holds RocksDB SST metadata
- `BDEV_SLOW` — large rotational disk; holds bulk SST data

`BlueRocksEnv` is the glue — it implements `rocksdb::Env` so that every `fopen`/`fwrite` RocksDB makes is intercepted and routed to BlueFS.

---

## The Allocator / FreelistManager Split

This is a two-tier design that's easy to confuse:

| Layer | Where | What it tracks | Rebuilt on? |
|---|---|---|---|
| `Allocator` (e.g. `AvlAllocator`) | RAM only | Which blocks are free | Every mount |
| `BitmapFreelistManager` | RocksDB | Same, but persistently | Never (source of truth) |

At mount time: FreelistManager iterates its RocksDB bitmap → calls `alloc->init_add_free()` for each free region → Allocator is ready.

At write time: `alloc->allocate()` reserves space in RAM. The KV transaction simultaneously XORs the bitmap in RocksDB (using merge operators, so it's O(1) at write time).

---

## Where to Start Reading the Code

If you're new, I'd suggest this reading order:

1. **`src/os/ObjectStore.h`** — understand the API BlueStore implements
2. **`bluestore_types.h`** — understand the on-disk structures before anything else
3. **`BlueStore.h`** — skim the nested class declarations (`Onode`, `Blob`, `Extent`, `ExtentMap`, `TransContext`)
4. **`BlueStore.cc:_do_write()`** — the write path entry point (~line 17805)
5. **`BlueStore.cc:_do_read()`** — the read path (~line 12722)
6. **`BlueStore.cc:_txc_state_proc()`** — the transaction state machine (~line 14594)
7. **`BlueFS.cc`** — once you understand the main engine, look at how RocksDB storage works

---

## Things That Trip Up Newcomers

- **`blob_offset` vs `logical_offset`**: `Extent.logical_offset` is where in the *object* the data lives. `Extent.blob_offset` is the byte offset *within the blob* where this extent's data starts. A blob can be larger than a single extent.
- **Sharded ExtentMaps**: For large objects (many extents), the extent map is split into shards stored as separate RocksDB keys. They load lazily via `fault_range()`. If you touch an extent and the shard isn't loaded, you'll get a stale view.
- **`flushing_count`**: An Onode tracks how many in-flight `TransContext` objects have modified it but not yet committed to RocksDB. Readers that need consistent metadata must wait for this to reach zero.
- **Space release timing**: Freed extents are not immediately returned to the in-memory allocator at KV commit time — they wait until `STATE_FINISHING` after all deferred writes from that transaction have also completed. This prevents a use-after-free on the block device.
