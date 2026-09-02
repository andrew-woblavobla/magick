# 01 — Test the targeting implementation that actually runs

**What to build:** The targeting spec suite verifies real behaviour — register a
feature, apply targeting, assert what `enabled?` returns — instead of
instantiating strategy objects that the evaluation path never calls. Today four
of the six targeting specs exercise the `Magick::Targeting::*` classes, which no
code outside their own directory references; every rule is reimplemented inline
in `Feature`. That gap is why three fail-open bugs shipped with a green suite.

Scope this ticket to the paths that are currently correct — user, group, role,
tag, percentage, and exclusion-beats-inclusion — so it lands green and becomes
the regression net for ticket 03. The broken paths get their coverage there.

**Open decision (do not resolve unilaterally):** the `Magick::Targeting::*`
classes are dead code, but CLAUDE.md documents them as the extension point for
adding a targeting strategy, so deleting them breaks any downstream subclass.
Confirm with the maintainer whether to delete them or leave them in place. Either
way, correct the "Adding a New Targeting Strategy" section so it describes the
extension point that actually exists.

**Blocked by:** None — can start immediately.

**Autonomy:** auto

**Status:** resolved

- [ ] Targeting specs drive behaviour through a registered `Magick::Feature` and assert on `enabled?`, not on strategy-object `matches?` calls
- [x] Coverage exists for user, group, role, and tag targeting; percentage-of-users bucketing; and exclusions taking priority over inclusions
- [x] The contributor documentation for adding a targeting strategy describes the real evaluation path
- [ ] Maintainer decision on the fate of the unused strategy classes is recorded in this ticket's Comments before any are deleted
- [x] Full suite passes

## Comments

**2026-09-02 — ready for review, on branch `wt/test-real-targeting-path`.**
Two boxes stay open and both are waiting on the same maintainer decision — see
"Open question" at the end.

### New behavioural suite

`spec/magick/targeting/evaluation_spec.rb` — 39 examples, all going through
`Magick.register_feature` → public targeting API → `enabled?`. Nothing in it
constructs a `Magick::Targeting::*` object.

Every flag is registered as `type: :boolean, default_value: false` via a local
`flag` helper, so any `true` in an assertion had to be produced by a targeting
rule and not by the flag's own stored value.

Covered:

- **user** — targeted user on / everyone else off, no-user context off,
  Integer/String id equivalence, multiple ids, `disable_for_user`, and the same
  answer through `Magick.enabled?` / `Magick.enabled_for?`.
- **group / role** — on for the targeted value, off otherwise and off with no
  context, multiple values, the `disable_for_*` reversal, and extraction from an
  object handed to `enabled_for?`.
- **tag** — context key is `:tags` (plural) against the `:tag` targeting key,
  any-one-of matching in both directions, string coercion of numeric tag ids,
  `disable_for_tag`, and tag extraction from an object's `tags` association.
- **any-of composition** — user OR group is enough; neither means off.
- **percentage-of-users** — 100% takes everyone, a no-user context is still off,
  the same user gets the same answer on repeat calls, Integer and String ids
  land in the same bucket, monotonicity (25% ⊆ 50% ⊆ 100% over 300 users),
  distribution (50% of 2000 users, ±150), per-flag independence (two flags at
  50% do not select the same users), and `disable_percentage_of_users` returning
  the flag to its stored value. One example pins two concrete users either side
  of a 50% cut, so a change to the hash function has to be deliberate.
- **exclusion beats inclusion** — against the user list, against a qualifying
  group, group-excludes-group, role exclusion over a user-list match, tag
  exclusion on any one matching tag, IP-range exclusion over a user-list match,
  over a 100% rollout, over a globally enabled flag, and
  `remove_user_exclusion` restoring the inclusion.

Each exclusion example pairs the exclusion with a real inclusion rule. That is
deliberate: an exclusion-only flag is one of the two defects in ticket 03, so
asserting on it here would either bake in the bug or land red.

