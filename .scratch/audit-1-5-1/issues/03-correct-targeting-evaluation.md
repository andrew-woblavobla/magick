# 03 — Targeting evaluation returns the right answer

**What to build:** Two fail-open/fail-closed defects in the same evaluation
method, both reproducible in four lines.

First, a flag whose *only* targeting is a gate — date range, IP list, custom
attribute, complex condition, or variant set — is permanently off. The
evaluation splits targeting keys into "inclusion" and "excluded_", but gate keys
belong to neither: they are already evaluated earlier in the flow and are never
matched during the inclusion scan, so evaluation falls through to "no inclusion
rule matched → false". A promo flag inside its own date window returns false.
This also switches off the entire `experiment` DSL permanently, since defining an
experiment sets variants.

Second, a targeting match on a boolean feature returns true *without reading the
stored value*. Because a flag carrying only exclusions counts as "targeting
matched", adding a single excluded user turns a globally disabled flag on for
every other user. That is fail-open: excluding one abuser ships the feature to
the entire user base.

**Blocked by:** 01 — the regression net must exist first.

**Autonomy:** auto

**Status:** in-progress

- [ ] A flag whose only targeting is a date range evaluates true inside the window and false outside it
- [ ] The same holds for IP-list, custom-attribute, complex-condition, and variant-only flags
- [ ] A flag defined through the `experiment` DSL is not switched off by the act of setting its variants
- [ ] A boolean flag with a stored value of false and one excluded user evaluates false for every other user, and false with no context
- [ ] Exclusions still take priority over inclusions
- [ ] Each of the above is covered by a spec that fails against the current implementation
