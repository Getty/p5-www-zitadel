use strict;
use warnings;

use Test::More;
use Test::Exception;
use JSON::MaybeXS qw(encode_json);
use Crypt::JWT qw(encode_jwt);
use Crypt::PK::RSA;
use Crypt::PK::ECC;

use WWW::Zitadel::OIDC;

# Signature algorithm allow-list of verify_token, exercised through the real
# Crypt::JWT: the tokens are signed with locally generated keys and nothing
# below _decode_jwt is mocked. Only the HTTP layer is replaced.

my $ISSUER   = 'https://zitadel.example.com';
my $JWKS_URI = "$ISSUER/oauth/v2/keys";

{
    package Local::Response;

    sub new {
        my ($class, %args) = @_;
        bless \%args, $class;
    }

    sub is_success      { 1 }
    sub status_line     { '200 OK' }
    sub decoded_content { $_[0]->{decoded_content} }
}

{
    # Serves the discovery document and the JWKS by URL, any number of times.
    package Local::KeyServerUA;

    sub new {
        my ($class, %args) = @_;
        bless { %args, gets => [] }, $class;
    }

    sub gets { $_[0]->{gets} }

    sub get {
        my ($self, $url) = @_;
        push @{ $self->{gets} }, $url;
        my $doc = $url eq $self->{jwks_uri}
            ? $self->{jwks}
            : { jwks_uri => $self->{jwks_uri} };
        return Local::Response->new(
            decoded_content => JSON::MaybeXS::encode_json($doc),
        );
    }
}

my $rsa = Crypt::PK::RSA->new;
$rsa->generate_key(256, 65537);
my $rsa_jwk = $rsa->export_key_jwk('public', 1);
$rsa_jwk->{kid} = 'rsa-1';

my $ecc = Crypt::PK::ECC->new;
$ecc->generate_key('secp256r1');
my $ecc_jwk = $ecc->export_key_jwk('public', 1);
$ecc_jwk->{kid} = 'ec-1';

my $JWKS = { keys => [ $rsa_jwk, $ecc_jwk ] };

sub _token {
    my ($alg) = @_;
    my ($key, $kid) = $alg =~ /^ES/ ? ($ecc, 'ec-1') : ($rsa, 'rsa-1');
    return encode_jwt(
        payload       => { iss => $ISSUER, sub => "user-$alg", exp => time + 300 },
        alg           => $alg,
        key           => $key,
        extra_headers => { kid => $kid },
    );
}

sub _oidc {
    my $ua = Local::KeyServerUA->new(jwks_uri => $JWKS_URI, jwks => $JWKS);
    return WWW::Zitadel::OIDC->new(issuer => $ISSUER, ua => $ua);
}

sub _jwks_fetches {
    my ($oidc) = @_;
    return scalar grep { $_ eq $JWKS_URI } @{ $oidc->ua->gets };
}

# Default allow-list: RS256/RS384/RS512.
for my $alg (qw(RS256 RS384 RS512)) {
    my $claims;
    lives_ok { $claims = _oidc()->verify_token(_token($alg)) }
        "$alg token is accepted by default";
    is $claims->{sub}, "user-$alg", "$alg token yields its claims";
}

# A validly signed token with an algorithm outside the default list is
# rejected, although its key is in the JWKS.
for my $alg (qw(PS256 ES256)) {
    throws_ok { _oidc()->verify_token(_token($alg), no_retry => 1) }
        qr/alg '\Q$alg\E' not in accepted_alg/,
        "$alg token is rejected by default";
}

# The allow-list also holds on the second pass after the JWKS refresh.
{
    my $oidc = _oidc();
    throws_ok { $oidc->verify_token(_token('PS256')) }
        qr/alg 'PS256' not in accepted_alg/,
        'PS256 token is rejected by default after the JWKS refresh retry';
    is _jwks_fetches($oidc), 2, 'the retry pass ran';
}

# Callers widen the list with accepted_alg ...
for my $alg (qw(PS256 ES256)) {
    my $claims;
    lives_ok {
        $claims = _oidc()->verify_token(_token($alg), accepted_alg => [$alg]);
    } "$alg token is accepted when listed in accepted_alg";
    is $claims->{sub}, "user-$alg", "$alg token yields its claims";
}

# ... and with the older option name accepted_key_alg.
{
    my $claims;
    lives_ok {
        $claims = _oidc()->verify_token(
            _token('PS256'), accepted_key_alg => ['PS256'],
        );
    } 'PS256 token is accepted when listed in accepted_key_alg';
    is $claims->{sub}, 'user-PS256', 'PS256 token yields its claims';
}

# A caller-supplied list narrows as well, under both names.
for my $opt (qw(accepted_alg accepted_key_alg)) {
    throws_ok {
        _oidc()->verify_token(_token('RS256'), $opt => ['RS512'], no_retry => 1);
    } qr/alg 'RS256' not in accepted_alg/,
        "RS256 token is rejected when $opt lists only RS512";
}

# Scalar and Regexp forms are passed through to Crypt::JWT.
lives_ok { _oidc()->verify_token(_token('ES256'), accepted_alg => 'ES256') }
    'accepted_alg takes a single algorithm name';
throws_ok {
    _oidc()->verify_token(
        _token('RS256'), accepted_alg => qr/^ES/, no_retry => 1,
    );
} qr/alg 'RS256' does not match accepted_alg/,
    'accepted_alg takes a Regexp';

# accepted_alg wins when both names are given.
throws_ok {
    _oidc()->verify_token(
        _token('PS256'),
        accepted_alg     => ['RS256'],
        accepted_key_alg => ['PS256'],
        no_retry         => 1,
    );
} qr/alg 'PS256' not in accepted_alg/,
    'accepted_alg takes precedence over accepted_key_alg';

done_testing;
