# Opportunistic Discard in BlueStore

Tracker: https://tracker.ceph.com/issues/80578

Depends on: https://github.com/ceph/ceph/pull/70794 (claim_range)

## Problem

Currently, discard and release are tightly coupled. With async discards
(`bdev_async_discard_threads > 0`), the range is released (`alloc->release()`)
only after BLKDISCARD finishes. During this time, the space belongs neither to
the allocator nor to any object. On a slow-discard device, up to
`bdev_discard_max_bytes` (10 GiB by default) per `KernelDevice` is held back and
can't be reused. i.e. under discard pressure the OSD looks fuller than its real
data, and that space can't be allocated.

## Idea

Decouple discard and release. Instead of holding onto the space until discard
happens, we release it back to the allocator. The idea being:

1. Release immediately
2. Queue the range for discard as a **hint**
3. When discard happens, `claim_range()` pins the parts of the range that are
   still free, and we discard and release only those parts. This avoids any
   loss to live data in the range that got written after release.

Sample code:

```
Producer code:

_txc_release_alloc():
    ...
    alloc->release(range);
    discard_released(range);
```

```
Discard thread:

_discard_thread():
    range = take from discard_queued
    exts = claim_range(range); // allocates the free space in the range, and returns those values
    _discard(exts);
    alloc->release(exts);
```

The order on the producer side matters: release first, then queue. If we queue
first, `_queue_discard` wakes a discard thread right away (`notify_one()`) and
it can call `claim_range()` before the producer reaches `alloc->release()`. The
range is still allocated, so `claim_range()` returns nothing and the discard is
wasted. It's never corruption, but since both start racing at the same moment
it would be common, not a corner case.

## Plan

### 1. Split `try_discard()` by what the caller guarantees

Today try_discard() is a bloated function. It caters to different callers with
different needs.

| caller | lines | guarantee |
|---|---|---|
| runtime release (BlueStore, BlueFS) | `BlueStore.cc:15399`, `BlueFS.cc:3886` | range was **just released**; someone may already own part of it |
| whole-device trim at mkfs | `BlueStore.cc:7369`, `BlueFS.cc:563` | nothing is allocated; no allocator in use yet |
| `trim_free_space` (`ceph-bluestore-tool trim`) | `BlueStore.cc:9518`, `BlueFS.cc:5551` | range is free; runs inside `foreach()` |

As you can see above:
- runtime release, this is an async operation - the space was just released and
  we want it to be discarded whenever possible
- mkfs and trim, this is a sync operation. These callers already give us the
  guarantee that the range is not in use and nobody can allocate from it

Along with that, if we now add `claim_range` to the picture - trying to do
`claim_range`:
- During mkfs, there may be no allocator yet. Even if there was one,
  `claim_range(whole_device)` would allocate the whole device
- `trim_free_space`: it runs inside the `foreach()` callback, with the allocator
  lock held. A `claim_range()` there would try to take the same lock.

I believe separating the concerns from each other would make the code more
readable and easier to understand and help us in building the feature.

I propose the following functions:

| new name | replaces | caller's promise |
|---|---|---|
| `discard_released(range)` | `try_discard()` at the two release sites | range has already been released; part of it may be reused by now |
| `discard_unused(range)` | `try_discard(..., async=false, ...)` at mkfs and `trim_free_space` | nobody uses the range or can allocate it for the duration of the call |
| `_claim_and_discard(range)` | (new, private) | sync fallback of `discard_released` |

`_claim_and_discard` is needed for the runtime sync path
(`bdev_enable_discard=true`, `bdev_async_discard_threads=0`). Today that path
discards the range directly, but under this design the range is already
released, so `discard_unused()`'s promise doesn't hold there. It has to claim
first, like the discard thread does.

The detailed contract for these functions is described below.

### 2. How to add `claim_range` to KernelDevice

At present, the release happens after the discard via discard_callback in
`discard_thread`. Similarly we will be adding a new callback called
`claim_range_cb` that claims ranges in the discard thread. This way `src/blk/`
still doesn't need to know what an allocator is.


| callback | replaces | job |
|---|---|---|
| `claim_range_cb` | (new) | before `_discard`: pin what's still free in a queued range, return it |
| `release_claimed_cb` | `discard_cb` / `discard_callback` | after `_discard`: release exactly what `claim_range_cb` returned |

