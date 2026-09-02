# 16 — Per-request caching is wired up

**What to build:** The documented per-request deduplication of feature checks
never installs. The integration module defines an inclusion hook and a nested
class-methods module, but is attached with `extend`, which fires the *extended*
hook, not the included one — and the module has no instance methods, so nothing
is installed at all.

Switching to `include` would not fix it either: the method being overridden is
defined directly on the singleton class, which precedes any extended or included
module in lookup. Only prepending onto the singleton class can override it.

Consequence: every call re-evaluates, so within one request a
percentage-of-requests rollout is re-rolled on every check and can return
different answers to different call sites on the same page.

**Blocked by:** None — can start immediately.

**Autonomy:** auto

**Status:** resolved

- [x] Repeated checks of the same feature with the same context within one request evaluate once and reuse the result
- [x] A percentage-of-requests flag returns a consistent answer for the duration of a request
- [x] The cache is per request and does not leak between requests
- [x] Behaviour is unchanged when the request-store dependency is absent
- [x] A spec proves the underlying evaluation is invoked once across repeated calls

## Comments

**2026-09-02 — implemented, all criteria met.** Branch `wt/wire-per-request-caching`.

### What changed

- **`lib/magick/request_store_integration.rb` (new).** The caching module,
  rewritten and moved out of the railtie. It is installed with
  `install!`, which **prepends** onto `Magick.singleton_class` — the only
  attachment that can wrap an `enabled?` defined directly on that singleton
  class. `install!` is idempotent and returns whether it did anything.
- **`lib/magick/rails/railtie.rb`.** Deleted the dead `included` hook +
  `ClassMethods` module and the `Magick.extend(...)` that fired the wrong hook;
  it now requires the new file and calls `Magick::RequestStoreIntegration.install!`.
  Also dropped the `RequestStore.store[:magick_features] ||= {}` seeding from
  `config.to_prepare` — the module creates its own hash lazily, and that line ran
  at boot in production, outside any request. `Magick::Rails::RequestStoreIntegration`
  is kept as an alias so the old constant path still resolves.
- **`spec/magick/request_store_integration_spec.rb` (new).** 17 examples.
- **README.** New "Per-Request Caching" section. The feature list has claimed
  "request store caching" since forever with nothing documenting it.
- **`request_store ~> 1.5`** added as a *development* dependency (Gemfile +
  gemspec). It stays optional at runtime.

### Behaviour

Cache key is `[feature_name.to_s, context]`, so `:foo` and `"foo"` are one
entry and two contexts are two. The old key was `"#{name}:#{context.hash}"`,
which could collide; the old read was `return cached unless cached.nil?`,
which never hit for a memoised `false`. Both are gone. `Magick.disabled?`
rides the same memo, since it routes through `enabled?`.

Caching only happens when `RequestStore` is loaded **and** `RequestStore.active?`
— i.e. inside a request opened by RequestStore's Rack (or Sidekiq) middleware.
Outside one (boot, console, rake) nothing would ever clear the entries, so a
memoised answer would outlive the moment that produced it; there, checks
evaluate live, exactly as when the gem is absent. `RequestStoreIntegration.clear!`
drops the memo mid-request for code that mutates a feature and then re-reads it
in the same request (documented in the README — it is the one behaviour change
callers could be surprised by).

### Verification

`bundle exec rspec` → **392 examples, 0 failures, 1 pending** (the pending one
is the pre-existing `admin_ui_spec` "requires Rails" example); stable across
three random seeds. The specs drive the real `RequestStore::Middleware` with a
fake Rack app, so a "request" in the spec is opened and cleared exactly as in
production. Highlights:

- 3 identical checks in one request → `Feature#enabled?` received **once**;
  with `hide_const('RequestStore')` the same 3 checks → **3 times**.
- 100 checks of a `enable_percentage_of_requests(50)` flag inside one request →
  one distinct answer; 100 single checks across 100 requests → both answers.
  Uncached, 100 checks in one request → both answers.
- After a request closes, `RequestStore.store` has no `:magick_features` key.
- `install!` returns true once, false after; the module ends up first in
  `singleton_class.ancestors`.

Also verified the real railtie path (loaded against a minimal `Rails` stub):
the module installs, the alias resolves, the flag is stable within a request
and re-rolls across requests.

RuboCop: the new lib file is clean. The spec trips `Metrics/BlockLength`, which
fires on 52 existing spec blocks — repo baseline, not a new offence.

### Found while working — separate bug, NOT fixed here

`module Magick::Rails` **shadows `::Rails`** for every lexical constant lookup
inside `module Magick`. So `defined?(Rails) ? Rails.env : ...` — which appears
in `config.rb`, `registry.rb`, `feature.rb` and elsewhere — resolves to
`Magick::Rails`, and `Magick::Rails.env` raises `NoMethodError`. Reproduced:

    Magick::Config.new
    # => NoMethodError: undefined method `env' for module Magick::Rails

That is live in any Rails app for the arity-0 DSL form the README documents
(`Magick.configure do ... end` → `ConfigDSL.configure` → `Config.new`). The
arity-1 form (`Magick.configure do |c| ... end`), which the railtie itself uses,
yields `self` and never builds a `Config`, which is presumably why it has gone
unnoticed. The fix is `::Rails` at those sites. It first showed up here because
requiring the caching module defined `Magick::Rails` in a non-Rails process and
broke 7 unrelated specs — which is also why the module now lives at
`Magick::RequestStoreIntegration` rather than under `Magick::Rails`. No audit
issue covers this; it wants its own ticket.

2026-09-03 — Delivery: committed and pushed, but drover-e2e moved on by 1 commit — the branch is pushed, and a rebase is the way on

2026-09-03 — Rebase: nothing to rebase.
