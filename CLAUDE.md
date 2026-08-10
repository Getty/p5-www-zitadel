# CLAUDE.md

WWW::Zitadel — Perl client for Zitadel identity management. OIDC discovery/JWKS/token
verification (`WWW::Zitadel::OIDC`) plus Management API v1 (`WWW::Zitadel::Management`),
unified behind the `WWW::Zitadel` entrypoint. Moo-based; released to CPAN via
Dist::Zilla `[@Author::GETTY]`.

Async twin: `p5-net-async-zitadel` (`Net::Async::Zitadel::*`), same API surface with `_f`
suffixes returning Futures — keep them in sync.

## Delegation

Delegate behavior-relevant code to the right agent instead of touching it yourself —
principle and lane are in `.claude/rules/www-zitadel-rules.md`.

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code | `www-zitadel-worker` (default) |
| Write/extend tests | `www-zitadel-test-writer` |
| Pre-release audit | `www-zitadel-release-checker` |
| Write/maintain POD | `www-zitadel-doc-writer` |

The agents carry their skills via `briefing.skills` (see `.claude/agents/`); the main
agent delegates rather than loading them. Skill sources live under `.claude/skills/`.

## Commands

```bash
prove -lr t          # full test suite (recursive; live/k8s tests skip by default)
dzil build           # build the distribution
dzil test            # test via Dist::Zilla
```

Live tests are opt-in: `ZITADEL_LIVE_TEST=1 ZITADEL_ISSUER='https://…' prove -l t/90-live-zitadel.t`.
Never run live/k8s suites uncontrolled — see house rules.