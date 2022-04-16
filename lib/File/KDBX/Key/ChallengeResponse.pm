package File::KDBX::Key::ChallengeResponse;
# ABSTRACT: A challenge-response key

use warnings;
use strict;

use File::KDBX::Error;
use namespace::clean;

use parent 'File::KDBX::Key';

our $VERSION = '999.999'; # VERSION

sub init {
    my $self = shift;
    my $primitive = shift or throw 'Missing key primitive';

    $self->{responder} = $primitive;

    return $self->hide;
}

=method raw_key

    $raw_key = $key->raw_key;
    $raw_key = $key->raw_key($challenge);

Get the raw key which is the response to a challenge. The response will be saved so that subsequent calls
(with or without the challenge) can provide the response without challenging the responder again. Only once
response is saved at a time; if you call this with a different challenge, the new response is saved over any
previous response.

=cut

sub raw_key {
    my $self = shift;
    if (@_) {
        my $challenge = shift // '';
        # Don't challenge if we already have the response.
        return $self->SUPER::raw_key if $challenge eq ($self->{challenge} // '');
        $self->_set_raw_key($self->challenge($challenge, @_));
        $self->{challenge} = $challenge;
    }
    $self->SUPER::raw_key;
}

=method challenge

    $response = $key->challenge($challenge, @options);

Issue a challenge and get a response, or throw if the responder failed to provide one.

=cut

sub challenge {
    my $self = shift;

    my $responder = $self->{responder} or throw 'Cannot issue challenge without a responder';
    return $responder->(@_);
}

1;
__END__

=head1 SYNOPSIS

    use File::KDBX::Key::ChallengeResponse;

    my $responder = sub {
        my $challenge = shift;
        ...;    # generate a response based on a secret of some sort
        return $response;
    };
    my $key = File::KDBX::Key::ChallengeResponse->new($responder);

=head1 DESCRIPTION

A challenge-response key is kind of like multifactor authentication, except you don't really I<authenticate>
to a KDBX database because it's not a service. Specifically it would be the "what you have" component. It
assumes there is some device that can store a key that is only known to the unlocker of a database.
A challenge is made to the device and the response generated based on the key is used as the raw key.

Inherets methods and attributes from L<File::KDBX::Key>.

This is a generic implementation where a responder subroutine is provided to provide the response. There is
also L<File::KDBX::Key::YubiKey> which is a subclass that allows YubiKeys to be responder devices.

=cut
