# 05 — The `require_role` hook is applied consistently

**What to build:** The gem's optional authentication hook is wired into one
controller and silently discards some configurations. Both defects mislead an
operator who has deliberately tried to lock the panel down.

**Not in scope — settled by design:** the Admin UI is unauthenticated by
default, and that stays. It matches Sidekiq, Resque, and Flipper's own UI, and
the README already documents it in two places: it recommends gating at the
router (`authenticate :admin_user do mount ... end`) as the production pattern,
and states that authentication is opt-in and the UI is reachable by anyone who
can hit its routes when the hook is nil. Hosts gating at the router are fully
protected today and are unaffected by this ticket.

What is broken is the *alternative* the README also offers — the built-in
`require_role` hook:

- **The stats route ignores it.** The hook is only wired into the features
  controller, so a host relying on `require_role` alone gets its feature routes
  gated and its stats route left open. That route also distinguishes known from
  unknown feature names, so it doubles as an enumeration oracle for flag names.
- **A non-callable value is silently dropped.** A symbol or string is truthy, so
  it passes the nil guard, then fails the callable check and falls through to no
  authentication at all — no warning, no error, no denial. The operator believes
  the panel is locked. The existing spec assigns exactly such a value and asserts
  only that it round-trips, which is why this was never caught.

**Blocked by:** None — can start immediately.

**Autonomy:** auto

**Status:** resolved

- [x] With `require_role` configured, the stats route enforces it exactly as the feature routes do — ideally via a filter shared by both controllers
- [x] A non-callable `require_role` is rejected loudly: either raise at configuration time or deny the request, never silently ignore it
- [x] Leaving `require_role` nil still permits access, unchanged, so router-gated hosts see no behaviour change
- [x] Specs assert that configured authentication is *enforced* on every route, not merely that the setting round-trips
- [x] The README's `require_role` section notes that router-level gating is the more robust option

## Comments

### What changed

**Shared filter (`lib/magick/admin_ui/authentication.rb`, new).** The gate now
lives in `Magick::AdminUI::Authentication`, whose `included` hook is what
installs `before_action :authenticate_admin!`. `FeaturesController` includes it
in place of its old local filter (same position in the chain, same method name,
so a host that overrode `authenticate_admin!` still works); `StatsController`
includes it for the first time. Including the module *is* the wiring, so a
controller added later cannot be added ungated.

`Authentication.decision(hook, controller)` is the policy on its own — pure
Ruby, no Rails — returning `:allow` for a nil hook or a truthy callable and
`:deny` for everything else, including a non-callable. An exception raised *by*
the hook is deliberately not rescued: the request is denied either way and the
backtrace is what tells the operator their auth code is broken.

**Loud rejection (`lib/magick/admin_ui.rb`).** `require_role` gained a
validating writer: anything that is neither nil nor callable raises the new
`Magick::ConfigurationError` at assignment time, with a message naming the
offending value and showing the lambda form. The request-time deny above is the
backstop for a config that got a non-callable some other way (a deserialized
config object, an `instance_variable_set`).

Leaving `require_role` nil is untouched — the panel stays open and router-gated
hosts see no behaviour change. That is asserted, per route, in the specs.

**Docs.** The README's Admin UI **Security** section now leads with the
router-level `authenticate` block as the more robust option (it covers every
route the engine mounts, including ones added by a later version) and presents
the hook as the alternative, documenting that a bare role name raises. The same
framing was added to the "Admin UI Security" section and to the install
generator's initializer template. CHANGELOG entry added under `Unreleased` — no
version bump, since the release cut for this audit is still undecided in
`spec.md`.

### Specs

The Admin UI had no executable coverage at all: `spec/magick/admin_ui_spec.rb`
was wrapped in `if defined?(Rails)` and Rails was not a dependency, so the whole
file was skipped. Round-tripping `config.require_role = :admin` was the only
"coverage" the hook had, and it never ran.

So the specs now boot a real thing. `spec/support/rails_app.rb` starts a
throwaway `Rails::Application` (root: `spec/support/dummy`) with the engine
mounted at `/magick`, and `spec/magick/admin_ui/authentication_request_spec.rb`
drives it over rack-test. It does not hard-code the route list: it enumerates
`Magick::AdminUI::Engine.routes.routes` and asserts, for **every** route,

- 403 when the hook denies,
- 403 when the config holds a non-callable,
- < 400 when the hook allows,
- < 400 when the hook is nil,

so a route added by a future version is covered the day it is added. Reverting
just the `StatsController` include turns 4 of these red, which is the check that
the specs actually bite. `spec/magick/admin_ui/authentication_spec.rb` covers
the decision function and the config writer directly.

### Judgement calls worth a reviewer's attention

1. **New dev dependencies.** `actionpack`, `actionview`, `railties` and
   `rack-test` were added to the Gemfile/gemspec (test-only; no runtime
   dependency added). Without them there is no honest way to assert enforcement
   *on every route*. The specs skip cleanly if they are absent.
2. **Lockfile churn.** Adding actionpack forced a re-resolve of the Rails family
   in `Gemfile.lock`: activerecord moved 7.2.3 → 8.1.3 and sqlite3 2.0.4 → 2.9.6
   (AR 8.1 requires sqlite3 >= 2.1). Every gem still satisfies the existing
   `< 9.0` / `~> 2.0` constraints and every declared version supports Ruby 3.2,
   so the CI matrix is unaffected. `ruby` and `x86_64-linux` were re-added to
   `PLATFORMS`, which the re-resolve had dropped — without them CI on
   ubuntu-latest would not install.
3. **`spec/magick/admin_ui_spec.rb` was rewritten.** Once Rails is loaded its
   `if defined?(Rails)` guard goes live, and its placeholder TODO examples fail:
   they assert controller actions return hashes (`controller.index[:features]`)
   and that `Engine.assets` exists. They had never executed and could not have
   passed. The engine-mounting and configuration examples were kept (two of them
   were also asserting the wrong thing — `magick_features_path` and a lowercase
   `'active'` badge), and the controller/view behaviour they gestured at is now
   covered for real by the request spec. Duplicated helper examples were dropped
   in favour of the existing `spec/magick/admin_ui/helpers_spec.rb`.
4. **The dummy app runs in `development`, not `test`.** Booting it changes
   `Rails.env` process-wide, and several library paths branch on
   `Rails.env.test?` — the Redis pub/sub subscriber skips starting itself there.
   Using `development` keeps every other spec on the code path it took before
   Rails was in the process. Cost: two extra `Magick: ignoring malformed pubsub
   payload` diagnostics on stderr, which are `Rails.env.development?`-gated
   `warn`s that were previously unreachable.

### Verification

`bundle exec rspec` — 464 examples, 0 failures (was 375 examples, 1 pending).
`bundle exec rubocop` on the touched files reports only `Metrics/BlockLength`
on spec blocks, which every existing spec file in the repo also trips.

2026-09-03 — Delivery: committed and pushed, but drover-e2e moved on by 1 commit — the branch is pushed, and a rebase is the way on

2026-09-03 — Rebase: nothing to rebase.
