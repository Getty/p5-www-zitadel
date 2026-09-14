use strict;
use warnings;
use Test::More tests => 7;

use_ok('WWW::Zitadel');
use_ok('WWW::Zitadel::OIDC');
use_ok('WWW::Zitadel::Management');
use_ok('WWW::Zitadel::Error');
use_ok('WWW::Zitadel::Error::Validation');
use_ok('WWW::Zitadel::Error::Network');
use_ok('WWW::Zitadel::Error::API');
