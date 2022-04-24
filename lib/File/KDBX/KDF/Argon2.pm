package File::KDBX::KDF::Argon2;
# ABSTRACT: The Argon2 family of key derivation functions

use warnings;
use strict;

use Crypt::Argon2 qw(argon2d_raw argon2id_raw);
use File::KDBX::Constants qw(:kdf);
use File::KDBX::Error;
use File::KDBX::Util qw(:class);
use namespace::clean;

extends 'File::KDBX::KDF';

our $VERSION = '999.999'; # VERSION

=attr salt

=attr parallelism

=attr memory

=attr iterations

=attr version

=attr secret

=attr assocdata

Get various KDF parameters.

C<version>, C<secret> and C<assocdata> are currently unused.

=cut

sub salt        { $_[0]->{+KDF_PARAM_ARGON2_SALT} or throw 'Salt is not set' }
sub seed        { $_[0]->salt }
sub parallelism { $_[0]->{+KDF_PARAM_ARGON2_PARALLELISM}    //= KDF_DEFAULT_ARGON2_PARALLELISM }
sub memory      { $_[0]->{+KDF_PARAM_ARGON2_MEMORY}         //= KDF_DEFAULT_ARGON2_MEMORY }
sub iterations  { $_[0]->{+KDF_PARAM_ARGON2_ITERATIONS}     //= KDF_DEFAULT_ARGON2_ITERATIONS }
sub version     { $_[0]->{+KDF_PARAM_ARGON2_VERSION}        //= KDF_DEFAULT_ARGON2_VERSION }
sub secret      { $_[0]->{+KDF_PARAM_ARGON2_SECRET} }
sub assocdata   { $_[0]->{+KDF_PARAM_ARGON2_ASSOCDATA} }

sub init {
    my $self = shift;
    my %args = @_;
    return $self->SUPER::init(
        KDF_PARAM_ARGON2_SALT()         => $args{+KDF_PARAM_ARGON2_SALT}        // $args{salt},
        KDF_PARAM_ARGON2_PARALLELISM()  => $args{+KDF_PARAM_ARGON2_PARALLELISM} // $args{parallelism},
        KDF_PARAM_ARGON2_MEMORY()       => $args{+KDF_PARAM_ARGON2_MEMORY}      // $args{memory},
        KDF_PARAM_ARGON2_ITERATIONS()   => $args{+KDF_PARAM_ARGON2_ITERATIONS}  // $args{iterations},
        KDF_PARAM_ARGON2_VERSION()      => $args{+KDF_PARAM_ARGON2_VERSION}     // $args{version},
        KDF_PARAM_ARGON2_SECRET()       => $args{+KDF_PARAM_ARGON2_SECRET}      // $args{secret},
        KDF_PARAM_ARGON2_ASSOCDATA()    => $args{+KDF_PARAM_ARGON2_ASSOCDATA}   // $args{assocdata},
    );
}

sub _transform {
    my $self = shift;
    my $key = shift;

    my ($uuid, $salt, $iterations, $memory, $parallelism)
        = ($self->uuid, $self->salt, $self->iterations, $self->memory, $self->parallelism);

    if ($uuid eq KDF_UUID_ARGON2D) {
        return argon2d_raw($key, $salt, $iterations, $memory, $parallelism, length($salt));
    }
    elsif ($uuid eq KDF_UUID_ARGON2ID) {
        return argon2id_raw($key, $salt, $iterations, $memory, $parallelism, length($salt));
    }

    throw 'Unknown Argon2 type', uuid => $uuid;
}

1;
__END__

=head1 DESCRIPTION

An Argon2 key derivation function. This is a L<File::KDBX::KDF> subclass.

This KDF allows for excellent resistance to ASIC password cracking. It's a solid choice but doesn't have the
track record of L<File::KDBX::KDF::AES> and requires using the KDBX4+ file format.

=cut
