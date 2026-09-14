package WWW::Zitadel::Error;

# ABSTRACT: Structured exception base class for WWW::Zitadel

use Moo;

# namespace::clean must NOT be used here: it would strip the overload
# operator stub that is installed by 'use overload' below.
use overload '""' => sub { $_[0]->message }, fallback => 1;

our $VERSION = '0.002';

=attr message

Human-readable error description. The object stringifies to this value,
so existing C<eval>/C<$@> patterns that match on the error string continue
to work unchanged.

=cut

has message => (
    is       => 'ro',
    required => 1,
);

# Concrete subclasses live one-per-file (Error/Validation.pm, Error/Network.pm,
# Error/API.pm). Load them here so `use WWW::Zitadel::Error` still pulls in the
# whole family — every caller only ever `use`s this module, then references
# ::Validation / ::Network / ::API. Required at runtime, after the base class is
# defined, so each subclass's `extends 'WWW::Zitadel::Error'` resolves cleanly.
require WWW::Zitadel::Error::Validation;
require WWW::Zitadel::Error::Network;
require WWW::Zitadel::Error::API;

1;

__END__

=head1 SYNOPSIS

    use WWW::Zitadel::Management;
    use WWW::Zitadel::Error;

    eval { $mgmt->get_user($id) };
    if (my $err = $@) {
        if (ref $err && $err->isa('WWW::Zitadel::Error::API')) {
            warn "API error (HTTP " . $err->http_status . "): " . $err->message;
        }
        elsif (ref $err && $err->isa('WWW::Zitadel::Error::Validation')) {
            warn "Bad call: " . $err->message;
        }
        else {
            die $err;
        }
    }

=head1 DESCRIPTION

C<WWW::Zitadel::Error> is the exception base class. Loading it also loads its
three concrete subclasses, each of which C<extends> this class and inherits the
stringification overload:

=over 4

=item L<WWW::Zitadel::Error::Validation>

Thrown when a required argument is missing or invalid (empty issuer, missing
user_id, etc.).

=item L<WWW::Zitadel::Error::Network>

Thrown when a discovery, JWKS, or other HTTP fetch fails at the transport level
(connection refused, timeout, non-success response on OIDC endpoints).

=item L<WWW::Zitadel::Error::API>

Thrown when the Management API returns a non-2xx response. Carries
C<http_status> (the status line string) and C<api_message> (the C<message>
field from the JSON error body, if any).

=back

All classes overload stringification to return C<message>, so existing code
that inspects C<$@> as a plain string continues to work without modification.

=head1 SEE ALSO

L<WWW::Zitadel>, L<WWW::Zitadel::OIDC>, L<WWW::Zitadel::Management>

=cut
