requires 'Moo';
requires 'LWP::UserAgent';
requires 'HTTP::Request';
requires 'JSON::MaybeXS';
requires 'Crypt::JWT';
requires 'URI';
requires 'MIME::Base64';
requires 'namespace::clean';

on test => sub {
    requires 'Test::More';
    requires 'Test::Exception';
    requires 'Path::Tiny';
};
