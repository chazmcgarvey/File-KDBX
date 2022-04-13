package File::KDBX::Loader::Raw;
# ABSTRACT: A no-op loader that doesn't do any parsing

use warnings;
use strict;

use parent 'File::KDBX::Loader';

our $VERSION = '999.999'; # VERSION

sub _read {
    my $self = shift;
    my $fh   = shift;

    $self->_read_body($fh);
}

sub _read_body {
    my $self = shift;
    my $fh   = shift;

    $self->_read_inner_body($fh);
}

sub _read_inner_body {
    my $self = shift;
    my $fh   = shift;

    my $content = do { local $/; <$fh> };
    $self->kdbx->raw($content);
}

1;
__END__

=head1 SYNOPSIS

    use File::KDBX::Loader;

    my $kdbx = File::KDBX::Loader->load_file('file.kdbx', $key, inner_format => 'Raw');
    print $kdbx->raw;

=head1 DESCRIPTION

A typical KDBX file is made up of an outer section (with headers) and an inner section (with the body). The
inner section is usually loaded using L<File::KDBX::Loader::XML>, but you can use the
B<File::KDBX::Loader::Raw> loader to not parse the body at all and just get the raw body content. This can be
useful for debugging or creating KDBX files with arbitrary content (see L<File::KDBX::Dumper::Raw>).

=cut
