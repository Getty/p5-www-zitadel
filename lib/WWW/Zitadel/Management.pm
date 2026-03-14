package WWW::Zitadel::Management;

# ABSTRACT: Client for Zitadel Management API v1

use Moo;
use JSON::MaybeXS qw(encode_json decode_json);
use LWP::UserAgent;
use HTTP::Request;
use MIME::Base64 qw(encode_base64);
use WWW::Zitadel::Error;
use namespace::clean;

our $VERSION = '0.002';

has base_url => (
    is       => 'ro',
    required => 1,
);

has token => (
    is       => 'ro',
    required => 1,
);

has ua => (
    is      => 'lazy',
    builder => sub { LWP::UserAgent->new(timeout => 30) },
);

has _api_base => (
    is      => 'lazy',
    builder => sub {
        my $base = $_[0]->base_url;
        $base =~ s{/+$}{};
        "$base/management/v1";
    },
);

sub BUILD {
    my $self = shift;
    die WWW::Zitadel::Error::Validation->new(
        message => 'base_url must not be empty',
    ) unless length $self->base_url;
}

# --- Generic request methods ---

sub _request {
    my ($self, $method, $path, $body) = @_;

    my $url = $self->_api_base . $path;
    my $req = HTTP::Request->new($method => $url);
    $req->header(Authorization => 'Bearer ' . $self->token);
    $req->header(Accept        => 'application/json');

    if ($body) {
        $req->header('Content-Type' => 'application/json');
        $req->content(encode_json($body));
    }

    my $res = $self->ua->request($req);
    my $data;
    if ($res->decoded_content && length $res->decoded_content) {
        eval { $data = decode_json($res->decoded_content) };
    }

    unless ($res->is_success) {
        my $api_msg = $data && $data->{message} ? $data->{message} : undef;
        my $msg = 'API error: ' . $res->status_line;
        $msg .= " - $api_msg" if $api_msg;
        die WWW::Zitadel::Error::API->new(
            message     => $msg,
            http_status => $res->status_line,
            api_message => $api_msg,
        );
    }

    return $data // {};
}

sub _get    { $_[0]->_request('GET',    $_[1]) }
sub _post   { $_[0]->_request('POST',   $_[1], $_[2]) }
sub _put    { $_[0]->_request('PUT',    $_[1], $_[2]) }
sub _delete { $_[0]->_request('DELETE', $_[1]) }

sub _require { die WWW::Zitadel::Error::Validation->new(message => $_[0]) }

# --- Users ---

sub list_users {
    my ($self, %args) = @_;
    $self->_post('/users/_search', {
        query => {
            offset => $args{offset} // 0,
            limit  => $args{limit}  // 100,
            asc    => $args{asc}    // JSON::MaybeXS::true,
        },
        $args{queries} ? (queries => $args{queries}) : (),
    });
}

sub get_user {
    my ($self, $user_id) = @_;
    $user_id or _require('user_id required');
    $self->_get("/users/$user_id");
}

sub create_human_user {
    my ($self, %args) = @_;
    $self->_post('/users/human', {
        userName => $args{user_name}  // _require('user_name required'),
        profile  => {
            firstName   => $args{first_name}  // _require('first_name required'),
            lastName    => $args{last_name}   // _require('last_name required'),
            displayName => $args{display_name} // "$args{first_name} $args{last_name}",
            $args{nick_name}          ? (nickName          => $args{nick_name})          : (),
            $args{preferred_language} ? (preferredLanguage => $args{preferred_language}) : (),
        },
        email => {
            email           => $args{email} // _require('email required'),
            isEmailVerified => $args{email_verified} // JSON::MaybeXS::false,
        },
        $args{phone} ? (phone => {
            phone           => $args{phone},
            isPhoneVerified => $args{phone_verified} // JSON::MaybeXS::false,
        }) : (),
        $args{password} ? (password => $args{password}) : (),
    });
}

