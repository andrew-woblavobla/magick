# Changelog

All notable changes to `magick-feature-flags` are documented in this file.

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
