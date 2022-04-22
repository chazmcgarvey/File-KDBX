package File::KDBX::KDF::AES;
# ABSTRACT: Using the AES cipher as a key derivation function

use warnings;
use strict;

use Crypt::Cipher;
use Crypt::Digest qw(digest_data);
use File::KDBX::Constants qw(:bool :kdf);
use File::KDBX::Error;
use File::KDBX::Util qw(:load can_fork);
use namespace::clean;

use parent 'File::KDBX::KDF';

our $VERSION = '999.999'; # VERSION

# Rounds higher than this are eligible for forking:
my $FORK_OPTIMIZATION_THRESHOLD = 100_000;

BEGIN {
    my $use_fork = $ENV{NO_FORK} || !can_fork;
    *_USE_FORK = $use_fork ? \&TRUE : \&FALSE;
}

sub init {
    my $self = shift;
    my %args = @_;
    return $self->SUPER::init(
        KDF_PARAM_AES_ROUNDS()  => $args{+KDF_PARAM_AES_ROUNDS} // $args{rounds},
        KDF_PARAM_AES_SEED()    => $args{+KDF_PARAM_AES_SEED}   // $args{seed},
    );
}

=attr rounds

    $rounds = $kdf->rounds;

Get the number of times to run the function during transformation.

=cut

sub rounds  { $_[0]->{+KDF_PARAM_AES_ROUNDS} || KDF_DEFAULT_AES_ROUNDS }
sub seed    { $_[0]->{+KDF_PARAM_AES_SEED} }

sub _transform {
    my $self    = shift;
    my $key     = shift;

    my $seed = $self->seed;
    my $rounds = $self->rounds;

    length($key) == 32 or throw 'Raw key must be 32 bytes', size => length($key);
    length($seed) == 32 or throw 'Invalid seed length', size => length($seed);

    my ($key_l, $key_r) = unpack('(a16)2', $key);

    goto NO_FORK if !_USE_FORK || $rounds < $FORK_OPTIMIZATION_THRESHOLD;
    {
        my $pid = open(my $read, '-|') // do { alert "fork failed: $!"; goto NO_FORK };
        if ($pid == 0) { # child
            my $l = _transform_half($seed, $key_l, $rounds);
            require POSIX;
            print $l or POSIX::_exit(1);
            POSIX::_exit(0);
        }
        my $r = _transform_half($seed, $key_r, $rounds);
        read($read, my $l, length($key_l)) == length($key_l) or do { alert "read failed: $!", goto NO_FORK };
        close($read) or do { alert "worker thread exited abnormally", status => $?; goto NO_FORK };
        return digest_data('SHA256', $l, $r);
    }

    # FIXME: This used to work but now it crashes frequently. Threads are now discouraged anyway, but it might
    # be nice if this was available for no-fork platforms.
    # if ($ENV{THREADS} && eval 'use threads; 1') {
    #     my $l = threads->create(\&_transform_half, $key_l, $seed, $rounds);
    #     my $r = _transform_half($key_r, $seed, $rounds);
    #     return digest_data('SHA256', $l->join, $r);
    # }

    NO_FORK:
    my $l = _transform_half($seed, $key_l, $rounds);
    my $r = _transform_half($seed, $key_r, $rounds);
    return digest_data('SHA256', $l, $r);
}

sub _transform_half_pp {
    my $seed    = shift;
    my $key     = shift;
    my $rounds  = shift;

    my $c = Crypt::Cipher->new('AES', $seed);

    my $result = $key;
    for (my $i = 0; $i < $rounds; ++$i) {
        $result = $c->encrypt($result);
    }

    return $result;
}

BEGIN {
    my $use_xs = load_xs;
    *_transform_half = $use_xs ? \&File::KDBX::XS::kdf_aes_transform_half : \&_transform_half_pp;
}

1;
__END__

=head1 DESCRIPTION

An AES-256-based key derivation function. This is a L<File::KDBX::KDF> subclass.

This KDF has a long, solid track record. It is supported in both KDBX3 and KDBX4.

=head1 CAVEATS

This module can be pretty slow when the number of rounds is high. If you have L<File::KDBX::XS>, that will
help. If your perl has C<fork>, that will also help. If you need to turn off one or both of these
optimizations for some reason, set the C<PERL_ONLY> (to prevent Loading C<File::KDBX::XS>) and C<NO_FORK>
environment variables.

=cut
