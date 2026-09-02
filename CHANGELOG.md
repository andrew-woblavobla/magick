# Changelog

All notable changes to `magick-feature-flags` are documented in this file.

## Unreleased

### Security

- **Config**: `ConfigDSL.load_from_file` now checks containment against the
  project root (`Rails.root`, else the directory holding the `Gemfile`, else an
  explicit `ConfigDSL.project_root =`) instead of `Dir.pwd`, and compares
  separator-aware. The old bare-prefix-of-CWD check was bypassable two ways:
  a sibling directory whose name merely starts with the project directory's
  name (`/srv/app-evil` passed for `/srv/app`), and any process running from
  `/`, which made every absolute path pass. Both sat directly in front of an
  `instance_eval` sink. `MAGICK_ALLOW_CONFIG_EVAL=1` still skips the check for
  a trusted file outside the tree, and is still dangerous.

### Fixes

- **Pub/Sub subscriber shuts down cleanly.** The subscriber thread's early-exit
  guards used `return` inside a block, which raises `LocalJumpError` instead of
  ending the thread. `Registry#shutdown` re-raised it out of `Thread#join`, so
  shutting down a registry with a live Redis subscription raised. The guards now
  use `next`.

### Development

- The `redis` gem is a development dependency, and CI runs a Redis service, so
  the Redis adapter, Pub/Sub cache invalidation, and circuit breaker are
  exercised on every push. Run them locally with `bundle exec rake spec:redis`;
  the default `bundle exec rspec` still needs no external services.

## 1.6.0 — 2026-08-05

Wire targeting contract for control-plane APIs. The gem now ships the two
primitives a flag-management endpoint needs — a canonical serializer and a
wholesale targeting write — while the host app keeps routes and auth.

### Features
- **`Feature#as_json`** — canonical wire-format flag payload (string keys).
  The `"targeting"` key is **always present** (`{}` = no targeting), list
  rules are arrays of strings, percentages are floats, and the internal
  `:variants` entry never appears inside `targeting`. Works directly with
  `render json: feature` / `render json: Magick.features.values`.
- **`Feature#replace_targeting(payload)`** — wholesale, declarative
  targeting write: the payload is the new state, keys absent from it are
  removed, `{}` clears everything. Lenient input (string/symbol keys, plural
  aliases, scalars for lists, numeric strings), strict validation: unknown
  keys or invalid values raise the new `Magick::InvalidTargetingError`
  before anything is applied (all-or-nothing) — map it to a 422. Records one
  audit entry and one version snapshot per call. A/B variants survive the
  replace untouched.
- **`Magick::TargetingPayload`** — the shared normalizer/serializer behind
  both primitives; `Feature#targeting` is now a public reader.

### Changes
- **Admin UI targeting form** submits through `replace_targeting`: one
  `replace_targeting` audit entry + one version per save, instead of one
  entry per changed rule. Rules the form has no fields for (IP, date range,
  custom attributes, complex conditions, group targeting) are carried over
  unchanged.
- **`Magick.import`** applies targeting through `replace_targeting` as well:
  imported targeting now replaces the feature's existing targeting wholesale,
  and invalid targeting payloads raise `ImportError` instead of being
  silently applied or skipped. Exports from older gem versions (which leaked
  `variants` into the targeting hash) still import cleanly.
