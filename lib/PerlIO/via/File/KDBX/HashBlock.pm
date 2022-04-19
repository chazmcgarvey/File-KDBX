package PerlIO::via::File::KDBX::HashBlock;
# ABSTRACT: Hash block stream PerlIO layer

use warnings;
use strict;

use Crypt::Digest qw(digest_data);
use Errno;
use File::KDBX::Error;
use File::KDBX::Util qw(:io);
use IO::Handle;
use namespace::clean;

our $VERSION = '999.999'; # VERSION
our $ALGORITHM = 'SHA256';
our $BLOCK_SIZE = 1048576;
our $ERROR;

=method push

    PerlIO::via::File::KDBX::HashBlock->push($fh, %attributes);

Push a new HashBlock layer, optionally with attributes.

This is identical to:

    binmode($fh, ':via(File::KDBX::HashBlock)');

except this allows you to customize the process with attributes.

B<WARNING:> When writing, you mustn't close the filehandle before popping this layer (using
C<binmode($fh, ':pop')>) or the stream will be truncated. The layer needs to know when there is no more data
before the filehandle closes so it can write the final block (which will likely be shorter than the other
blocks), and the way to indicate that is by popping the layer.

=cut

my %PUSHED_ARGS;
sub push {
    %PUSHED_ARGS and throw 'Pushing Hash layer would stomp existing arguments';
    my $class = shift;
    my $fh = shift;
    %PUSHED_ARGS = @_;
    binmode($fh, ':via(' . __PACKAGE__ . ')');
}

sub PUSHED {
    my ($class, $mode) = @_;

    $ENV{DEBUG_STREAM} and print STDERR "PUSHED\t$class (mode: $mode)\n";
    my $self = bless {
        algorithm   => $PUSHED_ARGS{algorithm} || $ALGORITHM,
        block_index => 0,
        block_size  => $PUSHED_ARGS{block_size} || $BLOCK_SIZE,
        buffer      => \(my $buf = ''),
        eof         => 0,
        mode        => $mode,
    }, $class;
    %PUSHED_ARGS = ();
    return $self;
}

sub FILL {
    my ($self, $fh) = @_;

    $ENV{DEBUG_STREAM} and print STDERR "FILL\t$self\n";
    return if $self->EOF($fh);

    my $block = eval { $self->_read_hash_block($fh) };
    if (my $err = $@) {
        $self->_set_error($err);
        return;
    }
    return $$block if defined $block;
}

sub WRITE {
    my ($self, $buf, $fh) = @_;

    $ENV{DEBUG_STREAM} and print STDERR "WRITE\t$self\n";
    return 0 if $self->EOF($fh);

    ${$self->{buffer}} .= $buf;

    $self->FLUSH($fh);

    return length($buf);
}

sub POPPED {
    my ($self, $fh) = @_;

    $ENV{DEBUG_STREAM} and print STDERR "POPPED\t$self\n";
    return if $self->EOF($fh) || $self->mode !~ /^w/;

    $self->FLUSH($fh);
    eval {
        $self->_write_next_hash_block($fh);     # partial block with remaining content
        $self->_write_final_hash_block($fh);    # terminating block
    };
    $self->_set_error($@) if $@;
}

sub FLUSH {
    my ($self, $fh) = @_;

    $ENV{DEBUG_STREAM} and print STDERR "FLUSH\t$self\n";
    return 0 if !ref $self;

    eval {
        while ($self->block_size <= length(${$self->{buffer}})) {
            $self->_write_next_hash_block($fh);
        }
    };
    if (my $err = $@) {
        $self->_set_error($err);
        return -1;
    }

    return 0;
}

sub EOF {
    $ENV{DEBUG_STREAM} and print STDERR "EOF\t$_[0]\n";
    $_[0]->{eof} || $_[0]->ERROR($_[1]);
}
sub ERROR {
    $ENV{DEBUG_STREAM} and print STDERR "ERROR\t$_[0] : ", $_[0]->{error} // 'ok', "\n";
    $ERROR = $_[0]->{error} if $_[0]->{error};
    $_[0]->{error} ? 1 : 0;
}
sub CLEARERR {
    $ENV{DEBUG_STREAM} and print STDERR "CLEARERR\t$_[0]\n";
    # delete $_[0]->{error};
}

