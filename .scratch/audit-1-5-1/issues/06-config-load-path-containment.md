# 06 — Config file loading can't escape the project tree

**What to build:** The DSL config loader evaluates the file it is given as Ruby.
Its containment check compares the resolved path against the working directory
using a bare string prefix, which is bypassable two ways, both confirmed:

- No trailing separator, so a sibling directory whose name merely starts with the
  project directory's name passes the check.
- It tests the working directory rather than the project root, so any process
  running from `/` reduces the guard to a no-op — every absolute path passes.

The guard sits directly in front of an eval sink, so a bypass is remote code
execution for any caller that derives the path from untrusted input.

**Blocked by:** None — can start immediately.

**Autonomy:** auto

**Status:** resolved

- [x] Containment is checked against the project root, separator-aware, so a sibling directory sharing a name prefix is rejected
- [x] The check does not depend on the process working directory
- [x] The existing environment-variable opt-out for trusted paths outside the tree still works and remains documented as dangerous
- [x] Specs cover the sibling-prefix case and the working-directory-is-root case

## Comments

**2026-09-02 — done, on branch `wt/config-load-path-containment`.**

Reproduced both bypasses against the old guard (`resolved.start_with?(Dir.pwd)`)
before changing anything: with cwd `/tmp/x/app`, `/tmp/x/app-evil/features.rb`
passed; with cwd `/`, every absolute path passed.

`lib/magick/config.rb`:

- New `ConfigDSL.project_root` — `Rails.root` when the host is a Rails app,
  else `Bundler.root` (the directory holding the Gemfile), else an explicitly
  assigned `ConfigDSL.project_root = '/srv/app'`. `Dir.pwd` is never consulted,
  so starting from `/` or chdir-ing later cannot widen the guard. Both sides of
  the comparison go through `File.realpath`, which also fixes Capistrano-style
  `current -> releases/x` deploys where the symlinked root never matched.
- New private `inside_project_root?` does separator-aware containment
  (`path == root || path.start_with?(root + File::SEPARATOR)`), so
  `/srv/app-evil` is no longer inside `/srv/app`.
- A root of `/` — or no determinable root — is treated as *no* containment
  rather than a prefix everything satisfies, so the loader refuses instead of
  degrading to a no-op. That is a behaviour change for a host running outside
  both Rails and Bundler: it must now set `project_root` explicitly (or use the
  env opt-out). Documented in the README.
- `MAGICK_ALLOW_CONFIG_EVAL=1` is unchanged and still skips the check; the
  method comment now spells out that it hands arbitrary code execution to
  anyone who can influence the path.

`spec/magick/config_load_from_file_spec.rb`: 3 existing examples kept, 8 added —
sibling-prefix (run from *inside* the fake root, which is what makes it a real
regression test for the bare-prefix bug), outside-file-while-cwd-is-`/`,
project-file-while-cwd-is-`/`, nested file under the root, root == `/`, no
determinable root, and two `.project_root` examples. 11 pass; full suite 383
examples, 0 failures (also with `--seed 1234`).

Docs: README gained a "Loading a DSL file yourself" subsection under DSL
Configuration covering the containment rule, `project_root=`, and a blunt
warning about `MAGICK_ALLOW_CONFIG_EVAL=1`. CHANGELOG has an `## Unreleased`
→ `### Security` entry.

RuboCop: one new offence, `Metrics/BlockLength` on the spec's top-level
`describe` — the repo has 51 of those across `spec/` already and no config for
the cop, so I left it consistent with the rest of the suite.

2026-09-03 — Delivery: pushed, but drover-e2e moved on by 1 commit — the branch is pushed, and a rebase is the way on

2026-09-03 — Rebase: nothing to rebase.
