# Ceph Write Path: Client → BlueStore

## Full Write Path (ASCII Diagram)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              CLIENT LAYER                                       │
│                                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │  CephFS App  │  │   RBD App    │  │   RGW App    │  │ Direct App   │       │
│  │ POSIX write()│  │ block write  │  │  S3/Swift PUT│  │  (librados)  │       │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘       │
└─────────│─────────────────│─────────────────│────────────────── │──────────────┘
          │                 │                 │                   │
          ▼                 │                 │                   │
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         INTERFACE / TRANSLATION LAYER                           │
│                                                                                 │
│  ┌──────────────────────────────┐                                               │
│  │   CephFS Kernel Client/FUSE  │                                               │
│  └───────────┬──────────────────┘                                               │
│              │                                                                  │
│    ┌─────────┴──────────┐                                                       │
│    │                    │                                                       │
│    ▼ metadata ops       ▼ data ops                                              │
│    │ (open/stat/mkdir)  │ (file content bytes)                                  │
│    │                    │                                                       │
│  ┌─┴──────────────┐     │                                                       │
│  │      MDS       │     │                                                       │
│  │ Metadata Server│     │          ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │ manages inodes,│     │          │  librbd  │  │RGW Daemon│  │ librados │   │
│  │ directory tree │     │          │          │  │HTTP→RADOS│  │          │   │
│  └────────────────┘     │          └────┬─────┘  └────┬─────┘  └────┬─────┘   │
│   (metadata only,       │               │              │              │         │
│    no data flows here)  │               │              │              │         │
└─────────────────────────│───────────────│──────────────│──────────────│─────────┘
                          │               │              │              │
                          └───────────────┴──────────────┴──────────────┘
                                                   │
                                                   ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            RADOS LAYER (librados)                               │
│                                                                                 │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │  1. Object Naming                                                        │   │
│  │     Map to RADOS object  e.g. file bytes → file_chunk_0, file_chunk_1    │   │
│  └─────────────────────────────────┬────────────────────────────────────────┘   │
│                                    │                                            │
│  ┌─────────────────────────────────▼────────────────────────────────────────┐   │
│  │  2. CRUSH Map Lookup                                                     │   │
│  │     Which Placement Group (PG) owns this object?                        │    │
│  │     PG = hash(object_name) % num_pgs                                    │    │
│  └─────────────────────────────────┬────────────────────────────────────────┘   │
│                                    │                                            │
│  ┌─────────────────────────────────▼────────────────────────────────────────┐   │
│  │  3. OSD Map Lookup                                                       │   │
│  │     Which OSDs host this PG?                                            │    │
│  │     Returns: [primary_osd, replica_osd_1, replica_osd_2]               │     │
│  └─────────────────────────────────┬────────────────────────────────────────┘   │
│                                    │                                            │
│  ┌─────────────────────────────────▼────────────────────────────────────────┐   │
│  │  4. Send write to Primary OSD (via TCP / msgr2 protocol)                │    │
│  └─────────────────────────────────┬────────────────────────────────────────┘   │
└────────────────────────────────────│─────────────────────────────────────────── ┘
                                     │
                          ┌──────────┘
                          │
         ┌────────────────┴────────────────────────────────────────────┐
         │                                                             │
         ▼                                                             ▼
