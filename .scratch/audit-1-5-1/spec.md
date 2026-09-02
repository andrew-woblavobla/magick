# Post-1.5.0 audit remediation

Source: a three-track review of the gem (Admin UI security, adapter/concurrency,
core library correctness) run after the 1.5.0 release. Every finding below was
reproduced by executing the library, not by inspection alone.

## Why this exists

The gem's core promise — "ask whether a flag is on, get the right answer" — is
broken for several common configurations, including two fail-open cases where a
disabled flag serves as enabled. Those are ticketed first. Everything else
(security defaults, distributed correctness, advertised-but-inert features,
reliability) follows.

The test suite was green throughout, because four of six targeting specs
exercise the `Magick::Targeting::*` strategy classes, which the evaluation path
never calls. Restoring real coverage is therefore a prefactor, not a follow-up.

## Phases

| Phase | Theme | Tickets |
| ----- | ----- | ------- |
| 0 | Safety nets (prefactor) | 01, 02 |
| 1 | Fail-open correctness | 03, 04 |
| 2 | Security | 05, 06 |
| 3 | 1.5.0 versioning regression | 07, 08 |
| 4 | Distributed correctness | 09–12 |
| 5 | Advertised features that don't work | 13–17 |
| 6 | Reliability and hygiene | 18–21 |

## Open decisions, deliberately not ticketed

- **Namespace collision.** The gem defines top-level `Magick`, as does RMagick —
  same constant, same `VERSION`, load-order-dependent breakage for any app using
  both. Moving to `MagickFeatureFlags` with an opt-in alias is a wide refactor
  best sequenced expand–contract, but it is a breaking product decision.
- **DSL injection.** Requiring the gem adds 24 public methods to `Object`
  (`nil.respond_to?(:experiment)` is true), with names as generic as `feature`
  and `add_dependency`, and no opt-out. Same decision, same sequence.
- **Fate of the `Magick::Targeting::*` classes.** They are dead code, but they
  are a documented extension point; removing them breaks any subclass. See
  ticket 01.

## Suggested release cut

Tickets 03–04 are the live-traffic risk — the gem returns wrong answers,
including two fail-open cases — and are the natural `1.5.1`. Tickets 07–08
repair a regression introduced in 1.5.0 itself and should follow closely.
Ticket 06 (config path containment) only bites hosts that derive a config path
from untrusted input, and ticket 05 only bites hosts using the built-in
`require_role` hook rather than router-level gating; both can ride the next
routine release. Not yet decided.

## Rejected findings

Recorded so they are not re-raised by a future audit:

- **"The Admin UI should authenticate by default."** Rejected. The
  unauthenticated default is deliberate and matches Sidekiq, Resque, and
  Flipper's UI: the host app gates the mounted route. The README already
  recommends the router-level `authenticate` block and states that
  authentication is opt-in. Only the inconsistent wiring of the *optional*
  `require_role` hook is a real defect — see ticket 05.
- **"Rollback records four audit entries and four version snapshots."**
  Rejected — not reproducible. The reentrancy guard added in 1.5.0 suppresses
  the nested mutators correctly; a rollback records exactly one audit entry and
  one version.
