# How BlueStore Bypasses the OS Filesystem

## The Old Way: FileStore (what everyone did before)

Before BlueStore, Ceph used **FileStore**. The stack looked like this:

```
Ceph OSD
    │
    ▼
FileStore
    │  calls open(), write(), fsync()
    ▼
OS Filesystem  (XFS / ext4 / btrfs)
    │  manages inodes, directory trees,
    │  page cache, journaling
    ▼
Block Device Driver
    │
    ▼
Physical Disk
```

FileStore stored each Ceph object as a **real file** on a real filesystem. `object_1234` was literally a file at `/var/lib/ceph/osd/osd.0/current/1.0_head/object_1234`. The OS filesystem handled all the hard problems: where on disk to put it, how to recover from crashes, buffering writes in the page cache.

---

## The Problem with That Approach

Letting the OS filesystem handle everything sounds convenient, but it introduced serious problems:

**1. Double journaling**

XFS and ext4 both maintain a **journal** (a write-ahead log) to survive crashes. Ceph's FileStore also maintained its **own journal** to keep object operations atomic. So every write was journaled **twice** — once by Ceph, once by the filesystem. Double the I/O, double the latency, for no extra safety.

```
Write arrives
    │
    ├──▶ Ceph journal (FileStore WAL)        ← write #1
    │
    ├──▶ XFS/ext4 journal (filesystem WAL)   ← write #2
    │
    └──▶ Actual file data                    ← write #3
```

**2. No control over I/O scheduling**

The kernel's page cache sits between `write()` and the disk. The OS decides when to actually flush dirty pages. Ceph had no way to say "flush this object's data to disk *before* you flush that object's metadata." This made it hard to guarantee crash consistency without `fsync()`, which is expensive.

**3. Metadata overhead**

Every Ceph object stored as a file means thousands of inodes, directory entries, and `readdir()` calls. XFS handles large directories okay, but it's not designed for millions of tiny files with Ceph-specific access patterns.

**4. No checksum support**

Filesystems like ext4 don't checksum file data — only metadata. If a disk silently corrupts a byte in the middle of a file (a "silent corruption"), ext4 has no idea. Ceph had to add checksums on top, but because the filesystem owned the I/O path, it was awkward.

**5. No compression at the right layer**

Transparent compression had to happen at the filesystem layer (btrfs has it, ext4 does not) or not at all. FileStore had no clean way to compress individual objects.

---

## What "Bypassing the Filesystem" Actually Means

BlueStore opens the raw block device directly — the same `/dev/sdb` or `/dev/nvme0n1` that you'd normally hand to `mkfs.xfs`. It uses:

```c
// BlueStore opens the device like this (simplified):
fd = open("/dev/sdb", O_RDWR | O_DIRECT);
```

`O_DIRECT` is the key flag. It tells the kernel: **do not use the page cache**. Reads and writes go straight from BlueStore's buffers to the disk controller, bypassing the kernel's buffering layer entirely.

Then instead of `write()` (which is synchronous and buffered), BlueStore uses **Linux AIO** (Asynchronous I/O):

```c
// Submit a write without blocking:
io_submit(aio_ctx, n_iocbs, iocbs);

// Later, check for completions:
io_getevents(aio_ctx, min, max, events, timeout);
```

This lets BlueStore submit dozens of I/O operations concurrently and get notified when each one finishes — without blocking a thread and without the kernel deciding when to flush.

The complete bypass looks like this:

```
BlueStore
    │
    │  O_DIRECT + Linux AIO
    │  (no filesystem, no page cache, no kernel buffering)
    ▼
Block Device Driver  (NVMe driver, SCSI driver, etc.)
    │
    ▼
Physical Disk / NVMe controller
```

---

## But Wait — What About RocksDB's Files?

RocksDB stores metadata (onodes, extent maps, freelist) in files — SSTables and a WAL. Files need a filesystem. BlueStore can't just hand RocksDB a raw `/dev/sdb` and say "good luck."

This is exactly why **BlueFS** exists. BlueFS is a tiny, purpose-built filesystem that BlueStore implements itself, living on the same raw block device:

```
BlueStore
    ├── Object data  ──────────────────────────────▶ raw block device (O_DIRECT AIO)
    │
    └── RocksDB metadata
            │
            ▼
         BlueFS  (BlueStore's own mini-filesystem)
            │  implements: create/open/write/sync/delete
            │  stores: SSTables, WAL, MANIFEST
            ▼
         raw block device (O_DIRECT AIO)
```

BlueFS is not a general-purpose filesystem. It has no directories (flat namespace), no permissions, no hard links. It only does what RocksDB needs, and it does it with the same O_DIRECT + AIO approach. `BlueRocksEnv` is the glue — it implements the `rocksdb::Env` interface so RocksDB thinks it's talking to a normal OS filesystem but is actually talking to BlueFS.

---

## What BlueStore Gains by Owning the I/O Path

| Problem with FileStore | BlueStore's solution |
|---|---|
| Double journaling | No filesystem journal. RocksDB is the only WAL. Small writes go into RocksDB's WAL once. Large writes bypass WAL entirely (written direct, metadata committed after). |
| Can't control flush ordering | BlueStore controls exactly when data AIOs are submitted and when RocksDB syncs. Data before metadata, always. |
| No data checksums | BlueStore computes checksums per blob chunk and stores them in the onode. Verified on every read. Entirely under BlueStore's control. |
| No compression | BlueStore compresses blobs before writing, stores the compressed length in the blob descriptor. The filesystem never sees the uncompressed data. |
| Metadata overhead for millions of files | No inodes, no directory entries. Objects are identified by keys in RocksDB. A lookup is a RocksDB `Get()`, not a `stat()` + `open()`. |
| Page cache unpredictability | BlueStore has its own `BufferSpace` cache per object, with explicit LRU eviction and size budgets. Nothing goes through the kernel page cache. |

---

## The One Trade-off

By bypassing the OS filesystem, BlueStore gives up all the years of filesystem tooling: `fsck`, `debugfs`, `find`, `ls`, `cp`. You can't browse BlueStore's data with shell commands. This is why `ceph-bluestore-tool` exists — it's the offline repair and inspection CLI that replaces what `e2fsck` and `xfs_repair` would normally give you.
