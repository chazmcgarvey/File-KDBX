package File::KDBX::Key::Password;
# ABSTRACT: A password key

use warnings;
use strict;

use Crypt::Digest qw(digest_data);
use Encode qw(encode);
use File::KDBX::Error;
use File::KDBX::Util qw(:class erase);
use namespace::clean;

extends 'File::KDBX::Key';

our $VERSION = '999.999'; # VERSION

sub init {
    my $self = shift;
    my $primitive = shift // throw 'Missing key primitive';

    $self->_set_raw_key(digest_data('SHA256', encode('UTF-8', $primitive)));

    return $self->hide;
}

1;
__END__

=head1 SYNOPSIS

    use File::KDBX::Key::Password;

    my $key = File::KDBX::Key::Password->new($password);

=head1 DESCRIPTION

A password key is as simple as it sounds. It's just a password or passphrase.

Inherets methods and attributes from L<File::KDBX::Key>.

=cut
