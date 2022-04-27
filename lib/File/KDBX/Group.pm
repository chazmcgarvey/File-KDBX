package File::KDBX::Group;
# ABSTRACT: A KDBX database group

use warnings;
use strict;

use Devel::GlobalDestruction;
use File::KDBX::Constants qw(:bool :icon);
use File::KDBX::Error;
use File::KDBX::Iterator;
use File::KDBX::Util qw(:assert :class :coercion generate_uuid);
use Hash::Util::FieldHash;
use List::Util qw(any sum0);
use Ref::Util qw(is_coderef is_ref);
use Scalar::Util qw(blessed);
use Time::Piece;
use boolean;
use namespace::clean;

extends 'File::KDBX::Object';

our $VERSION = '999.999'; # VERSION

sub _parent_container { 'groups' }

# has uuid                        => sub { generate_uuid(printable => 1) };
has name                        => '',          coerce => \&to_string;
has notes                       => '',          coerce => \&to_string;
has tags                        => '',          coerce => \&to_string;
has icon_id                     => ICON_FOLDER, coerce => \&to_icon_constant;
has custom_icon_uuid            => undef,       coerce => \&to_uuid;
has is_expanded                 => false,       coerce => \&to_bool;
has default_auto_type_sequence  => '',          coerce => \&to_string;
has enable_auto_type            => undef,       coerce => \&to_tristate;
has enable_searching            => undef,       coerce => \&to_tristate;
has last_top_visible_entry      => undef,       coerce => \&to_uuid;
# has custom_data                 => {};
has previous_parent_group       => undef,       coerce => \&to_uuid;
# has entries                     => [];
# has groups                      => [];
has times                       => {};

has last_modification_time  => sub { gmtime }, store => 'times', coerce => \&to_time;
has creation_time           => sub { gmtime }, store => 'times', coerce => \&to_time;
has last_access_time        => sub { gmtime }, store => 'times', coerce => \&to_time;
has expiry_time             => sub { gmtime }, store => 'times', coerce => \&to_time;
has expires                 => false,          store => 'times', coerce => \&to_bool;
has usage_count             => 0,              store => 'times', coerce => \&to_number;
has location_changed        => sub { gmtime }, store => 'times', coerce => \&to_time;

my @ATTRS = qw(uuid custom_data entries groups);
sub _set_nonlazy_attributes {
    my $self = shift;
    $self->$_ for @ATTRS, list_attributes(ref $self);
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
    if (@$entries && !blessed($entries->[0])) {
        @$entries = map { $self->_wrap_entry($_, $self->kdbx) } @$entries;
    }
    assert { !any { !blessed $_ } @$entries };
    return $entries;
}

sub entries_deeply {
    my $self = shift;
    my %args = @_;

    my $searching   = delete $args{searching};
    my $auto_type   = delete $args{auto_type};
    my $history     = delete $args{history};

    my $groups = $self->groups_deeply(%args);
    my @entries;

    return File::KDBX::Iterator->new(sub {
        if (!@entries) {
            while (my $group = $groups->next) {
                next if $searching && !$group->effective_enable_searching;
                next if $auto_type && !$group->effective_enable_auto_type;
                @entries = @{$group->entries};
                @entries = grep { $_->auto_type->{enabled} } @entries if $auto_type;
                @entries = map { ($_, @{$_->history}) } @entries if $history;
                last if @entries;
            }
        }
        shift @entries;
    });
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
    return $entry->_set_group($self)->_signal('added', $self);
}

sub remove_entry {
    my $self = shift;
    my $uuid = is_ref($_[0]) ? $self->_wrap_entry(shift)->uuid : shift;
    my %args = @_;
    my $objects = $self->{entries};
    for (my $i = 0; $i < @$objects; ++$i) {
        my $object = $objects->[$i];
        next if $uuid ne $object->uuid;
        $object->_set_group(undef);
        $object->_signal('removed') if $args{signal} // 1;
        return splice @$objects, $i, 1;
    }
}

##############################################################################

sub groups {
    my $self = shift;
    my $groups = $self->{groups} //= [];
    if (@$groups && !blessed($groups->[0])) {
        @$groups = map { $self->_wrap_group($_, $self->kdbx) } @$groups;
    }
    assert { !any { !blessed $_ } @$groups };
    return $groups;
}