┌─────────────────────────────────┐              ┌──────────────────────────────────┐
│         PRIMARY OSD             │              │       REPLICA OSDs (x2)          │
│                                 │              │                                  │
│  ┌───────────────────────────┐  │   forward    │  ┌────────────────────────────┐ │
│  │     OSD Op Queue          │  │─────────────▶│  │  Same BlueStore write path │ │
│  │  (receives the write op)  │  │              │  │  runs independently on     │ │
│  └─────────────┬─────────────┘  │              │  │  each replica              │ │
│                │                │              │  └──────────────┬─────────────┘ │
│  ┌─────────────▼─────────────┐  │              │                 │               │
│  │    Acquire PG Lock        │  │              │                 │ replica ACK   │
│  │ (serialize ops on this PG)│◀─┼──────────────┼─────────────────┘               │
│  └─────────────┬─────────────┘  │              └──────────────────────────────────┘
│                │                │
│  ┌─────────────▼─────────────┐  │
│  │ObjectStore::               │  │
│  │  queue_transactions()     │  │
│  │                           │  │
│  │ ← BlueStore implements    │  │
│  │   this API                │  │
│  └─────────────┬─────────────┘  │
└────────────────│────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        BLUESTORE  (inside Primary OSD)                          │
│                                                                                 │
│  ┌──────────────────────────────────────────────────────────────────────────┐  │
│  │  _txc_create()                                                           │  │
│  │  Create TransContext — the in-flight transaction object                  │  │
│  │  Holds: KV txn, AIO context, onode refs, alloc/release sets             │  │
│  └─────────────────────────────────┬────────────────────────────────────────┘  │
│                                    │                                            │
│  ┌─────────────────────────────────▼────────────────────────────────────────┐  │
│  │  _do_write()                                                             │  │
│  │  fault_range() — load relevant ExtentMap shards from RocksDB            │  │
│  └──────────────────┬──────────────────────────────┬────────────────────────┘  │
│                     │                              │                            │
│          size < min_alloc_size          size >= min_alloc_size                  │
│                     │                              │                            │
│  ┌──────────────────▼──────────────┐  ┌────────────▼───────────────────────┐  │
│  │  _do_write_small()              │  │  _do_write_big()                   │  │
│  │  Sub-alloc-unit write           │  │  Full block-aligned write          │  │
│  │                                 │  │  Try compression if enabled        │  │
│  │  Scan nearby extents for a      │  └────────────┬───────────────────────┘  │
│  │  reusable mutable blob          │               │                           │
│  └──────┬───────────────┬──────────┘               │                           │
│         │               │                          │                           │
│  blob   │        no     │                          │                           │
│  found  │        blob   │                          │                           │
│         │       found   │                          │                           │
│         ▼               ▼                          ▼                           │
│  ┌────────────┐  ┌────────────────────────────────────────────────────────┐   │
│  │  DEFERRED  │  │  DIRECT AIO PATH                                       │   │
│  │  WRITE     │  │                                                        │   │
│  │            │  │  alloc->allocate()                                     │   │
│  │  Data goes │  │  Get physical extents from in-memory Allocator         │   │
│  │  INTO the  │  │  (AvlAllocator / BitmapAllocator)                      │   │
│  │  RocksDB   │  │                                                        │   │
│  │  KV txn    │  │  bdev->aio_write()                                     │   │
│  │  under     │  │  Queue async write to raw block device                 │   │
│  │  PREFIX_   │  │                                                        │   │
│  │  DEFERRED  │  │  Update Blob: fill in pextent offsets, checksums       │   │
│  └──────┬─────┘  └────────────────────────┬───────────────────────────────┘   │
│         │                                 │                                    │
│         └─────────────────┬───────────────┘                                    │
│                           │                                                    │
│  ┌────────────────────────▼───────────────────────────────────────────────┐   │
│  │  _txc_write_nodes()                                                    │   │
│  │  Serialize all dirty Onodes into the RocksDB transaction               │   │
│  │  (updated extent map, object size, xattrs → PREFIX_OBJ keys)          │   │
│  └────────────────────────┬───────────────────────────────────────────────┘   │
│                           │                                                    │
│  ┌────────────────────────▼───────────────────────────────────────────────┐   │
│  │  _txc_finalize_kv()                                                    │   │
│  │  Update free-space bitmap in the same RocksDB transaction              │   │
│  │  BitmapFreelistManager XORs allocation bits (merge operator)          │   │
│  └────────────────────────┬───────────────────────────────────────────────┘   │
│                           │                                                    │
│              ┌────────────┘                                                    │
│              │                                                                 │
│    ┌─────────▼──────────────────────────────────────┐                         │
│    │           TWO THINGS HAPPEN IN PARALLEL         │                         │
│    └──────────────────┬─────────────────────┬────────┘                         │
│                       │                     │                                  │
│           ┌───────────▼──────┐   ┌──────────▼──────────────────┐              │
│           │  DATA PATH       │   │  METADATA PATH               │              │
│           │                  │   │                              │              │
│           │ bdev->aio_submit()   │ kv_sync_thread               │              │
│           │ Submit AIO to    │   │ db->submit_transaction()     │              │
│           │ kernel           │   │ db->sync()                   │              │
│           │                  │   │                              │              │
│           │ [kernel drives   │   │ RocksDB WAL flushed to disk  │              │
│           │  the I/O...]     │   │ → metadata is durable        │              │
│           │                  │   └──────────┬───────────────────┘              │
│           │ AIO completion   │              │                                  │
│           │ callback fires   │              │                                  │
│           │ → data is on     │              │                                  │
│           │   disk           │              │                                  │
│           └───────────┬──────┘              │                                  │
│                       │                     │                                  │
│                       └──────────┬──────────┘                                  │
│                                  │                                             │
│  ┌───────────────────────────────▼────────────────────────────────────────┐   │
│  │  on_commit() fires                                                     │   │
│  │  Transaction is committed. Primary OSD sends ACK to client.           │   │
│  └───────────────────────────────┬────────────────────────────────────────┘   │
│                                  │                                             │
│  ┌───────────────────────────────▼────────────────────────────────────────┐   │
│  │  kv_finalize_thread (runs after on_commit)                             │   │
│  │  - Apply deferred block writes to disk (if any small writes existed)  │   │
│  │  - Release freed extents back to in-memory Allocator                  │   │
│  └───────────────────────────────┬────────────────────────────────────────┘   │
└──────────────────────────────────│─────────────────────────────────────────────┘
                                   │
               ┌───────────────────┴───────────────────┐
               │                                       │
               ▼                                       ▼
