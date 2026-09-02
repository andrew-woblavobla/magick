# 02 — Redis exercised in CI

**What to build:** The Redis adapter, Pub/Sub cache invalidation, and circuit
breaker integration are executed by CI on every push. Today the Redis
integration spec is gated on both `REDIS_URL` being set and the `redis` gem being
loadable; the gem is absent from the Gemfile and the workflow has no Redis
service, so the gem's headline architecture ships completely unexercised.

Every ticket in Phase 4 is unverifiable until this lands.

**Blocked by:** None — can start immediately.

**Autonomy:** auto

**Status:** resolved

- [x] The `redis` gem is available in the test environment
- [x] The specs workflow runs a Redis service and sets the environment variable the integration specs gate on
- [x] The existing Redis integration specs actually execute in CI rather than being skipped, and this is visible in the job output
- [x] A deliberately failing assertion in a Redis integration spec fails the build (confirming the specs are not silently skipped)
- [x] Suite passes locally both with and without Redis available, so contributors without Redis are not blocked


## Comments

**Verification caveat, up front:** every criterion below was verified locally by
running the workflow's exact step commands under `bash -eo pipefail` (what
`shell: bash` gives on GitHub Actions), against a real `redis-server`. Nothing
has been pushed, so no actual GitHub Actions run has been observed. `act` is not
installed and Docker is not running here, so the workflow could not be executed
end to end. The unverified link is GitHub-hosted execution itself.

### What landed

- **`redis ~> 5.0` as a development dependency** (`Gemfile` with `require: false`,
  `magick.gemspec` dev dep, `Gemfile.lock`). It stays out of the runtime
  dependencies — the gem still works without Redis.
- **`.github/workflows/specs.yml`**: a `redis:7` service with a `redis-cli ping`
  healthcheck, `REDIS_URL: redis://localhost:6379/1` at job level, and a new
  **"Run Redis integration specs"** step.
- **`spec/support/redis.rb`** (`RedisSpecSupport`): the availability gate.
- **`rake spec:redis`**: the blessed local command.
- **`spec/magick/adapters/redis_integration_spec.rb`**: gate rewritten, group
  tagged `:redis`. The four existing examples are otherwise untouched.
- README "Development", CLAUDE.md "Quick Reference", CHANGELOG `## Unreleased`.

### Two things the ticket did not anticipate

**1. The Redis specs need their own process.** Simply adding the gem and setting
`REDIS_URL` does not work. `Magick.default_adapter_registry` builds a Redis
adapter whenever `defined?(Redis)` (`lib/magick.rb:362`, and the same check in
`config.rb:211`). Requiring the gem anywhere in the run flips that for the whole
process, so every spec reaching `Magick.default_adapter_registry` starts reading
and writing a real Redis. Measured: **13 failures in `versioning_spec.rb`** from
state leaking between examples (`Magick.reset!` does not flush Redis), and the
full suite went from 8s to hanging past 120s.

The fix keeps the two worlds apart rather than papering over it:

- `bundle exec rspec` never requires the `redis` gem. The gate short-circuits on
  `MAGICK_REDIS_SPECS`, so `::Redis` stays undefined and all 375 existing specs
  run exactly as before — memory-only, which is what they were written against.
- The Redis specs run as `rspec --tag redis` with `MAGICK_REDIS_SPECS=1`. All
  spec files load, but only the four `:redis` examples execute, so contamination
  has nothing to contaminate.

Two switches instead of one: `REDIS_URL` (where Redis lives — the gate the specs
have always used, and the one CI sets, per criterion 2) and `MAGICK_REDIS_SPECS`
(opt in to loading the gem). The second exists because a contributor with
`REDIS_URL` exported in their shell would otherwise hit the contamination above
just by running `bundle exec rspec`. CI keeps `REDIS_URL` at job level
deliberately, so every push re-proves the main suite is green with it exported.

