package WWW::Zitadel::Error::API;

# ABSTRACT: Raised when the ZITADEL API returns a non-successful HTTP response

use Moo;
extends 'WWW::Zitadel::Error';
use namespace::clean;

=attr http_status

The HTTP status line returned by the server, e.g. C<"400 Bad Request">.

=attr api_message

The C<message> field from the JSON error body returned by the API, if present.

=cut

has http_status => ( is => 'ro' );
has api_message => ( is => 'ro' );

1;

__END__

=head1 DESCRIPTION

Subclass of L<WWW::Zitadel::Error>. Thrown when the Management API returns a
non-2xx response. In addition to the inherited C<message> attribute and
stringification overload, it carries C<http_status> (the status line string)
and C<api_message> (the C<message> field from the JSON error body, if any).

=head1 SEE ALSO

L<WWW::Zitadel::Error>

=cut