- **`as_json` variants** read the authoritative store
  (`targeting[:variants]`), so the wire `variants` list is populated
  (`to_h`'s legacy top-level `variants` was always empty).

## 1.5.0 — 2026-08-05

Every save now creates a version, and the audit log covers every mutation.
Previously versions were only written by explicit `save_version` calls, and
the audit log fired only from `set_value`.

### Features
- **Automatic versioning.** Every state-changing operation on a feature
  (value, status, group, all targeting/exclusion mutations, variants,
  dependencies, delete) records a version snapshot through a single choke
  point (`Feature#record_change`). A thread-local reentrancy guard ensures one
  logical operation records exactly once — `enable` no longer surfaces as an
  internal `set_value`.
- **Full audit coverage with real action names.** Audit entries (and
  `magick.feature_flag.audit_logged` events) now carry the actual operation:
  `enable`, `disable`, `enable_for_user`, `exclude_role`, `set_status`,
  `set_group`, `delete`, `rollback`, … Subscribers matching on `'set_value'`
  for UI toggles will see the new names.
- **Adapter-backed, tiered version history.** The hot window (last
  `max_versions`, default 50, configurable via
  `versioning enabled: true, max_versions: N`) lives in memory/Redis and is
  shared across containers; the ActiveRecord adapter keeps an unlimited
  archive (`__magick_versions:<name>` row) that survives restarts, Redis
  flushes, and even feature deletion. `get_versions(name, all: true)` merges
  the archive; rollback reaches versions that left the hot window.
- **Actor attribution.** `Magick.with_actor(id) { ... }` stamps audit
  `user_id` and version `created_by` for every change in the block; explicit
  `user_id:` kwargs still win. The Admin UI attributes changes via the new
  `Magick::AdminUI.configure { |c| c.current_actor = ->(controller) { ... } }`
  hook (around_action on every request).
- **Definition mode.** `Magick.definition_mode { ... }` suppresses recording
  while declarative definitions are (re)applied; the railtie wraps the boot
  load of `config/features.rb`, so container boots no longer would flood
  history with identical snapshots.

### Fixes
- **Rollback restores state wholesale.** Previously rollback re-applied only
  user/group/role targeting additively (never clearing current rules),
  ignored exclusions/percentages/date ranges/variants, and skipped falsy
  values (`if feature_data[:value]` — a boolean `false` was never restored).
  It now replaces value (including `false`/empty), status, group, the entire
  targeting hash, and dependencies — and records the rollback itself as a new
  version instead of rewriting history.
- **Version history survives restarts.** `get_versions` previously read only
  a per-process in-memory list; adapter-written snapshots were never read
  back. History is now rehydrated from the adapters.
- **`versioning enabled: false` is honored.** `Config#apply!` used to re-run
  the DSL methods with their defaults, stomping explicit
  `enabled: false` settings for versioning/audit_log.
- **Single audit event per change.** `set_value` previously emitted
  `magick.feature_flag.audit_logged` twice (once itself, once via
  `AuditLog#log`).

## 1.4.3 — 2026-06-01

Fixes the multi-process/multi-container "toggle doesn't take effect until I
click again" bug in the Admin UI.

### Correctness
- **Admin UI now renders authoritative state.** In a load-balanced deployment
  the enable/disable POST and the redirected GET land on different
  processes/containers, so the process rendering the page could show its own
  stale in-memory cache until Pub/Sub caught up. `index`/`show`/`edit` now read
  straight from the shared backend (ActiveRecord → Redis) via the new
  `Adapters::Registry#authoritative_get_all_data` / `#refresh_all_from_source`
  and `Feature#reload_from_source!`, bypassing the local memory cache.
- **Cross-process cache invalidation no longer drops the final state.** A single
  `enable`/`disable` emits two Pub/Sub publishes (targeting, then value); the
  old 100 ms reload debounce dropped the second, leaving other processes holding
  the old value until their memory TTL (up to hours) expired. The subscriber now
  reloads on every valid invalidation (`Registry#process_cache_invalidation`);
  each reload reads complete state, so it stays idempotent.

### Reliability
- **Forked workers self-heal their Pub/Sub subscriber.** Under Puma
  `preload_app!`, workers inherit a dead subscriber thread and — in production —
  `config.to_prepare` does not re-run to revive it. A new Rack middleware
  (`Magick::Rails::SubscriberMiddleware`) calls the pid-guarded
  `ensure_subscriber!` per request, so each worker starts its own subscriber on
  first request. Near-free no-op in single-mode Puma. README corrected
  accordingly.

## 1.4.1 — 2026-04-16

Follow-up to 1.4.0 closing the nine acknowledged audit misses.

### Security
- `ExportImport.import` caps list size (10_000, overridable via
  `MAGICK_MAX_IMPORT_FEATURES`) and rejects non-Hash entries with
  `Magick::ExportImport::ImportError` (audit P1-S5).
- New `Magick::LogSafe.sanitize` wrapper; every `warn`/`Rails.logger.*`
  call that interpolates a feature name or exception message now runs
  its input through it to block log injection (audit P2-S2).
- Admin UI `update_targeting` and `update_variants` validate that their
  payloads are Hash-like before iterating; malformed shapes redirect
  with a generic alert instead of 500-ing with a stack trace (audit P2-S3).

### Correctness
- `Adapters::Base#set_all_data` now raises `NotImplementedError` so
  custom adapters fail loudly instead of silently dropping bulk writes
  (audit P2-Co6).
- `Versioning#save_version` computes the next version number and
  appends under the same mutex so concurrent saves can't collide
  (audit P2-C10). `get_versions` returns a dup'd snapshot.

### Resource hygiene
- `PerformanceMetrics.record_async` pre-caps `@metrics` at the
  `METRICS_RING_CAP` constant; drops the dead post-insert shift
  (audit P0-C2).
- Async Redis writes (`Registry#spawn_async_write`) now `rescue
  StandardError` and log so failures are visible instead of silently
  killing the thread (audit P1-C4).
- `Memory#set` and `#set_all_data` trigger `cleanup_expired_if_needed`,
  so write-heavy processes evict expired TTLs between 30s sweeps
  (audit P1-C8).

### Tests
- `versioning_spec.rb` covers sequential versions, get_versions
  snapshot semantics, 50-way concurrent save, and rollback.
- `log_safe_spec.rb` covers control-char replacement, truncation,
  custom max, and non-string inputs.
- `export_import_roundtrip_spec.rb` gains input-validation tests.

### Docs
- RAILS8_EVENTS.md documents `feature_enabled_globally` /
  `feature_disabled_globally` (were missing from the event list).
- Install generator template notes `Magick::AdminUI.configure` auth
  wiring and when to call `Magick.shutdown!` in non-Rails processes.

## 1.4.0 — 2026-04-16

Hardening release driven by a full audit (concurrency, security, correctness,
coverage). No breaking changes. Major highlights:

### Security

- **Admin UI**: `FeaturesController` and `StatsController` now include
  `ActionController::RequestForgeryProtection` and call `protect_from_forgery
  with: :exception`. Until this release the Admin UI was vulnerable to CSRF
  because inheriting `ActionController::Base` does not bring CSRF in by
  default.
- **Admin UI**: `set_feature` no longer falls through to `Magick[name]`, which
  would lazily create and persist a new feature from an attacker-chosen
  `params[:id]`. Unknown IDs now 404/redirect.
- **Admin UI**: Exception messages are no longer echoed into flash banners;
  they go to the server log and users see a generic "see server logs" message.
- **Admin UI helpers**: `feature_status_badge` returns `content_tag` so future
  callers can't accidentally render user input through `raw`/`html_safe`.
- **Pub/Sub**: Incoming `feature_name` payloads must match a conservative
  identifier pattern (`[a-zA-Z0-9_\-.:]{1,120}`); anything else is dropped,
  preventing a neighbour tenant on a shared Redis DB from triggering reload
  loops or memory growth.
- **Config**: `ConfigDSL.load_from_file` now resolves paths with `File.realpath`
  and refuses anything outside the project tree unless
  `MAGICK_ALLOW_CONFIG_EVAL=1` is set. This closes an RCE-by-path vector.

### Correctness / Bug fixes

- **Graceful shutdown**: New `Magick.shutdown!` and `Adapters::Registry#shutdown`
  cleanly terminate the Redis Pub/Sub subscriber thread. Without this, Puma /
  Rails graceful stops hung on the blocking `Redis#subscribe` call. Wired into
  the Railtie via `at_exit`.
- **Fork safety**: `Registry#ensure_subscriber!` and
  `PerformanceMetrics#ensure_async_processor!` restart background threads
  after a Puma worker fork so children don't share the parent's inherited
  subscriber socket. Invoked from `config.to_prepare`.
- **`Magick.reset!`**: Now resets the lazily-initialised default adapter
  registry singleton; previously tests and reconfigurations leaked the old
  in-memory cache.
- **Export/Import**: `export` now emits `group`, `dependencies` and
  `variants`. `import` applies every targeting key (inclusions and
  exclusions, tags, IPs, date ranges, custom attributes, variants, and
  dependencies) instead of silently dropping them.
- **IP targeting**: `Feature#enable_for_ip_addresses` and
  `#exclude_ip_addresses` used to store the incoming array as a stringified
  `'["1.2.3.4"]'`, so IP gating never actually worked. Both setters now
  append each IP directly.
- **Orphaned classes**: `Magick::Targeting::Complex`, `CustomAttribute`,
  `DateRange` and `IpAddress` existed in `lib/magick/targeting/` but were
  never required. They're now wired into `lib/magick.rb`.

### Resource hygiene

- **AuditLog** is now bounded via a ring-buffer-style cap (default 10_000,
  configurable via `max_entries:`); `entries` returns a dup'd snapshot so
  readers don't race with writers.
- **Registry**: `record_local_write` also sweeps stale tracking entries, so a
  write-heavy / read-light process no longer leaks `@local_writes` and
  `@last_reload_times`.
- **Redis SCAN** retries once with backoff on transient errors.

### Tests

- 297+ specs covering `FeatureDependency`, all targeting strategies,
  `CircuitBreaker` state transitions + concurrency, Registry shutdown +
  fork safety, Redis integration (REDIS_URL-gated), `AuditLog` eviction,
  `ConfigDSL.load_from_file` path validation, variant distribution, and
  full export/import round-trip.

## 1.3.1 — earlier

- Fix inverted dependency logic in `Feature#enable` / `#disable` cascade.

## 1.3.0 — earlier

- A/B testing support with variant management.
- Documentation for anonymous user experiments and variant safety.

## 1.2.x — earlier

- `magick-feature-flags` renamed + styles in Admin UI.

---

For older releases see `git log`.
