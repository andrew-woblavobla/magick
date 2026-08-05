# CONTEXT — magick-feature-flags

Domain glossary. Use these terms exactly; avoid the synonyms noted under each.

## Glossary

**Targeting** — the set of rules on a feature that scope who/what it is
enabled for (users, groups, roles, tags, IPs, percentages, date ranges,
custom attributes, complex conditions) plus their exclusion counterparts.
Stored internally as one hash (`Feature#targeting`, symbol keys). *Variants
are not targeting* — they live inside the same internal hash for storage
reasons only.

**Wire targeting payload** — the JSON representation of targeting exchanged
with control planes: string keys, list rules as arrays of strings,
percentages as floats. The `targeting` key is **always present**; `{}` is
the only spelling of "no targeting". Produced by `Feature#as_json`,
consumed by `Feature#replace_targeting`, translated by
`Magick::TargetingPayload`. Avoid: "targeting JSON", "targeting config".

**Wholesale replace** — the write semantic of `replace_targeting`: the
payload *is* the new targeting state; keys absent from it are removed; `{}`
clears everything. Contrast with the pre-1.6 per-rule imperative mutators
(`enable_for_user`, …), which still exist for programmatic use. Avoid:
"merge", "patch semantics".

**All-or-nothing validation** — `replace_targeting` validates the entire
payload before touching any state; one bad key/value means nothing is
applied (`Magick::InvalidTargetingError`, mapped to 422 by API callers).

**Panel contract** — the platform-side internal API
(`GET /internal/panel/flags`, `PATCH /flags/:name`) built *on top of* the
gem primitives. The gem ships no routes; paths and auth are the host app's.

**Choke point (change recording)** — `Feature#record_change`: one logical
operation = one audit entry + one version snapshot, under its real action
name (since 1.5.0). `replace_targeting` is one such operation regardless of
how many rules changed.
