# 20 — Performance metrics report real numbers

**What to build:** Four defects that make the metrics subsystem report wrong
values or behave badly under load.

- **Usage counts read as zero without Redis.** Reading a usage count forces a
  flush; unlike the periodic flush, the forced path does not check whether Redis
  is actually available. It clears pending updates and credits them as flushed,
  then writes nowhere, so the in-memory count drops to zero. Confirmed: after
  five recorded calls the first read returned zero.
- **A transient Redis error loses counts permanently.** Pending counters are
  drained and credited before the network write, and the write is best-effort
  rescued, so a failure leaves those counts absent from Redis *and* subtracted
  from memory.
- **Durations freeze on the oldest samples.** The metrics array caps by refusing
  new entries once full rather than evicting old ones, so with no Redis to drain
  it, the average is computed forever over the first thousand samples.
- **Keyspace globs block the server.** Three stats paths, including the one
  behind the Admin UI stats page, glob the Redis keyspace instead of using the
  cursor-based scan the adapter itself standardized on. Reads of the metrics
  collections also happen outside the mutex while the background thread mutates
  them.

**Blocked by:** None — can start immediately.

**Autonomy:** auto

**Status:** resolved

- [x] Usage counts are correct on a deployment with no Redis configured
- [x] A failed flush does not lose counts — they remain either pending or in memory
- [x] The duration sample buffer evicts oldest-first, so averages track recent behaviour
- [x] Stats paths enumerate keys with a cursor-based scan rather than a blocking glob
- [x] Reads of shared metrics state are synchronized against the background writer

## Comments

All four defects fixed in `lib/magick/performance_metrics.rb`, plus 20 new
examples in `spec/magick/performance_metrics_spec.rb` (17 of them fail against
the pre-fix file; the other 3 pin behaviour that was already correct). Full
suite: 395 examples, 0 failures.

**Usage counts without Redis.** `flush_to_redis` now resolves a Redis client
first (`stats_redis_client`) and returns before touching any state when there
is none, so the forced path from `usage_count` can no longer drain
`@pending_updates` and credit `@flushed_counts` for a write that goes nowhere.
`force_flush_to_redis` is now just that guarded call. Five recorded calls read
back as 5 on the first read and on every read after it.

**A failed flush no longer loses counts.** The write moved into
`write_flush_to_redis`, which credits `@flushed_counts` and drops the matching
duration samples only *after* the write for them lands; `settle_flush` puts
anything that did not land back into `@pending_updates`. Tracking is
per-feature, so a failure part-way through a multi-feature batch keeps the
features that succeeded credited (no double count on retry) and the rest
pending. Duration samples now travel with their aggregation group, so samples
recorded while a write is in flight are not swept away with it.

**Duration ring buffer.** `process_async_record` appends and then evicts from
the front instead of refusing new entries at `METRICS_RING_CAP`. With no Redis
to drain `@metrics`, the average now tracks the most recent 1,000 samples.

**Keyspace globs.** The three `redis.keys(...)` calls (both `average_duration`
enumeration branches and `most_used_features`, which is what the Admin UI stats
page reaches through `Magick.feature_stats`) go through a new `scan_stats_keys`
helper using the same cursor loop the Redis adapter standardized on. The
single-feature/single-operation path still uses direct `GET`s — no enumeration
at all. `grep` confirms no `.keys(` glob remains in `lib/` or `app/`.

**Synchronized reads.** `average_duration`, `usage_count`, `most_used_features`,
`flush_to_redis_if_needed` and `enable_redis_tracking` now read `@metrics` /
`@usage_count` / `@pending_updates` / `@flushed_counts` under `@mutex`; Redis
I/O stays outside the lock. The specs assert each reader actually blocks while
the mutex is held, and a concurrency smoke test runs 500 read rounds against
2,000 concurrent records.

Also updated the README metrics section to state the no-Redis and rolling-window
semantics.

### Notes / left out

- **No version bump or CHANGELOG entry.** Many audit tickets are in flight in
  parallel worktrees and all of them would collide on `lib/magick/version.rb`
  and the CHANGELOG header. Left for whoever cuts the release.
- **Out of scope, observed:** `most_used_features` adds the full in-memory
  `@usage_count` to the Redis totals without subtracting `@flushed_counts`, so
  once a flush has happened it double-counts what `usage_count` carefully
  de-duplicates. Not one of the four listed defects, so untouched.
- Residual best-effort edge: if a duration key's `INCRBYFLOAT` lands but its
  `INCRBY` fails, that key's sum can be counted twice on a later flush of the
  same feature. Fixing it properly needs a `MULTI` around the pair; the
  previous behaviour dropped those samples outright, so this is a smaller
  window than before.

2026-09-03 — Delivery: committed and pushed, but drover-e2e moved on by 1 commit — the branch is pushed, and a rebase is the way on

2026-09-03 — Rebase: nothing to rebase.
