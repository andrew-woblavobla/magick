# 14 — Variants survive export and import

**What to build:** Variants are silently lost through a full export and import
cycle.

The export helper reads an instance variable that is never assigned anywhere in
the gem — the only reference to it is the read itself. Variants actually live in
the feature's targeting, so the exported variants list is always empty while the
real data sits elsewhere in the same payload.

On the import side, the variant restore is guarded on the feature responding to a
method that does not exist, and the targeting application has no branch for
variants (or for complex conditions), so neither is reconstructed. A full round
trip returns a feature whose variant assignment is nil.

**Blocked by:** 13 — both tickets touch how variants are read out of targeting.

**Autonomy:** auto

**Status:** ready-for-agent

- [ ] The exported representation contains the feature's real variants
- [ ] A full export then import reconstructs variants such that variant assignment behaves as it did before the export
- [ ] Complex conditions also survive the round trip
- [ ] The dead variant-restore path and its unreachable guard are removed
- [ ] A round-trip spec covers a feature carrying variants, custom attributes, complex conditions, and exclusions together
