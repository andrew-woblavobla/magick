# Policy

Everything Drover may do here without being asked. Layered: the built-in
answer, your global file, this repository, then the ticket — each exists only
to be overridden. Editing by hand is the point: waiving a guardrail is a
decision the repository should carry.

**Delivers:** merge
**Workspace:** worktree
**Unattended:** yes
**Ceiling:** none
**On CI red:** revert-then-fix
**Night shift:** button, 19:00-07:00, idle 30m
**Base:** drover-e2e
**Tests:** bundle exec rspec
**Tests run by:** locally

## Guardrails

- [x] Every acceptance criterion ticked
- [x] It fast-forwards cleanly
- [x] The repository's tests pass
- [ ] A second session reviews the diff
