use strict;
use warnings;

use Test::More;
use Test::Exception;
use JSON::MaybeXS qw(encode_json);

use WWW::Zitadel::OIDC;
use WWW::Zitadel::Error;

# The error paths of the OIDC client: what a caller gets when the server
# answers with an error, when the answer is not JSON at all, when the
# discovery document lacks an endpoint and when the request never reached a
# server at all.

{
    package Local::Response;

    sub new {
        my ($class, %args) = @_;
        bless \%args, $class;
    }

    sub is_success      { $_[0]->{is_success} }
    sub status_line     { $_[0]->{status_line} }
    sub decoded_content { $_[0]->{decoded_content} // '' }

    # Like HTTP::Response::header: the field name does not matter, an
    # unknown field is undef.
    sub header {
        my ($self, $field) = @_;
        my $headers = $self->{headers} || {};
        for my $name (keys %$headers) {
            return $headers->{$name} if lc $name eq lc $field;
        }
        return undef;
    }
}

{
    package Local::OIDCUA;

    sub new {
        my ($class, %args) = @_;
        bless {
            get_queue  => $args{get_queue}  || [],
            post_queue => $args{post_queue} || [],
            calls      => { get => [], post => [] },
        }, $class;
    }

    sub calls { $_[0]->{calls} }

    sub get {
        my ($self, @args) = @_;
        push @{ $self->{calls}{get} }, [@args];
        my $res = shift @{ $self->{get_queue} };
        die "No mocked GET response available\n" unless $res;
        return $res;
    }

    sub post {
        my ($self, @args) = @_;
        push @{ $self->{calls}{post} }, [@args];
        my $res = shift @{ $self->{post_queue} };
        die "No mocked POST response available\n" unless $res;
        return $res;
    }
}

sub _discovery_json {
    return {
        jwks_uri               => 'https://zitadel.example.com/oauth/v2/keys',
        token_endpoint         => 'https://zitadel.example.com/oauth/v2/token',
        userinfo_endpoint      => 'https://zitadel.example.com/oidc/v1/userinfo',
        authorization_endpoint => 'https://zitadel.example.com/oauth/v2/authorize',
        introspection_endpoint => 'https://zitadel.example.com/oauth/v2/introspect',
    };
}

sub _response {
    my (%args) = @_;
    return Local::Response->new(
        is_success      => $args{is_success} // 0,
        status_line     => $args{status_line} // '200 OK',
        decoded_content => $args{body} // '',
        headers         => $args{headers} || {},
    );
}

sub _oidc {
    my (%args) = @_;
    return WWW::Zitadel::OIDC->new(
        issuer => 'https://zitadel.example.com',
        ua     => Local::OIDCUA->new(%args),
    );
}

# The discovery document is fetched first, so every case that talks to an
# endpoint needs it in the queue.
sub _with_discovery {
    my (%args) = @_;
    my $discovery = _response(
        is_success => 1,
        body       => encode_json(_discovery_json()),
    );
    return _oidc(
        get_queue  => [ $discovery, @{ $args{get_queue}  || [] } ],
        post_queue => $args{post_queue} || [],
    );
}

sub _error {
    my ($code) = @_;
    eval { $code->() };
    return $@;
}

# An attribute of the exception. The older exceptions do not carry the
# OAuth attributes at all, so the lookup must not die.
sub _attr {
    my ($err, $name) = @_;
    return undef unless ref $err && $err->can($name);
    return $err->$name;
}

# The token endpoint answers with an OAuth error: the caller has to be able
# to tell invalid_grant from invalid_client.
{
    my $oidc = _with_discovery(
        post_queue => [
            _response(
                status_line => '400 Bad Request',
                body => '{"error":"invalid_grant","error_description":"The user code is invalid"}',
            ),
        ],
    );

    my $err = _error(sub {
        $oidc->token(
            grant_type    => 'authorization_code',
            code          => 'nope',
            client_id     => 'client-1',
            client_secret => 'secret-1',
        );
    });

    ok ref $err && $err->isa('WWW::Zitadel::Error::API'),
        'a rejected token is an API error';
    is "$err", 'Token endpoint failed: 400 Bad Request',
        'the message of the token endpoint is unchanged';
    is _attr($err, 'http_status'), '400 Bad Request', 'the status line is carried';
    is _attr($err, 'api_message'), 'The user code is invalid',
        'the error description of the body is carried';
}

# An error body without a description carries the error code.
{
    my $oidc = _with_discovery(
        post_queue => [
            _response(
                status_line => '400 Bad Request',
                body        => '{"error":"invalid_client"}',
            ),
        ],
    );

    my $err = _error(sub {
        $oidc->token(grant_type => 'client_credentials');
    });

    ok ref $err && $err->isa('WWW::Zitadel::Error::API'),
        'a rejected token without description is an API error';
    is _attr($err, 'api_message'), 'invalid_client', 'the error code of the body is carried';
}

# A body that is not JSON at all carries the raw body, shortened.
{
    my $oidc = _with_discovery(
        post_queue => [
            _response(
                status_line => '500 Internal Server Error',
                body        => 'upstream is on fire',
            ),
        ],
    );

    my $err = _error(sub {
        $oidc->token(grant_type => 'client_credentials');
    });

    ok ref $err && $err->isa('WWW::Zitadel::Error::API'),
        'a server error is an API error, not a network error';
    is "$err", 'Token endpoint failed: 500 Internal Server Error',
        'the message of the token endpoint is unchanged';
    is _attr($err, 'http_status'), '500 Internal Server Error', 'the status line is carried';
    is _attr($err, 'api_message'), 'upstream is on fire', 'the raw body is carried';
}

# A long body is shortened in the error message.
{
    my $oidc = _with_discovery(
        post_queue => [
            _response(
                status_line => '500 Internal Server Error',
                body        => 'x' x 5000,
            ),
        ],
    );

    my $err = _error(sub {
        $oidc->token(grant_type => 'client_credentials');
    });

    is length(_attr($err, 'api_message') // ''), 203, 'a long body is shortened';
    like _attr($err, 'api_message'), qr/^x{200}\.\.\.$/, 'the shortened body ends with an ellipsis';
}

# The introspection endpoint.
{
    my $oidc = _with_discovery(
        post_queue => [
            _response(
                status_line => '401 Unauthorized',
                body        => '{"error":"invalid_client"}',
            ),
        ],
    );

    my $err = _error(sub {
        $oidc->introspect(
            'token-1',
            client_id     => 'client-1',
            client_secret => 'wrong',
        );
    });

    ok ref $err && $err->isa('WWW::Zitadel::Error::API'),
        'a rejected introspection is an API error';
    is "$err", 'Introspection failed: 401 Unauthorized',
        'the message of the introspection is unchanged';
    is _attr($err, 'http_status'), '401 Unauthorized', 'the status line is carried';
    is _attr($err, 'api_message'), 'invalid_client', 'the error code of the body is carried';
}

# The userinfo endpoint.
{
    my $oidc = _with_discovery(
        get_queue => [
            _response(
                status_line => '401 Unauthorized',
                body        => '{"error":"invalid_token","error_description":"The token is expired"}',
            ),
        ],
    );

    my $err = _error(sub { $oidc->userinfo('bad-token') });

    ok ref $err && $err->isa('WWW::Zitadel::Error::API'),
        'a rejected userinfo is an API error';
    is "$err", 'UserInfo failed: 401 Unauthorized',
        'the message of the userinfo is unchanged';
    is _attr($err, 'http_status'), '401 Unauthorized', 'the status line is carried';
    is _attr($err, 'api_message'), 'The token is expired',
        'the error description of the body is carried';
}

# A successful answer with a body that is not JSON is a fault of the
# server, not of the caller.
for my $case (
    {
        name   => 'token',
        method => 'token',
        label  => 'Token endpoint',
        call   => sub { $_[0]->token(grant_type => 'client_credentials') },
        queue  => 'post_queue',
    },
    {
        name   => 'introspection',
        method => 'introspect',
        label  => 'Introspection',
        call   => sub {
            $_[0]->introspect('token-1', client_id => 'c', client_secret => 's');
        },
        queue  => 'post_queue',
    },
    {
        name   => 'userinfo',
        method => 'userinfo',
        label  => 'UserInfo',
        call   => sub { $_[0]->userinfo('token-1') },
        queue  => 'get_queue',
    },
)
{
    my $html = '<html><body>gateway timeout</body></html>';
    my $oidc = _with_discovery(
        $case->{queue} => [
            _response(is_success => 1, body => $html),
        ],
    );

    my $err = _error(sub { $case->{call}->($oidc) });

    ok ref $err && $err->isa('WWW::Zitadel::Error::API'),
        "a body that is no JSON is an API error ($case->{name})";
    like "$err", qr/\Q$case->{label}\E response is not valid JSON/,
        "the message names the endpoint ($case->{name})";
    like "$err", qr/malformed JSON/,
        "the message carries the parser error ($case->{name})";
}

# The same for the discovery document and the keys.
{
    my $oidc = _oidc(
        get_queue => [
            _response(is_success => 1, body => '<html>not a document</html>'),
        ],
    );

    my $err = _error(sub { $oidc->discovery });

    ok ref $err && $err->isa('WWW::Zitadel::Error::API'),
        'a discovery document that is no JSON is an API error';
    like "$err", qr/Discovery response is not valid JSON/,
        'the message names the discovery';
}

{
    my $oidc = _with_discovery(
        get_queue => [
            _response(is_success => 1, body => '<html>not a key set</html>'),
        ],
    );

    my $err = _error(sub { $oidc->jwks });

    ok ref $err && $err->isa('WWW::Zitadel::Error::API'),
        'a key set that is no JSON is an API error';
    like "$err", qr/JWKS response is not valid JSON/, 'the message names the keys';
}

# A discovery document without the endpoint we need is a validation error.
{
    my $oidc = _oidc(
        get_queue => [
            _response(
                is_success => 1,
                body       => encode_json({ jwks_uri => 'https://zitadel.example.com/oauth/v2/keys' }),
            ),
        ],
    );

    for my $case (
        [ 'token_endpoint',         'No token_endpoint in discovery document' ],
        [ 'userinfo_endpoint',      'No userinfo_endpoint in discovery document' ],
        [ 'authorization_endpoint', 'No authorization_endpoint in discovery document' ],
        [ 'introspection_endpoint', 'No introspection_endpoint in discovery document' ],
    )
    {
        my ($method, $wording) = @$case;
        my $err = _error(sub { $oidc->$method });
        ok ref $err && $err->isa('WWW::Zitadel::Error::Validation'),
            "a missing $method is a validation error";
        is "$err", $wording, "the wording of a missing $method is unchanged";
    }
}

{
    my $oidc = _oidc(
        get_queue => [
            _response(
                is_success => 1,
                body       => encode_json({ token_endpoint => 'https://zitadel.example.com/oauth/v2/token' }),
            ),
        ],
    );

    my $err = _error(sub { $oidc->jwks_uri });
    ok ref $err && $err->isa('WWW::Zitadel::Error::Validation'),
        'a missing jwks_uri is a validation error';
    is "$err", 'No jwks_uri in discovery document',
        'the wording of a missing jwks_uri is unchanged';
}

# LWP could not reach a server at all: that is the one case that stays a
# network error.
for my $case (
    {
        name   => 'token',
        label  => 'Token endpoint',
        call   => sub { $_[0]->token(grant_type => 'client_credentials') },
        queue  => 'post_queue',
    },
    {
        name   => 'introspection',
        label  => 'Introspection',
        call   => sub {
            $_[0]->introspect('token-1', client_id => 'c', client_secret => 's');
        },
        queue  => 'post_queue',
    },
    {
        name   => 'userinfo',
        label  => 'UserInfo',
        call   => sub { $_[0]->userinfo('token-1') },
        queue  => 'get_queue',
    },
)
{
    my $oidc = _with_discovery(
        $case->{queue} => [
            _response(
                status_line => '500 Internal Server Error',
                body        => 'An internal error occurred',
                headers     => { 'Client-Warning' => 'Internal response' },
            ),
        ],
    );

    my $err = _error(sub { $case->{call}->($oidc) });

    ok ref $err && $err->isa('WWW::Zitadel::Error::Network'),
        "an internal LWP response is a network error ($case->{name})";
    ok !(ref $err && $err->isa('WWW::Zitadel::Error::API')),
        "an internal LWP response is no API error ($case->{name})";
    is "$err", $case->{label} . ' failed: 500 Internal Server Error',
        "the message of an internal LWP response is unchanged ($case->{name})";
}

done_testing;
