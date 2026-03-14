# TODO

## Bugs

- [ ] `Path::Tiny` in cpanfile test requires but never used anywhere -- remove it
- [ ] `MIME::Base64` in cpanfile runtime requires but never used anywhere -- remove it
- [ ] `Management::update_oidc_app` passes `%args` directly as a raw hashref without snake_case to camelCase conversion, unlike `create_oidc_app` which maps every key -- needs the same `redirect_uris` -> `redirectUris` (etc.) mapping

## Quality improvements

- [ ] Empty issuer URL (`issuer => ''`) accepted at construction time, only fails on first API call -- validate in `BUILD` (both `WWW::Zitadel` and `WWW::Zitadel::OIDC`)
- [ ] Empty `base_url` in `WWW::Zitadel::Management` similarly needs `BUILD` validation
- [ ] Structured exception classes instead of plain `die` strings -- distinguish network errors, validation errors, and API errors (e.g. `WWW::Zitadel::Error::Network`, `WWW::Zitadel::Error::Validation`, `WWW::Zitadel::Error::API`)
- [ ] Document UA instance reuse pattern in README (sharing a single `LWP::UserAgent` across OIDC and Management clients for connection pooling)

## Missing Management API endpoints

- [ ] Service users (`create_service_user`, `list_service_users`, `get_service_user`, `delete_service_user`)
- [ ] Organization operations (`create_org`, `list_orgs`, `update_org`, `deactivate_org`)
- [ ] Machine users / JWT key configuration (`add_machine_key`, `list_machine_keys`, `remove_machine_key`)
- [ ] `create_project` currently only covers basic fields -- check what ZITADEL v4.12+ added
- [ ] Password management (`set_password`, `request_password_reset`)
- [ ] Metadata operations (`set_user_metadata`, `get_user_metadata`, `list_user_metadata`)
- [ ] IDP (identity provider) configuration endpoints

## Test gaps

- [ ] Malformed JSON responses (non-JSON body on success, truncated JSON)
- [ ] Empty JWKS keys array (valid JSON but no keys to verify against)
- [ ] Token with missing required claims (sub, iss, exp)
- [ ] `update_oidc_app` camelCase conversion test (once the bug is fixed)
- [ ] Network timeout handling (LWP timeout behavior, connection refused)
- [ ] Discovery endpoint returning incomplete document (missing fields)
- [ ] Concurrent JWKS refresh race conditions

## Documentation

- [ ] Troubleshooting guide for common ZITADEL setup issues (PAT creation, CORS, self-hosted TLS)
- [ ] Token refresh strategy guidance (when to refresh, how to detect expiry, automatic retry patterns)
- [ ] JWKS key rotation edge case documentation (cache TTL, rotation during verification)
- [ ] Document the `queries` parameter format for `list_*` methods (Zitadel's native filter syntax)

## Async support

Async support will be in a separate distribution: **Net::Async::Zitadel** (`p5-net-async-zitadel`). It will provide IO::Async-based equivalents of `WWW::Zitadel::OIDC` and `WWW::Zitadel::Management` using non-blocking HTTP.
