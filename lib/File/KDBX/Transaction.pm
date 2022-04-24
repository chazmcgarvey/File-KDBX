package File::KDBX::Transaction;
# ABSTRACT: Make multiple database edits atomically

use warnings;
use strict;

use Devel::GlobalDestruction;
use File::KDBX::Util qw(:class);
use namespace::clean;

our $VERSION = '999.999'; # VERSION

=method new

    $txn = File::KDBX::Transaction->new($object);

Construct a new database transaction for editing an object atomically.

=cut

sub new {
    my $class   = shift;
    my $object  = shift;
    $object->begin_work(@_);
    return bless {object => $object}, $class;
}

sub DESTROY { !in_global_destruction and $_[0]->rollback }

=attr object

Get the object being transacted on.

=cut

has 'object', is => 'ro';

=method commit

    $txn->commit;

Commit the transaction, making updates to the L</object> permanent.

=cut

sub commit {
    my $self = shift;
    return if $self->{done};

    my $obj = $self->object;
    $obj->commit;
    $self->{done} = 1;
    return $obj;
}

=method rollback

    $txn->rollback;

Roll back the transaction, throwing away any updates to the L</object> made since the transaction began. This
happens automatically when the transaction is released, unless it has already been committed.

=cut

sub rollback {
    my $self = shift;
    return if $self->{done};

    my $obj = $self->object;
    $obj->rollback;
    $self->{done} = 1;
    return $obj;
}

1;
