package WWW::Zitadel::Error::Network;

# ABSTRACT: Raised when an HTTP request fails at the transport level

use Moo;
extends 'WWW::Zitadel::Error';
use namespace::clean;

1;

__END__

=head1 DESCRIPTION

Subclass of L<WWW::Zitadel::Error>. Thrown when a discovery, JWKS, or other HTTP
fetch fails at the transport level (connection refused, timeout, non-success
response on OIDC endpoints). Inherits the C<message> attribute and
stringification overload from the base class.

=head1 SEE ALSO

L<WWW::Zitadel::Error>

=cut
