# 02 — The Railtie is loaded by `require 'magick'`

**What to build:** A Rails host that follows the documented setup gets the
Railtie — and with it the fork-aware subscriber middleware — without knowing
it exists.

Follow-up to 01. Diagnosing the platform (`~/exodus/platform`) found the actual
cause of "toggles need a restart" there, and it is not any of the five
environmental causes listed in 01:

- The platform's Gemfile has `gem 'magick-feature-flags', '~> 1.6.0',
  require: 'magick'`. `lib/magick.rb` never required
  `magick/rails/railtie`; only `lib/magick/rails.rb` did, and nothing required
  *that*. Verified in the platform bundle:
  `defined?(Magick::Rails::Railtie) == nil`, no `SubscriberMiddleware` in the
  stack. This has been so since the gem's initial commit — the 1.4.x fork
  handling has never run anywhere.
- Since 11 Sep 2026 (`~/exodus/ansible/context/web-fleet-shape.md`) nearly
  every brand runs Puma cluster mode: `web_concurrency: 3`, `preload_app!`. The
  master boots the app and its subscriber; the three forked workers inherit a
  dead thread and, without the middleware, never call `ensure_subscriber!`.
  The Engine writes flags through `PATCH /panel/flags/:name` →
  `Magick.enable_feature` in one worker; that worker publishes, the master
  and Sidekiq hear it, no other web worker does. Reproduced with a fork in
  `spec/magick/adapters/redis_integration_spec.rb` ("across a fork").
- Redis is ElastiCache (`rediss://`, default user, no ACL restriction, no
  proxy), so pub/sub itself is fine — the happy path in 01 holds.
- The Railtie had never been *booted* either: `SubscriberMiddleware` was
  defined as `Magick::SubscriberMiddleware` (one namespace up) while the
  initializer referenced `Magick::Rails::SubscriberMiddleware` → `NameError`
  on first boot; and every bare `Rails.` inside `module Magick` (33 call sites
  in 9 files, plus 27 `defined?(Rails)` and the generators' `Rails::Generators`)
  resolves to `Magick::Rails` once that module exists → `NoMethodError` in
  `Registry#start_cache_invalidation_subscriber` on the very next line.
- The platform initializer lists `active_record` before `redis url:`, so the
  registry (and a first subscriber) is built before the URL is known and a
  second subscriber is started over it — ticket `audit-1-5-1/12` defect 3,
  whose code never landed. The same ordering silently ignores
  `async_updates enabled: true` and `memory_ttl 7200` there (registry already
  built) — reported to the platform, not fixed in the gem.

**Blocked by:** —

**Autonomy:** auto

**Status:** resolved

- [x] `require 'magick'` loads the Railtie when Rails is defined; a spec boots a real app with it in a child process
- [x] `SubscriberMiddleware` lives in `Magick::Rails` and is installed
- [x] No bare `Rails` reference inside `module Magick` (all `::Rails`); a static spec guards it
- [x] A forked child never UNSUBSCRIBEs/closes a connection its parent opened (`@subscriber_pid`); Redis spec proves the parent keeps listening after a child shuts down
- [x] A forked worker that runs `ensure_subscriber!` receives a peer invalidation (Redis spec)
- [x] `Registry#redis_adapter=` retires the running subscriber before swapping; `Config#redis` uses it (audit-1-5-1/12 defect 3)
- [x] `Magick.adapter_registry=` retires the registry it replaces
- [x] Starting a subscriber while one is alive is a no-op; retired threads leave their retry loop (generation)
- [x] CHANGELOG + README installation note

## Comments

**2026-09-18 — same branch as 01, `wt/source-refresh-fallback`, second commit.**
Verification: `bundle exec rspec` 803/0; Redis suite 25/0 (fork examples
included); rubocop counts unchanged on every touched lib file (lib/magick.rb
22 → 21). Mutation check: the "child shutting down" Redis spec fails with the
`@subscriber_pid` guard commented out.

Production inspection (CLIENT LIST on a brand's ElastiCache, process tree in a
web container) was NOT run: the session's auto-mode blocked SSH reads to prod.
The code-level evidence above is sufficient for the cause; a `CLIENT LIST |
grep sub=1` count equal to (masters + sidekiq) rather than (masters + workers +
sidekiq) would be the confirming observation.
