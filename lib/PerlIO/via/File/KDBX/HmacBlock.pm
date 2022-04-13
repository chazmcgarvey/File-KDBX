package PerlIO::via::File::KDBX::HmacBlock;
# ABSTRACT: HMAC block-stream PerlIO layer

use warnings;
use strict;

use Crypt::Digest qw(digest_data);
use Crypt::Mac::HMAC qw(hmac);
use File::KDBX::Error;
use File::KDBX::Util qw(:io assert_64bit);
use namespace::clean;

our $VERSION = '999.999'; # VERSION
our $BLOCK_SIZE = 1048576;
our $ERROR;

=method push

    PerlIO::via::File::KDBX::HmacBlock->push($fh, key => $key);
    PerlIO::via::File::KDBX::HmacBlock->push($fh, key => $key, block_size => $size);

Push a new HMAC-block layer with arguments. A key is required.

B<WARNING:> You mustn't push this layer using C<binmode> directly because the layer needs to be initialized
with the key and any other desired attributes.

B<WARNING:> When writing, you mustn't close the filehandle before popping this layer (using
C<binmode($fh, ':pop')>) or the stream will be truncated. The layer needs to know when there is no more data
before the filehandle closes so it can write the final block (which will likely be shorter than the other
blocks), and the way to indicate that is by popping the layer.

=cut

my %PUSHED_ARGS;
sub push {
    assert_64bit;

    %PUSHED_ARGS and throw 'Pushing HmacBlock layer would stomp existing arguments';

    my $class = shift;
    my $fh = shift;
    my %args = @_ % 2 == 0 ? @_ : (key => @_);
    $args{key} or throw 'Must pass a key';

    my $key_size = length($args{key});
    $key_size == 64 or throw 'Key must be 64 bytes in length', size => $key_size;

    %PUSHED_ARGS = %args;
    binmode($fh, ':via(' . __PACKAGE__ . ')');
}

sub PUSHED {
    my ($class, $mode) = @_;

    %PUSHED_ARGS or throw 'Programmer error: Use PerlIO::via::File::KDBX::HmacBlock->push instead of binmode';

    $ENV{DEBUG_STREAM} and print STDERR "PUSHED\t$class\n";
    my $buf = '';
    my $self = bless {
        block_index => 0,
        block_size  => $PUSHED_ARGS{block_size} || $BLOCK_SIZE,
        buffer      => \$buf,
        key         => $PUSHED_ARGS{key},
        mode        => $mode,
    }, $class;
    %PUSHED_ARGS = ();
    return $self;
}

sub FILL {
    my ($self, $fh) = @_;

    $ENV{DEBUG_STREAM} and print STDERR "FILL\t$self\n";
    return if $self->EOF($fh);

    my $block = eval { $self->_read_hashed_block($fh) };
    if (my $err = $@) {
        $self->_set_error($err);
        return;
    }
    if (length($block) == 0) {
        $self->{eof} = 1;
        return;
    }
    return $block;
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
    return if $self->mode !~ /^w/;

    $self->FLUSH($fh);
    eval {
        $self->_write_next_hmac_block($fh);     # partial block with remaining content
        $self->_write_final_hmac_block($fh);    # terminating block
    };
    $self->_set_error($@) if $@;
}

sub FLUSH {
    my ($self, $fh) = @_;

    $ENV{DEBUG_STREAM} and print STDERR "FLUSH\t$self\n";
    return 0 if !ref $self;

    eval {
        while ($self->block_size <= length(${$self->{buffer}})) {
            $self->_write_next_hmac_block($fh);
        }
    };
    if (my $err = $@) {
        $self->_set_error($err);
        return -1;
    }

    return 0;
}

sub EOF      {
    $ENV{DEBUG_STREAM} and print STDERR "EOF\t$_[0]\n";
    $_[0]->{eof} || $_[0]->ERROR($_[1]);
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

=attr key

    $key = $hmac_block->key;

Get the key used for authentication. The key must be exactly 64 bytes in size.

=cut

sub key { $_[0]->{key} or throw 'Key is not set' }

=attr block_size

    $size = $hmac_block->block_size;

Get the block size. Default is C<$PerlIO::via::File::KDBX::HmacBlock::BLOCK_SIZE>.

This only matters in write mode. When reading, block size is detected from the stream.

=cut

sub block_size  { $_[0]->{block_size} ||= $BLOCK_SIZE }

=attr block_index

=attr buffer

=attr mode

Internal attributes.

=cut

sub block_index { $_[0]->{block_index} ||= 0 }
sub buffer      { $_[0]->{buffer} }
sub mode        { $_[0]->{mode} }

sub _read_hashed_block {
    my $self = shift;
    my $fh = shift;

    read_all $fh, my $hmac, 32 or throw 'Failed to read HMAC';

    read_all $fh, my $size_buf, 4 or throw 'Failed to read HMAC block size';
    my ($size) = unpack('L<', $size_buf);

    my $block = '';
    if (0 < $size) {
        read_all $fh, $block, $size
            or throw 'Failed to read HMAC block', index => $self->block_index, size => $size;
    }

    my $index_buf = pack('Q<', $self->block_index);
    my $got_hmac = hmac('SHA256', $self->_hmac_key,
        $index_buf,
        $size_buf,
        $block,
    );

    $hmac eq $got_hmac
        or throw 'Block authentication failed', index => $self->block_index, got => $got_hmac, expected => $hmac;

    $self->{block_index}++;

    return $block;
}

sub _write_next_hmac_block {
    my $self    = shift;
    my $fh      = shift;
    my $buffer  = shift // $self->buffer;
    my $allow_empty = shift;

    my $size = length($$buffer);
    $size = $self->block_size if $self->block_size < $size;
    return 0 if $size == 0 && !$allow_empty;

    my $block = '';
    $block = substr($$buffer, 0, $size, '') if 0 < $size;

    my $index_buf = pack('Q<', $self->block_index);
    my $size_buf = pack('L<', $size);
    my $hmac = hmac('SHA256', $self->_hmac_key,
        $index_buf,
        $size_buf,
        $block,
    );

    print $fh $hmac, $size_buf, $block
        or throw 'Failed to write HMAC block', hmac => $hmac, block_size => $size, err => $fh->error;

    $self->{block_index}++;
    return 0;
}

sub _write_final_hmac_block {
    my $self = shift;
    my $fh = shift;

    $self->_write_next_hmac_block($fh, \'', 1);
}

sub _hmac_key {
    my $self = shift;
    my $key = shift // $self->key;
    my $index = shift // $self->block_index;

    my $index_buf = pack('Q<', $index);
    my $hmac_key = digest_data('SHA512', $index_buf, $key);
    return $hmac_key;
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

Writing to a handle with this layer will transform the data in a series of blocks. An HMAC is calculated for
each block and is included in the output.

Reading from a handle, each block will be verified and authenticated as the blocks are disassembled back into
a data stream.

Each block is encoded thusly:

=for :list
* HMAC - 32 bytes, calculated over [block index (increments starting with 0), block size and data]
* Block size - Little-endian unsigned 32-bit (counting only the data)
* Data - String of bytes

The terminating block is an empty block encoded as usual but block size is 0 and there is no data.

=cut
