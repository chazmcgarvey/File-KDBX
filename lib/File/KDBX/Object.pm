package File::KDBX::Object;
# ABSTRACT: A KDBX database object

use warnings;
use strict;

use Devel::GlobalDestruction;
use File::KDBX::Error;
use File::KDBX::Util qw(:uuid);
use Hash::Util::FieldHash qw(fieldhashes);
use Ref::Util qw(is_arrayref is_plain_hashref is_ref);
use Scalar::Util qw(blessed weaken);
use namespace::clean;

our $VERSION = '999.999'; # VERSION

fieldhashes \my (%KDBX, %PARENT);

=method new

    $object = File::KDBX::Object->new;
    $object = File::KDBX::Object->new(%attributes);
    $object = File::KDBX::Object->new(\%data);
    $object = File::KDBX::Object->new(\%data, $kdbx);

Construct a new KDBX object.

There is a subtlety to take note of. There is a significant difference between:

    File::KDBX::Entry->new(username => 'iambatman');

and:

    File::KDBX::Entry->new({username => 'iambatman'}); # WRONG

In the first, an empty object is first created and then initialized with whatever I<attributes> are given. In
the second, a hashref is blessed and essentially becomes the object. The significance is that the hashref
key-value pairs will remain as-is so the structure is expected to adhere to the shape of a raw B<Object>
(which varies based on the type of object), whereas with the first the attributes will set the structure in
the correct way (just like using the object accessors / getters / setters).

The second example isn't I<generally> wrong -- this type of construction is supported for a reason, to allow
for working with KDBX objects at a low level -- but it is wrong in this specific case only because
C<< {username => $str} >> isn't a valid raw KDBX entry object. The L</username> attribute is really a proxy
for the C<UserName> string, so the equivalent raw entry object should be
C<< {strings => {UserName => {value => $str}}} >>. These are roughly equivalent:

    File::KDBX::Entry->new(username => 'iambatman');
    File::KDBX::Entry->new({strings => {UserName => {value => 'iambatman'}}});

If this explanation went over your head, that's fine. Just stick with the attributes since they are typically
easier to use correctly and provide the most convenience. If in the future you think of some kind of KDBX
object manipulation you want to do that isn't supported by the accessors and methods, just know you I<can>
access an object's data directly.

=cut

sub new {
    my $class = shift;

    # copy constructor
    return $_[0]->clone if @_ == 1 && blessed $_[0] && $_[0]->isa($class);

    my $data;
    $data = shift if is_plain_hashref($_[0]);

    my $kdbx;
    $kdbx = shift if @_ % 2 == 1;

    my %args = @_;
    $args{kdbx} //= $kdbx if defined $kdbx;

    my $self = bless $data // {}, $class;
    $self->init(%args);
    $self->_set_default_attributes if !$data;
    return $self;
}

sub _set_default_attributes { die 'Not implemented' }

=method init

    $object = $object->init(%attributes);

Called by the constructor to set attributes. You normally should not call this.

=cut

sub init {
    my $self = shift;
    my %args = @_;

    while (my ($key, $val) = each %args) {
        if (my $method = $self->can($key)) {
            $self->$method($val);
        }
    }

    return $self;
}

=method wrap

    $object = File::KDBX::Object->wrap($object);

Ensure that a KDBX object is blessed.

=cut

sub wrap {
    my $class   = shift;
    my $object  = shift;
    return $object if blessed $object && $object->isa($class);
    return $class->new(@_, @$object) if is_arrayref($object);
    return $class->new($object, @_);
}

=method label

    $label = $object->label;
    $object->label($label);

Get or set the object's label, a text string that can act as a non-unique identifier. For an entry, the label
is its title string. For a group, the label is its name.

=cut

sub label { die 'Not implemented' }

=method clone

    $object_copy = $object->clone;
    $object_copy = File::KDBX::Object->new($object);

Make a clone of an object. By default the clone is indeed an exact copy that is associated with the same
database but not actually included in the object tree (i.e. it has no parent). Some options are allowed to
get different effects:

=for :list
* C<new_uuid> - If set, generate a new UUID for the copy (default: false)
* C<parent> - If set, add the copy to the same parent group, if any (default: false)
* C<relabel> - If set, append " - Copy" to the object's title or name (default: false)
* C<entries> - If set, copy child entries, if any (default: true)
* C<groups> - If set, copy child groups, if any (default: true)
* C<history> - If set, copy entry history, if any (default: true)
* C<reference_password> - Toggle whether or not cloned entry's Password string should be set as a field
    reference to the original entry's Password string (default: false)
* C<reference_username> - Toggle whether or not cloned entry's UserName string should be set as a field
    reference to the original entry's UserName string (default: false)

=cut

