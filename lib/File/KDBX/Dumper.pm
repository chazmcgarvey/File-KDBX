package File::KDBX::Dumper;
# ABSTRACT: Write KDBX files

use warnings;
use strict;

use Crypt::Digest qw(digest_data);
use File::KDBX::Constants qw(:magic :header :version :random_stream);
use File::KDBX::Error;
use File::KDBX::Util qw(:class);
use File::KDBX;
use IO::Handle;
use Module::Load;
use Ref::Util qw(is_ref is_scalarref);
use Scalar::Util qw(looks_like_number openhandle);
use namespace::clean;

our $VERSION = '999.999'; # VERSION

=method new

    $dumper = File::KDBX::Dumper->new(%attributes);

Construct a new L<File::KDBX::Dumper>.

=cut

sub new {
    my $class = shift;
    my $self = bless {}, $class;
    $self->init(@_);
}

=method init

    $dumper = $dumper->init(%attributes);

Initialize a L<File::KDBX::Dumper> with a new set of attributes.

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

    my $version = $self->kdbx->version;

    my $subclass;

    if (defined $format) {
        $subclass = $format;
    }
    elsif (!defined $version) {
        $subclass = 'XML';
    }
    elsif ($self->kdbx->sig2 == KDBX_SIG2_1) {
        $subclass = 'KDB';
    }
    elsif (looks_like_number($version)) {
        my $major = $version & KDBX_VERSION_MAJOR_MASK;
        my %subclasses = (
            KDBX_VERSION_2_0()  => 'V3',
            KDBX_VERSION_3_0()  => 'V3',
            KDBX_VERSION_4_0()  => 'V4',
        );
        if ($major == KDBX_VERSION_2_0) {
            alert sprintf("Upgrading KDBX version %x to version %x\n", $version, KDBX_VERSION_3_1);
            $self->kdbx->version(KDBX_VERSION_3_1);
        }
        $subclass = $subclasses{$major}
            or throw sprintf('Unsupported KDBX file version: %x', $version), version => $version;
    }
    else {
        throw sprintf('Unknown file version: %s', $version), version => $version;
    }

    load "File::KDBX::Dumper::$subclass";
    bless $self, "File::KDBX::Dumper::$subclass";
}

=method reset

    $dumper = $dumper->reset;

Set a L<File::KDBX::Dumper> to a blank state, ready to dump another KDBX file.

=cut

sub reset {
    my $self = shift;
    %$self = ();
    return $self;
}

=method dump

    $dumper->dump(\$string, $key);
    $dumper->dump(*IO, $key);
    $dumper->dump($filepath, $key);

Dump a KDBX file.

The C<$key> is either a L<File::KDBX::Key> or a primitive that can be cast to a Key object.

=cut

sub dump {
    my $self = shift;
    my $dst  = shift;
    return $self->dump_handle($dst, @_) if openhandle($dst);
    return $self->dump_string($dst, @_) if is_scalarref($dst);
    return $self->dump_file($dst, @_)   if defined $dst && !is_ref($dst);
    throw 'Programmer error: Must pass a stringref, filepath or IO handle to dump';
}

=method dump_string

    $dumper->dump_string(\$string, $key);
    \$string = $dumper->dump_string($key);

Dump a KDBX file to a string / memory buffer.

=cut

sub dump_string {
    my $self = shift;
    my $ref  = is_scalarref($_[0]) ? shift : undef;
    my %args = @_ % 2 == 0 ? @_ : (key => shift, @_);

    my $key = delete $args{key};
    $args{kdbx} //= $self->kdbx;

    $ref //= do {
        my $buf = '';
        \$buf;
    };

    open(my $fh, '>', $ref) or throw "Failed to open string buffer: $!";

    $self = $self->new if !ref $self;
    $self->init(%args, fh => $fh)->_dump($fh, $key);

    return $ref;
}

=method dump_file

    $dumper->dump_file($filepath, $key);

Dump a KDBX file to a filesystem.

=cut

sub dump_file {
    my $self     = shift;
    my $filepath = shift;
    my %args     = @_ % 2 == 0 ? @_ : (key => shift, @_);

    my $key = delete $args{key};
    $args{kdbx} //= $self->kdbx;

    require File::Temp;
    my ($fh, $filepath_temp) = eval { File::Temp::tempfile("${filepath}-XXXXXX", CLEANUP => 1) };
    if (!$fh or my $err = $@) {
        $err //= 'Unknown error';
        throw sprintf('Open file failed (%s): %s', $filepath_temp, $err),
            error       => $err,
            filepath    => $filepath_temp;
    }
    $fh->autoflush(1);

    $self = $self->new if !ref $self;
    $self->init(%args, fh => $fh, filepath => $filepath);
    $self->_dump($fh, $key);
    close($fh);

    my ($file_mode, $file_uid, $file_gid) = (stat($filepath))[2, 4, 5];

    my $mode = $args{mode} // $file_mode // do { my $m = umask; defined $m ? oct(666) &~ $m : undef };
    my $uid  = $args{uid}  // $file_uid  // -1;
    my $gid  = $args{gid}  // $file_gid  // -1;
    chmod($mode, $filepath_temp) if defined $mode;
    chown($uid, $gid, $filepath_temp);
    rename($filepath_temp, $filepath) or throw "Failed to write file ($filepath): $!", filepath => $filepath;

    return $self;
}

