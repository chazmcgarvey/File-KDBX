package File::KDBX::Loader;
# ABSTRACT: Load KDBX files

use warnings;
use strict;

use File::KDBX::Constants qw(:magic :header :version);
use File::KDBX::Error;
use File::KDBX::Util qw(:class :io);
use File::KDBX;
use IO::Handle;
use Module::Load ();
use Ref::Util qw(is_ref is_scalarref);
use Scalar::Util qw(looks_like_number openhandle);
use namespace::clean;

our $VERSION = '999.999'; # VERSION

=method new

    $loader = File::KDBX::Loader->new(%attributes);

Construct a new L<File::KDBX::Loader>.

=cut

sub new {
    my $class = shift;
    my $self = bless {}, $class;
    $self->init(@_);
}

=method init

    $loader = $loader->init(%attributes);

Initialize a L<File::KDBX::Loader> with a new set of attributes.

This is called by L</new>.

=cut

sub init {
    my $self = shift;
    my %args = @_;

    @$self{keys %args} = values %args;

    return $self;
}

sub _rebless {
    my $self    = shift;
    my $format  = shift // $self->format;

    my $sig2    = $self->kdbx->sig2;
    my $version = $self->kdbx->version;

    my $subclass;

    if (defined $format) {
        $subclass = $format;
    }
    elsif (defined $sig2 && $sig2 == KDBX_SIG2_1) {
        $subclass = 'KDB';
    }
    elsif (looks_like_number($version)) {
        my $major = $version & KDBX_VERSION_MAJOR_MASK;
        my %subclasses = (
            KDBX_VERSION_2_0() => 'V3',
            KDBX_VERSION_3_0() => 'V3',
            KDBX_VERSION_4_0() => 'V4',
        );
        $subclass = $subclasses{$major}
            or throw sprintf('Unsupported KDBX file version: %x', $version), version => $version;
    }
    else {
        throw sprintf('Unknown file version: %s', $version), version => $version;
    }

    Module::Load::load "File::KDBX::Loader::$subclass";
    bless $self, "File::KDBX::Loader::$subclass";
}

=method reset

    $loader = $loader->reset;

Set a L<File::KDBX::Loader> to a blank state, ready to load another KDBX file.

=cut

sub reset {
    my $self = shift;
    %$self = ();
    return $self;
}

=method load

    $kdbx = File::KDBX::Loader->load(\$string, $key);
    $kdbx = File::KDBX::Loader->load(*IO, $key);
    $kdbx = File::KDBX::Loader->load($filepath, $key);
    $kdbx = $loader->load(...); # also instance method

Load a KDBX file.

The C<$key> is either a L<File::KDBX::Key> or a primitive that can be cast to a Key object.

=cut

sub load {
    my $self = shift;
    my $src  = shift;
    return $self->load_handle($src, @_) if openhandle($src) || $src eq '-';
    return $self->load_string($src, @_) if is_scalarref($src);
    return $self->load_file($src, @_)   if !is_ref($src) && defined $src;
    throw 'Programmer error: Must pass a stringref, filepath or IO handle to read';
}

=method load_string

    $kdbx = File::KDBX::Loader->load_string($string, $key);
    $kdbx = File::KDBX::Loader->load_string(\$string, $key);
    $kdbx = $loader->load_string(...); # also instance method

Load a KDBX file from a string / memory buffer.

=cut

sub load_string {
    my $self = shift;
    my $str  = shift or throw 'Expected string to load';
    my %args = @_ % 2 == 0 ? @_ : (key => shift, @_);

    my $key = delete $args{key};
    $args{kdbx} //= $self->kdbx;

    my $ref = is_scalarref($str) ? $str : \$str;

    open(my $fh, '<', $ref) or throw "Failed to open string buffer: $!";

    $self = $self->new if !ref $self;
    $self->init(%args, fh => $fh)->_read($fh, $key);
    return $args{kdbx};
}

=method load_file

    $kdbx = File::KDBX::Loader->load_file($filepath, $key);
    $kdbx = $loader->load_file(...); # also instance method

Read a KDBX file from a filesystem.

=cut

sub load_file {
    my $self     = shift;
    my $filepath = shift;
    my %args     = @_ % 2 == 0 ? @_ : (key => shift, @_);

    my $key = delete $args{key};
    $args{kdbx} //= $self->kdbx;

    open(my $fh, '<:raw', $filepath) or throw 'Open file failed', filepath => $filepath;

    $self = $self->new if !ref $self;
    $self->init(%args, fh => $fh, filepath => $filepath)->_read($fh, $key);
    return $args{kdbx};
}

=method load_handle

    $kdbx = File::KDBX::Loader->load_handle($fh, $key);
    $kdbx = File::KDBX::Loader->load_handle(*IO, $key);
    $kdbx->load_handle(...); # also instance method

Read a KDBX file from an input stream / file handle.

=cut

sub load_handle {
    my $self = shift;
    my $fh   = shift;
    my %args     = @_ % 2 == 0 ? @_ : (key => shift, @_);

    $fh = *STDIN if $fh eq '-';

    my $key = delete $args{key};
    $args{kdbx} //= $self->kdbx;

    $self = $self->new if !ref $self;
    $self->init(%args, fh => $fh)->_read($fh, $key);
    return $args{kdbx};
}

