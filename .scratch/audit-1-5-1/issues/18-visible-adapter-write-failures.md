# 18 — Adapter write failures are visible in production

**What to build:** Failed Redis and ActiveRecord writes are silent outside
development. Every rescue in the registry's write paths logs only when Rails is
defined and the environment is development.

Because memory is written first and never rolled back, a persistent backend
failure produces a process that serves a value no other process has — with no log
line, no metric, and no event. The divergence is invisible until someone notices
a flag behaving differently on one container.

**Blocked by:** None — can start immediately.

**Autonomy:** auto

**Status:** resolved

- [x] Failed writes to Redis or ActiveRecord are logged in every environment, at error severity
- [x] Log output goes through the existing sanitizer used elsewhere in the gem
- [x] A failure emits an event on the existing instrumentation channel so hosts can alert on it
- [x] Logging a failure never raises, and never turns a partial write into an exception for the caller
- [x] Specs assert that a backend failure produces a log entry and an event

## Comments

Branch `wt/visible-adapter-write-failures`. Suite green: 398 examples, 0
failures (23 new). Not committed.

### What landed

**`Magick::AdapterFailure` (new, `lib/magick/adapter_failure.rb`)** — one place
where a failed backend write becomes visible. Every report does two things and
neither is gated on the environment:

- logs at **error** severity — `Rails.logger.error` when there is a logger,
  `$stderr` otherwise, so a plain-Ruby host still sees it;
- emits **`magick.feature_flag.adapter_write_failed`** through
  `Magick::Rails::Events`, with `backend`, `operation`, `feature_name`,
  `error_class`, `error_message`, `reason`.

`feature_name`, `error_message` and `reason` all go through
`Magick::LogSafe.sanitize` (the sanitizer already used by `spawn_async_write`
and `Feature`), so a driver message or a name off the wire cannot forge a log
line or flood the pipeline. `backend` and `operation` are gem-controlled
symbols and are not sanitized.

`report` is best effort three times over: `log` and `notify` each swallow their
own failures, and the whole method has an outer rescue. A broken log pipe or a
dead event subscriber cannot turn a partial write into an exception.

**Registry write paths** now route through two private helpers,
`write_to_redis` / `write_to_active_record`, which return true/false and report
every false. They rescue `StandardError`, not just `AdapterError` — a driver
exception that escaped an adapter's own wrapping used to propagate out of
`Registry#set` into the caller. Covered: `set`, `set_all_data`, `delete`,
`publish_cache_invalidation`, and the async write thread.

### Two things found along the way, both needed for the criteria

1. **The event channel was inert.** `Magick::Rails::Events` is nested inside
   `Magick::Rails`, so its bare `Rails` constant resolved *lexically* to that
   enclosing module, never to the framework. `rails81?` was therefore always
   false and **every** event in the gem — not just this new one — was a silent
   no-op inside a real Rails app. Emitting onto a dead channel would have
   ticked box 3 without satisfying it, so `rails81?` and `notify` now spell
   `::Rails`. Worth calling out at review: hosts that subscribed to
   `magick.feature_flag.*` and saw nothing will start receiving events.

2. **An open circuit breaker went silent.** `CircuitBreaker#call` returns
   `false` without invoking the adapter once the breaker is open, so under the
   exact scenario in the ticket — a backend that *stays* down — reporting would
   have stopped after the fifth failure, during the window in which divergence
   accumulates. `write_to_redis` now checks `open?` first and reports the drop
   with `reason: "circuit breaker open"`.

### Deliberately not changed

- `delete`'s Redis write is still **not** behind the circuit breaker, as
  before. Routing it through `write_to_redis` would have meant deletes getting
  dropped for up to the breaker timeout after an unrelated `set` tripped it —
  a write-semantics change this ticket did not ask for. It gets a plain rescue
  plus a report.
- The same `Rails`-shadowing bug as (1) affects roughly twenty other
  `defined?(Rails) && Rails.env.development?` guards across `feature.rb`,
  `performance_metrics.rb`, `dsl.rb`, `config.rb` and the rest of
  `registry.rb`. Inside a real Rails app those evaluate `Magick::Rails.env` and
  raise `NoMethodError` — several from inside a rescue block, which converts a
  swallowed error into a crash. The write paths in this ticket are fixed; the
  rest is a separate finding and probably its own ticket.

### Files

- `lib/magick/adapter_failure.rb` (new)
- `lib/magick/adapters/registry.rb`, `lib/magick/rails/events.rb`, `lib/magick.rb`
- `spec/magick/adapter_failure_spec.rb` (new, 9 examples — severity, message
  shape, event payload, sanitization, truncation, `$stderr` fallback, and that
  an exploding logger or event reporter neither raises nor suppresses the other)
- `spec/magick/adapters/registry_write_failure_spec.rb` (new, 14 examples — a
  failing Redis/AR backend on `set`, `set_all_data`, `delete`, async and
  publish produces a log entry *and* an event, never raises into the caller,
  and leaves the diverged memory value in place; plus the tripped-breaker case
  and an unwrapped `IOError`)
- `spec/support/fake_rails.rb` (new) + `spec/spec_helper.rb` — the suite runs
  without Rails, so these specs stand up a recording `Rails.logger` /
  `Rails.event` and load the real event module for the duration of one example.
- `CHANGELOG.md`, `README.md`, `RAILS8_EVENTS.md`

2026-09-03 — Delivery: committed and pushed, but drover-e2e moved on by 1 commit — the branch is pushed, and a rebase is the way on

2026-09-03 — Rebase: nothing to rebase.
