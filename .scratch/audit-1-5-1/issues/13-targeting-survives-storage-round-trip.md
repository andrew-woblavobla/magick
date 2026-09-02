# 13 — Targeting survives a round trip through storage

**What to build:** Targeting is symbolized only one level deep when loaded from
storage, but it is JSON round-tripped through the adapters, so nested structures
come back with string keys. The readers for variants and custom attributes look
up symbol keys only, so both silently stop working in every process that did not
write them.

Confirmed with the plain memory adapter: before a reload, variant assignment
returned a variant; after a reload the stored variants had string keys and both
variant lookup methods returned nil. Custom-attribute matching fails the same
way. Two readers — plain targeting and complex conditions — do handle both key
shapes, which is exactly why the gap is easy to miss.

The adapters also disagree with each other: the ActiveRecord adapter symbolizes
recursively while the memory and Redis adapters do not, so the first read after
boot can yield symbols and every subsequent cached read yields strings — the same
flag evaluating differently depending on which layer served it.

**Blocked by:** 01 — the regression net must exist first.

**Autonomy:** auto

**Status:** in-progress

- [ ] Nested targeting structures are normalized to a single consistent key shape when loaded, at any depth
- [ ] Variant assignment and variant values work identically before and after a reload
- [ ] Custom-attribute matching works after a reload, including when the context supplies a symbol key and storage returns a string one
- [ ] All three adapters agree on the key shape they return
- [ ] Specs assert behaviour after an explicit reload, not just immediately after the write
