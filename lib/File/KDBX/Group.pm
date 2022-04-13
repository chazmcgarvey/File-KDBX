package File::KDBX::Group;
# ABSTRACT: A KDBX database group

use warnings;
use strict;

use Devel::GlobalDestruction;
use File::KDBX::Constants qw(:icon);
use File::KDBX::Error;
use File::KDBX::Util qw(generate_uuid);
use List::Util qw(sum0);
use Ref::Util qw(is_ref);
use Scalar::Util qw(blessed);
use Time::Piece;
use boolean;
use namespace::clean;

use parent 'File::KDBX::Object';

our $VERSION = '999.999'; # VERSION

my @ATTRS = qw(uuid custom_data entries groups);
my %ATTRS = (
    # uuid                        => sub { generate_uuid(printable => 1) },
    name                        => '',
    notes                       => '',
    tags                        => '',
    icon_id                     => ICON_FOLDER,
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
    last_modification_time  => sub { gmtime },
    creation_time           => sub { gmtime },
    last_access_time        => sub { gmtime },
    expiry_time             => sub { gmtime },
    expires                 => false,
    usage_count             => 0,
    location_changed        => sub { gmtime },
);

while (my ($attr, $default) = each %ATTRS) {
    no strict 'refs'; ## no critic (ProhibitNoStrict)
    *{$attr} = sub {
        my $self = shift;
        $self->{$attr} = shift if @_;
        $self->{$attr} //= (ref $default eq 'CODE') ? $default->($self) : $default;
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
        # if (defined $old_uuid and my $kdbx = $KDBX{refaddr($self)}) {
        #     $kdbx->_update_group_uuid($old_uuid, $uuid, $self);
        # }
    }
    $self->{uuid};
}

sub label { shift->name(@_) }

sub entries {
    my $self = shift;
    my $entries = $self->{entries} //= [];
    require File::KDBX::Entry;
    @$entries = map { File::KDBX::Entry->wrap($_, $self->kdbx) } @$entries;
    return $entries;
}

sub groups {
    my $self = shift;
    my $groups = $self->{groups} //= [];
    @$groups = map { File::KDBX::Group->wrap($_, $self->kdbx) } @$groups;
    return $groups;
}

sub _kpx_groups { shift->groups(@_) }

sub all_groups {
    my $self = shift;
    return $self->kdbx->all_groups(base => $self, include_base => false);
}

sub all_entries {
    my $self = shift;
    return $self->kdbx->all_entries(base => $self);
}

sub _group {
    my $self  = shift;
    my $group = shift;
    return File::KDBX::Group->wrap($group, $self);
}

sub _entry {
    my $self  = shift;
    my $entry = shift;
    require File::KDBX::Entry;
    return File::KDBX::Entry->wrap($entry, $self);
}

sub add_entry {
    my $self = shift;
    my $entry = shift;
    push @{$self->{entries} ||= []}, $entry;
    return $entry;
}

sub add_group {
    my $self = shift;
    my $group = shift;
    push @{$self->{groups} ||= []}, $group;
    return $group;
}

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

sub remove_object {
    my $self = shift;
    my $object = shift;
    my $blessed = blessed($object);
    return $self->remove_group($object, @_) if $blessed && $object->isa('File::KDBX::Group');
    return $self->remove_entry($object, @_) if $blessed && $object->isa('File::KDBX::Entry');
    return $self->remove_group($object, @_) || $self->remove_entry($object, @_);
}

sub remove_group {
    my $self = shift;
    my $uuid = is_ref($_[0]) ? $self->_group(shift)->uuid : shift;
    my $objects = $self->{groups};
    for (my $i = 0; $i < @$objects; ++$i) {
        my $o = $objects->[$i];
        next if $uuid ne $o->uuid;
        return splice @$objects, $i, 1;
    }
}

sub remove_entry {
    my $self = shift;
    my $uuid = is_ref($_[0]) ? $self->_entry(shift)->uuid : shift;
    my $objects = $self->{entries};
    for (my $i = 0; $i < @$objects; ++$i) {
        my $o = $objects->[$i];
        next if $uuid ne $o->uuid;
        return splice @$objects, $i, 1;
    }
}

sub path {
    my $self = shift;
    my $lineage = $self->kdbx->trace_lineage($self) or return;
    return join('.', map { $_->name } @$lineage);
}

sub size {
    my $self = shift;
    return sum0 map { $_->size } @{$self->groups}, @{$self->entries};
}

sub level { $_[0]->kdbx->group_level($_[0]) }

sub TO_JSON { +{%{$_[0]}} }

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
