package WWW::Zitadel::OIDC;

# ABSTRACT: OIDC client for Zitadel - token verification, JWKS, discovery

use Moo;
use Crypt::JWT qw(decode_jwt);
use JSON::MaybeXS qw(decode_json);
use LWP::UserAgent;
use WWW::Zitadel::Error;
use namespace::clean;

our $VERSION = '0.002';

# The number of characters of a response body that are copied into an error
# message. A body can be an HTML page of a proxy; nobody wants that in a
# log line.
my $MAX_BODY_IN_ERROR = 200;

has issuer => (
    is       => 'ro',
    required => 1,
);

sub BUILD {
    my $self = shift;
    die WWW::Zitadel::Error::Validation->new(
        message => 'issuer must not be empty',
    ) unless length $self->issuer;
}

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
        unless ($res->is_success) {
            die WWW::Zitadel::Error::Network->new(
                message => 'Discovery failed: ' . $res->status_line,
            );
        }
        $self->_decode_json_body($res, 'Discovery');
    },
);

has _jwks_cache => (
    is      => 'rw',
    default => sub { undef },
);

# Seconds that have to pass between two refreshes of the keys. A token that
# names a key this client does not know makes the keys be fetched again, but
# not more often than this: a stream of forged tokens must not become a
# stream of requests to the issuer.
has jwks_min_age => (
    is      => 'ro',
    default => 60,
);

# When the keys were fetched the last time because a token named an unknown
# key. The first, cached fetch does not count: the first token with an
# unknown key has to be able to trigger a refresh right away.
has _jwks_fetched => (
    is       => 'rw',
    init_arg => undef,
    default  => sub { 0 },
);

sub discovery { $_[0]->_discovery }

# A discovery document without the endpoint we need is a wrong document, not
# a broken network: that is a validation error, with the same wording as
# before.
sub jwks_uri {
    my $self = shift;
    $self->_discovery->{jwks_uri}
        // die WWW::Zitadel::Error::Validation->new(
            message => 'No jwks_uri in discovery document',
        );
}

sub token_endpoint {
    my $self = shift;
    $self->_discovery->{token_endpoint}
        // die WWW::Zitadel::Error::Validation->new(
            message => 'No token_endpoint in discovery document',
        );
}

sub userinfo_endpoint {
    my $self = shift;
    $self->_discovery->{userinfo_endpoint}
        // die WWW::Zitadel::Error::Validation->new(
            message => 'No userinfo_endpoint in discovery document',
        );
}

sub authorization_endpoint {
    my $self = shift;
    $self->_discovery->{authorization_endpoint}
        // die WWW::Zitadel::Error::Validation->new(
            message => 'No authorization_endpoint in discovery document',
        );
}

sub introspection_endpoint {
    my $self = shift;
    $self->_discovery->{introspection_endpoint}
        // die WWW::Zitadel::Error::Validation->new(
            message => 'No introspection_endpoint in discovery document',
        );
}

sub jwks {
    my ($self, %args) = @_;
    my $force = $args{force_refresh} // 0;

    if (!$force && $self->_jwks_cache) {
        return $self->_jwks_cache;
    }

    my $res = $self->ua->get($self->jwks_uri);
    unless ($res->is_success) {
        die WWW::Zitadel::Error::Network->new(
            message => 'JWKS fetch failed: ' . $res->status_line,
        );
    }
    my $jwks = $self->_decode_json_body($res, 'JWKS');
    $self->_jwks_cache($jwks);
    $self->_jwks_fetched(time) if $force;
    return $jwks;
}

# The body of an answer, shortened for an error message.
sub _shorten {
    my ($self, $body) = @_;
    return undef unless defined $body;
    return $body if length $body <= $MAX_BODY_IN_ERROR;
    return substr($body, 0, $MAX_BODY_IN_ERROR) . '...';
}

# The parsed body of a successful answer. A body that is not JSON - the
# error page of a proxy, a wrong issuer URL - is a fault of the server, so
# it is reported as an API error and not as a failed call.
sub _decode_json_body {
    my ($self, $res, $label) = @_;

    my $body = $res->decoded_content;
    my $data = eval { decode_json($body) };
    if ($@) {
        my $reason = $@;
        chomp $reason;
        die WWW::Zitadel::Error::API->new(
            message     => $label . ' response is not valid JSON: ' . $reason,
            http_status => $res->status_line,
            api_message => $self->_shorten($body),
        );
    }
    return $data;
}

