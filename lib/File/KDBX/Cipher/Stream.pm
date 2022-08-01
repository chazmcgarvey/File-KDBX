package File::KDBX::Cipher::Stream;
# ABSTRACT: A cipher stream encrypter/decrypter

use warnings;
use strict;

use Crypt::Digest qw(digest_data);
use File::KDBX::Constants qw(:cipher :random_stream);
use File::KDBX::Error;
use File::KDBX::Util qw(:class);
use Scalar::Util qw(blessed);
use Module::Load;
use namespace::clean;

extends 'File::KDBX::Cipher';

our $VERSION = '999.999'; # VERSION

=attr counter

    $counter = $cipher->counter;

Get the initial counter / block count into the keystream.

=attr offset

    $offset = $cipher->offset;

Get the initial byte offset into the keystream. This has precedence over L</counter> if both are set.

=cut

has 'counter',  is => 'ro', default => 0;
has 'offset',   is => 'ro';
sub key_size    { { Salsa20 => 32, ChaCha => 32 }->{$_[0]->{algorithm} || ''} //  0 }
sub iv_size     { { Salsa20 =>  8, ChaCha => 12 }->{$_[0]->{algorithm} || ''} // -1 }
sub block_size  { 1 }

sub init {
    my $self = shift;
    my %args = @_;

    if (my $uuid = $args{uuid}) {
        if ($uuid eq CIPHER_UUID_CHACHA20 && length($args{iv}) == 16) {
            # extract the counter
            my $buf = substr($self->{iv}, 0, 4, '');
            $self->{counter} = unpack('L<', $buf);
        }
        elsif ($uuid eq CIPHER_UUID_SALSA20) {
            # only need eight bytes...
            $self->{iv} = substr($args{iv}, 8);
        }
    }
    elsif (my $id = $args{stream_id}) {
        my $key_ref = ref $args{key} ? $args{key} : \$args{key};
        if ($id == STREAM_ID_CHACHA20) {
            ($self->{key}, $self->{iv}) = unpack('a32 a12', digest_data('SHA512', $$key_ref));
        }
        elsif ($id == STREAM_ID_SALSA20) {
            ($self->{key}, $self->{iv}) = (digest_data('SHA256', $$key_ref), STREAM_SALSA20_IV);
        }
    }

    return $self;
}

=method crypt

    $ciphertext = $cipher->crypt($plaintext);
    $plaintext = $cipher->crypt($ciphertext);

Encrypt or decrypt some data. These ciphers are symmetric, so encryption and decryption are the same
operation. This method is an alias for both L<File::KDBX::Cipher/encrypt> and L<File::KDBX::Cipher/decrypt>.

=cut

sub crypt {
    my $self = shift;
    my $stream = $self->_stream;
    return join('', map { $stream->crypt(ref $_ ? $$_ : $_) } grep { defined } @_);
}

=method keystream

    $stream = $cipher->keystream;

Access the keystream.

=cut

sub keystream {
    my $self = shift;
    return $self->_stream->keystream(@_);
}

=method dup

    $cipher_copy = $cipher->dup(%attributes);

Get a copy of an existing cipher with the counter reset, optionally applying new attributes.

=cut

sub dup {
    my $self    = shift;
    my $class   = blessed($self);

    my $dup = bless {%$self, @_}, $class;
    delete $dup->{stream};
    return $dup;
}

sub _stream {
    my $self = shift;

    $self->{stream} //= do {
        my $s = eval {
            my $pkg = 'Crypt::Stream::'.$self->algorithm;
            my $counter = $self->counter;
            my $pos = 0;
            if (defined (my $offset = $self->offset)) {
                $counter = int($offset / 64);
                $pos = $offset % 64;
            }
            load $pkg;
            my $s = $pkg->new($self->key, $self->iv, $counter);
            # seek to correct position within block
            $s->keystream($pos) if $pos;
            $s;
        };
        if (my $err = $@) {
            throw 'Failed to initialize stream cipher library',
                error       => $err,
                algorithm   => $self->{algorithm},
                key_length  => length($self->key),
                iv_length   => length($self->iv),
                iv          => unpack('H*', $self->iv),
                key         => unpack('H*', $self->key);
        }
        $s;
    };
}

sub encrypt { goto &crypt }
sub decrypt { goto &crypt }

sub finish { delete $_[0]->{stream}; '' }

1;
__END__

=head1 SYNOPSIS

    use File::KDBX::Cipher::Stream;

    my $cipher = File::KDBX::Cipher::Stream->new(algorithm => $algorithm, key => $key, iv => $iv);

=head1 DESCRIPTION

A subclass of L<File::KDBX::Cipher> for encrypting and decrypting data using a stream cipher.

=cut
