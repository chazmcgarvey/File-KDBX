package PerlIO::via::File::KDBX::Crypt;
# ABSTRACT: Encrypter/decrypter PerlIO layer

use warnings;
use strict;

use File::KDBX::Error;
use IO::Handle;
use namespace::clean;

our $VERSION = '999.999'; # VERSION
our $BUFFER_SIZE = 8192;
our $ERROR;

=method push

    PerlIO::via::File::KDBX::Crypt->push($fh, cipher => $cipher);

Push an encryption or decryption layer onto a filehandle. C<$cipher> must be compatible with
L<File::KDBX::Cipher>.

You mustn't push this layer using C<binmode> directly because the layer needs to be initialized with the
required cipher object.

B<WARNING:> When writing, you mustn't close the filehandle before popping this layer (using
C<binmode($fh, ':pop')>) or the stream will be truncated. The layer needs to know when there is no more data
before the filehandle closes so it can finish the encryption correctly, and the way to indicate that is by
popping the layer.

=cut

my %PUSHED_ARGS;
sub push {
    %PUSHED_ARGS and throw 'Pushing Crypt layer would stomp existing arguments';
    my $class = shift;
    my $fh = shift;
    my %args = @_ % 2 == 0 ? @_ : (cipher => @_);
    $args{cipher} or throw 'Must pass a cipher';
    $args{cipher}->finish if defined $args{finish} && !$args{finish};

    %PUSHED_ARGS = %args;
    binmode($fh, ':via(' . __PACKAGE__ . ')');
}

sub PUSHED {
    my ($class, $mode) = @_;

    $ENV{DEBUG_STREAM} and print STDERR "PUSHED\t$class\n";
    %PUSHED_ARGS or throw 'Programmer error: Use PerlIO::via::File::KDBX::Crypt->push instead of binmode';

    my $buf = '';
    my $self = bless {
        buffer  => \$buf,
        cipher  => $PUSHED_ARGS{cipher},
        mode    => $mode,
    }, $class;
    %PUSHED_ARGS = ();
    return $self;
}

sub FILL {
    my ($self, $fh) = @_;

    $ENV{DEBUG_STREAM} and print STDERR "FILL\t$self\n";
    return if $self->EOF($fh);

    $fh->read(my $buf, $BUFFER_SIZE);
    if (0 < length($buf)) {
        my $plaintext = eval { $self->cipher->decrypt($buf) };
        if (my $err = $@) {
            $self->_set_error($err);
            return;
        }
        return $plaintext;
    }

    # finish
    my $plaintext = eval { $self->cipher->finish };
    if (my $err = $@) {
        $self->_set_error($err);
        return;
    }
    delete $self->{cipher};
    return $plaintext;
}

sub WRITE {
    my ($self, $buf, $fh) = @_;

    $ENV{DEBUG_STREAM} and print STDERR "WRITE\t$self\n";
    return 0 if $self->EOF($fh);

    ${$self->buffer} .= eval { $self->cipher->encrypt($buf) } || '';
    if (my $err = $@) {
        $self->_set_error($err);
        return 0;
    }
    return length($buf);
}

sub POPPED {
    my ($self, $fh) = @_;

    $ENV{DEBUG_STREAM} and print STDERR "POPPED\t$self\n";
    return if $self->EOF($fh) || $self->mode !~ /^w/;

    ${$self->buffer} .= eval { $self->cipher->finish } || '';
    if (my $err = $@) {
        $self->_set_error($err);
        return;
    }

    delete $self->{cipher};
    $self->FLUSH($fh);
}

sub FLUSH {
    my ($self, $fh) = @_;

    $ENV{DEBUG_STREAM} and print STDERR "FLUSH\t$self\n";
    return 0 if !ref $self;

    my $buf = $self->buffer;
    print $fh $$buf or return -1 if 0 < length($$buf);
    $$buf = '';
    return 0;
}

# sub EOF      { !$_[0]->cipher || $_[0]->ERROR($_[1]) }
# sub ERROR    { $_[0]->{error} ? 1 : 0 }
# sub CLEARERR { delete $_[0]->{error}; 0 }

sub EOF      {
    $ENV{DEBUG_STREAM} and print STDERR "EOF\t$_[0]\n";
    !$_[0]->cipher || $_[0]->ERROR($_[1]);
}
sub ERROR    {
    $ENV{DEBUG_STREAM} and print STDERR "ERROR\t$_[0] : ", $_[0]->{error} // 'ok', "\n";
    $_[0]->{error} ? 1 : 0;
}
sub CLEARERR {
    $ENV{DEBUG_STREAM} and print STDERR "CLEARERR\t$_[0]\n";
    # delete $_[0]->{error};
}

sub cipher  { $_[0]->{cipher} }
sub mode    { $_[0]->{mode} }
sub buffer  { $_[0]->{buffer} }

sub _set_error {
    my $self = shift;
    $ENV{DEBUG_STREAM} and print STDERR "err\t$self\n";
    delete $self->{cipher};
    if (exists &Errno::EPROTO) {
        $! = &Errno::EPROTO;
    }
    elsif (exists &Errno::EIO) {
        $! = &Errno::EIO;
    }
    $self->{error} = $ERROR = File::KDBX::Error->new(@_);
}

1;
__END__

=head1 SYNOPSIS

    use PerlIO::via::File::KDBX::Crypt;
    use File::KDBX::Cipher;

    my $cipher = File::KDBX::Cipher->new(...);

    open(my $out_fh, '>:raw', 'ciphertext.bin');
    PerlIO::via::File::KDBX::Crypt->push($out_fh, cipher => $cipher);

    print $out_fh $plaintext;

    binmode($out_fh, ':pop');   # <-- This is required.
    close($out_fh);

    open(my $in_fh, '<:raw', 'ciphertext.bin');
    PerlIO::via::File::KDBX::Crypt->push($in_fh, cipher => $cipher);

    my $plaintext = do { local $/; <$in_fh> );

    close($in_fh);

=cut