my %CLONE = (entries => 1, groups => 1, history => 1);
sub clone {
    my $self = shift;
    my %args = @_;

    local $CLONE{new_uuid}              = $args{new_uuid} // $args{parent} // 0;
    local $CLONE{entries}               = $args{entries}  // 1;
    local $CLONE{groups}                = $args{groups}   // 1;
    local $CLONE{history}               = $args{history}  // 1;
    local $CLONE{reference_password}    = $args{reference_password} // 0;
    local $CLONE{reference_username}    = $args{reference_username} // 0;

    require Storable;
    my $copy = Storable::dclone($self);

    if ($args{relabel} and my $label = $self->label) {
        $copy->label("$label - Copy");
    }
    if ($args{parent} and my $parent = $self->parent) {
        $parent->add_object($copy);
    }

    return $copy;
}

sub STORABLE_freeze {
    my $self    = shift;
    my $cloning = shift;

    my $copy = {%$self};
    delete $copy->{entries} if !$CLONE{entries};
    delete $copy->{groups}  if !$CLONE{groups};
    delete $copy->{history} if !$CLONE{history};

    return ($cloning ? Hash::Util::FieldHash::id($self) : ''), $copy;
}

sub STORABLE_thaw {
    my $self    = shift;
    my $cloning = shift;
    my $addr    = shift;
    my $copy    = shift;

    @$self{keys %$copy} = values %$copy;

    if ($cloning) {
        my $kdbx = $KDBX{$addr};
        $self->kdbx($kdbx) if $kdbx;
    }

    if (defined $self->{uuid}) {
        if (($CLONE{reference_password} || $CLONE{reference_username}) && $self->can('strings')) {
            my $uuid = format_uuid($self->{uuid});
            my $clone_obj = do {
                local $CLONE{new_uuid}              = 0;
                local $CLONE{entries}               = 1;
                local $CLONE{groups}                = 1;
                local $CLONE{history}               = 1;
                local $CLONE{reference_password}    = 0;
                local $CLONE{reference_username}    = 0;
                bless Storable::dclone({%$copy}), 'File::KDBX::Entry';
            };
            my $txn = $self->begin_work($clone_obj);
            if ($CLONE{reference_password}) {
                $self->password("{REF:P\@I:$uuid}");
            }
            if ($CLONE{reference_username}) {
                $self->username("{REF:U\@I:$uuid}");
            }
            $txn->commit;
        }
        $self->uuid(generate_uuid) if $CLONE{new_uuid};
    }
}

=attr kdbx

    $kdbx = $object->kdbx;
    $object->kdbx($kdbx);

Get or set the L<File::KDBX> instance associated with this object.

=cut

sub kdbx {
    my $self = shift;
    $self = $self->new if !ref $self;
    if (@_) {
        if (my $kdbx = shift) {
            $KDBX{$self} = $kdbx;
            weaken $KDBX{$self};
        }
        else {
            delete $KDBX{$self};
        }
    }
    $KDBX{$self} or throw 'Object is disassociated from a KDBX database', object => $self;
}

=method id

    $string_uuid = $object->id;
    $string_uuid = $object->id($delimiter);

Get the unique identifier for this object as a B<formatted> UUID string, typically for display purposes. You
could use this to compare with other identifiers formatted with the same delimiter, but it is more efficient
to use the raw UUID for that purpose (see L</uuid>).

A delimiter can optionally be provided to break up the UUID string visually. See
L<File::KDBX::Util/format_uuid>.

=cut

sub id { format_uuid(shift->uuid, @_) }

=method group

=method parent

    $group = $object->group;
    # OR equivalently
    $group = $object->parent;

Get the parent group to which an object belongs or C<undef> if it belongs to no group.

=cut

sub group {
    my $self = shift;
    my $addr = Hash::Util::FieldHash::id($self);
    if (my $group = $PARENT{$self}) {
        my $method = $self->_parent_container;
        for my $object (@{$group->$method}) {
            return $group if $addr == Hash::Util::FieldHash::id($object);
        }
        delete $PARENT{$self};
    }
    # always get lineage from root to leaf because the other way requires parent, so it would be recursive
    my $lineage = $self->kdbx->_trace_lineage($self) or return;
    my $group = pop @$lineage or return;
    $PARENT{$self} = $group; weaken $PARENT{$self};
    return $group;
}

sub parent { shift->group(@_) }

sub _set_group {
    my $self = shift;
    if (my $parent = shift) {
        $PARENT{$self} = $parent;
        weaken $PARENT{$self};
    }
    else {
        delete $PARENT{$self};
    }
    return $self;
}

### Name of the parent attribute expected to contain the object
sub _parent_container { die 'Not implemented' }

=method lineage

    \@lineage = $object->lineage;
    \@lineage = $object->lineage($base_group);

Get the direct line of ancestors from C<$base_group> (default: the root group) to an object. The lineage
includes the base group but I<not> the target object. Returns C<undef> if the target is not in the database
structure. Returns an empty arrayref is the object itself is a root group.