Note, `discard_cb` was responsible for releasing the range back to allocator. It
will be renamed to `release_claimed_cb` since we are now only releasing the
extents held by claim_range. 

For BlueFS, the producer now always decrements `bluefs_used` after `release()`,
so its `release_claimed_cb` only calls `release()`, like BlueStore's. BlueFS
registers one pair per device, the same way it does `wal_/db_/slow_discard_cb`
today.

The callbacks are a pair: both registered or neither.
- A release callback without a claim callback has nothing to release; a claim
  without a release leaks.
- Both of them will be bundled together with their `priv` into one struct,
  passed to `create()` as a single pointer or `nullptr`.
- `discard_released` will need both the callbacks, not having them will raise
  `ceph_assert` (in all builds).
- `discard_unused` doesn't use these callbacks, so it can work with or without
  them.

The claimed extents cross the boundary as `interval_set<uint64_t>`, but
`claim_range` uses `PExtentVector`. There are two options:
1. Do the conversion in claim_range_cb
2. Replace the `PExtentVector` with `interval_set`

I am leaning toward 1, since it's the easiest change to do as of this moment.
`src/blk/` can't name `PExtentVector` (it's a BlueStore type), and doing the
conversion on the BlueStore/BlueFS side keeps the `claim_range()` contract and
PR #70794 unchanged. During implementation if I discover things that invalidate
this, I will take up the work for the second approach.

```
claim_range_cb(range) -> interval_set:
    exts = alloc->claim_range(range)      // PExtentVector
    return exts converted to interval_set
```

### 3. Discard Queue

The meaning of discard queue has changed from 

>  These are the ranges that have not been released and need discards. Once
discard happens, it is the duty of the consumer to release it" 

TO

> These are the hints for which discard needs to happen. The ranges have already
been released. Do not worry if there is any miss in consuming any element since
all it costs is a missed discard

Some notes regarding the queue:
- Merge, never strict-insert: A range can now be released, allocated and
  released again while the first copy is still in queue. The strict
  `discard_queued.insert(to_release)` asserts on overlap and would crash. We
  change it to use the non-asserting union: `discard_queued.union_of(to_release)`
  which calls `union_insert` per interval
- Two threads on the same bytes are safe: if thread A has claimed X and is
  inside BLKDISCARD, X is allocated, so when thread B claims a re-queued X,
  `claim_range()` returns nothing for those bytes.
- A full queue drops the hint, it never falls back to sync. The space is
  already released, so nothing is lost but the discard. A new perf counter
  counts the dropped hints.

### 4. Shutdown

We have the following shutdown paths

1. Graceful shutdown
2. Fast Shutdown

**Fast shutdown.** Today, during a fast shutdown (null freelist / NCB,
`osd_fast_shutdown`) - code swaps the queue out and calls `alloc->init_add_free()`
on each range before we call `store_allocator()`, because queued ranges aren't
free yet.

- We need to now remove the `init_add_free()` loop because the ranges in the
  queue are already released and doing it again would lead to double-free (an
  assert in some backends eg: AVLAllocator, silent corruption in others).
- We keep `swap_discard_queued()` and just drop what it returns. The swap is
  what makes fast shutdown fast: `discard_drain()` only waits for the batches
  threads already hold, not the whole backlog.
- `discard_drain()` must stay before `store_allocator()`. A thread between
  `claim_range_cb` and `release_claimed_cb` holds bytes marked allocated in
  memory. `store_allocator()` would persist them as allocated, and in NCB mode
  that's a permanent leak, not just a missed discard (NCB fsck doesn't detect
  leaks).

With the RocksDB freelist, `osd_fast_shutdown` does `_exit(0)` without umount,
so the queue is thrown away, as today.

**Graceful shutdown.** Stays as today: `discard_drain()` works through the
whole backlog, and each batch is now claim → discard → release. 

**Stopping threads.** Unchanged. `stop` is checked only between batches, so a
thread always finishes claim → discard → release before it exits, and never
leaves claimed bytes behind.

## Interface

