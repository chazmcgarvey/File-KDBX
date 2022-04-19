package File::KDBX::IO::Crypt;
# ABSTRACT: Encrypter/decrypter IO handle

use warnings;
use strict;

use Errno;
use File::KDBX::Error;
use File::KDBX::Util qw(:empty);
use namespace::clean;

use parent 'File::KDBX::IO';

our $VERSION = '999.999'; # VERSION
our $BUFFER_SIZE = 16384;
our $ERROR;

=method new

    $fh = File::KDBX::IO::Crypt->new(%attributes);
    $fh = File::KDBX::IO::Crypt->new($fh, %attributes);

Construct a new crypto IO handle.

=cut

sub new {
    my $class = shift;
    my %args = @_ % 2 == 1 ? (fh => shift, @_) : @_;
    my $self = $class->SUPER::new;
    $self->_fh($args{fh}) or throw 'IO handle required';
    $self->cipher($args{cipher}) or throw 'Cipher required';
    return $self;
}

=attr cipher

A L<File::KDBX::Cipher> instance to do the actual encryption or decryption.

=cut

my %ATTRS = (
    cipher  => undef,
);
while (my ($attr, $default) = each %ATTRS) {
    no strict 'refs'; ## no critic (ProhibitNoStrict)
    *$attr = sub {
        my $self = shift;
        *$self->{$attr} = shift if @_;
        *$self->{$attr} //= (ref $default eq 'CODE') ? $default->($self) : $default;
    };
}

sub _FILL {
    my ($self, $fh) = @_;

    $ENV{DEBUG_STREAM} and print STDERR "FILL\t$self\n";
    my $cipher = $self->cipher or return;

    $fh->read(my $buf = '', $BUFFER_SIZE);
    if (0 < length($buf)) {
        my $plaintext = eval { $cipher->decrypt($buf) };
        if (my $err = $@) {
            $self->_set_error($err);
            return;
        }
        return $plaintext if 0 < length($plaintext);
    }

    # finish
    my $plaintext = eval { $cipher->finish };
    if (my $err = $@) {
        $self->_set_error($err);
        return;
    }
    $self->cipher(undef);
    return $plaintext;
}

sub _WRITE {
    my ($self, $buf, $fh) = @_;

    $ENV{DEBUG_STREAM} and print STDERR "WRITE\t$self\n";
    my $cipher = $self->cipher or return 0;

    my $new_data = eval { $cipher->encrypt($buf) } || '';
    if (my $err = $@) {
        $self->_set_error($err);
        return 0;
    }
    $self->_buffer_out_add($new_data) if nonempty $new_data;
    return length($buf);
}

sub _POPPED {
    my ($self, $fh) = @_;

    $ENV{DEBUG_STREAM} and print STDERR "POPPED\t$self\n";
    return if $self->_mode ne 'w';
    my $cipher = $self->cipher or return;

    my $new_data = eval { $cipher->finish } || '';
    if (my $err = $@) {
        $self->_set_error($err);
        return;
    }
    $self->_buffer_out_add($new_data) if nonempty $new_data;

    $self->cipher(undef);
    $self->_FLUSH($fh);
}

sub _FLUSH {
    my ($self, $fh) = @_;

    $ENV{DEBUG_STREAM} and print STDERR "FLUSH\t$self\n";
    return if $self->_mode ne 'w';

    my $buffer = $self->_buffer_out;
    while (@$buffer) {
        my $read = shift @$buffer;
        next if empty $read;
        $fh->print($read) or return -1;
    }
    return 0;
}

sub _set_error {
    my $self = shift;
    $ENV{DEBUG_STREAM} and print STDERR "err\t$self\n";
    if (exists &Errno::EPROTO) {
        $! = &Errno::EPROTO;
    }
    elsif (exists &Errno::EIO) {
        $! = &Errno::EIO;
    }
    $self->cipher(undef);
    $self->_error($ERROR = File::KDBX::Error->new(@_));
}

1;
__END__

=head1 SYNOPSIS

    use File::KDBX::IO::Crypt;
    use File::KDBX::Cipher;

    my $cipher = File::KDBX::Cipher->new(...);

    open(my $out_fh, '>:raw', 'ciphertext.bin');
    $out_fh = File::KDBX::IO::Crypt->new($out_fh, cipher => $cipher);

    print $out_fh $plaintext;

    close($out_fh);

    open(my $in_fh, '<:raw', 'ciphertext.bin');
    $in_fh = File::KDBX::IO::Crypt->new($in_fh, cipher => $cipher);

    my $plaintext = do { local $/; <$in_fh> );

    close($in_fh);

=cut
