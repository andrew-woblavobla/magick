# 12 — Subscriber threads start and stop cleanly

**What to build:** Three lifecycle defects in the Pub/Sub subscriber.

The subscriber's early-exit guards use `return` inside the thread block, which
raises `LocalJumpError` rather than exiting. The block's own broad rescue catches
it and falls into a sleep-and-retry loop, so a condition meant to shut the thread
down cleanly instead spins forever. Confirmed on Ruby 3.3.3: a subscriber whose
client was unavailable re-invoked it repeatedly and was still alive after eleven
seconds.

The fork guard marks the subscriber as owned by the current process *before* the
thread is confirmed started, so if starting fails the guard permanently reports
"already running" and that worker never receives another invalidation.

Reconfiguring Redis starts a second subscriber without stopping the first, which
stays blocked on its subscription forever and is no longer reachable by shutdown —
leaking a thread and a connection per reconfiguration or dev reload.

**Blocked by:** 02 — unverifiable without Redis in CI.

**Autonomy:** auto

**Status:** in-progress

- [ ] A guard condition that should stop the subscriber terminates the thread instead of raising into the retry loop
- [ ] A subscriber that cannot start does not leave the process marked as having a live subscriber
- [ ] Reconfiguring Redis does not leave an orphaned subscriber thread or connection
- [ ] Shutdown terminates the subscriber promptly, and repeated start calls are idempotent
- [ ] Specs cover the unavailable-client, failed-start, and reconfigure cases
