# 04 — `enable`/`disable` are atomic and the bulk API matches them

**What to build:** Two inconsistencies between the single-feature and bulk
toggle paths.

`Magick.bulk_disable` only writes a false value; it does not clear targeting the
way `Feature#disable` does. Combined with the boolean short-circuit fixed in
ticket 03, a flag enabled for a specific user stays on for that user after a bulk
disable reports success. The bulk helpers also silently skip string and number
features entirely while still reporting success.

Separately, `Feature#enable` clears and persists an empty targeting hash *before*
validating the feature type, so calling it on a string or number feature raises
after the targeting has already been wiped and written to the backend. The caller
sees an exception and reasonably assumes nothing changed.

**Blocked by:** 03.

**Autonomy:** auto

**Status:** ready-for-agent

- [ ] A flag enabled for a specific user evaluates false for that user after `bulk_disable`
- [ ] The bulk helpers either handle non-boolean features or report that they did not act, rather than silently no-opping
- [ ] Calling `enable` on a string or number feature raises without having modified or persisted targeting
- [ ] Targeting is unchanged in the backend after such a failed call, verified by reading it back
