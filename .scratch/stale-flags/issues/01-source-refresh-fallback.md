# 01 — Registered features converge on the shared store without a restart

**What to build:** A flag change reaches every process even when the Pub/Sub
invalidation never arrives, and a process can tell when it is not listening.

Operators report that a toggle "affects only the VM where it was called" and
that other instances pick it up only on redeploy. The platform's ops tooling has
codified this: `magick_write` documents that a change reaches players only after
`brand_restart`. Verified 2026-09-18 with two real processes over one Redis 7.0.8,
on `main` and on released v1.6.0:

- **The design works.** A toggle made through the gem API in process A flips
  process B within ~1.5s. Cross-process propagation is not broken.
- **Nothing else ever refreshes a registered feature.** `Feature` caches
  `@stored_value` / `@targeting` in the object; `get_value` short-circuits on
  `@stored_value_initialized`, so the memory adapter's TTL never applies, and
  `Registry#@refresh_thread` is dead code. A received invalidation (or an explicit
  `reload`) is the *only* refresh path. Any change that does not produce a
  received PUBLISH leaves every other process stale until restart:
  - a write made outside a gem process (ops tool, script, direct store edit) —
    nothing publishes;
  - a Redis ACL user without `@pubsub` (Redis 7 default `resetchannels`) —
    reproduced: reader stays `false` while Redis holds `true`;
  - a Redis proxy that does not carry SUBSCRIBE (Twemproxy, Envoy);
  - one Redis per VM (the railtie defaults to `Redis.new(db: 1)` = localhost
    when `config.redis_url` is unset);
  - a subscriber connection silently dropped by an LB/NAT idle timeout or a
    failover — `subscribe` is a blocking read with no keepalive, so the thread
    stays "alive" and never hears anything again.
- **It is silent.** v1.6.0 logs nothing at all in production for a failed
  PUBLISH or SUBSCRIBE. `main` reports the failed PUBLISH through
  `AdapterFailure`; a failed SUBSCRIBE still retries every 5s behind
  `warn ... if Rails.env.development?`.

Ticket `audit-1-5-1/12` describes a `subscriber_running?` and a subscribe-loop
rewrite as resolved, but that work exists on no branch (`wt/subscriber-thread-
lifecycle` sits at the 1.6.0 commit); only the `return`→`next` fix landed.

**Blocked by:** —

**Autonomy:** auto

**Status:** resolved

- [x] A registered feature whose stored state changed in the shared backend without any invalidation arriving evaluates to the new state within a bounded interval (default 30s), in every process
- [x] The refresh is driven from evaluation, needs no new thread, costs at most one bulk source read per process per interval, and never raises into `enabled?`
- [x] A local write in flight (memory ahead of the shared store) is never reverted by a refresh
- [x] A source that answers with a partial or empty view cannot strip live features: nothing is evicted by the refresh, and an unreachable source touches nothing
- [x] The interval is configurable (`refresh_interval` in the DSL and on the registry) and can be disabled
- [x] A subscriber that cannot subscribe is reported through `AdapterFailure` (error log + event) in every environment, rate-limited so a permanently broken Redis does not flood the log, and recovery is logged
- [x] `Registry#subscriber_running?` and `Magick.health` expose whether this process is listening and when it last refreshed, for host health checks
- [x] Specs cover the out-of-band write, the in-flight local write, deletion, the disabled interval, a failing source, and — against a real Redis — a write with no PUBLISH converging in a second registry
- [x] ADR + README + CHANGELOG describe the guarantee: Pub/Sub is the fast path, the periodic source refresh is the bound

## Comments

**2026-09-18 — worked on `wt/source-refresh-fallback`.**

### What landed

**`lib/magick/adapters/registry.rb`**

- `DEFAULT_REFRESH_INTERVAL = 30.0`, constructor kwarg `refresh_interval:`,
  `#refresh_interval` / `#refresh_interval=` (nil, false, 0 and negatives switch
  it off; garbage raises `ArgumentError`).
- `#refresh_if_stale!` — hot-path entry: clock compare; once due, `try_lock`,
  claim the slot (`@last_refresh_at`) *before* the read, then
  `#refresh_from_source!`. Concurrent callers skip; a dead source is probed once
  per interval. Never raises.
- `#refresh_from_source!` — one bulk read (`read_source_features`: AR first,
  then Redis; returns `nil` when no backend answered, `{}` only for a genuinely
  empty store), diff against the previous read of the source
  (`changed_since_last_read`; first read compares to memory), write changed
  features into memory and reload the registered instance
  (`reload_registered_feature`, now shared with `process_cache_invalidation`).
  Vanished features are not evicted — a deliberate choice, see ADR-0002 §5.
  Failures → `AdapterFailure.report(operation: :refresh)`.
