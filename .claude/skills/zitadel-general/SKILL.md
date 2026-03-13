---
name: zitadel-general
description: "General ZITADEL workflow for HI integration and WWW::Zitadel maintenance (OIDC, Management API, tests, k8s live checks)"
user-invocable: true
allowed-tools: Read, Grep, Glob, Bash
model: sonnet
---

Use this skill when working on ZITADEL-related tasks in this workspace, especially:

- finishing or extending `p5-www-zitadel`
- integrating ZITADEL into `hi-proto` services
- writing/maintaining tests and docs for OIDC + Management API flows
- validating live setup in Kubernetes

## Primary repos

- Library: `p5-www-zitadel/`
- HI app integration target: `hi-proto/`

## Workflow

1. Determine scope first:
- `library`: API client behavior in `WWW::Zitadel::*`
- `integration`: how HI services consume verified identity
- `deployment`: k8s runtime (issuer, DNS, cert, gateway, live checks)

2. For library changes in `p5-www-zitadel`:
- Edit modules in `lib/WWW/Zitadel*.pm`
- Add/adjust offline tests in `t/02-oidc.t` and `t/03-management.t`
- Keep live tests opt-in (`t/90-live-zitadel.t`, `t/91-k8s-pod.t`)
- Update `README.md` and `Changes`

3. For HI integration:
- Check current auth mode before changing behavior
- Document whether integration is edge auth only or native token verification
- Add explicit config shape examples (issuer/client/audience/scopes)

4. Always validate with:
```bash
cd /storage/raid/home/getty/dev/perl/p5-www-zitadel
prove -lr t
```

5. Optional live validation:
```bash
ZITADEL_LIVE_TEST=1 \
ZITADEL_ISSUER='https://<issuer>' \
prove -lv t/90-live-zitadel.t
```

6. Optional pod-to-issuer connectivity test:
```bash
ZITADEL_K8S_TEST=1 \
ZITADEL_ISSUER='https://<issuer>' \
ZITADEL_KUBECONFIG='/storage/raid/home/getty/avatar/.kube/config' \
prove -lv t/91-k8s-pod.t
```

## PostgreSQL 18 note

- If setup fails with `partitioned tables cannot be unlogged`, this is a ZITADEL migration compatibility issue in older ZITADEL versions, not a generic PostgreSQL 18 problem.
- Use ZITADEL versions that include PG18 compatibility fix (v4.11.0+ line).

## Documentation rules

- Keep README examples executable and aligned with real method names.
- Keep POD and README consistent.
- Record any new behavior in `Changes` under `{{$NEXT}}`.
