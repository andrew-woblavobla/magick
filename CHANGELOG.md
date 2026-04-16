# Changelog

All notable changes to `magick-feature-flags` are documented in this file.

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