=method dump_handle

    $dumper->dump_handle($fh, $key);
    $dumper->dump_handle(*IO, $key);

Dump a KDBX file to an output stream / file handle.

=cut

sub dump_handle {
    my $self = shift;
    my $fh   = shift;
    my %args = @_ % 2 == 0 ? @_ : (key => shift, @_);

    $fh = *STDOUT if $fh eq '-';

    my $key = delete $args{key};
    $args{kdbx} //= $self->kdbx;

    $self = $self->new if !ref $self;
    $self->init(%args, fh => $fh)->_dump($fh, $key);
}

=attr kdbx

    $kdbx = $dumper->kdbx;
    $dumper->kdbx($kdbx);

Get or set the L<File::KDBX> instance with the data to be dumped.

=cut

sub kdbx {
    my $self = shift;
    return File::KDBX->new if !ref $self;
    $self->{kdbx} = shift if @_;
    $self->{kdbx} //= File::KDBX->new;
}

=attr format

Get the file format used for writing the database. Normally the format is auto-detected from the database,
which is the safest choice. Possible formats:

=for :list
* C<V3>
* C<V4>
* C<KDB>
* C<XML> (only used if explicitly set)
* C<Raw> (only used if explicitly set)

B<WARNING:> There is a potential for data loss if you explicitly use a format that doesn't support the
features used by the KDBX database being written.

The most common reason to explicitly specify the file format is to save a database as an unencrypted XML file:

    $kdbx->dump_file('database.xml', format => 'XML');

=attr inner_format

Get the format of the data inside the KDBX envelope. This only applies to C<V3> and C<V4> formats. Possible
formats:

=for :list
* C<XML> - Write the database groups and entries as XML (default)
* C<Raw> - Write L<File::KDBX/raw> instead of the actual database contents

=attr allow_upgrade

    $bool = $dumper->allow_upgrade;

Whether or not to allow implicitly upgrading a database to a newer version. When enabled, in order to avoid
potential data loss, the database can be upgraded as-needed in cases where the database file format version is
too low to support new features being used.

The default is to allow upgrading.

=attr randomize_seeds

    $bool = $dumper->randomize_seeds;

Whether or not to randomize seeds in a database before writing. The default is to randomize seeds, and there's
not often a good reason not to do so. If disabled, the seeds associated with the KDBX database will be used as
they are.

=cut

has 'format',           is => 'ro';
has 'inner_format',     is => 'ro', default => 'XML';
has 'allow_upgrade',    is => 'ro', default => 1;
has 'randomize_seeds',  is => 'ro', default => 1;

sub _fh { $_[0]->{fh} or throw 'IO handle not set' }

sub _dump {
    my $self = shift;
    my $fh = shift;
    my $key = shift;

    my $kdbx = $self->kdbx;

    my $min_version = $kdbx->minimum_version;
    if ($kdbx->version < $min_version && $self->allow_upgrade) {
        alert sprintf("Implicitly upgrading database from %x to %x\n", $kdbx->version, $min_version),
            version => $kdbx->version, min_version => $min_version;
        $kdbx->version($min_version);
    }
    $self->_rebless;

    if (ref($self) =~ /::(?:KDB|V[34])$/) {
        $key //= $kdbx->key ? $kdbx->key->reload : undef;
        defined $key or throw 'Must provide a master key', type => 'key.missing';
    }

    $self->_prepare;

    my $magic = $self->_write_magic_numbers($fh);
    my $headers = $self->_write_headers($fh);

    $kdbx->unlock;

    $self->_write_body($fh, $key, "$magic$headers");

    return $kdbx;
}

sub _prepare {
    my $self = shift;
    my $kdbx = $self->kdbx;

    if ($kdbx->version < KDBX_VERSION_4_0) {
        # force Salsa20 inner random stream
        $kdbx->inner_random_stream_id(STREAM_ID_SALSA20);
        my $key = $kdbx->inner_random_stream_key;
        substr($key, 32) = '';
        $kdbx->inner_random_stream_key($key);
    }

    $kdbx->randomize_seeds if $self->randomize_seeds;
}

sub _write_magic_numbers {
    my $self = shift;
    my $fh = shift;

    my $kdbx = $self->kdbx;

    $kdbx->sig1 == KDBX_SIG1 or throw 'Invalid file signature', sig1 => $kdbx->sig1;
    $kdbx->version < KDBX_VERSION_OLDEST || KDBX_VERSION_LATEST < $kdbx->version
        and throw 'Unsupported file version', version => $kdbx->version;

    my @magic = ($kdbx->sig1, $kdbx->sig2, $kdbx->version);

    my $buf = pack('L<3', @magic);
    $fh->print($buf) or throw 'Failed to write file signature';

    return $buf;
}

sub _write_headers { die "Not implemented" }

sub _write_body { die "Not implemented" }

sub _write_inner_body {
    my $self = shift;

    my $current_pkg = ref $self;
    require Scope::Guard;
    my $guard = Scope::Guard->new(sub { bless $self, $current_pkg });

    $self->_rebless($self->inner_format);
    $self->_write_inner_body(@_);
}

1;
