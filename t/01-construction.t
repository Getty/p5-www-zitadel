use strict;
use warnings;
use Test::More;
use Test::Exception;

use WWW::Zitadel;
use WWW::Zitadel::OIDC;
use WWW::Zitadel::Management;

# WWW::Zitadel requires issuer
throws_ok { WWW::Zitadel->new } qr/required/, 'WWW::Zitadel needs issuer';

my $z = WWW::Zitadel->new(issuer => 'https://zitadel.example.com');
isa_ok $z, 'WWW::Zitadel';
is $z->issuer, 'https://zitadel.example.com', 'issuer set correctly';

# OIDC requires issuer
throws_ok { WWW::Zitadel::OIDC->new } qr/required/, 'OIDC needs issuer';

my $oidc = WWW::Zitadel::OIDC->new(issuer => 'https://zitadel.example.com');
isa_ok $oidc, 'WWW::Zitadel::OIDC';
is $oidc->issuer, 'https://zitadel.example.com', 'OIDC issuer correct';
isa_ok $oidc->ua, 'LWP::UserAgent', 'OIDC has UA';

# Management requires base_url and token
throws_ok { WWW::Zitadel::Management->new } qr/required/, 'Management needs base_url+token';
throws_ok {
    WWW::Zitadel::Management->new(base_url => 'https://z.example.com')
} qr/required/, 'Management needs token';

my $mgmt = WWW::Zitadel::Management->new(
    base_url => 'https://zitadel.example.com',
    token    => 'test-pat-token',
);
isa_ok $mgmt, 'WWW::Zitadel::Management';
is $mgmt->base_url, 'https://zitadel.example.com', 'Management base_url';
is $mgmt->token, 'test-pat-token', 'Management token';

# Lazy OIDC from main object
my $z2 = WWW::Zitadel->new(
    issuer => 'https://z2.example.com',
    token  => 'my-pat',
);
isa_ok $z2->oidc, 'WWW::Zitadel::OIDC', 'lazy OIDC';
is $z2->oidc->issuer, 'https://z2.example.com', 'OIDC inherits issuer';

# Management requires token via main object
my $z3 = WWW::Zitadel->new(issuer => 'https://z3.example.com');
throws_ok { $z3->management } qr/requires a token/, 'management without token dies';

isa_ok $z2->management, 'WWW::Zitadel::Management', 'lazy Management';

# verify_token requires a token argument
throws_ok { $oidc->verify_token(undef) } qr/No token/, 'verify_token needs token';

# userinfo requires access_token
throws_ok { $oidc->userinfo(undef) } qr/No access token/, 'userinfo needs token';

# Management methods require IDs
throws_ok { $mgmt->get_user(undef) } qr/user_id required/, 'get_user needs id';
throws_ok { $mgmt->get_project(undef) } qr/project_id required/, 'get_project needs id';
throws_ok { $mgmt->get_app(undef, 'x') } qr/project_id required/, 'get_app needs project_id';
throws_ok { $mgmt->get_app('p', undef) } qr/app_id required/, 'get_app needs app_id';

done_testing;
