# 10 — Redis failure degrades gracefully

**What to build:** The circuit breaker does not currently protect much, and when
it trips it makes things actively worse.

- **An open circuit corrupts peers.** The breaker returns a falsey value when
  open instead of signalling, so the write path's rescue never fires and
  execution continues to publish a cache invalidation. Peers dutifully reload the
  *pre-toggle* value from Redis. A brief Redis blip therefore propagates stale
  state across the fleet for the remainder of the breaker's timeout.
- **Reads are unprotected and untimed.** Only writes go through the breaker;
  every read path calls Redis directly, and the default client is constructed
  with no connect, read, or write timeout. A Redis that black-holes packets
  rather than refusing connections will block request threads for the driver's
  default timeout while the breaker sits open doing nothing.
- **A failed probe does not re-open.** Transitioning to half-open resets the
  failure count, and re-opening requires reaching the full threshold again, so a
  permanently dead Redis admits several requests per timeout cycle instead of one.
- **Existence checks are not fail-safe.** The registry's existence check is the
  only one of its read methods without a rescue, so it propagates adapter errors
  to callers outside the fail-safe evaluation path, breaking the gem's documented
  "never raises" contract.

**Blocked by:** 02 — unverifiable without Redis in CI.

**Autonomy:** auto

**Status:** in-progress

- [ ] An open circuit prevents the write path from publishing a cache invalidation
- [ ] Read paths are protected by the breaker
- [ ] The default Redis client sets explicit connect, read, and write timeouts
- [ ] A single failed half-open probe re-opens the circuit immediately
- [ ] The registry existence check returns false rather than raising when the backend is unavailable
- [ ] An integration spec covers an unreachable Redis and asserts no invalidation is published and no exception escapes
