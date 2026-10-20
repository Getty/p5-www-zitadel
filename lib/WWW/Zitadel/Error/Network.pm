package WWW::Zitadel::Error::Network;

# ABSTRACT: Raised when an HTTP request fails at the transport level

use Moo;
extends 'WWW::Zitadel::Error';
use namespace::clean;

1;

__END__

=head1 DESCRIPTION

Subclass of L<WWW::Zitadel::Error>. Thrown when a request never reached a
server: the connection was refused, the name did not resolve, the TLS
handshake failed, the request timed out, or the HTTP library answered with an
internal response. A discovery document or a JWKS that cannot be fetched is
reported this way as well. Inherits the C<message> attribute and
stringification overload from the base class.

=head1 SEE ALSO

L<WWW::Zitadel::Error>

=cut
