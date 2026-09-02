# 11 — Async writes preserve order and bounded resources

**What to build:** With async updates enabled, each write spawns its own thread
with no ordering and no cap.

Two writes to the same key in quick succession can land out of order: memory ends
up holding the newer value while Redis retains the older one, permanently
divergent, with the trailing publish instructing peers to load the stale value.
Reproduced directly — memory held the second write, Redis the first.

There is also no pool, cap, or backpressure. Two hundred writes spawned two
hundred threads, so an Admin UI bulk toggle or a boot-time DSL apply can exhaust
the Redis connection pool.

**Blocked by:** 02 — unverifiable without Redis in CI.

**Autonomy:** auto

**Status:** in-progress

- [ ] Async writes are drained by a serialized writer rather than one thread per write
- [ ] Writes to the same feature reach Redis in the order they were issued
- [ ] The pending-write queue is bounded, with defined behaviour when full (block or drop-with-log, chosen deliberately and documented)
- [ ] A burst of writes creates a constant number of threads, not one per write
- [ ] Shutdown drains or abandons pending writes deterministically, without hanging
