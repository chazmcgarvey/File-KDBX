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

Issue a challenge and get a response, or throw if the responder failed.

=cut

sub challenge {
    my $self = shift;

    my $responder = $self->{responder} or throw 'Cannot issue challenge without a responder';
    return $responder->(@_);
}

1;
__END__

=head1 SYNOPSIS

    my $key = File::KDBX::Key::ChallengeResponse->(
        responder => sub { my $challenge = shift; ...; return $response },
    );

=head1 DESCRIPTION

=cut