┌──────────────────────────────┐       ┌───────────────────────────────────────┐
│   RAW BLOCK DEVICE           │       │   RocksDB  (via BlueFS)               │
│   (NVMe / HDD)               │       │   (on same or separate device)        │
│                              │       │                                       │
│   Object data bytes          │       │   PREFIX_OBJ   → Onode + ExtentMap    │
│   (written via AIO)          │       │   PREFIX_ALLOC → Free-space bitmap    │
│                              │       │   PREFIX_DEFERRED → Small write data  │
│                              │       │   PREFIX_SHARED_BLOB → Clone refcounts│
└──────────────────────────────┘       └───────────────────────────────────────┘
```

---

## Key Takeaways from the Diagram

### 1. CephFS is special: it splits metadata and data
- **Metadata ops** (`open`, `stat`, `mkdir`) go to the **MDS** (Metadata Server)
- **Data ops** (actual file bytes) bypass MDS entirely and go straight to RADOS/OSDs
- RBD, RGW, and librados have no MDS — they talk directly to RADOS

### 2. RADOS is the universal routing layer
Every interface (CephFS, RBD, RGW) eventually translates to a RADOS object write. RADOS uses the **CRUSH algorithm** to deterministically map `(object_name, pool)` → `PG` → `[primary OSD, replica OSDs]` without any central coordinator.

### 3. The Primary OSD fans out to replicas
The client only talks to the primary OSD. The primary forwards the write to replicas in parallel. The transaction is not ACKed to the client until **enough replicas** (based on pool's `min_size`) have durably committed.

### 4. BlueStore runs two parallel paths
- **Data path**: Object bytes go to the raw block device via Linux AIO (async, bypasses kernel page cache)
- **Metadata path**: Onode (extent map, object size) + freelist update go into a single atomic RocksDB transaction

These two happen concurrently. Data hits disk first. Then RocksDB commits the metadata. The design is crash-safe: if the system dies between the two, orphaned data is cleaned up by `ceph-bluestore-tool fsck`.

### 5. Small vs Large writes take different paths
| Write size | Path | Why |
|---|---|---|
| `< min_alloc_size` (4KB–64KB) | Deferred (through RocksDB) | Avoids costly read-modify-write of a partial block |
| `>= min_alloc_size` | Direct AIO to block device | Full blocks can be written without reading first |

### 6. `on_commit()` fires before deferred writes complete
The client gets its ACK when RocksDB commits. Any deferred block writes (small writes stored in RocksDB's WAL) are flushed to disk *after* the ACK. This is safe because the data is already durable in RocksDB's WAL.