=attr algorithm

    $algo = $hash_block->algorithm;

Get the hash algorithm. Default is C<SHA256>.

=cut

sub algorithm { $_[0]->{algorithm} //= $ALGORITHM }

=attr block_size

    $size = $hash_block->block_size;

Get the block size. Default is C<$PerlIO::via::File::KDBX::HashBlock::BLOCK_SIZE>.

This only matters in write mode. When reading, block size is detected from the stream.

=cut

sub block_size  { $_[0]->{block_size} //= $BLOCK_SIZE }

=attr block_index

=attr buffer

=attr mode

Internal attributes.

=cut

sub block_index { $_[0]->{block_index} ||= 0 }
sub buffer      { $_[0]->{buffer} }
sub mode        { $_[0]->{mode} }

sub _read_hash_block {
    my $self = shift;
    my $fh = shift;

    read_all $fh, my $buf, 4 or throw 'Failed to read hash block index';
    my ($index) = unpack('L<', $buf);

    $index == $self->block_index
        or throw 'Invalid block index', index => $index;

    read_all $fh, my $hash, 32 or throw 'Failed to read hash';

    read_all $fh, $buf, 4 or throw 'Failed to read hash block size';
    my ($size) = unpack('L<', $buf);

    if ($size == 0) {
        $hash eq ("\0" x 32)
            or throw 'Invalid final block hash', hash => $hash;
        $self->{eof} = 1;
        return undef;
    }

    read_all $fh, my $block, $size or throw 'Failed to read hash block', index => $index, size => $size;

    my $got_hash = digest_data('SHA256', $block);
    $hash eq $got_hash
        or throw 'Hash mismatch', index => $index, size => $size, got => $got_hash, expected => $hash;

    $self->{block_index}++;
    return \$block;
}

sub _write_next_hash_block {
    my $self = shift;
    my $fh = shift;

    my $size = length(${$self->buffer});
    $size = $self->block_size if $self->block_size < $size;
    return 0 if $size == 0;

    my $block = substr(${$self->buffer}, 0, $size, '');

    my $buf = pack('L<', $self->block_index);
    print $fh $buf or throw 'Failed to write hash block index';

    my $hash = digest_data('SHA256', $block);
    print $fh $hash or throw 'Failed to write hash';

    $buf = pack('L<', length($block));
    print $fh $buf or throw 'Failed to write hash block size';

    # $fh->write($block, $size) or throw 'Failed to hash write block';
    print $fh $block or throw 'Failed to hash write block';

    $self->{block_index}++;
    return 0;
}

sub _write_final_hash_block {
    my $self = shift;
    my $fh = shift;

    my $buf = pack('L<', $self->block_index);
    print $fh $buf or throw 'Failed to write hash block index';

    my $hash = "\0" x 32;
    print $fh $hash or throw 'Failed to write hash';

    $buf = pack('L<', 0);
    print $fh $buf or throw 'Failed to write hash block size';

    $self->{eof} = 1;
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
    $self->{error} = $ERROR = File::KDBX::Error->new(@_);
}

1;
__END__

=head1 DESCRIPTION

Writing to a handle with this layer will transform the data in a series of blocks. Each block is hashed, and
the hash is included with the block in the stream.

Reading from a handle, each hash block will be verified as the blocks are disassembled back into a data
stream.

Each block is encoded thusly:

=for :list
* Block index - Little-endian unsigned 32-bit integer, increments starting with 0
* Hash - 32 bytes
* Block size - Little-endian unsigned 32-bit (counting only the data)
* Data - String of bytes

The terminating block is an empty block where hash is 32 null bytes, block size is 0 and there is no data.

=cut
