package WWW::Zitadel::Error::Validation;

# ABSTRACT: Raised when a required argument is missing or invalid

use Moo;
extends 'WWW::Zitadel::Error';
use namespace::clean;

1;

__END__

=head1 DESCRIPTION

Subclass of L<WWW::Zitadel::Error>. Thrown when a required argument is missing
or invalid (empty issuer, missing user_id, etc.) — before any HTTP request is
made. Inherits the C<message> attribute and stringification overload from the
base class.

=head1 SEE ALSO

L<WWW::Zitadel::Error>

=cut