- `#subscriber_running?` — `@subscribed` is set in redis-rb's `on.subscribe`
  callback and cleared on unsubscribe/return/raise, AND the thread must be alive.
- `#health` — `redis`, `active_record`, `subscriber_running`,
  `subscriber_last_error`, `refresh_interval`, `last_source_refresh_at`,
  `pending_async_writes`.
- Subscriber thread: `report_subscriber_failure` (first at once, then one per
  `SUBSCRIBER_FAILURE_REPORT_INTERVAL = 300s`), `note_subscriber_connected`
  (logs recovery via new `AdapterFailure.report_recovery`), `SUBSCRIBER_RETRY_DELAY`
  constant replaces the bare `sleep 5`. A `subscribe` that returns without a
  shutdown now raises into the retry loop and resubscribes.
- `@refresh_thread` (dead code) removed.

**`lib/magick/feature.rb`** — `refresh_from_source_if_stale` (private) called
from `enabled?`, `get_value`, `get_variant`; a transient instance reloads
itself when its own name is among the changes (the registry only reloads the
registered instance). `@_source_refresh` caches `respond_to?(:refresh_if_stale!)`
so a bare adapter still works.

**`lib/magick.rb`** — `Magick.refresh!`, `Magick.health`.
**`lib/magick/config.rb`** — `refresh_interval` DSL method, applied in `apply!`
only when the file said something.
**`lib/magick/adapter_failure.rb`** — `.report_recovery(backend:, operation:)`.

### Specs

- `spec/magick/adapters/registry_refresh_spec.rb` (24) — diff/apply, first-read
  vs memory, in-flight local write not reverted then picked up as a no-op,
  vanished feature kept, reserved namespaces excluded, unreachable source
  touches nothing, one read per interval, 16 concurrent callers → 1 read,
  failing source probed once, off switches, interval validation, health.
- `spec/magick/source_refresh_spec.rb` (13) — through `Magick.enabled?` /
  `variant`: value, targeting and variants follow an unpublished write within
  the interval, unregistered features too, 200 evaluations → 1 read,
  `refresh_interval false`, bare adapter, `Magick.refresh!`, `Magick.health`,
  DSL.
- `spec/magick/adapters/registry_subscriber_health_spec.rb` (6) — scripted
  redis-rb stand-in: listening after ack / not after shutdown, failing
  subscription reported once and visible in health, re-reported after the
  interval, recovery logged and error cleared, resubscribe after a dropped
  connection, no report during shutdown.
- `spec/magick/adapters/redis_integration_spec.rb` (+2, real Redis) — a raw
  `HSET` with no PUBLISH converges a registered feature; `subscriber_running?`
  against a live server.
- `spec/magick/adapter_failure_spec.rb` (+3) — `.report_recovery`.

### Verification

- `bundle exec rspec`: **794 examples, 0 failures** (was 748).
- `rake spec:redis` equivalent against Redis 7.0.8: **23 examples, 0 failures**
  (was 21); repeated 3×, and the thread-sensitive files 5×, no flakes.
- Rubocop: offence count unchanged on every touched lib file (registry.rb 32 → 32:
  two new `Metrics/MethodLength` on `refresh_from_source!` / `health`, two
  pre-existing ones removed by the `process_cache_invalidation` refactor).
- Two real processes over one Redis, the reporter's scenario: a raw `HSET`
  (no PUBLISH) and a gem toggle under a Redis ACL user without `@pubsub` both
  left the reader stale forever on `main`; with `refresh_interval = 1` both
  converge at t≈2.1s, and the ACL case now logs
  `Magick: redis subscribe failed: Redis::PermissionError: NOPERM …` once per
  process.

### Notes for whoever consolidates

- `docs/` and `CLAUDE.md` are gitignored: ADR-0002 and the CLAUDE.md update
  live in the main checkout only. `CONTEXT.md` (tracked) gained
  *Invalidation (Pub/Sub)*, *Source refresh* and *Registered feature*.
- `audit-1-5-1/12` is marked resolved but its code (`run_subscriber_loop`,
  `subscriber_running?`, reconfigure teardown) is on no branch; only the
  `return`→`next` fix landed. This branch adds `subscriber_running?` with a
  stricter meaning (ack'd, not merely alive). Defects 2 and 3 of that ticket
  (pid claimed before start confirmed; `Config#redis` stacking subscribers)
  remain open.
- No version bump; CHANGELOG entry under Unreleased.
