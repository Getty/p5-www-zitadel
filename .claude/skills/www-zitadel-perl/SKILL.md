---
name: www-zitadel-perl
description: "Usage guide for WWW::Zitadel Perl client (OIDC, Management API, token flows, tests)"
user-invocable: true
allowed-tools: Read, Grep, Glob, Bash
model: sonnet
---

Use this skill when the task is "how do I use `WWW::Zitadel` in Perl?".

## Module map

- `WWW::Zitadel`: unified entrypoint (`issuer`, optional `token`)
- `WWW::Zitadel::OIDC`: discovery, JWKS, token verification, userinfo, introspection, token endpoint helpers
- `WWW::Zitadel::Management`: Management API v1 (users/projects/apps/roles/grants)

## Quickstart (unified entrypoint)

```perl
use WWW::Zitadel;

my $z = WWW::Zitadel->new(
  issuer => 'https://zitadel.example.com',
  token  => $ENV{ZITADEL_PAT}, # only needed for management calls
);

my $claims = $z->oidc->verify_token($jwt, audience => 'client-id');
my $projects = $z->management->list_projects(limit => 20);
```

Important: management methods are direct methods like
`list_users`, `create_human_user`, `create_project` (no `->users->list` subclient API).

## OIDC usage

Typical calls:

- `discovery`
- `jwks(force_refresh => 1?)`
- `verify_token($jwt, audience => ..., verify_exp => 1, ...)`
- `userinfo($access_token)`
- `introspect($token, client_id => ..., client_secret => ...)`
- `client_credentials_token(...)`
- `refresh_token($refresh_token, ...)`
- `exchange_authorization_code(code => ..., redirect_uri => ..., ...)`

`verify_token` retries once with refreshed JWKS when signature validation fails
(useful for key rotation).

## Management API usage

Create client:

```perl
my $mgmt = WWW::Zitadel::Management->new(
  base_url => 'https://zitadel.example.com',
  token    => $ENV{ZITADEL_PAT},
);
```

Common flow:

1. `create_project(name => ...)`
2. `create_oidc_app($project_id, name => ..., redirect_uris => [...])`
3. `add_project_role($project_id, role_key => ...)`
4. `create_user_grant(user_id => ..., project_id => ..., role_keys => [...])`

## Error handling

This distribution currently throws via `die` on validation/API errors.
Wrap in `eval`/`Try::Tiny` when needed.

## Test commands

Offline tests:

```bash
cd /storage/raid/home/getty/dev/perl/p5-www-zitadel
prove -lr t
```

Live issuer tests:

```bash
ZITADEL_LIVE_TEST=1 \
ZITADEL_ISSUER='https://your-zitadel.example.com' \
prove -lv t/90-live-zitadel.t
```

Kubernetes pod reachability test:

```bash
ZITADEL_K8S_TEST=1 \
ZITADEL_ISSUER='https://your-zitadel.example.com' \
ZITADEL_KUBECONFIG='/storage/raid/home/getty/avatar/.kube/config' \
prove -lv t/91-k8s-pod.t
```
