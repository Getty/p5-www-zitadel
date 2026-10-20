#!/usr/bin/env perl

use strict;
use warnings;

use Carp qw( croak );
use File::Spec;
use FindBin;
use Test::More;

# The cpanfile is what the installer reads. A module the code loads but the
# cpanfile does not name is not missing at build time, it is missing when the
# library is loaded on a machine where the module is not installed yet.
#
# The lists below name the module the code loads and, behind it, the names the
# cpanfile may carry for it. Where module and distribution differ, the
# distribution counts: HTTP::Request comes with HTTP::Message, URI::Escape
# comes with URI and the two Crypt::PK modules come with CryptX.
#
# LWP::Protocol::https belongs to the transport chain: without it LWP::UserAgent
# answers 501 and no request ever reaches the issuer.

my $cpanfile = File::Spec->catfile( $FindBin::Bin, File::Spec->updir, 'cpanfile' );

plan skip_all => 'cpanfile is not part of the distribution' unless -f $cpanfile;

my ( %runtime, %test );
my ( @runtime_order, @test_order );
my $phase = 'runtime';

open my $fh, '<', $cpanfile or croak "cannot read $cpanfile: $!";
while ( my $line = <$fh> ) {
    if ( $line =~ /^\s*on\s+(\w+)\s*=>\s*sub\s*\{/ ) {
        $phase = $1;
        next;
    }
    if ( $phase ne 'runtime' && $line =~ /^\s*\};/ ) {
        $phase = 'runtime';
        next;
    }
    next unless $line =~ /^\s*requires\s+'([^']+)'/;
    my $module = $1;
    if ( $phase eq 'test' ) {
        $test{$module}    = 1;
        push @test_order,   $module;
    }
    else {
        $runtime{$module} = 1;
        push @runtime_order, $module;
    }
}
close $fh;

my @runtime_prereq = (
    [ 'Crypt::JWT'          => qw( Crypt::JWT ) ],
    [ 'HTTP::Request'       => qw( HTTP::Request HTTP::Message ) ],
    [ 'JSON::MaybeXS'       => qw( JSON::MaybeXS ) ],
    [ 'LWP::Protocol::https' => qw( LWP::Protocol::https ) ],
    [ 'LWP::UserAgent'      => qw( LWP::UserAgent ) ],
    [ 'Moo'                 => qw( Moo ) ],
    [ 'URI::Escape'         => qw( URI::Escape URI ) ],
    [ 'namespace::clean'    => qw( namespace::clean ) ],
);

my @test_prereq = (
    [ 'Crypt::JWT'      => qw( Crypt::JWT ) ],
    [ 'Crypt::PK::ECC'  => qw( Crypt::PK::ECC CryptX ) ],
    [ 'Crypt::PK::RSA'  => qw( Crypt::PK::RSA CryptX ) ],
    [ 'HTTP::Request'   => qw( HTTP::Request HTTP::Message ) ],
    [ 'JSON::MaybeXS'   => qw( JSON::MaybeXS ) ],
    [ 'Moo'             => qw( Moo ) ],
    [ 'Test::Exception' => qw( Test::Exception ) ],
    [ 'Test::More'      => qw( Test::More ) ],
);

# a name the cpanfile carries for a module in the given phase
sub declared {
    my ( $phase, @names ) = @_;
    for my $name ( @names ) {
        return 1 if $phase eq 'test' ? $test{$name} : $runtime{$name};
    }
    return 0;
}

# a runtime prerequisite has to stand in the runtime phase: a name in the test
# phase alone is not installed when the distribution is applied
for my $entry ( @runtime_prereq ) {
    my ( $module, @names ) = @$entry;
    ok( declared( 'runtime', @names ), "$module is a declared prerequisite" );
}

# a test prerequisite is fine in the test phase and in the runtime phase, the
# runtime phase is installed either way
for my $entry ( @test_prereq ) {
    my ( $module, @names ) = @$entry;
    ok(
        declared( 'test', @names ) || declared( 'runtime', @names ),
        "$module is a declared prerequisite for the tests"
    );
}

# the prerequisites of a phase stand in alphabetical order
for my $phase ( 'runtime', 'test' ) {
    my @order = $phase eq 'test' ? @test_order : @runtime_order;
    is_deeply(
        \@order,
        [ sort { lc $a cmp lc $b } @order ],
        "the $phase prereqs stand in alphabetical order"
    );
}

done_testing;
