requires 'Crypt::JWT';
requires 'HTTP::Request';
requires 'JSON::MaybeXS';
requires 'LWP::Protocol::https';
requires 'LWP::UserAgent';
requires 'MIME::Base64';
requires 'Moo';
requires 'namespace::clean';
requires 'URI::Escape';

on test => sub {
    requires 'Crypt::PK::ECC';
    requires 'Crypt::PK::RSA';
    requires 'Test::Exception';
    requires 'Test::More';
};
