package File::KDBX::Cipher::CBC;
# ABSTRACT: A CBC block cipher mode encrypter/decrypter

use warnings;
use strict;

use Crypt::Mode::CBC;
use File::KDBX::Error;
use File::KDBX::Util qw(:class);
use namespace::clean;

extends 'File::KDBX::Cipher';

our $VERSION = '999.999'; # VERSION

has key_size => 32;
sub iv_size     { 16 }
sub block_size  { 16 }

sub encrypt {
    my $self = shift;

    my $mode = $self->{mode} ||= do {
        my $m = Crypt::Mode::CBC->new($self->algorithm);
        $m->start_encrypt($self->key, $self->iv);
        $m;
    };

    return join('', map { $mode->add(ref $_ ? $$_ : $_) } grep { defined } @_);
}

sub decrypt {
    my $self = shift;

    my $mode = $self->{mode} ||= do {
        my $m = Crypt::Mode::CBC->new($self->algorithm);
        $m->start_decrypt($self->key, $self->iv);
        $m;
    };

    return join('', map { $mode->add(ref $_ ? $$_ : $_) } grep { defined } @_);
}

sub finish {
    my $self = shift;
    return '' if !$self->{mode};
    my $out = $self->{mode}->finish;
    delete $self->{mode};
    return $out;
}

1;
__END__

=head1 SYNOPSIS

    use File::KDBX::Cipher::CBC;

    my $cipher = File::KDBX::Cipher::CBC->new(algorithm => $algo, key => $key, iv => $iv);

=head1 DESCRIPTION

A subclass of L<File::KDBX::Cipher> for encrypting and decrypting data using the CBC block cipher mode.

=cut
