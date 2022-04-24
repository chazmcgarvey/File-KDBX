package File::KDBX::Key::Composite;
# ABSTRACT: A composite key made up of component keys

use warnings;
use strict;

use Crypt::Digest qw(digest_data);
use File::KDBX::Error;
use File::KDBX::Util qw(:class :erase);
use Ref::Util qw(is_arrayref);
use Scalar::Util qw(blessed);
use namespace::clean;

extends 'File::KDBX::Key';

our $VERSION = '999.999'; # VERSION

sub init {
    my $self = shift;
    my $primitive = shift // throw 'Missing key primitive';

    my @primitive = grep { defined } is_arrayref($primitive) ? @$primitive : $primitive;
    @primitive or throw 'Composite key must have at least one component key', count => scalar @primitive;

    my @keys = map { blessed $_ && $_->can('raw_key') ? $_ : File::KDBX::Key->new($_,
        keep_primitive => $self->{keep_primitive}) } @primitive;
    $self->{keys} = \@keys;

    return $self->hide;
}

=method raw_key

    $raw_key = $key->raw_key;
    $raw_key = $key->raw_key($challenge);

Get the raw key from each component key and return a generated composite raw key.

=cut

sub raw_key {
    my $self = shift;
    my $challenge = shift;

    my @keys = @{$self->keys} or throw 'Cannot generate a raw key from an empty composite key';

    my @basic_keys = map { $_->raw_key } grep { !$_->can('challenge') } @keys;
    my $response;
    $response = $self->challenge($challenge, @_) if defined $challenge;
    my $cleanup = erase_scoped \@basic_keys, $response;

    return digest_data('SHA256',
        @basic_keys,
        defined $response ? $response : (),
    );
}

=attr keys

    \@keys = $key->keys;

Get one or more component L<File::KDBX::Key>.

=cut

sub keys {
    my $self = shift;
    $self->{keys} = shift if @_;
    return $self->{keys} ||= [];
}

=method challenge

    $response = $key->challenge(...);

Issues a challenge to any L<File::KDBX::Key::ChallengeResponse> components keys. Arguments are passed through
to each component key. The responses are hashed together and the composite response is returned.

Returns empty string if there are no challenge-response components keys.

=cut

sub challenge {
    my $self = shift;

    my @chalresp_keys = grep { $_->can('challenge') } @{$self->keys} or return '';

    my @responses = map { $_->challenge(@_) } @chalresp_keys;
    my $cleanup = erase_scoped \@responses;

    return digest_data('SHA256', @responses);
}

sub hide {
    my $self = shift;
    $_->hide for @{$self->keys};
    return $self;
}

sub show {
    my $self = shift;
    $_->show for @{$self->keys};
    return $self;
}

1;
__END__

=head1 SYNOPSIS

    use File::KDBX::Key::Composite;

    my $key = File::KDBX::Key::Composite->(\@component_keys);

=head1 DESCRIPTION

A composite key is a collection of other keys. A master key capable of unlocking a KDBX database is always
a composite key, even if it only has a single component.

Inherets methods and attributes from L<File::KDBX::Key>.

=cut
