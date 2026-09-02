# 17 — Audit log has a durable default

**What to build:** The audit log is not durable anywhere. Its default adapter is
an anonymous class whose entire body is an empty append method, so entries live
only in a per-process, in-memory ring capped at ten thousand and are discarded on
restart or reset.

In a multi-container deployment each process therefore sees only the changes it
made itself, and no process can answer "who changed this flag" about a change
made anywhere else. For a feature the README presents as audit logging, that is a
correctness gap rather than a performance one — it became more visible in 1.5.0,
which greatly increased the number of entries written.

Secondary: the adapter append runs inside the log's mutex, so a real
database-backed adapter would serialize every feature mutation in the process
behind a single lock.

**Blocked by:** None — can start immediately.

**Autonomy:** auto

**Status:** resolved

- [x] A default deployment persists audit entries somewhere that survives process restart
- [x] Entries written by one process are readable by another
- [x] The adapter write happens outside the lock that guards the in-memory ring
- [x] Hosts can still supply their own audit adapter, and can still opt out entirely
- [x] The retention and durability characteristics of the default are documented, including any cap

## Comments

**2026-09-02 — implemented on `wt/durable-audit-log` (1.6.1).**

The no-op anonymous default adapter is gone. `Magick::AuditLog` now has the
same two-tier shape as `Versioning`: the per-process ring stays (capped at
`max_entries`, default 10,000, across all features) and a new
`AuditLog::Store` writes every entry to the adapters that outlive the process
— Redis and/or ActiveRecord — under a reserved `__magick_audit:<feature>`
pseudo-feature namespace, capped at `retention` (default 200) **per feature**.
`entries` merges the shared history with the local ring, reading the shared
adapters directly rather than through the registry (whose memory-first `get`
would answer with this process's own cache and hide other processes' entries).

Per criterion:

1. **Durable by default** — no audit-specific configuration needed: whatever
   durable adapters the deployment has are used. Caveat worth stating plainly:
   a *memory-only* deployment still has nothing that outlives the process, so
   it keeps the ring only. That is inherent, not a fallback;
   `Magick.audit_log.durable?` tells a host which one it has, and the README
   says so.
2. **Cross-process reads** — covered by `spec/magick/audit_log_durability_spec.rb`
   (two registries over one SQLite table = two containers) and by a
   Redis-shaped fake backend in `spec/magick/audit_log_spec.rb`.
3. **Outside the lock** — both the durable write and a host adapter's `append`
   now run after the `synchronize` block. Two specs pin this: a host adapter
   that reads the log from inside `append` (would deadlock on the old
   non-reentrant mutex), and two mutations sitting inside a blocking adapter
   at the same time.
4. **Host adapter / opt-out** — `audit_log adapter:` still receives every
   entry (now outside the lock, and an exception it raises is logged instead of
   aborting the mutation). Found and fixed a real bug here: `audit_log
   enabled: false` did *not* opt out, because `Magick.configure` creates a
   default `AuditLog` before the DSL runs and `apply!` only assigned when the
   config's value was truthy — so an opted-out host kept recording entries
   (and would now have started writing them durably). Also added
   `persist: false` for hosts whose own sink is the system of record: keeps
   the ring and the sink, writes nothing to Redis/ActiveRecord.
5. **Documented** — README "Audit Logging" gained a durability/retention
   section with the tier table and both caps; also the install template,
   `config/magick.rb.example`, and the CHANGELOG.

Also in scope, because the new store made it matter: `Registry#preload!` and
`load_all_from_source` now skip reserved bookkeeping namespaces (audit *and*
version blobs), so audit history is not dragged into the memory cache on every
boot or into the Admin UI's bulk refresh. `all_features` already filtered
version snapshots; it now filters both.

Notes / trade-offs for review:

- Each durable append is a read-merge-write of the feature's capped list, so a
  same-feature write from two containers in the same instant can clobber one
  entry in the shared list. Entries carry a unique sortable `id`, and each
  write merges this process's recent ring back in, so a clobbered entry is
  restored by that process's next write (spec:
  "restores an entry that lost a write race"). Fully atomic appends would need
  a new adapter primitive (Redis lists / a locked row); that felt like more
  surface than this ticket wanted — say the word if you'd rather have it.
- Cost per mutation: one read + one write per durable adapter (~40-80KB of
  JSON at the default retention). Fine at admin write rates, and it is on the
  same hot path ticket 08 is looking at for version history.
- The Redis path is exercised only by an adapter-shaped fake — no `redis` gem
  or `REDIS_URL` in this environment (see ticket 02).

`bundle exec rspec`: 396 examples, 0 failures, 1 pending (pre-existing).

2026-09-03 — Delivery: pushed, but drover-e2e moved on by 1 commit — the branch is pushed, and a rebase is the way on

2026-09-03 — Rebase: nothing to rebase.