=attr kdbx

    $kdbx = $loader->kdbx;
    $loader->kdbx($kdbx);

Get or set the L<File::KDBX> instance for storing the loaded data into.

=cut

sub kdbx {
    my $self = shift;
    return File::KDBX->new if !ref $self;
    $self->{kdbx} = shift if @_;
    $self->{kdbx} //= File::KDBX->new;
}

=attr format

Get the file format used for reading the database. Normally the format is auto-detected from the data stream.
This auto-detection works well, so there's not really a good reason to explicitly specify the format.
Possible formats:

=for :list
* C<V3>
* C<V4>
* C<KDB>
* C<XML>
* C<Raw>

=attr inner_format

Get the format of the data inside the KDBX envelope. This only applies to C<V3> and C<V4> formats. Possible
formats:

=for :list
* C<XML> - Read the database groups and entries as XML (default)
* C<Raw> - Read and store the result in L<File::KDBX/raw> without parsing

=cut

has format          => undef, is => 'ro';
has inner_format    => 'XML', is => 'ro';

=method read_magic_numbers

    $magic = File::KDBX::Loader->read_magic_numbers($fh);
    ($sig1, $sig2, $version, $magic) = File::KDBX::Loader->read_magic_numbers($fh);

    $magic = $loader->read_magic_numbers($fh);
    ($sig1, $sig2, $version, $magic) = $loader->read_magic_numbers($fh);

Read exactly 12 bytes from an IO handle and parse them into the three magic numbers that begin
a KDBX file. This is a quick way to determine if a file is actually a KDBX file.

C<$sig1> should always be C<KDBX_SIG1> if reading an actual KDB or KDBX file.

C<$sig2> should be C<KDBX_SIG2_1> for KeePass 1 files and C<KDBX_SIG2_2> for KeePass 2 files.

C<$version> is the file version (e.g. C<0x00040001>).

C<$magic> is the raw 12 bytes read from the IO handle.

If called on an instance, the C<sig1>, C<sig2> and C<version> attributes will be set in the L</kdbx>
and the instance will be blessed into the correct loader subclass.

=cut

sub read_magic_numbers {
    my $self = shift;
    my $fh   = shift;
    my $kdbx = shift // $self->kdbx;

    read_all $fh, my $magic, 12 or throw 'Failed to read file signature';

    my ($sig1, $sig2, $version) = unpack('L<3', $magic);

    if ($kdbx) {
        $kdbx->sig1($sig1);
        $kdbx->sig2($sig2);
        $kdbx->version($version);
        $self->_rebless if ref $self;
    }

    return wantarray ? ($sig1, $sig2, $version, $magic) : $magic;
}

sub _fh { $_[0]->{fh} or throw 'IO handle not set' }

sub _read {
    my $self = shift;
    my $fh   = shift;
    my $key  = shift;

    my $kdbx = $self->kdbx;
    $key //= $kdbx->key ? $kdbx->key->reload : undef;
    $kdbx->reset;

    read_all $fh, my $buf, 1 or throw 'Failed to read the first byte', type => 'parser';
    my $first = ord($buf);
    $fh->ungetc($first);
    if ($first != KDBX_SIG1_FIRST_BYTE) {
        # not a KDBX file... try skipping the outer layer
        return $self->_read_inner_body($fh);
    }

    my $magic = $self->read_magic_numbers($fh, $kdbx);
    $kdbx->sig1 == KDBX_SIG1 or throw 'Invalid file signature', type => 'parser', sig1 => $kdbx->sig1;

    if (ref($self) =~ /::(?:KDB|V[34])$/) {
        defined $key or throw 'Must provide a master key', type => 'key.missing';
    }

    my $headers = $self->_read_headers($fh);

    eval {
        $self->_read_body($fh, $key, "$magic$headers");
    };
    if (my $err = $@) {
        throw "Failed to load KDBX file: $err",
            error               => $err,
            compression_error   => $IO::Uncompress::Gunzip::GunzipError,
            crypt_error         => $File::KDBX::IO::Crypt::ERROR,
            hash_error          => $File::KDBX::IO::HashBLock::ERROR,
            hmac_error          => $File::KDBX::IO::HmacBLock::ERROR;
    }
}

sub _read_headers {
    my $self = shift;
    my $fh   = shift;

    my $headers = $self->kdbx->headers;
    my $all_raw = '';

    while (my ($type, $val, $raw) = $self->_read_header($fh)) {
        $all_raw .= $raw;
        last if $type == HEADER_END;
        $headers->{$type} = $val;
    }

    return $all_raw;
}

sub _read_body { die "Not implemented" }

sub _read_inner_body {
    my $self = shift;

    my $current_pkg = ref $self;
    require Scope::Guard;
    my $guard = Scope::Guard->new(sub { bless $self, $current_pkg });

    $self->_rebless($self->inner_format);
    $self->_read_inner_body(@_);
}

1;
__END__

=head1 DESCRIPTION


=cut
