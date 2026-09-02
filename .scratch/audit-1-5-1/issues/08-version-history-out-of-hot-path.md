# 08 — Version history stays out of the hot path

**What to build:** Version snapshots leak into paths that should only ever see
features, and the archive rewrites more data than it appends.

The registry's feature enumeration filters the reserved version namespace, but
the bulk preload and the admin source-refresh do not, so process boot and every
Admin UI index render pull the entire version archive into the memory adapter.
Measured at roughly 37 KB for 120 toggles of a single flag; at a few thousand
versions across a few hundred flags that is tens of megabytes per worker at boot
and a visibly slow admin index.

Separately, the archive stores one key per version inside a single row's data
blob, and the adapter's write path reads that whole blob, merges one key, and
writes it all back under a row lock. Appending version N rewrites all N−1
predecessors.

**Blocked by:** 07 — both tickets change the archive write path.

**Autonomy:** auto

**Status:** in-progress

- [ ] Bulk preload and the admin source-refresh skip the reserved version namespace, as feature enumeration already does
- [ ] After preload, the memory adapter contains no version snapshots
- [ ] Appending a version writes an amount of data proportional to that one version, not to the whole history
- [ ] Reading history and rolling back still work against archives written before the change, or a migration path is documented
- [ ] A spec covers a feature with many versions and asserts preload does not load them
