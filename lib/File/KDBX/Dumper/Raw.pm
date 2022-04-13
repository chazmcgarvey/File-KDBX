package File::KDBX::Dumper::Raw;
# ABSTRACT: A no-op dumper that dumps content as-is

use warnings;
use strict;

use parent 'File::KDBX::Dumper';

our $VERSION = '999.999'; # VERSION

sub _dump {
    my $self = shift;
    my $fh   = shift;

    $self->_write_body($fh);
}

sub _write_headers { '' }

sub _write_body {
    my $self = shift;
    my $fh   = shift;

    $self->_write_inner_body($fh);
}

sub _write_inner_body {
    my $self = shift;
    my $fh   = shift;

    $fh->print($self->kdbx->raw);
}

1;
__END__

=head1 SYNOPSIS

    use File::KDBX::Dumper;
    use File::KDBX;

    my $kdbx = File::KDBX->new;
    $kdbx->raw("Secret file contents\n");

    $kdbx->dump_file('file.kdbx', $key, inner_format => 'Raw');
    # OR
    File::KDBX::Dumper->dump_file('file.kdbx', $key,
        kdbx => $kdbx,
        inner_format => 'Raw',
    );

=head1 DESCRIPTION

A typical KDBX file is made up of an outer section (with headers) and an inner section (with the body). The
inner section is usually dumped using L<File::KDBX::Dumper::XML>, but you can use the
B<File::KDBX::Dumper::Raw> dumper to just write some arbitrary data as the body content. The result won't
necessarily be parseable by typical KeePass implementations, but it can be read back using
L<File::KDBX::Loader::Raw>. It's a way to encrypt any file with the same high level of security as a KDBX
database.

=cut
