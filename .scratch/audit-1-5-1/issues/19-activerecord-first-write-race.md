# 19 — ActiveRecord first-write race is handled

**What to build:** Two containers writing a flag that has never been persisted
can both attempt to create its row. The write path takes a row lock inside a
transaction, but a lock on a row that does not exist yet locks nothing, so both
proceed to create and the loser raises a uniqueness violation.

That error is a statement-invalid subclass, so it does enter the existing rescue —
but the retry logic only retries messages mentioning a locked, busy, or timed-out
database, so a uniqueness violation is not retried. It becomes an adapter error,
which ticket 18 shows is currently swallowed silently.

Realistic trigger: a rolling deploy where several workers boot and apply
declarative feature definitions at the same time.

Also worth recording during this work: the row lock is silently dropped by the
SQLite visitor, so on SQLite the read-modify-write relies entirely on SQLite's
global write lock plus a short retry budget.

**Blocked by:** 02.

**Autonomy:** auto

**Status:** in-progress

- [ ] Concurrent first writes to the same previously-unpersisted feature all succeed, with no uniqueness violation escaping
- [ ] The write is expressed as an upsert, or the uniqueness violation is explicitly retried
- [ ] Behaviour is verified on the database used in CI, and the SQLite locking caveat is documented
- [ ] The retry budget is documented so operators know when writes give up
