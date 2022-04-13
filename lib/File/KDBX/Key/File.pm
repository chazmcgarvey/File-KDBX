package File::KDBX::Key::File;
# ABSTRACT: A file key

use warnings;
use strict;

use Crypt::Digest qw(digest_data);
use Crypt::Misc 0.029 qw(decode_b64);
use File::KDBX::Constants qw(:key_file);
use File::KDBX::Error;
use File::KDBX::Util qw(:erase trim);
use Ref::Util qw(is_ref is_scalarref);
use Scalar::Util qw(openhandle);
use XML::LibXML::Reader;
use namespace::clean;

use parent 'File::KDBX::Key';

our $VERSION = '999.999'; # VERSION

sub init {
    my $self = shift;
    my $primitive = shift // throw 'Missing key primitive';

    my $data;
    my $cleanup;

    if (openhandle($primitive)) {
        seek $primitive, 0, 0;  # not using ->seek method so it works on perl 5.10
        my $buf = do { local $/; <$primitive> };
        $data = \$buf;
        $cleanup = erase_scoped $data;
    }
    elsif (is_scalarref($primitive)) {
        $data = $primitive;
    }
    elsif (defined $primitive && !is_ref($primitive)) {
        open(my $fh, '<:raw', $primitive)
            or throw "Failed to open key file ($primitive)", filepath => $primitive;
        my $buf = do { local $/; <$fh> };
        $data = \$buf;
        $cleanup = erase_scoped $data;
        $self->{filepath} = $primitive;
    }
    else {
        throw 'Unexpected primitive type', type => ref $primitive;
    }

    my $raw_key;
    if (substr($$data, 0, 120) =~ /<KeyFile>/
            and my ($type, $version) = $self->_load_xml($data, \$raw_key)) {
        $self->{type}    = $type;
        $self->{version} = $version;
        $self->_set_raw_key($raw_key);
    }
    elsif (length($$data) == 32) {
        $self->{type} = KEY_FILE_TYPE_BINARY;
        $self->_set_raw_key($$data);
    }
    elsif ($$data =~ /^[A-Fa-f0-9]{64}$/) {
        $self->{type} = KEY_FILE_TYPE_HEX;
        $self->_set_raw_key(pack('H64', $$data));
    }
    else {
        $self->{type} = KEY_FILE_TYPE_HASHED;
        $self->_set_raw_key(digest_data('SHA256', $$data));
    }

    return $self->hide;
}

=method reload

    $key->reload;

Re-read the key file, if possible, and update the raw key if the key changed.

=cut

sub reload {
    my $self = shift;
    $self->init($self->{filepath}) if defined $self->{filepath};
    return $self;
}

=attr type

    $type = $key->type;

Get the type of key file. Can be one of:

=for :list
* C<KEY_FILE_TYPE_BINARY>
* C<KEY_FILE_TYPE_HEX>
* C<KEY_FILE_TYPE_XML>
* C<KEY_FILE_TYPE_HASHED>

=cut

sub type { $_[0]->{type} }

=attr version

    $version = $key->version;

Get the file version. Only applies to XML key files.

=cut

sub version { $_[0]->{version} }

=attr filepath

    $filepath = $key->filepath;

Get the filepath to the key file, if known.

=cut

sub filepath { $_[0]->{filepath} }

##############################################################################

sub _load_xml {
    my $self = shift;
    my $buf  = shift;
    my $out  = shift;

    my ($version, $hash, $data);

    my $reader  = XML::LibXML::Reader->new(string => $$buf);
    my $pattern = XML::LibXML::Pattern->new('/KeyFile/Meta/Version|/KeyFile/Key/Data');

    while ($reader->nextPatternMatch($pattern) == 1) {
        next if $reader->nodeType != XML_READER_TYPE_ELEMENT;
        my $name = $reader->localName;
        if ($name eq 'Version') {
            $reader->read if !$reader->isEmptyElement;
            $reader->nodeType == XML_READER_TYPE_TEXT
                or alert 'Expected text node with version', line => $reader->lineNumber;
            my $val = trim($reader->value);
            defined $version
                and alert 'Overwriting version', previous => $version, new => $val, line => $reader->lineNumber;
            $version = $val;
        }
        elsif ($name eq 'Data') {
            $hash = trim($reader->getAttribute('Hash')) if $reader->hasAttributes;
            $reader->read if !$reader->isEmptyElement;
            $reader->nodeType == XML_READER_TYPE_TEXT
                or alert 'Expected text node with data', line => $reader->lineNumber;
            $data = $reader->value;
            $data =~ s/\s+//g if defined $data;
        }
    }

    return if !defined $version || !defined $data;

    if ($version =~ /^1\.0/ && $data =~ /^[A-Za-z0-9+\/=]+$/) {
        $$out = eval { decode_b64($data) };
        if (my $err = $@) {
            throw 'Failed to decode key in key file', version => $version, data => $data, error => $err;
        }
        return (KEY_FILE_TYPE_XML, $version);
    }
    elsif ($version =~ /^2\.0/ && $data =~ /^[A-Fa-f0-9]+$/ && defined $hash && $hash =~ /^[A-Fa-f0-9]+$/) {
        $$out = pack('H*', $data);
        $hash = pack('H*', $hash);
        my $got_hash = digest_data('SHA256', $$out);
        $hash eq substr($got_hash, 0, 4)
            or throw 'Checksum mismatch', got => $got_hash, expected => $hash;
        return (KEY_FILE_TYPE_XML, $version);
    }

    throw 'Unexpected data in key file', version => $version, data => $data;
}

1;
