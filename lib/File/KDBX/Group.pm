package File::KDBX::Group;
# ABSTRACT: A KDBX database group

use warnings;
use strict;

use Devel::GlobalDestruction;
use File::KDBX::Constants qw(:icon);
use File::KDBX::Error;
use File::KDBX::Util qw(generate_uuid);
use Hash::Util::FieldHash;
use List::Util qw(sum0);
use Ref::Util qw(is_coderef is_ref);
use Scalar::Util qw(blessed);
use Time::Piece;
use boolean;
use namespace::clean;

use parent 'File::KDBX::Object';

our $VERSION = '999.999'; # VERSION

sub _parent_container { 'groups' }

my @ATTRS = qw(uuid custom_data entries groups);
my %ATTRS = (
    # uuid                        => sub { generate_uuid(printable => 1) },
    name                        => '',
    notes                       => '',
    tags                        => '',
    icon_id                     => sub { defined $_[1] ? icon($_[1]) : ICON_FOLDER },
    custom_icon_uuid            => undef,
    is_expanded                 => false,
    default_auto_type_sequence  => '',
    enable_auto_type            => undef,
    enable_searching            => undef,
    last_top_visible_entry      => undef,
    # custom_data                 => sub { +{} },
    previous_parent_group       => undef,
    # entries                     => sub { +[] },
    # groups                      => sub { +[] },
);
my %ATTRS_TIMES = (
    last_modification_time  => sub { scalar gmtime },
    creation_time           => sub { scalar gmtime },
    last_access_time        => sub { scalar gmtime },
    expiry_time             => sub { scalar gmtime },
    expires                 => false,
    usage_count             => 0,
    location_changed        => sub { scalar gmtime },
);

while (my ($attr, $setter) = each %ATTRS) {
    no strict 'refs'; ## no critic (ProhibitNoStrict)
    *{$attr} = is_coderef $setter ? sub {
        my $self = shift;
        $self->{$attr} = $setter->($self, shift) if @_;
        $self->{$attr} //= $setter->($self);
    } : sub {
        my $self = shift;
        $self->{$attr} = shift if @_;
        $self->{$attr} //= $setter;
    };
}
while (my ($attr, $default) = each %ATTRS_TIMES) {
    no strict 'refs'; ## no critic (ProhibitNoStrict)
    *{$attr} = sub {
        my $self = shift;
        $self->{times}{$attr} = shift if @_;
        $self->{times}{$attr} //= (ref $default eq 'CODE') ? $default->($self) : $default;
    };
}

sub _set_default_attributes {
    my $self = shift;
    $self->$_ for @ATTRS, keys %ATTRS, keys %ATTRS_TIMES;
}

sub uuid {
    my $self = shift;
    if (@_ || !defined $self->{uuid}) {
        my %args = @_ % 2 == 1 ? (uuid => shift, @_) : @_;
        my $old_uuid = $self->{uuid};
        my $uuid = $self->{uuid} = delete $args{uuid} // generate_uuid;
        $self->_signal('uuid.changed', $uuid, $old_uuid) if defined $old_uuid;
    }
    $self->{uuid};
}

##############################################################################

sub entries {
    my $self = shift;
    my $entries = $self->{entries} //= [];
    # FIXME - Looping through entries on each access is too expensive.
    @$entries = map { $self->_wrap_entry($_, $self->kdbx) } @$entries;
    return $entries;
}

sub all_entries {
    my $self = shift;
    # FIXME - shouldn't have to delegate to the database to get this
    return $self->kdbx->all_entries(base => $self);
}

=method add_entry

    $entry = $group->add_entry($entry);
    $entry = $group->add_entry(%entry_attributes);

Add an entry to a group. If C<$entry> already has a parent group, it will be removed from that group before
being added to C<$group>.

=cut

