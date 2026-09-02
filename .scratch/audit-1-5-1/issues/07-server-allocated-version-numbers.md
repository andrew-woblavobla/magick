# 07 — Version numbers are allocated by the shared backend

**What to build:** Version history clobbers itself across processes. This is a
regression introduced with automatic versioning in 1.5.0.

The hot window is memoized per process on first read and never re-read. Each
append computes the next version number from that stale local copy and then
writes the whole list back, so two containers saving versions destroy each
other's snapshots and disagree about what a given version number contains.
Reproduced with two instances over one shared backend: instance A held versions
1 and 2, instance B held a different version 2, the backend held B's list, and
A's snapshot was gone. `rollback(name, 2)` therefore restores different data
depending on which container serves the request — which defeats the point of
having a rollback safety net at all.

The archive is clobbered the same way, since it keys entries by the same
locally-computed number.

**Blocked by:** None — can start immediately.

**Autonomy:** auto

**Status:** resolved

- [x] Version numbers are allocated by the shared store (an atomic increment or database sequence), not computed from a process-local cache
- [x] Appending re-reads current history rather than trusting a window memoized for the process lifetime
- [x] Two versioning instances over one backend produce a single interleaved history with no lost snapshots and no duplicate numbers
- [x] A given version number resolves to the same snapshot from every process
- [x] Existing history written by 1.5.0 is still readable after the change, or a documented migration path exists

## Comments

**Done — version bumped to 1.6.1.** All five acceptance criteria are met.

### What changed

**Numbers now come from the store, not the process.** Two new adapter
primitives on `Magick::Adapters::Base`:

- `#next_sequence(feature_name, key, floor:)` — atomically allocate the next
  number. ActiveRecord does it in a transaction holding the row lock; Redis with
  `HSETNX` (seed) + `HINCRBY` (allocate); memory under its own mutex. The `floor:`
  argument is the highest number the caller can see, so a store whose counter is
  missing — upgrade from 1.5.0, Redis flush, restored dump — resumes above the
  surviving history instead of restarting at 1 over it.
- `#delete_key(feature_name, key)` — remove one key, needed to prune the hot
  window now that snapshots are stored one key each.

`Versioning` picks a single sequence authority rather than fanning out like
writes do (two processes reading different layers would otherwise get the same
number): ActiveRecord first — its counter lives in the same row as the archive
it numbers, so it can never fall behind it — then Redis, then, with no shared
backend at all, process memory.

**The hot window is one key per snapshot** (`version_<n>`, the layout the archive
already used) instead of one `versions` list blob that every append rewrote
wholesale. That was the second half of the clobbering: even with correct
numbering, a full-list rewrite drops entries another process wrote in between.
Retention prunes by `allocated - max_versions` rather than by a count of what
this process happened to read, so racing appends agree on what to drop.

**Nothing is memoized for the process lifetime.** The `@hot` cache and its mutex
are gone; `get_versions`, appends and `find_version` all read the store. Where
sources disagree about a number (only possible for pre-upgrade history), the
durable shared copy wins — archive over Redis over local memory. With no Redis
configured the archive also backs the hot window, since a memory adapter only
ever holds what its own process wrote.

### On the 1.5.0 migration

Old single-blob windows are still read, and the first append after the upgrade
writes their entries out as `version_<n>` keys and empties the blob. 1.5.0
archives (already `version_<n>`, but with no counter) are read as-is and the
counter is seeded from their high-water mark. Nothing to run by hand; documented
in CHANGELOG under "Upgrading" and in the README versioning section.

One caveat worth knowing during rollout: processes still on 1.5.0 keep numbering
locally, so the guarantee only holds once the whole fleet is on ≥1.6.1.

### Verification

- `bundle exec rspec` — 387 examples, 0 failures.
- New `spec/magick/versioning_shared_store_spec.rb`: two containers (separate
  memory caches, separate adapter objects, one SQLite database) interleaving into
  one history, identical version→snapshot views from both, allocation ignoring a
  window this process read earlier, and rollback resolving identically either
  side. Appends there are sequential on purpose — a SQLite `:memory:` database is
  private to the connection that opened it, so threads would each get their own
  database; I confirmed that directly before dropping the threaded case.
- Concurrency is covered where a store can really be shared: two `Versioning`
  instances over one memory store in `versioning_spec.rb`, and against a real
  Redis in `redis_integration_spec.rb` (40 allocations across 4 clients × 10
  threads, no duplicates).
- Ran the Redis specs and a scripted end-to-end check against a live server
  (they are skipped without `REDIS_URL` — that is ticket 02's job): interleaved
  two-container history, 16 concurrent appends with nothing lost, pruning leaving
  exactly `sequence` + the last three `version_<n>` keys, legacy blob migrated
  forward, and numbering continuing correctly after a Redis flush.

### Notes for other tickets

- **08** builds on this: the archive layout it needs to make append-sized is
  already one key per version, and `Versioning` no longer writes list blobs.
- **12**: `Registry#start_cache_invalidation_subscriber` raises `LocalJumpError`
  on shutdown (`return if @stopping` inside the thread block, registry.rb). It
  fails the existing pubsub Redis spec on `main` too — I confirmed against
  `HEAD` — so I left it alone and kept my Redis spec clear of `shutdown`.
- `CLAUDE.md` is gitignored and absent from the worktree, so its "Versioning"
  implementation note still describes the 1.5.0 layout and could use a line
  about server-allocated numbers.
- Left uncommitted on `wt/server-allocated-version-numbers` for review.

### Merge overlaps with sibling audit branches

- **Version / CHANGELOG.** I bumped to 1.6.1 and wrote a `## 1.6.1` CHANGELOG
  section. `wt/durable-audit-log` (ticket 17) has done the same, so
  `lib/magick/version.rb`, `Gemfile.lock` and the CHANGELOG heading will
  conflict. Both branches mean the same release — resolve by keeping one
  heading and combining the bullet lists, not by inventing a second version.
- **`spec/magick/adapters/redis_integration_spec.rb`.** I added examples for
  `#next_sequence` / `#delete_key` and a two-container history test to the file
  as it exists on `main` (gated on `REDIS_URL` + `defined?(::Redis)`). Ticket 02
  is reworking that same file onto a `:redis` tag with `spec/support/redis.rb`
  and `rake spec:redis`, because requiring the redis gem process-wide flips
  Magick's `defined?(Redis)` auto-detection and contaminates the other 375
  specs. Whoever merges must carry my new examples over with the `:redis` tag —
  they must not end up running in a plain `bundle exec rspec`.

2026-09-03 — Delivery: committed and pushed, but drover-e2e moved on by 1 commit — the branch is pushed, and a rebase is the way on

2026-09-03 — Rebase: nothing to rebase.
