package File::KDBX::Transaction;
# ABSTRACT: Make multiple database edits atomically

use warnings;
use strict;

use Devel::GlobalDestruction;
use namespace::clean;

our $VERSION = '999.999'; # VERSION

sub new {
    my $class = shift;
    my $object = shift;
    my $orig   = shift // $object->clone;
    return bless {object => $object, original => $orig}, $class;
}

sub DESTROY { !in_global_destruction and $_[0]->rollback }

sub object   { $_[0]->{object} }
sub original { $_[0]->{original} }

sub commit {
    my $self = shift;
    my $obj = $self->object;
    if (my $commit = $obj->can('_commit')) {
        $commit->($obj, $self);
    }
    $self->{committed} = 1;
    return $obj;
}

sub rollback {
    my $self = shift;
    return if $self->{committed};

    my $obj = $self->object;
    my $orig = $self->original;

    %$obj = ();
    @$obj{keys %$orig} = values %$orig;

    return $obj;
}

1;