=cut

sub lineage {
    my $self = shift;
    my $base = shift;

    my $base_addr = $base ? Hash::Util::FieldHash::id($base) : 0;

    # try leaf to root
    my @path;
    my $o = $self;
    while ($o = $o->parent) {
        unshift @path, $o;
        last if $base_addr == Hash::Util::FieldHash::id($o);
    }
    return \@path if @path && ($base_addr == Hash::Util::FieldHash::id($path[0]) || $path[0]->is_root);

    # try root to leaf
    return $self->kdbx->_trace_lineage($self, $base);
}

=method remove

    $object = $object->remove;

Remove the object from the database. If the object is a group, all contained objects are removed as well.

=cut

sub remove {
    my $self = shift;
    my $parent = $self->parent;
    $parent->remove_object($self) if $parent;
    return $self;
}

=method tag_list

    @tags = $entry->tag_list;

Get a list of tags, split from L</tag> using delimiters C<,>, C<.>, C<:>, C<;> and whitespace.

=cut

sub tag_list {
    my $self = shift;
    return grep { $_ ne '' } split(/[,\.:;]|\s+/, trim($self->tags) // '');
}

=method custom_icon

    $image_data = $object->custom_icon;
    $image_data = $object->custom_icon($image_data, %attributes);

Get or set an icon image. Returns C<undef> if there is no custom icon set. Setting a custom icon will change
the L</custom_icon_uuid> attribute.

Custom icon attributes (supported in KDBX4.1 and greater):

=for :list
* C<name> - Name of the icon (text)
* C<last_modification_time> - Just what it says (datetime)

=cut

sub custom_icon {
    my $self = shift;
    my $kdbx = $self->kdbx;
    if (@_) {
        my $img = shift;
        my $uuid = defined $img ? $kdbx->add_custom_icon($img, @_) : undef;
        $self->icon_id(0) if $uuid;
        $self->custom_icon_uuid($uuid);
        return $img;
    }
    return $kdbx->custom_icon_data($self->custom_icon_uuid);
}

=method custom_data

    \%all_data = $object->custom_data;
    $object->custom_data(\%all_data);

    \%data = $object->custom_data($key);
    $object->custom_data($key => \%data);
    $object->custom_data(%data);
    $object->custom_data(key => $value, %data);

Get and set custom data. Custom data is metadata associated with an object.

Each data item can have a few attributes associated with it.

=for :list
* C<key> - A unique text string identifier used to look up the data item (required)
* C<value> - A text string value (required)
* C<last_modification_time> (optional, KDBX4.1+)

=cut

sub custom_data {
    my $self = shift;
    $self->{custom_data} = shift if @_ == 1 && is_plain_hashref($_[0]);
    return $self->{custom_data} //= {} if !@_;

    my %args = @_     == 2 ? (key => shift, value => shift)
             : @_ % 2 == 1 ? (key => shift, @_) : @_;

    if (!$args{key} && !$args{value}) {
        my %standard = (key => 1, value => 1, last_modification_time => 1);
        my @other_keys = grep { !$standard{$_} } keys %args;
        if (@other_keys == 1) {
            my $key = $args{key} = $other_keys[0];
            $args{value} = delete $args{$key};
        }
    }

    my $key = $args{key} or throw 'Must provide a custom_data key to access';

    return $self->{custom_data}{$key} = $args{value} if is_plain_hashref($args{value});

    while (my ($field, $value) = each %args) {
        $self->{custom_data}{$key}{$field} = $value;
    }
    return $self->{custom_data}{$key};
}

=method custom_data_value

    $value = $object->custom_data_value($key);

Exactly the same as L</custom_data> except returns just the custom data's value rather than a structure of
attributes. This is a shortcut for:

    my $data = $object->custom_data($key);
    my $value = defined $data ? $data->{value} : undef;

=cut

sub custom_data_value {
    my $self = shift;
    my $data = $self->custom_data(@_) // return undef;
    return $data->{value};
}

sub _wrap_group {
    my $self  = shift;
    my $group = shift;
    require File::KDBX::Group;
    return File::KDBX::Group->wrap($group, $KDBX{$self});
}

sub _wrap_entry {
    my $self  = shift;
    my $entry = shift;
    require File::KDBX::Entry;
    return File::KDBX::Entry->wrap($entry, $KDBX{$self});
}

sub TO_JSON { +{%{$_[0]}} }

1;
__END__

=for Pod::Coverage STORABLE_freeze STORABLE_thaw TO_JSON

=head1 DESCRIPTION

KDBX is an object database. This abstract class represents an object. You should not use this class directly
but instead use its subclasses:

=for :list
* L<File::KDBX::Entry>
* L<File::KDBX::Group>

There is some functionality shared by both types of objects, and that's what this class provides.

=cut