```
// discard everything in range; caller guarantees nobody is using it
int discard_unused(range)

// discard only what's still free in range, then give it back
void _claim_and_discard(range):
    exts = claim_range_cb(range)
    for ext in exts: _discard(ext)        // only claimed exts
    release_claimed_cb(exts)

// range was already released; discard what's still free, later if possible
void discard_released(range):
    ceph_assert(callbacks registered)                      // first
    if !support_discard || !bdev_enable_discard: return    // before any claim
    if _discard_started():                                 // own discard_lock hold, as today
        _queue_discard(range)
    else:
        _claim_and_discard(range)                          // discard_lock not held

// insert a hint; drop it if the queue is full
void _queue_discard(range):
    lock(discard_lock)
    if max_pending > 0 && discard_queued.num_intervals() >= max_pending:
        ++dropped_hints                                    // new perf counter
        notify_one
        return                                             // full: drop the hint
    discard_queued.union_of(range)                         // merge on overlap
    notify_one
```


## Contract

### `void discard_released(range)`

Tell the device that `range` was just released, so that whatever part of it is
still free when the device gets to it can be discarded.

- **Preconditions**
  - The caller has already released `range` to the allocator. Part of it may
    already be reallocated and hold live data.
  - The device was created with the claim/release callbacks. Asserted in all
    builds, before anything else.
  - The caller doesn't hold the allocator lock or `discard_lock`. The sync path
    takes the allocator lock through the callbacks.
- **Postcondition (on return)**
  - The allocator state is the same as before the call. Async: nothing has been
    claimed yet. Sync: the still-free parts were claimed, discarded and released
    again before returning.
  - No byte that was allocated at claim time has been discarded or released by
    this call, now or later.
- **Returns:** nothing. Release is unconditional, so no caller has anything to
  do with a result.
- **Not guaranteed**
  - That any of `range` is ever discarded:
    - discard is off or unsupported → no-op (return before any claim);
    - the queue is full → the hint is dropped, and the new perf counter is
      bumped (next to `discard_op`), so operators can see discards being skipped;
    - the OSD crashes before a thread processes the entry → the hint is lost;
    - the discard threads are stopped at runtime just as the hint is queued → it
      sits unprocessed (pre-existing race);
    - the range is reallocated before the claim → only the parts still free at
      claim time are discarded, possibly none.
  - *When* the discard happens. In async mode, any time after return.
  - That free space stays constant. While a thread processes a batch, the
    claimed parts are allocated, so `get_free()` drops by up to one batch per
    thread.
  - That BLKDISCARD succeeds, or that a later read of discarded blocks returns
    zeros.
- **Crash:** claims live only in memory. The FreelistManager never sees them,
  and after an unclean NCB shutdown the allocator is rebuilt from onodes, which
  don't reference claimed space. So a crash loses pending and in-flight
  discards, never space. (A *clean* NCB umount is different: in-flight claims
  must be released before `store_allocator()`.)
- **Called from:** `BlueStore::_txc_release_alloc`,
  `BlueFS::_release_pending_allocations`.

### `int discard_unused(range)`

Discard all of `range` now. For ranges no one can be using.

- **Preconditions**
  - Nothing holds data in `range`, and nothing can allocate from it until the
    call returns. The caller guarantees this (mkfs: no allocator yet;
    `trim_free_space`: the allocator lock is held for the whole `foreach()`).
  - `range` lies within the device.
- **Gate:** checks `support_discard` only. No `force` parameter, and
  `bdev_enable_discard` is not consulted. Each caller already has its own gate
  (`bluestore_discard_on_mkfs`, BlueFS's `trim` flag, an explicit
  `ceph-bluestore-tool trim`), so `force` would always be true.
- **Postcondition (on return)**
  - BLKDISCARD has been issued for all of `range`, synchronously, split by
    `bdev_max_discard_length`.
  - The allocator is untouched. `discard_unused` never calls into it, so it's
    safe to call with the allocator lock held.
- **Returns:** `0` if every BLKDISCARD succeeded. Otherwise the **first** error,
  but it keeps going through the rest of the range, so as much as possible gets
  trimmed. `-EOPNOTSUPP` if the device doesn't support discard. mkfs ignores the
  result (an HDD returns `-EOPNOTSUPP` and must not fail mkfs), and
  `trim_free_space` reports it to `outss`.
- **Not guaranteed:** that BLKDISCARD succeeds, or that a later read returns
  zeros.
- **Callbacks:** not used; works with or without them.
- **Called from:** mkfs whole-device trim (BlueStore, BlueFS);
  `trim_free_space` (BlueStore, BlueFS), inside `foreach()` with the allocator
  lock held.

### `_claim_and_discard(range)` (private)

A comment, not a full contract:

