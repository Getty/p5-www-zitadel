use strict;
use warnings;

use Test::More;
use Test::Exception;
use JSON::MaybeXS qw(decode_json encode_json);
use HTTP::Request;

use WWW::Zitadel::Management;

{
    package Local::Response;

    sub new {
        my ($class, %args) = @_;
        bless \%args, $class;
    }

    sub is_success      { $_[0]->{is_success} }
    sub status_line     { $_[0]->{status_line} }
    sub decoded_content { $_[0]->{decoded_content} // '' }
}

{
    package Local::MgmtUA;

    sub new {
        my ($class, %args) = @_;
        bless {
            queue    => $args{queue} || [],
            requests => [],
        }, $class;
    }

    sub requests { $_[0]->{requests} }

    sub request {
        my ($self, $req) = @_;
        push @{ $self->{requests} }, $req;
        my $res = shift @{ $self->{queue} };
        die "No mocked response available\n" unless $res;
        return $res;
    }
}

{
    package Local::Recorder;

    use Moo;
    extends 'WWW::Zitadel::Management';

    has calls => (
        is      => 'rw',
        default => sub { [] },
    );

    sub _request {
        my ($self, $method, $path, $body) = @_;
        push @{ $self->calls }, [ $method, $path, $body ];
        return { ok => JSON::MaybeXS::true };
    }
}

sub _success_json {
    my ($data) = @_;
    return Local::Response->new(
        is_success      => 1,
        status_line     => '200 OK',
        decoded_content => encode_json($data),
    );
}

# Base URL normalization and request metadata.
{
    my $ua = Local::MgmtUA->new(
        queue => [ _success_json({ ok => 1 }) ],
    );

    my $mgmt = WWW::Zitadel::Management->new(
        base_url => 'https://zitadel.example.com///',
        token    => 'pat-token',
        ua       => $ua,
    );

    is $mgmt->_api_base, 'https://zitadel.example.com/management/v1', '_api_base trims trailing slashes';

    my $res = $mgmt->_post('/users/_search', { query => { limit => 1 } });
    is $res->{ok}, 1, '_request returns decoded JSON payload';

    my $req = $ua->requests->[0];
    isa_ok $req, 'HTTP::Request';
    is $req->method, 'POST', 'request method set';
    is $req->uri->as_string, 'https://zitadel.example.com/management/v1/users/_search', 'request URL includes API base';
    is $req->header('Authorization'), 'Bearer pat-token', 'Authorization header set';
    is $req->header('Accept'), 'application/json', 'Accept header set';
    is $req->header('Content-Type'), 'application/json', 'Content-Type set for request with body';

    my $payload = decode_json($req->content);
    is $payload->{query}{limit}, 1, 'request body encoded as JSON';
}

# Empty successful response falls back to empty hashref.
{
    my $ua = Local::MgmtUA->new(
        queue => [ Local::Response->new(is_success => 1, status_line => '204 No Content', decoded_content => '') ],
    );

    my $mgmt = WWW::Zitadel::Management->new(
        base_url => 'https://zitadel.example.com',
        token    => 'pat-token',
        ua       => $ua,
    );

    my $res = $mgmt->_delete('/users/u1');
    is_deeply $res, {}, 'empty response returns empty hashref';
}

# Error response includes API message when available.
{
    my $ua = Local::MgmtUA->new(
        queue => [ Local::Response->new(
            is_success      => 0,
            status_line     => '400 Bad Request',
            decoded_content => encode_json({ message => 'invalid input' }),
        ) ],
    );

    my $mgmt = WWW::Zitadel::Management->new(
        base_url => 'https://zitadel.example.com',
        token    => 'pat-token',
        ua       => $ua,
    );

    throws_ok { $mgmt->_get('/users/x') }
        qr/API error: 400 Bad Request - invalid input/,
        'error includes message from API payload';
}

# Error response without parsable JSON still reports status line.
{
    my $ua = Local::MgmtUA->new(
        queue => [ Local::Response->new(
            is_success      => 0,
            status_line     => '503 Service Unavailable',
            decoded_content => '<html>upstream down</html>',
        ) ],
    );

    my $mgmt = WWW::Zitadel::Management->new(
        base_url => 'https://zitadel.example.com',
        token    => 'pat-token',
        ua       => $ua,
    );

    throws_ok { $mgmt->_get('/users/x') }
        qr/API error: 503 Service Unavailable/,
        'error without JSON payload still includes status';
}

# High-level methods produce expected paths and payload shapes.
{
    my $mgmt = Local::Recorder->new(
        base_url => 'https://zitadel.example.com',
        token    => 'pat-token',
    );

    $mgmt->list_users(offset => 5, limit => 20, queries => [ { foo => 'bar' } ]);
    my ($method1, $path1, $body1) = @{ $mgmt->calls->[0] };
    is $method1, 'POST', 'list_users uses POST';
    is $path1, '/users/_search', 'list_users path';
    is $body1->{query}{offset}, 5, 'list_users offset mapped';
    is $body1->{query}{limit}, 20, 'list_users limit mapped';
    ok $body1->{query}{asc}, 'list_users asc defaults to true';

    $mgmt->create_human_user(
        user_name  => 'alice',
        first_name => 'Alice',
        last_name  => 'Smith',
        email      => 'alice@example.com',
    );

    my ($method2, $path2, $body2) = @{ $mgmt->calls->[1] };
    is $method2, 'POST', 'create_human_user uses POST';
    is $path2, '/users/human', 'create_human_user path';
    is $body2->{userName}, 'alice', 'username mapped';
    is $body2->{profile}{displayName}, 'Alice Smith', 'display name defaults to first + last name';

    $mgmt->create_oidc_app(
        'project-1',
        name          => 'Web App',
        redirect_uris => ['https://app.example.com/cb'],
    );

    my ($method3, $path3, $body3) = @{ $mgmt->calls->[2] };
    is $method3, 'POST', 'create_oidc_app uses POST';
    is $path3, '/projects/project-1/apps/oidc', 'create_oidc_app path';
    is_deeply $body3->{redirectUris}, ['https://app.example.com/cb'], 'redirect URIs mapped';
    is $body3->{appType}, 'OIDC_APP_TYPE_WEB', 'default app type is set';
}

# Remaining high-level methods map to expected paths and payloads.
{
    my $mgmt = Local::Recorder->new(
        base_url => 'https://zitadel.example.com',
        token    => 'pat-token',
    );

    $mgmt->get_user('u1');
    $mgmt->update_user('u1', first_name => 'A', last_name => 'B');
    $mgmt->deactivate_user('u1');
    $mgmt->reactivate_user('u1');
    $mgmt->delete_user('u1');

    $mgmt->list_projects;
    $mgmt->get_project('p1');
    $mgmt->update_project('p1', name => 'Renamed');
    $mgmt->delete_project('p1');

    $mgmt->list_apps('p1');
    $mgmt->get_app('p1', 'a1');
    $mgmt->update_oidc_app('p1', 'a1', redirect_uris => ['https://example/cb']);
    $mgmt->delete_app('p1', 'a1');

    $mgmt->get_org;
    $mgmt->add_project_role('p1', role_key => 'viewer');
    $mgmt->list_project_roles('p1');
    $mgmt->create_user_grant(
        user_id    => 'u1',
        project_id => 'p1',
        role_keys  => ['viewer'],
    );
    $mgmt->list_user_grants(limit => 3);

    is_deeply $mgmt->calls->[0], ['GET', '/users/u1', undef], 'get_user path';
    is $mgmt->calls->[1][0], 'PUT', 'update_user uses PUT';
    is $mgmt->calls->[1][1], '/users/u1/profile', 'update_user path';
    is $mgmt->calls->[1][2]{firstName}, 'A', 'update_user maps first name';
    is_deeply $mgmt->calls->[2], ['POST', '/users/u1/_deactivate', {}], 'deactivate_user path';
    is_deeply $mgmt->calls->[3], ['POST', '/users/u1/_reactivate', {}], 'reactivate_user path';
    is_deeply $mgmt->calls->[4], ['DELETE', '/users/u1', undef], 'delete_user path';

    is $mgmt->calls->[5][1], '/projects/_search', 'list_projects path';
    is $mgmt->calls->[5][2]{query}{limit}, 100, 'list_projects default limit';
    is_deeply $mgmt->calls->[6], ['GET', '/projects/p1', undef], 'get_project path';
    is $mgmt->calls->[7][1], '/projects/p1', 'update_project path';
    is $mgmt->calls->[7][2]{name}, 'Renamed', 'update_project name mapped';
    is_deeply $mgmt->calls->[8], ['DELETE', '/projects/p1', undef], 'delete_project path';

    is $mgmt->calls->[9][1], '/projects/p1/apps/_search', 'list_apps path';
    is_deeply $mgmt->calls->[10], ['GET', '/projects/p1/apps/a1', undef], 'get_app path';
    is $mgmt->calls->[11][1], '/projects/p1/apps/a1/oidc_config', 'update_oidc_app path';
    is_deeply $mgmt->calls->[12], ['DELETE', '/projects/p1/apps/a1', undef], 'delete_app path';

    is_deeply $mgmt->calls->[13], ['GET', '/orgs/me', undef], 'get_org path';
    is $mgmt->calls->[14][1], '/projects/p1/roles', 'add_project_role path';
    is $mgmt->calls->[14][2]{displayName}, 'viewer', 'add_project_role display_name defaults to role_key';
    is $mgmt->calls->[15][1], '/projects/p1/roles/_search', 'list_project_roles path';
    is $mgmt->calls->[16][1], '/users/u1/grants', 'create_user_grant path';
    is_deeply $mgmt->calls->[16][2]{roleKeys}, ['viewer'], 'create_user_grant role keys mapped';
    is $mgmt->calls->[17][1], '/users/grants/_search', 'list_user_grants path';
    is $mgmt->calls->[17][2]{query}{limit}, 3, 'list_user_grants limit mapped';
}

# Additional required-argument checks.
{
    my $mgmt = WWW::Zitadel::Management->new(
        base_url => 'https://zitadel.example.com',
        token    => 'pat-token',
        ua       => Local::MgmtUA->new(queue => [ _success_json({ ok => 1 }) ]),
    );

    throws_ok {
        $mgmt->create_human_user(
            user_name  => 'alice',
            first_name => 'Alice',
            email      => 'alice@example.com',
        );
    } qr/last_name required/, 'create_human_user validates last_name';

    throws_ok {
        $mgmt->create_oidc_app('project-1', name => 'App');
    } qr/redirect_uris required/, 'create_oidc_app validates redirect_uris';

    throws_ok {
        $mgmt->add_project_role('project-1', display_name => 'Admin');
    } qr/role_key required/, 'add_project_role validates role_key';

    throws_ok {
        $mgmt->create_user_grant(project_id => 'p1', role_keys => ['admin']);
    } qr/user_id required/, 'create_user_grant validates user_id';
}

# update_oidc_app maps snake_case keys to camelCase.
{
    my $mgmt = Local::Recorder->new(
        base_url => 'https://zitadel.example.com',
        token    => 'pat-token',
    );

    $mgmt->update_oidc_app('p1', 'a1',
        redirect_uris           => ['https://app.example.com/cb'],
        response_types          => ['OIDC_RESPONSE_TYPE_CODE'],
        grant_types             => ['OIDC_GRANT_TYPE_AUTHORIZATION_CODE'],
        app_type                => 'OIDC_APP_TYPE_WEB',
        auth_method             => 'OIDC_AUTH_METHOD_TYPE_BASIC',
        post_logout_uris        => ['https://app.example.com/logout'],
        dev_mode                => JSON::MaybeXS::false,
        access_token_type       => 'OIDC_TOKEN_TYPE_BEARER',
        id_token_role_assertion => JSON::MaybeXS::true,
        additional_origins      => ['https://app2.example.com'],
    );

    my ($method, $path, $body) = @{ $mgmt->calls->[0] };
    is $method, 'PUT', 'update_oidc_app uses PUT';
    is $path, '/projects/p1/apps/a1/oidc_config', 'update_oidc_app path';
    is_deeply $body->{redirectUris}, ['https://app.example.com/cb'], 'redirect_uris -> redirectUris';
    is_deeply $body->{responseTypes}, ['OIDC_RESPONSE_TYPE_CODE'], 'response_types -> responseTypes';
    is_deeply $body->{grantTypes}, ['OIDC_GRANT_TYPE_AUTHORIZATION_CODE'], 'grant_types -> grantTypes';
    is $body->{appType}, 'OIDC_APP_TYPE_WEB', 'app_type -> appType';
    is $body->{authMethodType}, 'OIDC_AUTH_METHOD_TYPE_BASIC', 'auth_method -> authMethodType';
    is_deeply $body->{postLogoutRedirectUris}, ['https://app.example.com/logout'], 'post_logout_uris -> postLogoutRedirectUris';
    is_deeply $body->{additionalOrigins}, ['https://app2.example.com'], 'additional_origins -> additionalOrigins';
}

# Service users and machine keys.
{
    my $mgmt = Local::Recorder->new(
        base_url => 'https://zitadel.example.com',
        token    => 'pat-token',
    );

    $mgmt->create_service_user(user_name => 'ci-bot', name => 'CI Bot', description => 'CI pipeline user');
    $mgmt->list_service_users(limit => 10);
    $mgmt->get_service_user('su1');
    $mgmt->delete_service_user('su1');

    $mgmt->add_machine_key('su1', type => 'KEY_TYPE_JSON', expiration_date => '2030-01-01T00:00:00Z');
    $mgmt->list_machine_keys('su1', limit => 5);
    $mgmt->remove_machine_key('su1', 'key1');

    my $c = $mgmt->calls;

    is $c->[0][0], 'POST', 'create_service_user uses POST';
    is $c->[0][1], '/users/machine', 'create_service_user path';
    is $c->[0][2]{userName}, 'ci-bot', 'create_service_user userName';
    is $c->[0][2]{name}, 'CI Bot', 'create_service_user name';
    is $c->[0][2]{description}, 'CI pipeline user', 'create_service_user description';

    is $c->[1][1], '/users/_search', 'list_service_users path';
    is $c->[1][2]{query}{limit}, 10, 'list_service_users limit';
    is $c->[1][2]{queries}[0]{typeQuery}{type}, 'TYPE_MACHINE', 'list_service_users filters by machine type';

    is_deeply $c->[2], ['GET', '/users/su1', undef], 'get_service_user path';
    is_deeply $c->[3], ['DELETE', '/users/su1', undef], 'delete_service_user path';

    is $c->[4][1], '/users/su1/keys', 'add_machine_key path';
    is $c->[4][2]{type}, 'KEY_TYPE_JSON', 'add_machine_key type';
    is $c->[4][2]{expirationDate}, '2030-01-01T00:00:00Z', 'add_machine_key expiration_date -> expirationDate';

    is $c->[5][1], '/users/su1/keys/_search', 'list_machine_keys path';
    is $c->[5][2]{query}{limit}, 5, 'list_machine_keys limit';

    is_deeply $c->[6], ['DELETE', '/users/su1/keys/key1', undef], 'remove_machine_key path';

    throws_ok { $mgmt->create_service_user(name => 'Bot') } qr/user_name required/, 'create_service_user validates user_name';
    throws_ok { $mgmt->add_machine_key(undef) } qr/user_id required/, 'add_machine_key validates user_id';
    throws_ok { $mgmt->remove_machine_key('u1', undef) } qr/key_id required/, 'remove_machine_key validates key_id';
}

# Password management and user metadata.
{
    my $mgmt = Local::Recorder->new(
        base_url => 'https://zitadel.example.com',
        token    => 'pat-token',
    );

    $mgmt->set_password('u1', password => 's3cr3t!', change_required => JSON::MaybeXS::true);
    $mgmt->request_password_reset('u1');

    $mgmt->set_user_metadata('u1', 'department', 'engineering');
    $mgmt->get_user_metadata('u1', 'department');
    $mgmt->list_user_metadata('u1', limit => 20);

    my $c = $mgmt->calls;

    is $c->[0][1], '/users/u1/password', 'set_password path';
    is $c->[0][2]{password}, 's3cr3t!', 'set_password body has password';
    ok $c->[0][2]{changeRequired}, 'set_password change_required -> changeRequired';

    is_deeply $c->[1], ['POST', '/users/u1/_reset_password', {}], 'request_password_reset path';

    is $c->[2][1], '/users/u1/metadata/department', 'set_user_metadata path';
    use MIME::Base64 qw(decode_base64);
    is decode_base64($c->[2][2]{value}), 'engineering', 'set_user_metadata value is base64-encoded';

    is_deeply $c->[3], ['GET', '/users/u1/metadata/department', undef], 'get_user_metadata path';

    is $c->[4][1], '/users/u1/metadata/_search', 'list_user_metadata path';
    is $c->[4][2]{query}{limit}, 20, 'list_user_metadata limit';

    throws_ok { $mgmt->set_password(undef, password => 'x') } qr/user_id required/, 'set_password validates user_id';
    throws_ok { $mgmt->set_password('u1') } qr/password required/, 'set_password validates password';
    throws_ok { $mgmt->set_user_metadata('u1', undef, 'v') } qr/key required/, 'set_user_metadata validates key';
    throws_ok { $mgmt->set_user_metadata('u1', 'k', undef) } qr/value required/, 'set_user_metadata validates value';
}

# Organization operations.
{
    my $mgmt = Local::Recorder->new(
        base_url => 'https://zitadel.example.com',
        token    => 'pat-token',
    );

    $mgmt->create_org(name => 'Acme Corp');
    $mgmt->list_orgs(limit => 50, queries => [{ nameQuery => { name => 'Acme' } }]);
    $mgmt->update_org(name => 'Acme Inc');
    $mgmt->deactivate_org;

    my $c = $mgmt->calls;

    is $c->[0][0], 'POST', 'create_org uses POST';
    is $c->[0][1], '/orgs', 'create_org path';
    is $c->[0][2]{name}, 'Acme Corp', 'create_org name';

    is $c->[1][1], '/orgs/_search', 'list_orgs path';
    is $c->[1][2]{query}{limit}, 50, 'list_orgs limit';
    is scalar @{ $c->[1][2]{queries} }, 1, 'list_orgs queries forwarded';

    is $c->[2][0], 'PUT', 'update_org uses PUT';
    is $c->[2][1], '/orgs/me', 'update_org path';
    is $c->[2][2]{name}, 'Acme Inc', 'update_org name';

    is_deeply $c->[3], ['POST', '/orgs/me/_deactivate', {}], 'deactivate_org path';

    throws_ok { $mgmt->create_org } qr/name required/, 'create_org validates name';
    throws_ok { $mgmt->update_org } qr/name required/, 'update_org validates name';
}

# Identity provider operations.
{
    my $mgmt = Local::Recorder->new(
        base_url => 'https://zitadel.example.com',
        token    => 'pat-token',
    );

    $mgmt->create_oidc_idp(
        name          => 'Google',
        client_id     => 'gid',
        client_secret => 'gsecret',
        issuer        => 'https://accounts.google.com',
        scopes        => ['openid', 'email'],
        auto_register => 1,
    );
    $mgmt->list_idps(limit => 5);
    $mgmt->get_idp('idp1');
    $mgmt->update_idp('idp1', name => 'Google Updated');
    $mgmt->activate_idp('idp1');
    $mgmt->deactivate_idp('idp1');
    $mgmt->delete_idp('idp1');

    my $c = $mgmt->calls;

    is $c->[0][0], 'POST', 'create_oidc_idp uses POST';
    is $c->[0][1], '/idps/oidc', 'create_oidc_idp path';
    is $c->[0][2]{name}, 'Google', 'create_oidc_idp name';
    is $c->[0][2]{clientId}, 'gid', 'create_oidc_idp clientId';
    is $c->[0][2]{clientSecret}, 'gsecret', 'create_oidc_idp clientSecret';
    is $c->[0][2]{issuer}, 'https://accounts.google.com', 'create_oidc_idp issuer';
    is_deeply $c->[0][2]{scopes}, ['openid', 'email'], 'create_oidc_idp scopes';
    ok $c->[0][2]{autoRegister}, 'create_oidc_idp auto_register -> autoRegister';

    is $c->[1][1], '/idps/_search', 'list_idps path';
    is $c->[1][2]{query}{limit}, 5, 'list_idps limit';

    is_deeply $c->[2], ['GET', '/idps/idp1', undef], 'get_idp path';

    is $c->[3][0], 'PUT', 'update_idp uses PUT';
    is $c->[3][1], '/idps/idp1', 'update_idp path';
    is $c->[3][2]{name}, 'Google Updated', 'update_idp name';

    is_deeply $c->[4], ['POST', '/idps/idp1/_activate',   {}], 'activate_idp path';
    is_deeply $c->[5], ['POST', '/idps/idp1/_deactivate', {}], 'deactivate_idp path';
    is_deeply $c->[6], ['DELETE', '/idps/idp1', undef],        'delete_idp path';

    throws_ok { $mgmt->create_oidc_idp(client_id => 'x', client_secret => 'y', issuer => 'z') }
        qr/name required/, 'create_oidc_idp validates name';
    throws_ok { $mgmt->create_oidc_idp(name => 'n', client_secret => 'y', issuer => 'z') }
        qr/client_id required/, 'create_oidc_idp validates client_id';
    throws_ok { $mgmt->get_idp(undef) }    qr/idp_id required/, 'get_idp validates idp_id';
    throws_ok { $mgmt->delete_idp(undef) } qr/idp_id required/, 'delete_idp validates idp_id';
    throws_ok { $mgmt->update_idp('i1') }  qr/name required/,   'update_idp validates name';
}

# _request produces API exception objects with typed class.
{
    my $ua = Local::MgmtUA->new(
        queue => [ Local::Response->new(
            is_success      => 0,
            status_line     => '403 Forbidden',
            decoded_content => encode_json({ message => 'permission denied' }),
        ) ],
    );

    my $mgmt = WWW::Zitadel::Management->new(
        base_url => 'https://zitadel.example.com',
        token    => 'pat-token',
        ua       => $ua,
    );

    eval { $mgmt->_get('/users/x') };
    my $err = $@;
    ok ref $err && $err->isa('WWW::Zitadel::Error::API'), 'API errors throw WWW::Zitadel::Error::API';
    like "$err", qr/403 Forbidden/, 'API error stringifies with status';
    like "$err", qr/permission denied/, 'API error stringifies with api message';
    is $err->http_status, '403 Forbidden', 'API error http_status attribute';
    is $err->api_message, 'permission denied', 'API error api_message attribute';
}

# create_project maps name and camelCase project options; requires name.
{
    my $mgmt = Local::Recorder->new(
        base_url => 'https://zitadel.example.com',
        token    => 'pat-token',
    );

    $mgmt->create_project(
        name                      => 'My App',
        project_role_assertion    => JSON::MaybeXS::true,
        project_role_check        => JSON::MaybeXS::true,
        has_project_check         => JSON::MaybeXS::true,
        private_labeling_setting  => 'PRIVATE_LABELING_SETTING_ENFORCE_PROJECT_RESOURCE_OWNER',
    );

    my ($method, $path, $body) = @{ $mgmt->calls->[0] };
    is $method, 'POST', 'create_project uses POST';
    is $path, '/projects', 'create_project path';
    is $body->{name}, 'My App', 'create_project name mapped';
    ok $body->{projectRoleAssertion}, 'create_project project_role_assertion -> projectRoleAssertion';
    ok $body->{projectRoleCheck}, 'create_project project_role_check -> projectRoleCheck';
    ok $body->{hasProjectCheck}, 'create_project has_project_check -> hasProjectCheck';
    is $body->{privateLabelingSetting}, 'PRIVATE_LABELING_SETTING_ENFORCE_PROJECT_RESOURCE_OWNER',
        'create_project private_labeling_setting -> privateLabelingSetting';

    throws_ok { $mgmt->create_project() } qr/name required/, 'create_project validates name';
}

# update_project forwards camelCase options in addition to name.
{
    my $mgmt = Local::Recorder->new(
        base_url => 'https://zitadel.example.com',
        token    => 'pat-token',
    );

    $mgmt->update_project('p1',
        name                      => 'Renamed',
        project_role_assertion    => JSON::MaybeXS::true,
        project_role_check        => JSON::MaybeXS::true,
        has_project_check         => JSON::MaybeXS::true,
        private_labeling_setting  => 'PRIVATE_LABELING_SETTING_UNSPECIFIED',
    );

    my ($method, $path, $body) = @{ $mgmt->calls->[0] };
    is $method, 'PUT', 'update_project uses PUT';
    is $path, '/projects/p1', 'update_project path';
    is $body->{name}, 'Renamed', 'update_project name mapped';
    ok $body->{projectRoleAssertion}, 'update_project project_role_assertion -> projectRoleAssertion';
    ok $body->{projectRoleCheck}, 'update_project project_role_check -> projectRoleCheck';
    ok $body->{hasProjectCheck}, 'update_project has_project_check -> hasProjectCheck';
    is $body->{privateLabelingSetting}, 'PRIVATE_LABELING_SETTING_UNSPECIFIED',
        'update_project private_labeling_setting -> privateLabelingSetting';

    throws_ok { $mgmt->update_project(undef) } qr/project_id required/, 'update_project validates project_id';
    throws_ok { $mgmt->update_project('p1') } qr/name required/, 'update_project validates name';
}

# create_human_user maps optional profile, email, phone and password fields.
{
    my $mgmt = Local::Recorder->new(
        base_url => 'https://zitadel.example.com',
        token    => 'pat-token',
    );

    $mgmt->create_human_user(
        user_name          => 'bob',
        first_name         => 'Bob',
        last_name          => 'Builder',
        email              => 'bob@example.com',
        email_verified     => JSON::MaybeXS::true,
        nick_name          => 'Bobby',
        preferred_language => 'en',
        phone              => '+1-555-1234',
        phone_verified     => JSON::MaybeXS::true,
        password           => 's3cr3t!',
    );

    my ($method, $path, $body) = @{ $mgmt->calls->[0] };
    is $method, 'POST', 'create_human_user (optional) uses POST';
    is $path, '/users/human', 'create_human_user (optional) path';
    is $body->{userName}, 'bob', 'create_human_user (optional) userName';
    is $body->{profile}{nickName}, 'Bobby', 'create_human_user nick_name -> nickName';
    is $body->{profile}{preferredLanguage}, 'en', 'create_human_user preferred_language -> preferredLanguage';
    ok $body->{email}{isEmailVerified}, 'create_human_user email_verified -> isEmailVerified';
    is $body->{phone}{phone}, '+1-555-1234', 'create_human_user phone forwarded';
    ok $body->{phone}{isPhoneVerified}, 'create_human_user phone_verified -> isPhoneVerified';
    is $body->{password}, 's3cr3t!', 'create_human_user password forwarded';
}

# update_user maps display_name and nick_name in addition to first/last name.
{
    my $mgmt = Local::Recorder->new(
        base_url => 'https://zitadel.example.com',
        token    => 'pat-token',
    );

    $mgmt->update_user('u1',
        first_name   => 'Alice',
        last_name    => 'Wonderland',
        display_name => 'Alice W.',
        nick_name    => 'Ali',
    );

    my ($method, $path, $body) = @{ $mgmt->calls->[0] };
    is $method, 'PUT', 'update_user (optional) uses PUT';
    is $path, '/users/u1/profile', 'update_user (optional) path';
    is $body->{firstName}, 'Alice', 'update_user first_name -> firstName';
    is $body->{lastName}, 'Wonderland', 'update_user last_name -> lastName';
    is $body->{displayName}, 'Alice W.', 'update_user display_name -> displayName';
    is $body->{nickName}, 'Ali', 'update_user nick_name -> nickName';
}

# User grant lifecycle: update / deactivate / reactivate / delete.
{
    my $mgmt = Local::Recorder->new(
        base_url => 'https://zitadel.example.com',
        token    => 'pat-token',
    );

    $mgmt->update_user_grant('u1', 'g1', role_keys => ['admin']);
    $mgmt->deactivate_user_grant('u1', 'g1');
    $mgmt->reactivate_user_grant('u1', 'g1');
    $mgmt->delete_user_grant('u1', 'g1');

    my $c = $mgmt->calls;

    is $c->[0][0], 'PUT', 'update_user_grant uses PUT';
    is $c->[0][1], '/users/u1/grants/g1', 'update_user_grant path';
    is_deeply $c->[0][2]{roleKeys}, ['admin'], 'update_user_grant role_keys -> roleKeys';

    is_deeply $c->[1], ['POST', '/users/u1/grants/g1/_deactivate', {}], 'deactivate_user_grant path';
    is_deeply $c->[2], ['POST', '/users/u1/grants/g1/_reactivate', {}], 'reactivate_user_grant path';
    is_deeply $c->[3], ['DELETE', '/users/u1/grants/g1', undef], 'delete_user_grant path';

    throws_ok { $mgmt->update_user_grant(undef, 'g1', role_keys => ['admin']) }
        qr/user_id required/, 'update_user_grant validates user_id';
    throws_ok { $mgmt->update_user_grant('u1', undef, role_keys => ['admin']) }
        qr/grant_id required/, 'update_user_grant validates grant_id';
    throws_ok { $mgmt->deactivate_user_grant(undef, 'g1') }
        qr/user_id required/, 'deactivate_user_grant validates user_id';
    throws_ok { $mgmt->delete_user_grant('u1', undef) }
        qr/grant_id required/, 'delete_user_grant validates grant_id';
}

# Typed identity providers (JWT, Google, AzureAD, GitHub, GitHub Enterprise,
# GitLab, GitLab self-hosted, Apple, LDAP) target the Add*Provider endpoints
# and thread provider_options through as a nested hashref.
{
    my $mgmt = Local::Recorder->new(
        base_url => 'https://zitadel.example.com',
        token    => 'pat-token',
    );

    $mgmt->create_jwt_idp(
        name          => 'J',
        issuer        => 'https://i',
        jwt_endpoint  => 'https://j',
        keys_endpoint => 'https://k',
        header_name   => 'x',
        audience      => 'a',
        provider_options => { isCreationAllowed => JSON::MaybeXS::true },
    );
    $mgmt->create_google_idp(
        name          => 'G',
        client_id     => 'c',
        client_secret => 's',
        provider_options => { isAutoCreation => JSON::MaybeXS::true },
    );
    $mgmt->create_azuread_idp(
        name          => 'A',
        client_id     => 'c',
        client_secret => 's',
        tenant        => 'tid',
    );
    $mgmt->create_github_idp(
        name          => 'GH',
        client_id     => 'c',
        client_secret => 's',
    );
    $mgmt->create_github_enterprise_idp(
        name                   => 'GHE',
        client_id              => 'c',
        client_secret          => 's',
        authorization_endpoint => 'https://a',
        token_endpoint         => 'https://t',
        user_endpoint          => 'https://u',
    );
    $mgmt->create_gitlab_idp(
        name          => 'GL',
        client_id     => 'c',
        client_secret => 's',
    );
    $mgmt->create_gitlab_self_hosted_idp(
        name          => 'GLS',
        issuer        => 'https://gl',
        client_id     => 'c',
        client_secret => 's',
    );
    $mgmt->create_apple_idp(
        name          => 'AP',
        client_id     => 'c',
        team_id       => 't',
        key_id        => 'k',
        private_key   => 'PK',
        scopes        => ['email'],
    );
    $mgmt->create_ldap_idp(
        name                 => 'L',
        servers              => ['ldap://x'],
        start_tls            => 1,
        base_dn              => 'dc=x',
        bind_dn              => 'cn=y',
        bind_password        => 'p',
        user_base            => 'ou=users',
        user_object_classes  => ['person'],
        user_filters         => ['cn'],
        timeout              => 5,
        root_ca              => 'PEM',
    );

    my $c = $mgmt->calls;
    use MIME::Base64 qw(decode_base64);

    # JWT
    is $c->[0][0], 'POST', 'create_jwt_idp uses POST';
    is $c->[0][1], '/idps/generic_jwt', 'create_jwt_idp path';
    is $c->[0][2]{name}, 'J', 'create_jwt_idp name';
    is $c->[0][2]{issuer}, 'https://i', 'create_jwt_idp issuer';
    is $c->[0][2]{jwtEndpoint}, 'https://j', 'create_jwt_idp jwt_endpoint -> jwtEndpoint';
    is $c->[0][2]{keysEndpoint}, 'https://k', 'create_jwt_idp keys_endpoint -> keysEndpoint';
    is $c->[0][2]{headerName}, 'x', 'create_jwt_idp header_name -> headerName';
    is $c->[0][2]{audience}, 'a', 'create_jwt_idp audience forwarded';
    ok $c->[0][2]{providerOptions}{isCreationAllowed}, 'create_jwt_idp provider_options nested';

    # Google
    is $c->[1][1], '/idps/google', 'create_google_idp path';
    is $c->[1][2]{name}, 'G', 'create_google_idp name forwarded';
    is $c->[1][2]{clientId}, 'c', 'create_google_idp client_id -> clientId';
    is $c->[1][2]{clientSecret}, 's', 'create_google_idp client_secret -> clientSecret';
    ok $c->[1][2]{providerOptions}{isAutoCreation}, 'create_google_idp provider_options nested';

    # AzureAD
    is $c->[2][1], '/idps/azure', 'create_azuread_idp path';
    is $c->[2][2]{name}, 'A', 'create_azuread_idp name';
    is $c->[2][2]{clientId}, 'c', 'create_azuread_idp client_id -> clientId';
    is $c->[2][2]{clientSecret}, 's', 'create_azuread_idp client_secret -> clientSecret';
    is $c->[2][2]{tenant}, 'tid', 'create_azuread_idp tenant passthrough';

    # GitHub
    is $c->[3][1], '/idps/github', 'create_github_idp path';
    is $c->[3][2]{name}, 'GH', 'create_github_idp name forwarded';
    is $c->[3][2]{clientId}, 'c', 'create_github_idp client_id -> clientId';

    # GitHub Enterprise
    is $c->[4][1], '/idps/github_es', 'create_github_enterprise_idp path';
    is $c->[4][2]{name}, 'GHE', 'create_github_enterprise_idp name';
    is $c->[4][2]{clientId}, 'c', 'create_github_enterprise_idp client_id -> clientId';
    is $c->[4][2]{clientSecret}, 's', 'create_github_enterprise_idp client_secret -> clientSecret';
    is $c->[4][2]{authorizationEndpoint}, 'https://a', 'create_github_enterprise_idp authorization_endpoint -> authorizationEndpoint';
    is $c->[4][2]{tokenEndpoint}, 'https://t', 'create_github_enterprise_idp token_endpoint -> tokenEndpoint';
    is $c->[4][2]{userEndpoint}, 'https://u', 'create_github_enterprise_idp user_endpoint -> userEndpoint';

    # GitLab
    is $c->[5][1], '/idps/gitlab', 'create_gitlab_idp path';
    is $c->[5][2]{clientId}, 'c', 'create_gitlab_idp client_id -> clientId';

    # GitLab self-hosted
    is $c->[6][1], '/idps/gitlab_self_hosted', 'create_gitlab_self_hosted_idp path';
    is $c->[6][2]{issuer}, 'https://gl', 'create_gitlab_self_hosted_idp issuer';
    is $c->[6][2]{name}, 'GLS', 'create_gitlab_self_hosted_idp name';
    is $c->[6][2]{clientId}, 'c', 'create_gitlab_self_hosted_idp client_id -> clientId';
    is $c->[6][2]{clientSecret}, 's', 'create_gitlab_self_hosted_idp client_secret -> clientSecret';

    # Apple
    is $c->[7][1], '/idps/apple', 'create_apple_idp path';
    is $c->[7][2]{name}, 'AP', 'create_apple_idp name forwarded';
    is $c->[7][2]{clientId}, 'c', 'create_apple_idp client_id -> clientId';
    is $c->[7][2]{teamId}, 't', 'create_apple_idp team_id -> teamId';
    is $c->[7][2]{keyId}, 'k', 'create_apple_idp key_id -> keyId';
    is decode_base64($c->[7][2]{privateKey}), 'PK', 'create_apple_idp private_key base64-encoded';
    is_deeply $c->[7][2]{scopes}, ['email'], 'create_apple_idp scopes forwarded';

    # LDAP
    is $c->[8][1], '/idps/ldap', 'create_ldap_idp path';
    is $c->[8][2]{name}, 'L', 'create_ldap_idp name';
    is_deeply $c->[8][2]{servers}, ['ldap://x'], 'create_ldap_idp servers forwarded';
    ok $c->[8][2]{startTls}, 'create_ldap_idp start_tls -> startTls';
    is $c->[8][2]{baseDn}, 'dc=x', 'create_ldap_idp base_dn -> baseDn';
    is $c->[8][2]{bindDn}, 'cn=y', 'create_ldap_idp bind_dn -> bindDn';
    is $c->[8][2]{bindPassword}, 'p', 'create_ldap_idp bind_password -> bindPassword';
    is $c->[8][2]{userBase}, 'ou=users', 'create_ldap_idp user_base -> userBase';
    is_deeply $c->[8][2]{userFilters}, ['cn'], 'create_ldap_idp user_filters -> userFilters';
    is $c->[8][2]{timeout}, 5, 'create_ldap_idp timeout forwarded';
    is decode_base64($c->[8][2]{rootCa}), 'PEM', 'create_ldap_idp root_ca base64-encoded';

    throws_ok { $mgmt->create_jwt_idp(name => 'J') }
        qr/issuer required/, 'create_jwt_idp validates issuer';
    throws_ok { $mgmt->create_google_idp() }
        qr/client_id required/, 'create_google_idp validates client_id (name is optional)';
    throws_ok { $mgmt->create_ldap_idp(name => 'L') }
        qr/servers required/, 'create_ldap_idp validates servers';
    throws_ok { $mgmt->create_ldap_idp(name => 'L', servers => ['x']) }
        qr/base_dn required/, 'create_ldap_idp validates base_dn after servers';
    throws_ok { $mgmt->create_apple_idp(client_id => 'c', team_id => 't', key_id => 'k') }
        qr/private_key required/, 'create_apple_idp validates private_key';
}

# Project roles and SAML / API applications.
{
    my $mgmt = Local::Recorder->new(
        base_url => 'https://zitadel.example.com',
        token    => 'pat-token',
    );

    $mgmt->update_project_role('p1', 'admin', display_name => 'Admin', group => 'g');
    $mgmt->remove_project_role('p1', 'admin');
    $mgmt->create_saml_app('p1', name => 'S', metadata_xml => '<?xml version="1.0"?><md/>');
    $mgmt->create_saml_app('p1', name => 'S2', metadata_url => 'https://m');
    $mgmt->update_saml_app('p1', 'a1', metadata_xml => '<?xml version="1.0"?><md/>');
    $mgmt->create_api_app('p1', name => 'A', auth_method => 'API_AUTH_METHOD_TYPE_BASIC');

    my $c = $mgmt->calls;
    use MIME::Base64 qw(decode_base64);

    is $c->[0][0], 'PUT', 'update_project_role uses PUT';
    is $c->[0][1], '/projects/p1/roles/admin', 'update_project_role path';
    is $c->[0][2]{displayName}, 'Admin', 'update_project_role display_name -> displayName';
    is $c->[0][2]{group}, 'g', 'update_project_role group forwarded';

    is_deeply $c->[1], ['DELETE', '/projects/p1/roles/admin', undef], 'remove_project_role path';

    is $c->[2][0], 'POST', 'create_saml_app (xml) uses POST';
    is $c->[2][1], '/projects/p1/apps/saml', 'create_saml_app (xml) path';
    is $c->[2][2]{name}, 'S', 'create_saml_app (xml) name';
    is decode_base64($c->[2][2]{metadataXml}), '<?xml version="1.0"?><md/>', 'create_saml_app metadata_xml base64-encoded';

    is $c->[3][1], '/projects/p1/apps/saml', 'create_saml_app (url) path';
    is $c->[3][2]{name}, 'S2', 'create_saml_app (url) name';
    is $c->[3][2]{metadataUrl}, 'https://m', 'create_saml_app metadata_url -> metadataUrl';
    ok !exists $c->[3][2]{metadataXml}, 'create_saml_app (url) omits metadataXml';

    is $c->[4][0], 'PUT', 'update_saml_app uses PUT';
    is $c->[4][1], '/projects/p1/apps/a1/saml_config', 'update_saml_app path';
    is decode_base64($c->[4][2]{metadataXml}), '<?xml version="1.0"?><md/>', 'update_saml_app metadata_xml base64-encoded';

    is $c->[5][0], 'POST', 'create_api_app uses POST';
    is $c->[5][1], '/projects/p1/apps/api', 'create_api_app path';
    is $c->[5][2]{name}, 'A', 'create_api_app name';
    is $c->[5][2]{authMethodType}, 'API_AUTH_METHOD_TYPE_BASIC', 'create_api_app auth_method -> authMethodType';

    throws_ok { $mgmt->update_project_role(undef, 'admin', display_name => 'X') }
        qr/project_id required/, 'update_project_role validates project_id';
    throws_ok { $mgmt->update_project_role('p1', undef, display_name => 'X') }
        qr/role_key required/, 'update_project_role validates role_key';
    throws_ok { $mgmt->update_project_role('p1', 'admin') }
        qr/display_name required/, 'update_project_role validates display_name';
    throws_ok { $mgmt->remove_project_role('p1', undef) }
        qr/role_key required/, 'remove_project_role validates role_key';
    throws_ok { $mgmt->create_saml_app('p1', name => 'S') }
        qr/metadata_xml or metadata_url required/, 'create_saml_app requires metadata';
    throws_ok { $mgmt->update_saml_app('p1', 'a1') }
        qr/metadata_xml or metadata_url required/, 'update_saml_app requires metadata';
    throws_ok { $mgmt->create_api_app('p1') }
        qr/name required/, 'create_api_app validates name';
}

# Organization domains and remaining user lifecycle (lock/unlock/resend).
{
    my $mgmt = Local::Recorder->new(
        base_url => 'https://zitadel.example.com',
        token    => 'pat-token',
    );

    $mgmt->reactivate_org;
    $mgmt->add_org_domain('example.com');
    $mgmt->generate_org_domain_validation('example.com', type => 'HTTP');
    $mgmt->validate_org_domain('example.com');
    $mgmt->set_primary_org_domain('example.com');
    $mgmt->list_org_domains(limit => 10);
    $mgmt->remove_org_domain('example.com');

    $mgmt->lock_user('u1');
    $mgmt->unlock_user('u1');
    $mgmt->resend_email_verification('u1');

    my $c = $mgmt->calls;

    is_deeply $c->[0], ['POST', '/orgs/me/_reactivate', {}], 'reactivate_org path';

    is $c->[1][0], 'POST', 'add_org_domain uses POST';
    is $c->[1][1], '/orgs/me/domains', 'add_org_domain path';
    is $c->[1][2]{domain}, 'example.com', 'add_org_domain domain in body';

    is $c->[2][1], '/orgs/me/domains/example.com/validation/_generate', 'generate_org_domain_validation path';
    is $c->[2][2]{type}, 'HTTP', 'generate_org_domain_validation type forwarded';

    is_deeply $c->[3], ['POST', '/orgs/me/domains/example.com/validation/_validate', {}], 'validate_org_domain path';
    is_deeply $c->[4], ['POST', '/orgs/me/domains/example.com/_set_primary', {}], 'set_primary_org_domain path';

    is $c->[5][1], '/orgs/me/domains/_search', 'list_org_domains path';
    is $c->[5][2]{query}{limit}, 10, 'list_org_domains limit mapped';

    is_deeply $c->[6], ['DELETE', '/orgs/me/domains/example.com', undef], 'remove_org_domain path';

    is_deeply $c->[7], ['POST', '/users/u1/_lock', {}], 'lock_user path';
    is_deeply $c->[8], ['POST', '/users/u1/_unlock', {}], 'unlock_user path';
    is_deeply $c->[9], ['POST', '/users/u1/email/_resend_verification', {}], 'resend_email_verification path';

    throws_ok { $mgmt->add_org_domain(undef) }
        qr/domain required/, 'add_org_domain validates domain';
    throws_ok { $mgmt->generate_org_domain_validation('example.com') }
        qr/type required/, 'generate_org_domain_validation validates type';
    throws_ok { $mgmt->set_primary_org_domain(undef) }
        qr/domain required/, 'set_primary_org_domain validates domain';
    throws_ok { $mgmt->remove_org_domain(undef) }
        qr/domain required/, 'remove_org_domain validates domain';
    throws_ok { $mgmt->lock_user(undef) }
        qr/user_id required/, 'lock_user validates user_id';
    throws_ok { $mgmt->unlock_user(undef) }
        qr/user_id required/, 'unlock_user validates user_id';
    throws_ok { $mgmt->resend_email_verification(undef) }
        qr/user_id required/, 'resend_email_verification validates user_id';
}

done_testing;
