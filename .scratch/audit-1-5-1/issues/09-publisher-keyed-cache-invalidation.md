# 09 — Cache invalidation is keyed on the publisher

**What to build:** Cross-container cache invalidation is dropped by design.

The registry suppresses invalidation messages for any feature it wrote recently,
to avoid reacting to its own publishes. But the suppression is keyed on "did I
write this feature within the debounce window", not on who published the message.
Two containers toggling the same flag inside that window therefore each discard
the other's invalidation, and both keep serving their own value while the shared
store holds one of them.

Nothing heals this. Once initialized, a feature's cached value is only cleared by
an explicit reload, so the memory adapter's TTL does not rescue it — the divergence
persists until the next write to that flag or a process restart.

**Blocked by:** 02 — unverifiable without Redis in CI.

**Autonomy:** auto

**Status:** in-progress

- [ ] Invalidation messages carry the identity of the publishing process
- [ ] A process ignores only messages it published itself, and always acts on messages from peers
- [ ] The time-based suppression window is removed rather than merely shortened
- [ ] An integration spec with two registries over one Redis proves a peer's write within the old window is observed
- [ ] A process still does not reload in response to its own write