**2. Turning Redis on immediately failed — a real bug, and it overlaps ticket 12.**
`publishes cache invalidation that a second registry observes` failed with
`LocalJumpError: unexpected return` out of `Registry#shutdown`. The subscriber
thread's early-exit guards use `return` inside a block, which raises rather than
ending the thread; `terminate_subscriber_thread`'s `Thread#join` then re-raises it
into the caller. That is the first defect described in **ticket 12**.

I fixed the minimal form of it — four `return` → `next` in
`start_cache_invalidation_subscriber` (`lib/magick/adapters/registry.rb:556,573,606,610`)
— because criterion 3 is unreachable with a red build, and quarantining the
Pub/Sub spec would have contradicted the ticket outright. **Ticket 12 is not
done**: its other two defects (fork guard marking ownership before the thread
starts; reconfiguring Redis orphaning the old subscriber) and its spec coverage
for the unavailable-client, failed-start, and reconfigure cases are untouched.
Rubocop offences on `registry.rb` went 43 → 42; no new ones anywhere.

### Evidence

Redis step, verbatim from the workflow:

```
Magick::Adapters::Redis integration
  round-trips a value through hset/hget
  enumerates keys via SCAN
  deletes a feature
  publishes cache invalidation that a second registry observes

4 examples, 0 failures
Redis integration examples executed and passed: 4
```

The four names in the log are criterion 3's visibility. The JSON count assertion
is the belt to that braces: if the group is ever filtered out, rspec exits 0 on
"0 examples" and the check fails the step with *"No Redis integration examples
ran - they were skipped, not executed."* Confirmed by running the step with the
opt-in removed → **exit 1**.

Criterion 4, deliberate failure. Flipped `expect(adapter.get(:foo, 'value')).to
be true` to `be false` and ran the step:

```
4 examples, 1 failure
  expected false / got true
STEP EXIT=1 (with deliberate failure)
```

`set -e` aborted before the count check, so the step fails on the assertion
alone. Assertion restored afterwards; `grep -c DELIBERATE` → 0.

Criterion 5, all eight combinations:

| # | Condition | Result |
|---|---|---|
| A | `rspec`, no Redis env, Redis up | 375 examples, 0 failures — exit 0 |
| B | `rspec`, `REDIS_URL` set, Redis up | 375 examples, 0 failures — exit 0 |
| C | `rake spec:redis`, Redis up | 4 examples, 0 failures — exit 0 |
| D | CI Redis step, Redis up | exit 0, "executed and passed: 4" |
| E | `rspec`, no Redis env, Redis down | 375 examples, 0 failures — exit 0 |
| F | `rspec`, `REDIS_URL` set, Redis down | 375 examples, 0 failures — exit 0 |
| G | `rake spec:redis`, Redis down | exit 1, clear abort message |
| H | CI Redis step, Redis down | exit 1 |

B and F are the contributor footgun cases. G/H is criterion 4's other half: with
`MAGICK_REDIS_SPECS=1` an unreachable Redis aborts rather than skipping —

```
MAGICK_REDIS_SPECS=1 but Redis at redis://localhost:6379/1 is not usable
(Redis::CannotConnectError: Connection refused ...).
Start Redis or unset MAGICK_REDIS_SPECS.
```

### For the reviewer

- **`rake spec:redis` calls `FLUSHDB`** on the database in `REDIS_URL` (pre-existing
  `around` hook). Flagged in the README; the task defaults to db 1.
- The `return` → `next` fix overlaps ticket 12 — worth a glance before 12 starts.
- Not pushed, so no green CI run to point at. Worth confirming on the first push
  that the `redis:7` service comes up on both matrix legs (3.2.0 and 3.3.3).

2026-09-03 — Delivery held back — fast-forwards cleanly: drover-e2e moved on by 1 commit; tests pass: was not checked; a second session reviews: was not checked

2026-09-03 — Delivery: committed and pushed, but drover-e2e moved on by 1 commit — the branch is pushed, and a rebase is the way on

2026-09-03 — Rebase: nothing to rebase.