sub add_entry {
    my $self = shift;
    my $entry   = @_ % 2 == 1 ? shift : undef;
    my %args    = @_;

    my $kdbx = delete $args{kdbx} // eval { $self->kdbx };

    $entry = $self->_wrap_entry($entry // [%args]);
    $entry->uuid;
    $entry->kdbx($kdbx) if $kdbx;

    push @{$self->{entries} ||= []}, $entry->remove;
    return $entry->_set_group($self);
}

sub remove_entry {
    my $self = shift;
    my $uuid = is_ref($_[0]) ? $self->_wrap_entry(shift)->uuid : shift;
    my $objects = $self->{entries};
    for (my $i = 0; $i < @$objects; ++$i) {
        my $o = $objects->[$i];
        next if $uuid ne $o->uuid;
        return splice @$objects, $i, 1;
        $o->_set_group(undef);
        return @$objects, $i, 1;
    }
}

##############################################################################

sub groups {
    my $self = shift;
    my $groups = $self->{groups} //= [];
    # FIXME - Looping through groups on each access is too expensive.
    @$groups = map { $self->_wrap_group($_, $self->kdbx) } @$groups;
    return $groups;
}

sub all_groups {
    my $self = shift;
    # FIXME - shouldn't have to delegate to the database to get this
    return $self->kdbx->all_groups(base => $self, include_base => false);
}

sub _kpx_groups { shift->groups(@_) }

=method add_group

    $new_group = $group->add_group($new_group);
    $new_group = $group->add_group(%group_attributes);

Add a group to a group. If C<$new_group> already has a parent group, it will be removed from that group before
being added to C<$group>.

=cut

sub add_group {
    my $self    = shift;
    my $group   = @_ % 2 == 1 ? shift : undef;
    my %args    = @_;

    my $kdbx = delete $args{kdbx} // eval { $self->kdbx };

    $group = $self->_wrap_group($group // [%args]);
    $group->uuid;
    $group->kdbx($kdbx) if $kdbx;

    push @{$self->{groups} ||= []}, $group->remove;
    return $group->_set_group($self);
}

sub remove_group {
    my $self = shift;
    my $uuid = is_ref($_[0]) ? $self->_wrap_group(shift)->uuid : shift;
    my $objects = $self->{groups};
    for (my $i = 0; $i < @$objects; ++$i) {
        my $o = $objects->[$i];
        next if $uuid ne $o->uuid;
        $o->_set_group(undef);
        return splice @$objects, $i, 1;
    }
}

##############################################################################

=method add_object

    $new_entry = $group->add_object($new_entry);
    $new_group = $group->add_object($new_group);

Add an object (either a L<File::KDBX::Entry> or a L<File::KDBX::Group>) to a group. This is the generic
equivalent of the object forms of L</add_entry> and L</add_group>.

=cut

sub add_object {
    my $self = shift;
    my $obj  = shift;
    if ($obj->isa('File::KDBX::Entry')) {
        $self->add_entry($obj);
    }
    elsif ($obj->isa('File::KDBX::Group')) {
        $self->add_group($obj);
    }
}

=method remove_object

    $group->remove_object($entry);
    $group->remove_object($group);

Remove an object (either a L<File::KDBX::Entry> or a L<File::KDBX::Group>) from a group. This is the generic
equivalent of the object forms of L</remove_entry> and L</remove_group>.

=cut

sub remove_object {
    my $self = shift;
    my $object = shift;
    my $blessed = blessed($object);
    return $self->remove_group($object, @_) if $blessed && $object->isa('File::KDBX::Group');
    return $self->remove_entry($object, @_) if $blessed && $object->isa('File::KDBX::Entry');
    return $self->remove_group($object, @_) || $self->remove_entry($object, @_);
}

##############################################################################

=method is_root

    $bool = $group->is_root;

Determine if a group is the root group of its associated database.

=cut

sub is_root {
    my $self = shift;
    my $kdbx = eval { $self->kdbx } or return;
    return Hash::Util::FieldHash::id($kdbx->root) == Hash::Util::FieldHash::id($self);
}

=method path

    $string = $group->path;

Get a string representation of a group's lineage. This is used as the substitution value for the
C<{GROUP_PATH}> placeholder. See L<File::KDBX::Entry/Placeholders>.

For a root group, the path is simply the name of the group. For deeper groups, the path is a period-separated
sequence of group names between the root group and C<$group>, including C<$group> but I<not> the root group.
In other words, paths of deeper groups leave the root group name out.

    Database
    -> Root         # path is "Root"
       -> Foo       # path is "Foo"
          -> Bar    # path is "Foo.Bar"

Yeah, it doesn't make much sense to me, either, but this matches the behavior of KeePass.

=cut

sub path {
    my $self = shift;
    return $self->name if $self->is_root;
    my $lineage = $self->lineage or return;
    my @parts = (@$lineage, $self);
    shift @parts;
    return join('.', map { $_->name } @parts);
}

=method size

    $size = $group->size;

Get the size (in bytes) of a group, including the size of all subroups and entries, if any.

=cut

sub size {
    my $self = shift;
    return sum0 map { $_->size } @{$self->groups}, @{$self->entries};
}

=method depth

    $depth = $group->depth;

Get the depth of a group within a database. The root group is at depth 0, its direct children are at depth 1,
etc. A group not in a database tree structure returns a depth of -1.

=cut

sub depth { $_[0]->is_root ? 0 : (scalar @{$_[0]->lineage || []} || -1) }

sub label { shift->name(@_) }

sub _signal {
    my $self = shift;
    my $type = shift;
    return $self->SUPER::_signal("group.$type", @_);
}

sub _commit {
    my $self = shift;
    my $time = gmtime;
    $self->last_modification_time($time);
    $self->last_access_time($time);
}

1;
__END__

=head1 DESCRIPTION

=attr uuid

=attr name

=attr notes

=attr tags

=attr icon_id

=attr custom_icon_uuid

=attr is_expanded

=attr default_auto_type_sequence

=attr enable_auto_type

=attr enable_searching

=attr last_top_visible_entry

=attr custom_data

=attr previous_parent_group

=attr entries

=attr groups

=attr last_modification_time

=attr creation_time

=attr last_access_time

=attr expiry_time

=attr expires

=attr usage_count

=attr location_changed

Get or set various group fields.

=cut