# LWP marks an answer it could not deliver itself - a refused connection, a
# timeout - with the status 500 and the header "Client-Warning: Internal
# response". A server that answers with an error is a different case: the
# server did answer, and the body it sent says why.
sub _is_internal_response {
    my ($self, $res) = @_;

    my $warning = eval { $res->header('Client-Warning') };
    return 0 unless defined $warning && $warning =~ /Internal response/i;

    my $status = $res->status_line // '';
    return $status =~ /^500\b/ ? 1 : 0;
}

# The OAuth error of a failed answer: the description if the body carries
# one, the error code otherwise, the raw body if it is not JSON at all.
sub _api_message {
    my ($self, $res) = @_;

    my $body = $res->decoded_content;
    return undef unless defined $body && length $body;

    my $data = eval { decode_json($body) };
    if (ref $data eq 'HASH') {
        for my $field (qw(error_description error)) {
            my $value = $data->{$field};
            next unless defined $value && !ref $value && length $value;
            return $value;
        }
    }
    return $self->_shorten($body);
}

# The exception for an endpoint that did not answer successfully. The
# message stays exactly as it has always been, so that callers matching on
# the error string keep working.
sub _endpoint_error {
    my ($self, $res, $label) = @_;

    my $message = $label . ' failed: ' . $res->status_line;

    if ($self->_is_internal_response($res)) {
        return WWW::Zitadel::Error::Network->new(message => $message);
    }

    return WWW::Zitadel::Error::API->new(
        message     => $message,
        http_status => $res->status_line,
        api_message => $self->_api_message($res),
    );
}

sub verify_token {
    my ($self, $token, %args) = @_;
    die WWW::Zitadel::Error::Validation->new(message => 'No token provided')
        unless defined $token;

    # Crypt::JWT pins the signature algorithm through accepted_alg and
    # silently ignores option names it does not know, so the list has to be
    # handed over under exactly that name. accepted_key_alg is the name this
    # method took first and stays as an alias.
    my $accepted_alg = $args{accepted_alg}
        // $args{accepted_key_alg}
        // ['RS256', 'RS384', 'RS512'];

    my %check = (
        token        => $token,
        verify_exp   => $args{verify_exp} // 1,
        verify_iat   => $args{verify_iat} // 0,
        verify_nbf   => $args{verify_nbf} // 0,
        verify_iss   => $self->issuer,
        verify_aud   => $args{audience},
        accepted_alg => $accepted_alg,
    );

    my $jwks   = $self->jwks;
    my $claims = eval { $self->_decode_jwt(%check, kid_keys => $jwks) };
    my $error  = $@;

    # Key rotation: only an unknown key can be cured by new keys. Every other
    # rejection - an expired token, the wrong issuer, a bad signature - is the
    # token's own fault and must not cost a request to the issuer. The refresh
    # happens at most once per jwks_min_age, so a stream of forged tokens
    # does not become a stream of requests either.
    if (   $error
        && !$args{no_retry}
        && $error =~ /kid_keys lookup failed/
        && time - $self->_jwks_fetched >= $self->jwks_min_age )
    {
        $jwks   = $self->jwks(force_refresh => 1);
        $claims = eval { $self->_decode_jwt(%check, kid_keys => $jwks) };
        $error  = $@;
    }

    die $error if $error;

    return $claims;
}

sub _decode_jwt {
    my ($self, %args) = @_;
    return decode_jwt(%args);
}

sub userinfo {
    my ($self, $access_token) = @_;
    die WWW::Zitadel::Error::Validation->new(message => 'No access token provided')
        unless defined $access_token;

    my $res = $self->ua->get(
        $self->userinfo_endpoint,
        Authorization => "Bearer $access_token",
    );
    unless ($res->is_success) {
        die $self->_endpoint_error($res, 'UserInfo');
    }
    return $self->_decode_json_body($res, 'UserInfo');
}

sub introspect {
    my ($self, $token, %args) = @_;
    die WWW::Zitadel::Error::Validation->new(message => 'No token provided')
        unless defined $token;
    die WWW::Zitadel::Error::Validation->new(
        message => 'Introspection requires client_id and client_secret',
    ) unless $args{client_id} && $args{client_secret};

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
    unless ($res->is_success) {
        die $self->_endpoint_error($res, 'Introspection');
    }
    return $self->_decode_json_body($res, 'Introspection');
}

sub token {
    my ($self, %args) = @_;

    my $grant_type = delete $args{grant_type}
        // die WWW::Zitadel::Error::Validation->new(message => 'grant_type required');

    my $res = $self->ua->post(
        $self->token_endpoint,
        Content_Type => 'application/x-www-form-urlencoded',
        Content      => {
            grant_type => $grant_type,
            %args,
        },
    );
    unless ($res->is_success) {
        die $self->_endpoint_error($res, 'Token endpoint');
    }
    return $self->_decode_json_body($res, 'Token endpoint');
}