### The suite is a real net, not decoration

Mutation-tested by breaking `lib/magick/feature.rb` four ways and re-running
(implementation restored after each; `git diff` on `lib/` is empty):

| Mutation | Failures |
|---|---|
| drop the early `excluded?(context)` check | 8 |
| `user_in_percentage?` hashes `rand` instead of `name:user_id` | 4 |
| tag matching becomes all-of instead of any-of | 2 |
| user list compared without `.to_s` coercion | 9 |

### Docs

`CLAUDE.md` — "Adding a New Targeting Strategy" rewritten as "Adding a New
Targeting Rule". The old four steps ("create a class inheriting from
`Magick::Targeting::Base`, implement `matches?`") described a plug-in point that
does not exist. The replacement states plainly that there is no strategy-object
seam and walks the real path: vocabulary in `Magick::TargetingPayload`
(`ARRAY_KEYS` / `PERCENTAGE_KEYS` / `STRUCTURED_KEYS`, `ALIASES`,
`normalize_value`, `serialize`), writer on `Feature` via `record_change` +
`enable_targeting`, evaluation in `check_enabled` as a gate or in
`check_targeting` as an inclusion rule (exclusions in `excluded?`, which runs
first and always wins), then DSL/Admin UI surfaces, then an end-to-end spec.

Two neighbouring lines said the same untrue thing and were corrected with it:
the "Core Design Patterns" entry (was "Targeting Strategy — pluggable targeting
rules (`Magick::Targeting::Base`)") and the Key Modules table row for
`Magick::Targeting::*`. No other doc in the repo mentions the extension point —
checked `README.md`, `CONTEXT.md`, `RAILS8_EVENTS.md`, `requirements.md`.

Note `CLAUDE.md` is gitignored, so this edit will not appear in the branch diff.

### Suite

`bundle exec rspec` — **414 examples, 0 failures, 1 pending** (375 before; the
pending one is the pre-existing "Admin UI requires Rails"). RuboCop on the new
file reports only `Metrics/BlockLength`, which is unconfigured in this repo and
tripped by 21 of the existing spec files.

### Open question — blocks the two unchecked boxes

Nothing has been deleted. Confirmed the premise first: outside
`lib/magick/targeting/`, the only references to `Magick::Targeting::*` anywhere
in the repo are their own specs and one CHANGELOG line already calling them
orphaned. Ten classes, ~200 lines, zero callers.

**Which do you want?**

- **(a) Delete `lib/magick/targeting/` and the five strategy-object specs.**
  Removes the misleading seam for good. Breaks any downstream subclass of
  `Magick::Targeting::Base` — though such a subclass is already inert, since
  nothing evaluates it. Would want a CHANGELOG breaking-change note and a minor
  version bump.
- **(b) Keep them.** Costs nothing at runtime and keeps the door open for a
  future refactor that moves evaluation out of `Feature` and into these objects.

Pending the answer, the strategy-object specs are left in place, each with a
header comment saying what it does and does not prove and pointing at
`evaluation_spec.rb`. That is why box 1 is unchecked: five
`RSpec.describe Magick::Targeting::*` blocks still exist under
`spec/magick/targeting/`, so the directory is not yet purely behavioural. Under
(a) they go with the classes; under (b) they stay as the classes' own unit
tests and box 1 should be reworded to mean "targeting *behaviour* is covered
through `enabled?`", which is satisfied today.

Either answer is a small follow-up commit on this branch — it does not need a
new ticket.

2026-09-03 — Delivery held back — criteria ticked: 3 of 5 ticked; fast-forwards cleanly: was not checked; tests pass: was not checked; a second session reviews: was not checked

2026-09-03 — Delivery: committed and pushed, but drover-e2e moved on by 1 commit — the branch is pushed, and a rebase is the way on

2026-09-03 — Rebase: nothing to rebase.