sub groups_deeply {
    my $self = shift;
    my %args = @_;

    my @groups = ($args{inclusive} // 1) ? $self : @{$self->groups};
    my $algo = lc($args{algorithm} || 'ids');

    if ($algo eq 'dfs') {
        my %visited;
        return File::KDBX::Iterator->new(sub {
            my $next = shift @groups or return;
            if (!$visited{Hash::Util::FieldHash::id($next)}++) {
                while (my @children = @{$next->groups}) {
                    unshift @groups, @children, $next;
                    $next = shift @groups;
                    $visited{Hash::Util::FieldHash::id($next)}++;
                }
            }
            $next;
        });
    }
    elsif ($algo eq 'bfs') {
        return File::KDBX::Iterator->new(sub {
            my $next = shift @groups or return;
            push @groups, @{$next->groups};
            $next;
        });
    }
    return File::KDBX::Iterator->new(sub {
        my $next = shift @groups or return;
        unshift @groups, @{$next->groups};
        $next;
    });
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
    return $group->_set_group($self)->_signal('added', $self);
}

sub remove_group {
    my $self = shift;
    my $uuid = is_ref($_[0]) ? $self->_wrap_group(shift)->uuid : shift;
    my %args = @_;
    my $objects = $self->{groups};
    for (my $i = 0; $i < @$objects; ++$i) {
        my $object = $objects->[$i];
        next if $uuid ne $object->uuid;
        $object->_set_group(undef);
        $object->_signal('removed') if $args{signal} // 1;
        return splice @$objects, $i, 1;
    }
}

##############################################################################

sub objects_deeply {
    my $self = shift;
    my %args = @_;

    my $searching   = delete $args{searching};
    my $auto_type   = delete $args{auto_type};
    my $history     = delete $args{history};

    my $groups = $self->groups_deeply(%args);
    my @entries;

    return File::KDBX::Iterator->new(sub {
        if (!@entries) {
            while (my $group = $groups->next) {
                next if $searching && !$group->effective_enable_searching;
                next if $auto_type && !$group->effective_enable_auto_type;
                @entries = @{$group->entries};
                @entries = grep { $_->auto_type->{enabled} } @entries if $auto_type;
                @entries = map { ($_, @{$_->history}) } @entries if $history;
                return $group;
            }
        }
        shift @entries;
    });
}

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

Determine if a group is the root group of its connected database.

=cut

sub is_root {
    my $self = shift;
    my $kdbx = eval { $self->kdbx } or return FALSE;
    return Hash::Util::FieldHash::id($kdbx->root) == Hash::Util::FieldHash::id($self);
}

=method is_recycle_bin

    $bool = $group->is_recycle_bin;

Get whether or not a group is the recycle bin of its connected database.

=cut

sub is_recycle_bin {
    my $self    = shift;
    my $kdbx    = eval { $self->kdbx } or return FALSE;
    my $group   = $kdbx->recycle_bin;
    return $group && Hash::Util::FieldHash::id($group) == Hash::Util::FieldHash::id($self);
}

=method is_entry_templates

    $bool = $group->is_entry_templates;

Get whether or not a group is the group containing entry template of its connected database.

=cut

sub entry_templates {
    my $self    = shift;
    my $kdbx    = eval { $self->kdbx } or return FALSE;
    my $group   = $kdbx->entry_templates;
    return $group && Hash::Util::FieldHash::id($group) == Hash::Util::FieldHash::id($self);
}

=method is_last_selected

    $bool = $group->is_last_selected;

Get whether or not a group is the prior selected group of its connected database.

=cut

sub last_selected {
    my $self    = shift;
    my $kdbx    = eval { $self->kdbx } or return FALSE;
    my $group   = $kdbx->last_selected;
    return $group && Hash::Util::FieldHash::id($group) == Hash::Util::FieldHash::id($self);
}

=method is_last_top_visible

    $bool = $group->is_last_top_visible;

Get whether or not a group is the latest top visible group of its connected database.

=cut

sub last_top_visible {
    my $self    = shift;
    my $kdbx    = eval { $self->kdbx } or return FALSE;
    my $group   = $kdbx->last_top_visible;
    return $group && Hash::Util::FieldHash::id($group) == Hash::Util::FieldHash::id($self);
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

sub effective_default_auto_type_sequence {
    my $self = shift;
    my $sequence = $self->default_auto_type_sequence;
    return $sequence if defined $sequence;

    my $parent = $self->parent or return '{USERNAME}{TAB}{PASSWORD}{ENTER}';
    return $parent->effective_default_auto_type_sequence;
}

sub effective_enable_auto_type {
    my $self = shift;
    my $enabled = $self->enable_auto_type;
    return $enabled if defined $enabled;

    my $parent = $self->parent or return true;
    return $parent->effective_enable_auto_type;
}

sub effective_enable_searching {
    my $self = shift;
    my $enabled = $self->enable_searching;
    return $enabled if defined $enabled;

    my $parent = $self->parent or return true;
    return $parent->effective_enable_searching;
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