sub client_credentials_token {
    my ($self, %args) = @_;

    my $client_id = delete $args{client_id}
        // die WWW::Zitadel::Error::Validation->new(message => 'client_id required');
    my $client_secret = delete $args{client_secret}
        // die WWW::Zitadel::Error::Validation->new(message => 'client_secret required');

    return $self->token(
        grant_type    => 'client_credentials',
        client_id     => $client_id,
        client_secret => $client_secret,
        %args,
    );
}

sub refresh_token {
    my ($self, $refresh_token, %args) = @_;
    die WWW::Zitadel::Error::Validation->new(message => 'refresh_token required')
        unless defined $refresh_token && length $refresh_token;

    return $self->token(
        grant_type    => 'refresh_token',
        refresh_token => $refresh_token,
        %args,
    );
}

sub exchange_authorization_code {
    my ($self, %args) = @_;

    my $code = delete $args{code}
        // die WWW::Zitadel::Error::Validation->new(message => 'code required');
    my $redirect_uri = delete $args{redirect_uri}
        // die WWW::Zitadel::Error::Validation->new(message => 'redirect_uri required');

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

Token verification fetches the keys again when a token names a key the
client does not know, which handles key rotation. Every other rejection is
thrown unchanged and does not cost a request to the issuer.

A failed call raises a L<WWW::Zitadel::Error> subclass: a missing argument or
a discovery document without the needed endpoint is a
L<WWW::Zitadel::Error::Validation>, an answer that was not successful is a
L<WWW::Zitadel::Error::API> carrying C<http_status> and C<api_message> (the
OAuth C<error_description> or C<error> of the body), and a request that never
reached a server is a L<WWW::Zitadel::Error::Network>.

=attr issuer

Required. The Zitadel issuer URL, e.g. C<https://zitadel.example.com>.

=attr ua

Optional L<LWP::UserAgent> instance. A default one with 10s timeout is created.

=attr jwks_min_age

Seconds that have to pass before L</verify_token> fetches the keys again for
a token that names an unknown key. Default 60, so that a stream of forged
tokens does not become a stream of requests to Zitadel.

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
C<verify_nbf> (default 0), C<accepted_alg> (default RS256/384/512).

A token that names a key the JWKS does not have makes the keys be fetched
again and the token be decoded once more; that happens at most once per
L</jwks_min_age>. Every other rejection - an expired token, the wrong
issuer, a bad signature - is thrown unchanged and does not fetch the keys
again. C<no_retry> turns the refresh off.

C<accepted_alg> is the allow-list of signature algorithms and is passed to
L<Crypt::JWT> as its C<accepted_alg>: an algorithm name, an arrayref of names
or a C<Regexp>. A token signed with any other algorithm is rejected, even if
its key is in the JWKS. The default accepts RSA PKCS#1 v1.5 signatures only;
an instance that signs with ECDSA or Ed25519 keys needs the list widened:

    my $claims = $oidc->verify_token($jwt,
        accepted_alg => ['RS256', 'ES256', 'EdDSA'],
    );

C<accepted_key_alg> is the older name of the same option and is still
accepted; C<accepted_alg> wins if both are given.

=method userinfo

    my $info = $oidc->userinfo($access_token);

Calls the UserInfo endpoint with the given access token. Returns parsed
JSON response.

An answer that was not successful throws L<WWW::Zitadel::Error::API> with
the status line in C<http_status> and the OAuth error of the body in
C<api_message>.

=method introspect

    my $info = $oidc->introspect($token,
        client_id     => $id,
        client_secret => $secret,
    );

Calls the token introspection endpoint. Requires C<client_id> and
C<client_secret> for authentication.

An answer that was not successful throws L<WWW::Zitadel::Error::API> with
the status line in C<http_status> and the OAuth error of the body in
C<api_message>.

=method token

    my $token_response = $oidc->token(
        grant_type => 'client_credentials',
        client_id => $id,
        client_secret => $secret,
        scope => 'openid profile',
    );

Generic token endpoint helper. Sends a form-encoded POST to the discovered
C<token_endpoint> and returns parsed JSON.

An answer that was not successful throws L<WWW::Zitadel::Error::API> with
the status line in C<http_status> and the OAuth error of the body in
C<api_message>, so that C<invalid_grant> can be told apart from
C<invalid_client>.

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
