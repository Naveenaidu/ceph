# What RocksDB Does in BlueStore

RocksDB is BlueStore's **metadata store**. It never touches object data (the actual bytes a user wrote) — that goes directly to the block device via AIO. RocksDB's job is to store everything BlueStore needs to *find and describe* that data.

---

## The Core Problem RocksDB Solves

When BlueStore gets a read request for `object_foo, offset=4096, length=512`, it needs to answer:

- Does this object exist?
- How big is it?
- Which physical disk addresses hold bytes 4096–4608?
- Is that region compressed? With what algorithm?
- What's the checksum for that chunk?

All of that lives in RocksDB. Without it, BlueStore has a block device full of bytes with no map to find anything.

---

## What Exactly Is Stored in RocksDB

RocksDB uses **key prefixes** to namespace different types of data. Here's everything BlueStore stores there:

### 1. Onodes — `PREFIX_OBJ` (`"O"`)
The most important one. An **Onode** is the per-object record:

```
Key:   "O" + encoded ghobject_t  (the object's identity)
Value: bluestore_onode_t
         ├── nid          (numeric object ID)
         ├── size         (logical object size in bytes)
         ├── attrs        (xattrs: map<string, buffer>)
         ├── extent_map   (logical offset → Blob → physical extents)
         │     └── [0, 65536) → Blob #3 → [{disk_offset=1048576, len=65536}]
         ├── omap_head    (pointer to omap data)
         └── shard_info   (for large objects with sharded extent maps)
```

Every read starts here. Every write updates this.

### 2. Free Space Bitmap — `PREFIX_ALLOC_BITMAP` (`"b"`)
The persistent record of which blocks on the raw block device are free vs. allocated:

```
Key:   "b" + block_offset
Value: XOR bitmap (each bit = one min_alloc_size block)
```

This uses RocksDB's **merge operator** — allocation and release operations are XOR-merged at compaction time rather than doing read-modify-write on every transaction. On mount, BlueStore reads this bitmap and rebuilds the in-memory allocator from it.

### 3. Deferred Write Data — `PREFIX_DEFERRED` (`"L"`)
For small writes (smaller than `min_alloc_size`), the actual data payload is stored here temporarily:

```
Key:   "L" + sequence_number
Value: bluestore_deferred_transaction_t
         └── list of {disk_offset, data_bytes}
```

After RocksDB commits this record (making it durable), a background thread reads it back and writes the data to the block device. On crash recovery, BlueStore replays any `PREFIX_DEFERRED` records it finds that haven't been applied yet.

### 4. Shared Blob Reference Counts — `PREFIX_SHARED_BLOB` (`"X"`)
When a snapshot or clone makes two objects share the same physical data, BlueStore promotes that blob to "shared" and tracks reference counts:

```
Key:   "X" + sbid  (shared blob ID)
Value: bluestore_shared_blob_t
         └── ref_map: {offset → {length, ref_count}}
```

When the ref count for a range drops to zero, that physical space can be freed.

### 5. Store-level Superblock — `PREFIX_SUPER` (`"S"`)
Global metadata about the store itself:

```
Key:   "S" + "nid_max"        → highest assigned object numeric ID
Key:   "S" + "blobid_max"     → highest assigned shared blob ID
Key:   "S" + "min_alloc_size" → block allocation granularity
Key:   "S" + "per_pool_omap"  → omap layout mode
```

### 6. Statfs Counters — `PREFIX_STAT` (`"T"`)
Running totals of space usage, updated atomically with each transaction:

```
Key:   "T" + pool_id
Value: {total_bytes, allocated_bytes, stored_bytes, compressed_bytes, ...}
```

### 7. Omap Data — `PREFIX_OMAP` / `PREFIX_PGMETA_OMAP`
Object map (omap) is a per-object key-value store exposed to Ceph clients (used heavily by RGW for S3 bucket indexes, CephFS for directory entries). This lives entirely in RocksDB:

```
Key:   omap_prefix + omap_head + user_key
Value: user_value
```

---

## Why RocksDB Specifically

BlueStore could have used any key-value store. RocksDB was chosen for several reasons:

**1. Log-Structured Merge Tree (LSM)**
RocksDB is an LSM store — writes always go to a sequential append-only log (WAL), then get compacted into sorted SSTables. Sequential writes are fast on both HDDs and SSDs. This matches BlueStore's write pattern perfectly.

**2. Atomic batch writes**
RocksDB's `WriteBatch` lets BlueStore update the onode, freelist bitmap, deferred write record, and statfs counter all in a single atomic commit. Either everything lands or nothing does. This is BlueStore's crash consistency guarantee.

**3. Merge operators**
The free-space bitmap uses RocksDB's merge operator — rather than read-modify-write on every allocation, BlueStore just appends an XOR record. RocksDB merges them during compaction. This turns O(n) bitmap updates into O(1) writes.

**4. Column families**
RocksDB can keep different key namespaces in separate column families with separate compaction policies and block caches. BlueStore uses this to give onodes their own cache pool (tunable separately from general KV data).

**5. BlueFS integration**
RocksDB uses `rocksdb::Env` as an abstraction over the OS. BlueStore implements `BlueRocksEnv` — a custom `Env` that routes all of RocksDB's file I/O through BlueFS, keeping everything off the OS filesystem.

---

## The Relationship at a Glance

```
Object write arrives
        │
        ├─── Object data bytes ──────────────────▶ raw block device (AIO)
        │                                              (bypasses RocksDB entirely)
        │
        └─── Everything else ────────────────────▶ RocksDB (single atomic commit)
                  │
                  ├── updated Onode (new extent map entry pointing to the bytes above)
                  ├── freelist XOR (marks those blocks as allocated)
                  ├── deferred payload (if small write)
                  └── statfs delta

Object read arrives
        │
        └─── RocksDB Get("O" + object_key) ──▶ Onode
                  │
                  └── ExtentMap tells BlueStore: "bytes 0–65535 are at disk offset 1048576"
                            │
                            └─── AIO read from raw block device at that offset
```

RocksDB is the **index and journal**. The block device is the **data store**. Neither can function without the other.

---

## One Important Subtlety

RocksDB itself needs to persist its files (SSTables, WAL). Those files live on **BlueFS** — BlueStore's own tiny filesystem — which in turn writes to the same raw block device (or a separate faster one). So the full picture is:

```
BlueStore
    ├── Object data   ──▶ raw block device
    └── RocksDB
            └── BlueFS ──▶ raw block device (same or separate NVMe)
```

BlueFS exists solely to give RocksDB a place to put its files without involving the OS filesystem.
