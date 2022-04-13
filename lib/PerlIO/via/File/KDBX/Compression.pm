package PerlIO::via::File::KDBX::Compression;
# ABSTRACT: [De]compressor PerlIO layer

use warnings;
use strict;

use Errno;
use File::KDBX::Error;
use File::KDBX::Util qw(load_optional);
use IO::Handle;
use namespace::clean;

our $VERSION = '999.999'; # VERSION
our $BUFFER_SIZE = 8192;
our $ERROR;

=method push

    PerlIO::via::File::KDBX::Compression->push($fh);
    PerlIO::via::File::KDBX::Compression->push($fh, %options);

Push a compression or decompression layer onto a filehandle. Data read from the handle is decompressed, and
data written to a handle is compressed.

Any arguments are passed along to the Inflate or Deflate constructors of C<Compress::Raw::Zlib>.

This is identical to:

    binmode($fh, ':via(File::KDBX::Compression)');

except this allows you to specify compression options.

B<WARNING:> When writing, you mustn't close the filehandle before popping this layer (using
C<binmode($fh, ':pop')>) or the stream will be truncated. The layer needs to know when there is no more data
before the filehandle closes so it can finish the compression correctly, and the way to indicate that is by
popping the layer.

=cut

my @PUSHED_ARGS;
sub push {
    @PUSHED_ARGS and throw 'Pushing Compression layer would stomp existing arguments';
    my $class = shift;
    my $fh    = shift;
    @PUSHED_ARGS = @_;
    binmode($fh, ':via(' . __PACKAGE__ . ')');
}

sub PUSHED {
    my ($class, $mode) = @_;

    $ENV{DEBUG_STREAM} and print STDERR "PUSHED\t$class\n";
    my $buf = '';

    my $self = bless {
        buffer  => \$buf,
        mode    => $mode,
        $mode =~ /^r/ ? (inflator => _inflator(@PUSHED_ARGS)) : (),
        $mode =~ /^w/ ? (deflator => _deflator(@PUSHED_ARGS)) : (),
    }, $class;
    @PUSHED_ARGS = ();
    return $self;
}

sub FILL {
    my ($self, $fh) = @_;

    $ENV{DEBUG_STREAM} and print STDERR "FILL\t$self\n";
    return if $self->EOF($fh);

    $fh->read(my $buf, $BUFFER_SIZE);
    if (0 < length($buf)) {
        my $status = $self->inflator->inflate($buf, my $out);
        $status == Compress::Raw::Zlib::Z_OK() || $status == Compress::Raw::Zlib::Z_STREAM_END() or do {
            $self->_set_error("Failed to uncompress: $status", status => $status);
            return;
        };
        return $out;
    }

    delete $self->{inflator};
    return undef;
}

sub WRITE {
    my ($self, $buf, $fh) = @_;

    $ENV{DEBUG_STREAM} and print STDERR "WRITE\t$self\n";
    return 0 if $self->EOF($fh);

    my $status = $self->deflator->deflate($buf, my $out);
    $status == Compress::Raw::Zlib::Z_OK() or do {
        $self->_set_error("Failed to compress: $status", status => $status);
        return 0;
    };

    ${$self->buffer} .= $out;
    return length($buf);
}

sub POPPED {
    my ($self, $fh) = @_;

    $ENV{DEBUG_STREAM} and print STDERR "POPPED\t$self\n";
    return if $self->EOF($fh) || $self->mode !~ /^w/;

    # finish
    my $status = $self->deflator->flush(my $out, Compress::Raw::Zlib::Z_FINISH());
    delete $self->{deflator};
    $status == Compress::Raw::Zlib::Z_OK() or do {
        $self->_set_error("Failed to compress: $status", status => $status);
        return;
    };

    ${$self->buffer} .= $out;
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

sub EOF      {
    $ENV{DEBUG_STREAM} and print STDERR "EOF\t$_[0]\n";
    (!$_[0]->inflator && !$_[0]->deflator) || $_[0]->ERROR($_[1]);
}
sub ERROR    {
    $ENV{DEBUG_STREAM} and print STDERR "ERROR\t$_[0] : ", $_[0]->{error} // 'ok', "\n";
    $ERROR = $_[0]->{error} if $_[0]->{error};
    $_[0]->{error} ? 1 : 0;
}
sub CLEARERR {
    $ENV{DEBUG_STREAM} and print STDERR "CLEARERR\t$_[0]\n";
    # delete $_[0]->{error};
}

sub inflator { $_[0]->{inflator} }
sub deflator { $_[0]->{deflator} }
sub mode     { $_[0]->{mode} }
sub buffer   { $_[0]->{buffer} }

sub _inflator {
    load_optional('Compress::Raw::Zlib');
    my ($inflator, $status)
        = Compress::Raw::Zlib::Inflate->new(-WindowBits => Compress::Raw::Zlib::WANT_GZIP(), @_);
    $status == Compress::Raw::Zlib::Z_OK()
        or throw 'Failed to initialize inflator', status => $status;
    return $inflator;
}

sub _deflator {
    load_optional('Compress::Raw::Zlib');
    my ($deflator, $status)
        = Compress::Raw::Zlib::Deflate->new(-WindowBits => Compress::Raw::Zlib::WANT_GZIP(), @_);
    $status == Compress::Raw::Zlib::Z_OK()
        or throw 'Failed to initialize deflator', status => $status;
    return $deflator;
}

sub _set_error {
    my $self = shift;
    $ENV{DEBUG_STREAM} and print STDERR "err\t$self\n";
    delete $self->{inflator};
    delete $self->{deflator};
    if (exists &Errno::EPROTO) {
        $! = &Errno::EPROTO;
    }
    elsif (exists &Errno::EIO) {
        $! = &Errno::EIO;
    }
    $self->{error} = $ERROR = File::KDBX::Error->new(@_);
}

1;
