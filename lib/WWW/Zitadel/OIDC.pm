package WWW::Zitadel::OIDC;

# ABSTRACT: OIDC client for Zitadel - token verification, JWKS, discovery

use Moo;
use Crypt::JWT qw(decode_jwt);
use JSON::MaybeXS qw(decode_json);
use LWP::UserAgent;
use URI;
use namespace::clean;

our $VERSION = '0.001';

has issuer => (
    is       => 'ro',
    required => 1,
);

has ua => (
    is      => 'lazy',
    builder => sub { LWP::UserAgent->new(timeout => 10) },
);

has _discovery => (
    is      => 'lazy',
    builder => sub {
        my $self = shift;
        my $url = $self->issuer . '/.well-known/openid-configuration';
        my $res = $self->ua->get($url);
        die "Discovery failed: " . $res->status_line . "\n" unless $res->is_success;
        decode_json($res->decoded_content);
    },
);

has _jwks_cache => (
    is      => 'rw',
    default => sub { undef },
);

sub discovery { $_[0]->_discovery }

sub jwks_uri {
    my $self = shift;
    $self->_discovery->{jwks_uri}
        // die "No jwks_uri in discovery document\n";
}

sub token_endpoint {
    my $self = shift;
    $self->_discovery->{token_endpoint}
        // die "No token_endpoint in discovery document\n";
}

sub userinfo_endpoint {
    my $self = shift;
    $self->_discovery->{userinfo_endpoint}
        // die "No userinfo_endpoint in discovery document\n";
}

sub authorization_endpoint {
    my $self = shift;
    $self->_discovery->{authorization_endpoint}
        // die "No authorization_endpoint in discovery document\n";
}

sub introspection_endpoint {
    my $self = shift;
    $self->_discovery->{introspection_endpoint}
        // die "No introspection_endpoint in discovery document\n";
}

sub jwks {
    my ($self, %args) = @_;
    my $force = $args{force_refresh} // 0;

    if (!$force && $self->_jwks_cache) {
        return $self->_jwks_cache;
    }

    my $res = $self->ua->get($self->jwks_uri);
    die "JWKS fetch failed: " . $res->status_line . "\n" unless $res->is_success;
    my $jwks = decode_json($res->decoded_content);
    $self->_jwks_cache($jwks);
    return $jwks;
}

sub verify_token {
    my ($self, $token, %args) = @_;
    die "No token provided\n" unless defined $token;

    my $jwks = $self->jwks;
    my $claims;
    eval {
        $claims = $self->_decode_jwt(
            token       => $token,
            kid_keys    => $jwks,
            verify_exp  => $args{verify_exp} // 1,
            verify_iat  => $args{verify_iat} // 0,
            verify_nbf  => $args{verify_nbf} // 0,
            verify_iss  => $self->issuer,
            verify_aud  => $args{audience},
            accepted_key_alg => $args{accepted_key_alg} // ['RS256', 'RS384', 'RS512'],
        );
    };
    if ($@ && !$args{no_retry}) {
        # Key rotation: refresh JWKS and retry once
        $jwks = $self->jwks(force_refresh => 1);
        $claims = $self->_decode_jwt(
            token       => $token,
            kid_keys    => $jwks,
            verify_exp  => $args{verify_exp} // 1,
            verify_iat  => $args{verify_iat} // 0,
            verify_nbf  => $args{verify_nbf} // 0,
            verify_iss  => $self->issuer,
            verify_aud  => $args{audience},
            accepted_key_alg => $args{accepted_key_alg} // ['RS256', 'RS384', 'RS512'],
        );
    }
    elsif ($@) {
        die $@;
    }

    return $claims;
}

sub _decode_jwt {
    my ($self, %args) = @_;
    return decode_jwt(%args);
}

sub userinfo {
    my ($self, $access_token) = @_;
    die "No access token provided\n" unless defined $access_token;

    my $res = $self->ua->get(
        $self->userinfo_endpoint,
        Authorization => "Bearer $access_token",
    );
    die "UserInfo failed: " . $res->status_line . "\n" unless $res->is_success;
    return decode_json($res->decoded_content);
}

sub introspect {
    my ($self, $token, %args) = @_;
    die "No token provided\n" unless defined $token;
    die "Introspection requires client_id and client_secret\n"
        unless $args{client_id} && $args{client_secret};

    my $res = $self->ua->post(
        $self->introspection_endpoint,
        Content_Type => 'application/x-www-form-urlencoded',
        Content      => {
            token         => $token,
            client_id     => $args{client_id},
            client_secret => $args{client_secret},
            token_type_hint => $args{token_type_hint} // 'access_token',
        },
    );
    die "Introspection failed: " . $res->status_line . "\n" unless $res->is_success;
    return decode_json($res->decoded_content);
}

