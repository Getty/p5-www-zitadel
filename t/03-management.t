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
    $mgmt->update_oidc_app('p1', 'a1', redirectUris => ['https://example/cb']);
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

done_testing;
