package WWW::Zitadel::Management;

# ABSTRACT: Client for Zitadel Management API v1

use Moo;
use JSON::MaybeXS qw(encode_json decode_json);
use LWP::UserAgent;
use HTTP::Request;
use namespace::clean;

our $VERSION = '0.001';

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
        my $msg = "API error: " . $res->status_line;
        if ($data && $data->{message}) {
            $msg .= " - $data->{message}";
        }
        die "$msg\n";
    }

    return $data // {};
}

sub _get    { $_[0]->_request('GET',    $_[1]) }
sub _post   { $_[0]->_request('POST',   $_[1], $_[2]) }
sub _put    { $_[0]->_request('PUT',    $_[1], $_[2]) }
sub _delete { $_[0]->_request('DELETE', $_[1]) }

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
    die "user_id required\n" unless $user_id;
    $self->_get("/users/$user_id");
}

sub create_human_user {
    my ($self, %args) = @_;
    $self->_post('/users/human', {
        userName => $args{user_name} // die("user_name required\n"),
        profile  => {
            firstName   => $args{first_name} // die("first_name required\n"),
            lastName    => $args{last_name}  // die("last_name required\n"),
            displayName => $args{display_name} // "$args{first_name} $args{last_name}",
            $args{nick_name}       ? (nickName       => $args{nick_name})       : (),
            $args{preferred_language} ? (preferredLanguage => $args{preferred_language}) : (),
        },
        email => {
            email           => $args{email} // die("email required\n"),
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
    die "user_id required\n" unless $user_id;
    $self->_put("/users/$user_id/profile", {
        $args{first_name}    ? (firstName   => $args{first_name})    : (),
        $args{last_name}     ? (lastName    => $args{last_name})     : (),
        $args{display_name}  ? (displayName => $args{display_name})  : (),
        $args{nick_name}     ? (nickName    => $args{nick_name})     : (),
    });
}

sub deactivate_user {
    my ($self, $user_id) = @_;
    die "user_id required\n" unless $user_id;
    $self->_post("/users/$user_id/_deactivate", {});
}

sub reactivate_user {
    my ($self, $user_id) = @_;
    die "user_id required\n" unless $user_id;
    $self->_post("/users/$user_id/_reactivate", {});
}

sub delete_user {
    my ($self, $user_id) = @_;
    die "user_id required\n" unless $user_id;
    $self->_delete("/users/$user_id");
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
    die "project_id required\n" unless $project_id;
    $self->_get("/projects/$project_id");
}

sub create_project {
    my ($self, %args) = @_;
    $self->_post('/projects', {
        name                   => $args{name} // die("name required\n"),
        $args{project_role_assertion}    ? (projectRoleAssertion    => $args{project_role_assertion})    : (),
        $args{project_role_check}        ? (projectRoleCheck        => $args{project_role_check})        : (),
        $args{has_project_check}         ? (hasProjectCheck         => $args{has_project_check})         : (),
        $args{private_labeling_setting}  ? (privateLabelingSetting  => $args{private_labeling_setting})  : (),
    });
}

sub update_project {
    my ($self, $project_id, %args) = @_;
    die "project_id required\n" unless $project_id;
    $self->_put("/projects/$project_id", {
        name => $args{name} // die("name required\n"),
        $args{project_role_assertion}    ? (projectRoleAssertion    => $args{project_role_assertion})    : (),
        $args{project_role_check}        ? (projectRoleCheck        => $args{project_role_check})        : (),
        $args{has_project_check}         ? (hasProjectCheck         => $args{has_project_check})         : (),
        $args{private_labeling_setting}  ? (privateLabelingSetting  => $args{private_labeling_setting})  : (),
    });
}

sub delete_project {
    my ($self, $project_id) = @_;
    die "project_id required\n" unless $project_id;
    $self->_delete("/projects/$project_id");
}

# --- Applications (OIDC) ---

sub list_apps {
    my ($self, $project_id, %args) = @_;
    die "project_id required\n" unless $project_id;
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
    die "project_id required\n" unless $project_id;
    die "app_id required\n" unless $app_id;
    $self->_get("/projects/$project_id/apps/$app_id");
}

sub create_oidc_app {
    my ($self, $project_id, %args) = @_;
    die "project_id required\n" unless $project_id;
    $self->_post("/projects/$project_id/apps/oidc", {
        name                  => $args{name} // die("name required\n"),
        redirectUris          => $args{redirect_uris} // die("redirect_uris required\n"),
        responseTypes         => $args{response_types} // ['OIDC_RESPONSE_TYPE_CODE'],
        grantTypes            => $args{grant_types} // ['OIDC_GRANT_TYPE_AUTHORIZATION_CODE'],
        appType               => $args{app_type} // 'OIDC_APP_TYPE_WEB',
        authMethodType        => $args{auth_method} // 'OIDC_AUTH_METHOD_TYPE_BASIC',
        $args{post_logout_uris}   ? (postLogoutRedirectUris => $args{post_logout_uris}) : (),
        $args{dev_mode}           ? (devMode                => $args{dev_mode})          : (),
        $args{access_token_type}  ? (accessTokenType        => $args{access_token_type}) : (),
        $args{id_token_role_assertion} ? (idTokenRoleAssertion => $args{id_token_role_assertion}) : (),
    });
}

sub update_oidc_app {
    my ($self, $project_id, $app_id, %args) = @_;
    die "project_id required\n" unless $project_id;
    die "app_id required\n" unless $app_id;
    $self->_put("/projects/$project_id/apps/$app_id/oidc_config", \%args);
}

sub delete_app {
    my ($self, $project_id, $app_id) = @_;
    die "project_id required\n" unless $project_id;
    die "app_id required\n" unless $app_id;
    $self->_delete("/projects/$project_id/apps/$app_id");
}

# --- Organizations ---

sub get_org {
    my ($self) = @_;
    $self->_get('/orgs/me');
}

# --- Roles ---

sub add_project_role {
    my ($self, $project_id, %args) = @_;
    die "project_id required\n" unless $project_id;
    $self->_post("/projects/$project_id/roles", {
        roleKey     => $args{role_key} // die("role_key required\n"),
        displayName => $args{display_name} // $args{role_key},
        $args{group} ? (group => $args{group}) : (),
    });
}

sub list_project_roles {
    my ($self, $project_id, %args) = @_;
    die "project_id required\n" unless $project_id;
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
    my $user_id = $args{user_id} // die "user_id required\n";
    $self->_post("/users/$user_id/grants", {
        projectId  => $args{project_id} // die("project_id required\n"),
        roleKeys   => $args{role_keys}  // die("role_keys required\n"),
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

1;

__END__

=head1 SYNOPSIS

    use WWW::Zitadel::Management;

    my $mgmt = WWW::Zitadel::Management->new(
        base_url => 'https://zitadel.example.com',
        token    => $personal_access_token,
    );

    # Users
    my $users = $mgmt->list_users(limit => 50);
    my $user  = $mgmt->create_human_user(
        user_name  => 'alice',
        first_name => 'Alice',
        last_name  => 'Smith',
        email      => 'alice@example.com',
    );
    my $info  = $mgmt->get_user($user_id);
    $mgmt->deactivate_user($user_id);
    $mgmt->delete_user($user_id);

    # Projects
    my $projects = $mgmt->list_projects;
    my $project  = $mgmt->create_project(name => 'My App');

    # OIDC Applications
    my $app = $mgmt->create_oidc_app($project_id,
        name          => 'Web Client',
        redirect_uris => ['https://app.example.com/callback'],
    );

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

=head1 DESCRIPTION

Client for the Zitadel Management API v1. Authenticates with a Personal
Access Token (PAT) and provides methods for managing users, projects,
OIDC applications, roles, and user grants.

All C<list_*> methods accept C<offset>, C<limit>, and C<queries> parameters.
The C<queries> parameter takes Zitadel's native query filter format.

=attr base_url

Required. The Zitadel instance URL, e.g. C<https://zitadel.example.com>.

=attr token

Required. Personal Access Token for authenticating with the Management API.

=attr ua

Optional L<LWP::UserAgent> instance.

=method list_users

=method get_user

=method create_human_user

=method update_user

=method deactivate_user

=method reactivate_user

=method delete_user

User CRUD operations. C<create_human_user> requires C<user_name>,
C<first_name>, C<last_name>, and C<email>.

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

=method get_org

Returns the current organization of the authenticated user.

=method add_project_role

=method list_project_roles

Manage project roles. C<add_project_role> requires C<project_id> and
C<role_key>.

=method create_user_grant

=method list_user_grants

Assign roles to users. C<create_user_grant> requires C<user_id>,
C<project_id>, and C<role_keys> (arrayref).

=head1 SEE ALSO

L<WWW::Zitadel>, L<WWW::Zitadel::OIDC>

=cut
