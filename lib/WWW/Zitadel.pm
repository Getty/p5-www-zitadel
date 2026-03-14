package WWW::Zitadel;

# ABSTRACT: Perl client for Zitadel identity management (OIDC + Management API)

use Moo;
use WWW::Zitadel::OIDC;
use WWW::Zitadel::Management;
use WWW::Zitadel::Error;
use namespace::clean;

our $VERSION = '0.002';

has issuer => (
    is       => 'ro',
    required => 1,
);

sub BUILD {
    my $self = shift;
    die WWW::Zitadel::Error::Validation->new(
        message => 'issuer must not be empty',
    ) unless length $self->issuer;
}

has token => (
    is  => 'ro',
    doc => 'Personal Access Token for Management API',
);

has oidc => (
    is      => 'lazy',
    builder => sub {
        WWW::Zitadel::OIDC->new(issuer => $_[0]->issuer);
    },
);

has management => (
    is      => 'lazy',
    builder => sub {
        my $self = shift;
        die WWW::Zitadel::Error::Validation->new(
            message => 'Management API requires a token',
        ) unless $self->token;
        WWW::Zitadel::Management->new(
            base_url => $self->issuer,
            token    => $self->token,
        );
    },
);

1;

__END__

=head1 SYNOPSIS

    use WWW::Zitadel;

    my $z = WWW::Zitadel->new(
        issuer => 'https://zitadel.example.com',
        token  => $ENV{ZITADEL_PAT},  # Personal Access Token
    );

    # OIDC - verify tokens, fetch JWKS
    my $claims = $z->oidc->verify_token($access_token);
    my $jwks   = $z->oidc->jwks;

    # Management API - CRUD users, projects, apps
    my $users = $z->management->list_users(limit => 20);
    my $user  = $z->management->create_human_user(
        user_name  => 'alice',
        first_name => 'Alice',
        last_name  => 'Smith',
        email      => 'alice@example.com',
    );

=head1 DESCRIPTION

WWW::Zitadel is a Perl client for Zitadel, the open-source identity management
platform. It provides:

=over 4

=item * B<OIDC Client> - Token verification via JWKS, discovery endpoint,
userinfo. Uses L<Crypt::JWT> for JWT validation.

=item * B<Management API Client> - CRUD operations for users, projects,
applications, and organizations.

=back

Zitadel speaks standard OpenID Connect, so the OIDC client works with
any OIDC-compliant provider. The Management API client is Zitadel-specific.

=attr issuer

Required issuer URL, for example C<https://zitadel.example.com>.

=attr token

Optional Personal Access Token (PAT). Required only when using
L</management>.

=attr oidc

Lazy-built L<WWW::Zitadel::OIDC> client, configured with C<issuer>.

=attr management

Lazy-built L<WWW::Zitadel::Management> client, configured with C<issuer>
as C<base_url>. Dies if C<token> is missing.

=head1 SEE ALSO

L<WWW::Zitadel::OIDC>, L<WWW::Zitadel::Management>, L<Crypt::JWT>

=cut
