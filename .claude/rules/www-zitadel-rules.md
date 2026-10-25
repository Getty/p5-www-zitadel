# WWW-Zitadel House Rules

The shared house rules come from skilletor — bundle `getty-cpan-dist@getty`: engineering
discipline, the delegation lock, the publish gate, karr coordination, CPAN release. They load
as `.claude/rules/.local.*.md`; if they are missing, run `skilletor sync` and publish nothing
until they load. This file adds what is true only here, and wins where it differs.

## What this repo is

Perl client for Zitadel identity management (OIDC + Management API). Read first: the callers
and the sibling module (`WWW::Zitadel::OIDC` ↔ `WWW::Zitadel::Management`).

## Agent team

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code | `www-zitadel-worker` (default) |
| Write/extend tests | `www-zitadel-test-writer` |
| Write/maintain POD | `www-zitadel-doc-writer` |
| Commits, `Changes`, card → done, pre-release audit | `www-zitadel-release-manager` |
| Read-only research, audit, gap analysis | `www-zitadel-worker` ("read-only, change nothing") |

Behavior-relevant = runtime behavior, the public API (`WWW::Zitadel`, `::OIDC`,
`::Management`), error handling, the sync/async sibling invariant, tests, performance. Pure
prose docs and `Changes` notes are not.

## Hazards

- **Live and k8s tests hit real systems.** `t/90-live-zitadel.t` talks to a real ZITADEL
  instance (opt-in via `ZITADEL_LIVE_TEST=1 ZITADEL_ISSUER=…`); `t/91-k8s-pod.t` hits a real
  k8s cluster. Both are off by default and run on shared hardware — never run them
  uncontrolled or fanned out; a default `prove -lr t` must pass with them skipped.
- **Sync/async twin.** `p5-net-async-zitadel` mirrors this repo's public API with `_f`
  suffixes and Futures. An API change here is incomplete until the twin matches — ticket the
  twin, never edit it.
- **Test runner trap.** Plain `prove -l t/` is non-recursive; always use `prove -lr t` so
  subdir tests are never silently skipped (the suite is flat today, keep `-r` anyway).

## Perl specifics — reference, don't restate

Module loading, Moo patterns, dependency pinning, `[@Author::GETTY]` release metadata, POD
directives and house style live in skills `getty-perl-moo`, `perl-release-dist-ini`,
`getty-perl-release-author-getty` and `www-zitadel-core` (force-loaded for `www-zitadel-*`
agents).
