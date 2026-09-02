# 01 — Round-trip every targeting rule kind, not only lists and percentages

**What to build:** The wire contract promises that `serialize` and `normalize`
are inverses — what a control plane reads back is what it sent. That promise is
currently tested for list rules and percentages only.

Date ranges, custom attributes, complex conditions and every exclusion
counterpart are not covered, so a serialisation change to any of them would pass
the suite and break the panel.

Extend the round-trip guarantee to every rule kind the glossary names, one
example per kind, asserting `normalize(serialize(t)) == t`.

Do not change `TargetingPayload` unless a genuine asymmetry turns up. If one
does, fix it and say so — that is the point of asking.

**Blocked by:** None — can start immediately.

**Status:** resolved

**Autonomy:** ask

## Acceptance criteria

- [x] Every targeting rule kind named in CONTEXT.md has a round-trip example
- [x] Exclusion counterparts are covered alongside their inclusion rules
- [x] Each example asserts normalize(serialize(t)) equals the original targeting
- [x] The internal-only :variants key is shown not to cross the wire
- [x] `bundle exec rspec` passes

## Comments

Done in `spec/magick/targeting_payload_spec.rb`, under a new
`describe 'round-trip (normalize(serialize(t)) == t)'` block that replaces the
single list+percentage example that was there.

**No asymmetry found — `TargetingPayload` is unchanged.** I probed all 15
canonical keys in both directions (`normalize(serialize(t)) == t` and
`serialize(normalize(w)) == w`) before writing anything. Every canonical
internal value round-trips exactly. Details below.

**Coverage** — one example per glossary kind, 15 in all, inclusion and
exclusion side by side: users, groups, roles, tags, IPs, user percentages,
request percentages, date ranges, custom attributes, complex conditions, and
`excluded_users` / `excluded_groups` / `excluded_roles` / `excluded_tags` /
`excluded_ip_addresses`. (The glossary names exclusion counterparts only for
the five list rules; `CANONICAL_KEYS` has no others.) The fixtures use the
shape `normalize` itself produces — i.e. what `replace_targeting` stores and
adapters persist — so the fixed point under test is the real one.

Three examples beyond the per-kind set:

- *round-trips every rule kind at once* also asserts the fixture keys equal
  `CANONICAL_KEYS`. Adding a rule kind to the module without adding a
  round-trip example now fails the suite instead of passing silently — that
  was the failure mode the ticket describes.
- *leaves the internal variants entry out of the round-trip entirely*:
  `serialize` drops `:variants`, and the resulting payload is accepted by
  `normalize` without resurrecting it. (The existing example that `normalize`
  *rejects* an explicit `variants` key stays where it was.)
- *converges to a fixed point for internal state the wire cannot express* —
  see below.

**The one narrowing, and why it is not a bug.** Internal targeting can hold
Ruby objects JSON has no type for: `enable_for_date_range(Time.utc(...))`
stores `Time` bounds, and free-form `complex_conditions` params can hold
Symbol values. `serialize` renders those as an iso8601 String and a String
respectively, and `normalize` has nothing to parse them back into, so strict
identity cannot hold for that input — no encoder could make it hold. What
matters for the panel is that it converges rather than drifting: one trip
reaches a fixed point, so a read-modify-write cycle from a control plane is
stable. That is asserted rather than left implicit, and the comment above it
records the reasoning so the gap does not read as an oversight later.

Full suite: 392 examples, 0 failures, 1 pending (the pre-existing
`admin_ui_spec.rb:177` pending, needs Rails). Rubocop on the file reports only
`Metrics/BlockLength`, which every spec file in the repo trips (51 occurrences
across `spec/`) — no rubocop-rspec config is loaded. No new offence kinds.