```
// Sync fallback of discard_released(). Claims what is still free in
// range, discards only that, and releases it again. Takes the allocator
// lock through the callbacks: never call with it or discard_lock held.
```

It releases its own claimed extents, the same way the discard thread does. The
caller never sees `exts`, so it can't release them, and if nobody does, the
space leaks.

### `_queue_discard(range)` (private)

- Returns nothing. The space is already released, so whether the hint was
  queued or dropped changes nothing for the caller.
- A full queue drops the hint, never falls back to sync.
- The "threads running?" check (`_discard_started()`) and the insert stay in
  separate `discard_lock` holds, as today. The sync fallback runs after that, so
  `discard_lock` is released before `claim_range_cb` takes the allocator lock.

## Implementation

The branch is based on the claim_range commits (#70794). Each step below is one
commit (or a small group) and the tree builds and works after every one of
them.

**0. Before this branch: drain BlueFS's devices before `store_allocator()`**

Separate backportable PR, and it has to merge first. Today `_close_db()` drains
only BlueStore's `KernelDevice` before `store_allocator()`; BlueFS's devices are
drained later in `_close_bluefs()`. Add a small `BlueFS` method that runs
`discard_drain()` over its `bdev[]` and call it next to `bdev->discard_drain()`.

**1. Add `discard_unused()` and move the trim callers to it**

- Add `discard_unused(range)` to `BlockDevice` (no-op default) and
  `KernelDevice`, as per its contract.
- Switch mkfs (BlueStore, BlueFS) and `trim_free_space` (BlueStore, BlueFS) to
  it.
- No behaviour change. `try_discard()` stays for the two release sites for now.

**2. Queue: `insert` → `union_of`**

- `_queue_discard` uses `discard_queued.union_of(to_release)`.
- Harmless today (queued ranges can't overlap yet), but needed before step 4.

**3. Add the callback pair**

- Add the struct holding `claim_range_cb`, `release_claimed_cb` and their
  `priv`, and pass it to `create()` as one pointer or `nullptr`.
- Rename `discard_cb` / `discard_callback` → `release_claimed_cb`.
- Implement `claim_range_cb` in BlueStore and BlueFS (one per device for
  BlueFS), with the `PExtentVector` → `interval_set` conversion inside it.
- The `nullptr` creators (tools, tests, label read/write, ...) don't change.
- Registered but not called yet. No behaviour change.

**4. The behaviour change**

This will be a single commit. Releasing at the producer while the thread
still releases everything would double-free, and claiming in the thread while
the producer still holds the range would discard nothing.

- Discard thread: after `l.unlock()`, call `claim_range_cb`, discard only the
  returned extents, then `release_claimed_cb` with exactly those extents.
- Add `discard_released()` and `_claim_and_discard()`, and remove
  `try_discard()`.
- `BlueStore::_txc_release_alloc` and `BlueFS::_release_pending_allocations`:
  `alloc->release()` unconditionally, then `discard_released()`.
- BlueFS: decrement `bluefs_used` at the producer; `handle_discard` only calls
  `release()`.
- Full queue drops the hint instead of holding the space.
- NCB fast shutdown: remove the `init_add_free()` loop, keep
  `swap_discard_queued()` and drop what it returns.

**5. Perf counter for dropped hints**

Next to `discard_op`, bumped in `_queue_discard` when the queue is full.

**6. Add some important comments**

- Drain before `store_allocator()` (`_close_db()`), before `alloc->shutdown()`
  (`_close_alloc()`), before deleting allocators (`BlueFS::_stop_alloc()`).
- The `stop` checks in the discard thread: a thread must finish claim →
  discard → release before it exits.

**7. Tests**

- Unit test with fake callbacks: only claimed extents are discarded and
  released; re-queuing an overlapping range doesn't assert.
- Reuse the claim_range stress setup (`ClaimRangeStressSmallDevice*`,
  `doSyntheticTest` with deep fsck) with `bdev_enable_discard=true`,
  `bdev_async_discard_threads>=2` and a large `bdev_debug_discard_sleep`, so
  ranges are reallocated while queued.
- Negative control: discard the whole queued range instead of only the claimed
  extents. It must fail the content / csum check.
- Run in NCB mode too (`bluestore_debug_enforce_settings=ssd`).
- Perf: free space under a sustained write + delete workload on a slow-discard
  device, old vs new. That's the point of the feature, so the PR should show it.
