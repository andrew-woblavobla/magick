# 15 — Dependencies are persisted

**What to build:** Feature dependencies exist only in the memory of the process
that declared them. Adding or removing a dependency mutates an in-process list;
nothing writes it to storage and nothing reads it back on load. Confirmed: after
declaring a dependency and setting a value, the stored keys for that feature
contain no dependency data, and a freshly constructed instance reports none.

Because an unknown prerequisite is treated as satisfied, the failure is silent
and fails open — every other container serves the dependent feature as live
regardless of whether its prerequisite is on, and the relationship vanishes
entirely on restart.

**Blocked by:** 01 — the regression net must exist first.

**Autonomy:** auto

**Status:** in-progress

- [ ] Adding and removing a dependency is persisted to the backend
- [ ] Dependencies are restored when a feature is loaded in another process or after a restart
- [ ] A dependent feature evaluates false when its prerequisite is off, from a process that did not declare the relationship
- [ ] Dependencies survive an export and import round trip
- [ ] The treatment of a genuinely unknown prerequisite is deliberate and documented, rather than incidental