sub token {
    my ($self, %args) = @_;

    my $grant_type = delete $args{grant_type}
        // die "grant_type required\n";

    my $res = $self->ua->post(
        $self->token_endpoint,
        Content_Type => 'application/x-www-form-urlencoded',
        Content      => {
            grant_type => $grant_type,
            %args,
        },
    );
    die "Token endpoint failed: " . $res->status_line . "\n" unless $res->is_success;
    return decode_json($res->decoded_content);
}

sub client_credentials_token {
    my ($self, %args) = @_;

    my $client_id = delete $args{client_id}
        // die "client_id required\n";
    my $client_secret = delete $args{client_secret}
        // die "client_secret required\n";

    return $self->token(
        grant_type    => 'client_credentials',
        client_id     => $client_id,
        client_secret => $client_secret,
        %args,
    );
}

sub refresh_token {
    my ($self, $refresh_token, %args) = @_;
    die "refresh_token required\n" unless defined $refresh_token && length $refresh_token;

    return $self->token(
        grant_type    => 'refresh_token',
        refresh_token => $refresh_token,
        %args,
    );
}

sub exchange_authorization_code {
    my ($self, %args) = @_;

    my $code = delete $args{code}
        // die "code required\n";
    my $redirect_uri = delete $args{redirect_uri}
        // die "redirect_uri required\n";

    return $self->token(
        grant_type   => 'authorization_code',
        code         => $code,
        redirect_uri => $redirect_uri,
        %args,
    );
}

1;

__END__

=head1 SYNOPSIS

    use WWW::Zitadel::OIDC;

    my $oidc = WWW::Zitadel::OIDC->new(
        issuer => 'https://zitadel.example.com',
    );

    # Discovery
    my $config = $oidc->discovery;

    # Fetch JWKS
    my $jwks = $oidc->jwks;

    # Verify an access token (JWT)
    my $claims = $oidc->verify_token($access_token);

    # Verify with audience check
    my $claims = $oidc->verify_token($token,
        audience => 'my-client-id',
    );

    # Fetch user info
    my $user = $oidc->userinfo($access_token);

    # Token introspection (requires client credentials)
    my $info = $oidc->introspect($token,
        client_id     => $client_id,
        client_secret => $client_secret,
    );

    # Token endpoint helpers
    my $cc = $oidc->client_credentials_token(
        client_id     => $client_id,
        client_secret => $client_secret,
        scope         => 'openid profile',
    );

    my $refreshed = $oidc->refresh_token(
        $refresh_token,
        client_id     => $client_id,
        client_secret => $client_secret,
    );

=head1 DESCRIPTION

OIDC client for Zitadel. Handles discovery, JWKS fetching, JWT verification
via L<Crypt::JWT>, and userinfo/introspection endpoints.

Token verification automatically retries with a refreshed JWKS on failure,
handling key rotation transparently.

=attr issuer

Required. The Zitadel issuer URL, e.g. C<https://zitadel.example.com>.

=attr ua

Optional L<LWP::UserAgent> instance. A default one with 10s timeout is created.

=method discovery

Returns the parsed OpenID Connect discovery document from
C</.well-known/openid-configuration>.

=method jwks

Returns the JSON Web Key Set. Caches after first fetch.
Pass C<< force_refresh => 1 >> to bypass the cache.

=method verify_token

    my $claims = $oidc->verify_token($jwt, %options);

Verifies a JWT access token against the JWKS. Returns the decoded claims
hashref on success, dies on failure.

Options: C<audience>, C<verify_exp> (default 1), C<verify_iat> (default 0),
C<verify_nbf> (default 0), C<accepted_key_alg> (default RS256/384/512).

=method userinfo

    my $info = $oidc->userinfo($access_token);

Calls the UserInfo endpoint with the given access token. Returns parsed
JSON response.

=method introspect

    my $info = $oidc->introspect($token,
        client_id     => $id,
        client_secret => $secret,
    );

Calls the token introspection endpoint. Requires C<client_id> and
C<client_secret> for authentication.

=method token

    my $token_response = $oidc->token(
        grant_type => 'client_credentials',
        client_id => $id,
        client_secret => $secret,
        scope => 'openid profile',
    );

Generic token endpoint helper. Sends a form-encoded POST to the discovered
C<token_endpoint> and returns parsed JSON.

=method client_credentials_token

    my $token_response = $oidc->client_credentials_token(
        client_id => $id,
        client_secret => $secret,
        scope => 'openid profile',
    );

Convenience wrapper around C<token> for C<client_credentials>.

=method refresh_token

    my $token_response = $oidc->refresh_token(
        $refresh_token,
        client_id => $id,
        client_secret => $secret,
    );

Convenience wrapper around C<token> for C<refresh_token>.

=method exchange_authorization_code

    my $token_response = $oidc->exchange_authorization_code(
        code => $code,
        redirect_uri => $redirect_uri,
        client_id => $id,
        client_secret => $secret,
        code_verifier => $verifier,
    );

Convenience wrapper around C<token> for C<authorization_code>.

=head1 SEE ALSO

L<WWW::Zitadel>, L<Crypt::JWT>

=cut