sub update_user {
    my ($self, $user_id, %args) = @_;
    $user_id or _require('user_id required');
    $self->_put("/users/$user_id/profile", {
        $args{first_name}   ? (firstName   => $args{first_name})   : (),
        $args{last_name}    ? (lastName    => $args{last_name})    : (),
        $args{display_name} ? (displayName => $args{display_name}) : (),
        $args{nick_name}    ? (nickName    => $args{nick_name})    : (),
    });
}

sub deactivate_user {
    my ($self, $user_id) = @_;
    $user_id or _require('user_id required');
    $self->_post("/users/$user_id/_deactivate", {});
}

sub reactivate_user {
    my ($self, $user_id) = @_;
    $user_id or _require('user_id required');
    $self->_post("/users/$user_id/_reactivate", {});
}

sub delete_user {
    my ($self, $user_id) = @_;
    $user_id or _require('user_id required');
    $self->_delete("/users/$user_id");
}

# --- Service / machine users ---

sub create_service_user {
    my ($self, %args) = @_;
    $self->_post('/users/machine', {
        userName    => $args{user_name} // _require('user_name required'),
        name        => $args{name}      // _require('name required'),
        $args{description} ? (description => $args{description}) : (),
    });
}

sub list_service_users {
    my ($self, %args) = @_;
    $self->_post('/users/_search', {
        query => {
            offset => $args{offset} // 0,
            limit  => $args{limit}  // 100,
            asc    => $args{asc}    // JSON::MaybeXS::true,
        },
        queries => [
            { typeQuery => { type => 'TYPE_MACHINE' } },
            @{ $args{queries} // [] },
        ],
    });
}

sub get_service_user {
    my ($self, $user_id) = @_;
    $user_id or _require('user_id required');
    $self->_get("/users/$user_id");
}

sub delete_service_user {
    my ($self, $user_id) = @_;
    $user_id or _require('user_id required');
    $self->_delete("/users/$user_id");
}

# --- Machine keys (JWT auth for service users) ---

sub add_machine_key {
    my ($self, $user_id, %args) = @_;
    $user_id or _require('user_id required');
    $self->_post("/users/$user_id/keys", {
        type => $args{type} // 'KEY_TYPE_JSON',
        $args{expiration_date} ? (expirationDate => $args{expiration_date}) : (),
    });
}

sub list_machine_keys {
    my ($self, $user_id, %args) = @_;
    $user_id or _require('user_id required');
    $self->_post("/users/$user_id/keys/_search", {
        query => {
            offset => $args{offset} // 0,
            limit  => $args{limit}  // 100,
        },
    });
}

sub remove_machine_key {
    my ($self, $user_id, $key_id) = @_;
    $user_id or _require('user_id required');
    $key_id  or _require('key_id required');
    $self->_delete("/users/$user_id/keys/$key_id");
}

# --- Password management ---

sub set_password {
    my ($self, $user_id, %args) = @_;
    $user_id or _require('user_id required');
    $self->_post("/users/$user_id/password", {
        password        => $args{password} // _require('password required'),
        $args{change_required} ? (changeRequired => $args{change_required}) : (),
    });
}

sub request_password_reset {
    my ($self, $user_id) = @_;
    $user_id or _require('user_id required');
    $self->_post("/users/$user_id/_reset_password", {});
}

# --- User metadata ---

sub set_user_metadata {
    my ($self, $user_id, $key, $value) = @_;
    $user_id       or _require('user_id required');
    $key           or _require('key required');
    defined $value or _require('value required');
    $self->_post("/users/$user_id/metadata/$key", {
        value => encode_base64($value, ''),
    });
}

sub get_user_metadata {
    my ($self, $user_id, $key) = @_;
    $user_id or _require('user_id required');
    $key     or _require('key required');
    $self->_get("/users/$user_id/metadata/$key");
}

sub list_user_metadata {
    my ($self, $user_id, %args) = @_;
    $user_id or _require('user_id required');
    $self->_post("/users/$user_id/metadata/_search", {
        query => {
            offset => $args{offset} // 0,
            limit  => $args{limit}  // 100,
        },
    });
}

# --- Projects ---

sub list_projects {
    my ($self, %args) = @_;
    $self->_post('/projects/_search', {
        query => {
            offset => $args{offset} // 0,
            limit  => $args{limit}  // 100,
        },
        $args{queries} ? (queries => $args{queries}) : (),
    });
}

sub get_project {
    my ($self, $project_id) = @_;
    $project_id or _require('project_id required');
    $self->_get("/projects/$project_id");
}

sub create_project {
    my ($self, %args) = @_;
    $self->_post('/projects', {
        name                  => $args{name} // _require('name required'),
        $args{project_role_assertion}   ? (projectRoleAssertion   => $args{project_role_assertion})   : (),
        $args{project_role_check}       ? (projectRoleCheck       => $args{project_role_check})       : (),
        $args{has_project_check}        ? (hasProjectCheck        => $args{has_project_check})        : (),
        $args{private_labeling_setting} ? (privateLabelingSetting => $args{private_labeling_setting}) : (),
    });
}

sub update_project {
    my ($self, $project_id, %args) = @_;
    $project_id or _require('project_id required');
    $self->_put("/projects/$project_id", {
        name => $args{name} // _require('name required'),
        $args{project_role_assertion}   ? (projectRoleAssertion   => $args{project_role_assertion})   : (),
        $args{project_role_check}       ? (projectRoleCheck       => $args{project_role_check})       : (),
        $args{has_project_check}        ? (hasProjectCheck        => $args{has_project_check})        : (),
        $args{private_labeling_setting} ? (privateLabelingSetting => $args{private_labeling_setting}) : (),
    });
}

sub delete_project {
    my ($self, $project_id) = @_;
    $project_id or _require('project_id required');
    $self->_delete("/projects/$project_id");
}

# --- Applications (OIDC) ---

sub list_apps {
    my ($self, $project_id, %args) = @_;
    $project_id or _require('project_id required');
    $self->_post("/projects/$project_id/apps/_search", {
        query => {
            offset => $args{offset} // 0,
            limit  => $args{limit}  // 100,
        },
        $args{queries} ? (queries => $args{queries}) : (),
    });
}

sub get_app {
    my ($self, $project_id, $app_id) = @_;
    $project_id or _require('project_id required');
    $app_id     or _require('app_id required');
    $self->_get("/projects/$project_id/apps/$app_id");
}

sub create_oidc_app {
    my ($self, $project_id, %args) = @_;
    $project_id or _require('project_id required');
    $self->_post("/projects/$project_id/apps/oidc", {
        name                  => $args{name}          // _require('name required'),
        redirectUris          => $args{redirect_uris} // _require('redirect_uris required'),
        responseTypes         => $args{response_types} // ['OIDC_RESPONSE_TYPE_CODE'],
        grantTypes            => $args{grant_types}    // ['OIDC_GRANT_TYPE_AUTHORIZATION_CODE'],
        appType               => $args{app_type}       // 'OIDC_APP_TYPE_WEB',
        authMethodType        => $args{auth_method}    // 'OIDC_AUTH_METHOD_TYPE_BASIC',
        $args{post_logout_uris}        ? (postLogoutRedirectUris => $args{post_logout_uris})        : (),
        $args{dev_mode}                ? (devMode                => $args{dev_mode})                : (),
        $args{access_token_type}       ? (accessTokenType        => $args{access_token_type})       : (),
        $args{id_token_role_assertion} ? (idTokenRoleAssertion   => $args{id_token_role_assertion}) : (),
        $args{additional_origins}      ? (additionalOrigins      => $args{additional_origins})      : (),
    });
}

sub update_oidc_app {
    my ($self, $project_id, $app_id, %args) = @_;
    $project_id or _require('project_id required');
    $app_id     or _require('app_id required');
    $self->_put("/projects/$project_id/apps/$app_id/oidc_config", {
        $args{redirect_uris}           ? (redirectUris            => $args{redirect_uris})           : (),
        $args{response_types}          ? (responseTypes           => $args{response_types})          : (),
        $args{grant_types}             ? (grantTypes              => $args{grant_types})             : (),
        $args{app_type}                ? (appType                 => $args{app_type})                : (),
        $args{auth_method}             ? (authMethodType          => $args{auth_method})             : (),
        $args{post_logout_uris}        ? (postLogoutRedirectUris  => $args{post_logout_uris})        : (),
        $args{dev_mode}                ? (devMode                 => $args{dev_mode})                : (),
        $args{access_token_type}       ? (accessTokenType         => $args{access_token_type})       : (),
        $args{id_token_role_assertion} ? (idTokenRoleAssertion    => $args{id_token_role_assertion}) : (),
        $args{additional_origins}      ? (additionalOrigins       => $args{additional_origins})      : (),
    });
}

sub delete_app {
    my ($self, $project_id, $app_id) = @_;
    $project_id or _require('project_id required');
    $app_id     or _require('app_id required');
    $self->_delete("/projects/$project_id/apps/$app_id");
}

# --- Organizations ---

sub get_org {
    my ($self) = @_;
    $self->_get('/orgs/me');
}

sub create_org {
    my ($self, %args) = @_;
    $self->_post('/orgs', {
        name => $args{name} // _require('name required'),
    });
}

sub list_orgs {
    my ($self, %args) = @_;
    $self->_post('/orgs/_search', {
        query => {
            offset => $args{offset} // 0,
            limit  => $args{limit}  // 100,
        },
        $args{queries} ? (queries => $args{queries}) : (),
    });
}

sub update_org {
    my ($self, %args) = @_;
    $self->_put('/orgs/me', {
        name => $args{name} // _require('name required'),
    });
}

sub deactivate_org {
    my ($self) = @_;
    $self->_post('/orgs/me/_deactivate', {});
}

# --- Roles ---

sub add_project_role {
    my ($self, $project_id, %args) = @_;
    $project_id or _require('project_id required');
    $self->_post("/projects/$project_id/roles", {
        roleKey     => $args{role_key} // _require('role_key required'),
        displayName => $args{display_name} // $args{role_key},
        $args{group} ? (group => $args{group}) : (),
    });
}

sub list_project_roles {
    my ($self, $project_id, %args) = @_;
    $project_id or _require('project_id required');
    $self->_post("/projects/$project_id/roles/_search", {
        query => {
            offset => $args{offset} // 0,
            limit  => $args{limit}  // 100,
        },
        $args{queries} ? (queries => $args{queries}) : (),
    });
}

# --- User Grants (role assignments) ---

sub create_user_grant {
    my ($self, %args) = @_;
    my $user_id = $args{user_id} // _require('user_id required');
    $self->_post("/users/$user_id/grants", {
        projectId => $args{project_id} // _require('project_id required'),
        roleKeys  => $args{role_keys}  // _require('role_keys required'),
    });
}

sub list_user_grants {
    my ($self, %args) = @_;
    $self->_post('/users/grants/_search', {
        query => {
            offset => $args{offset} // 0,
            limit  => $args{limit}  // 100,
        },
        $args{queries} ? (queries => $args{queries}) : (),
    });
}

# --- Identity Providers (IDPs) ---

sub list_idps {
    my ($self, %args) = @_;
    $self->_post('/idps/_search', {
        query => {
            offset => $args{offset} // 0,
            limit  => $args{limit}  // 100,
        },
        $args{queries} ? (queries => $args{queries}) : (),
    });
}

sub get_idp {
    my ($self, $idp_id) = @_;
    $idp_id or _require('idp_id required');
    $self->_get("/idps/$idp_id");
}

sub create_oidc_idp {
    my ($self, %args) = @_;
    $self->_post('/idps/oidc', {
        name         => $args{name}          // _require('name required'),
        clientId     => $args{client_id}     // _require('client_id required'),
        clientSecret => $args{client_secret} // _require('client_secret required'),
        issuer       => $args{issuer}        // _require('issuer required'),
        scopes       => $args{scopes}        // ['openid', 'profile', 'email'],
        $args{display_name_mapping} ? (displayNameMapping => $args{display_name_mapping}) : (),
        $args{username_mapping}     ? (usernameMapping    => $args{username_mapping})     : (),
        $args{auto_register}        ? (autoRegister       => $args{auto_register})        : (),
    });
}

sub update_idp {
    my ($self, $idp_id, %args) = @_;
    $idp_id or _require('idp_id required');
    $self->_put("/idps/$idp_id", {
        name => $args{name} // _require('name required'),
        $args{display_name_mapping} ? (displayNameMapping => $args{display_name_mapping}) : (),
        $args{username_mapping}     ? (usernameMapping    => $args{username_mapping})     : (),
        $args{auto_register}        ? (autoRegister       => $args{auto_register})        : (),
    });
}

sub delete_idp {
    my ($self, $idp_id) = @_;
    $idp_id or _require('idp_id required');
    $self->_delete("/idps/$idp_id");
}

sub activate_idp {
    my ($self, $idp_id) = @_;
    $idp_id or _require('idp_id required');
    $self->_post("/idps/$idp_id/_activate", {});
}

sub deactivate_idp {
    my ($self, $idp_id) = @_;
    $idp_id or _require('idp_id required');
    $self->_post("/idps/$idp_id/_deactivate", {});
}

1;

__END__

=head1 SYNOPSIS

    use WWW::Zitadel::Management;

    my $mgmt = WWW::Zitadel::Management->new(
        base_url => 'https://zitadel.example.com',
        token    => $personal_access_token,
    );

    # Human users
    my $users = $mgmt->list_users(limit => 50);
    my $user  = $mgmt->create_human_user(
        user_name  => 'alice',
        first_name => 'Alice',
        last_name  => 'Smith',
        email      => 'alice@example.com',
    );
    my $info = $mgmt->get_user($user_id);
    $mgmt->deactivate_user($user_id);
    $mgmt->delete_user($user_id);

    # Service (machine) users
    my $svc = $mgmt->create_service_user(
        user_name => 'ci-bot',
        name      => 'CI Bot',
    );
    my $key = $mgmt->add_machine_key($svc->{userId});
    my $keys = $mgmt->list_machine_keys($svc->{userId});
    $mgmt->remove_machine_key($svc->{userId}, $key->{keyId});

    # Password management
    $mgmt->set_password($user_id, password => 's3cr3t!');
    $mgmt->request_password_reset($user_id);

    # User metadata
    $mgmt->set_user_metadata($user_id, 'department', 'engineering');
    my $meta = $mgmt->get_user_metadata($user_id, 'department');
    my $all  = $mgmt->list_user_metadata($user_id);

    # Projects
    my $projects = $mgmt->list_projects;
    my $project  = $mgmt->create_project(name => 'My App');

    # OIDC Applications
    my $app = $mgmt->create_oidc_app($project_id,
        name          => 'Web Client',
        redirect_uris => ['https://app.example.com/callback'],
    );
    $mgmt->update_oidc_app($project_id, $app_id,
        redirect_uris => ['https://app.example.com/callback', 'https://app.example.com/silent'],
    );

    # Organizations
    my $orgs = $mgmt->list_orgs;
    $mgmt->update_org(name => 'Acme Corp');
    $mgmt->deactivate_org;

    # Roles
    $mgmt->add_project_role($project_id,
        role_key     => 'admin',
        display_name => 'Administrator',
    );

    # User Grants (assign roles)
    $mgmt->create_user_grant(
        user_id    => $user_id,
        project_id => $project_id,
        role_keys  => ['admin'],
    );

    # Identity Providers
    my $idp = $mgmt->create_oidc_idp(
        name          => 'Google',
        client_id     => $client_id,
        client_secret => $client_secret,
        issuer        => 'https://accounts.google.com',
    );
    $mgmt->activate_idp($idp->{idp}{id});
    my $idps = $mgmt->list_idps;

=head1 DESCRIPTION

Client for the Zitadel Management API v1. Authenticates with a Personal
Access Token (PAT) and provides methods for managing users, service users,
projects, OIDC applications, organizations, roles, and user grants.

All C<list_*> methods accept C<offset>, C<limit>, and C<queries> parameters.
The C<queries> parameter takes Zitadel's native query filter format — an
arrayref of query objects, for example:

    queries => [
        { displayNameQuery => { displayName => 'alice', method => 'TEXT_QUERY_METHOD_CONTAINS' } }
    ]

See the L<ZITADEL Management API docs|https://zitadel.com/docs/apis/mgmtapi> for
the full query syntax per resource type.

Errors are thrown as L<WWW::Zitadel::Error> subclass objects. Because they
stringify to their C<message>, existing C<eval>/C<$@> string-matching patterns
continue to work. For typed dispatch, check C<< $@->isa('WWW::Zitadel::Error::API') >>
etc.

=attr base_url

Required. The Zitadel instance URL, e.g. C<https://zitadel.example.com>.
Must not be empty.

=attr token

Required. Personal Access Token for authenticating with the Management API.

=attr ua

Optional L<LWP::UserAgent> instance. Provide a shared instance to reuse HTTP
connections across both OIDC and Management clients:

    my $ua   = LWP::UserAgent->new(timeout => 30);
    my $oidc = WWW::Zitadel::OIDC->new(issuer => $issuer, ua => $ua);
    my $mgmt = WWW::Zitadel::Management->new(
        base_url => $issuer,
        token    => $pat,
        ua       => $ua,
    );

=method list_users

=method get_user

=method create_human_user

=method update_user

=method deactivate_user

=method reactivate_user

=method delete_user

Human user CRUD operations. C<create_human_user> requires C<user_name>,
C<first_name>, C<last_name>, and C<email>.

=method create_service_user

=method list_service_users

=method get_service_user

=method delete_service_user

Machine/service user operations. C<create_service_user> requires C<user_name>
and C<name>. C<list_service_users> automatically filters to machine-type users.

=method add_machine_key

=method list_machine_keys

=method remove_machine_key

Manage JWT authentication keys for a service user. C<add_machine_key> accepts
an optional C<type> (default C<KEY_TYPE_JSON>) and C<expiration_date>.

=method set_password

=method request_password_reset

Password operations. C<set_password> requires C<user_id> and C<password>.

=method set_user_metadata

=method get_user_metadata

=method list_user_metadata

Key/value metadata attached to a user. Values are base64-encoded as required
by the ZITADEL API. C<set_user_metadata($user_id, $key, $value)>.

=method list_projects

=method get_project

=method create_project

=method update_project

=method delete_project

Project CRUD operations. C<create_project> requires C<name>.

=method list_apps

=method get_app

=method create_oidc_app

=method update_oidc_app

=method delete_app

OIDC application management within a project. C<create_oidc_app> requires
C<project_id>, C<name>, and C<redirect_uris>.

C<update_oidc_app> accepts the same snake_case keys as C<create_oidc_app>:
C<redirect_uris>, C<response_types>, C<grant_types>, C<app_type>,
C<auth_method>, C<post_logout_uris>, C<dev_mode>, C<access_token_type>,
C<id_token_role_assertion>, C<additional_origins>.

=method get_org

Returns the current organization of the authenticated user.

=method create_org

=method list_orgs

=method update_org

=method deactivate_org

Organization operations. C<create_org> and C<update_org> require C<name>.

=method add_project_role

=method list_project_roles

Manage project roles. C<add_project_role> requires C<project_id> and
C<role_key>.

=method create_user_grant

=method list_user_grants

Assign roles to users. C<create_user_grant> requires C<user_id>,
C<project_id>, and C<role_keys> (arrayref).

=method list_idps

=method get_idp

=method create_oidc_idp

=method update_idp

=method delete_idp

=method activate_idp

=method deactivate_idp

Identity provider management. C<create_oidc_idp> requires C<name>,
C<client_id>, C<client_secret>, and C<issuer>. Optional: C<scopes>
(default C<["openid","profile","email"]>), C<display_name_mapping>,
C<username_mapping>, C<auto_register>.

=head1 SEE ALSO

L<WWW::Zitadel>, L<WWW::Zitadel::OIDC>, L<WWW::Zitadel::Error>

=cut
