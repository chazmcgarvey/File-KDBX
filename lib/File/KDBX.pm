package File::KDBX;
# ABSTRACT: Encrypted databases to store secret text and files

use warnings;
use strict;

use Crypt::PRNG qw(random_bytes);
use Devel::GlobalDestruction;
use File::KDBX::Constants qw(:all);
use File::KDBX::Error;
use File::KDBX::Safe;
use File::KDBX::Util qw(:class :coercion :empty :uuid :search erase simple_expression_query snakify);
use Hash::Util::FieldHash qw(fieldhashes);
use List::Util qw(any);
use Ref::Util qw(is_ref is_arrayref is_plain_hashref);
use Scalar::Util qw(blessed);
use Time::Piece;
use boolean;
use namespace::clean;

our $VERSION = '999.999'; # VERSION
our $WARNINGS = 1;

fieldhashes \my (%SAFE, %KEYS);

=method new

    $kdbx = File::KDBX->new(%attributes);
    $kdbx = File::KDBX->new($kdbx); # copy constructor

Construct a new L<File::KDBX>.

=cut

sub new {
    my $class = shift;

    # copy constructor
    return $_[0]->clone if @_ == 1 && blessed $_[0] && $_[0]->isa($class);

    my $self = bless {}, $class;
    $self->init(@_);
    $self->_set_nonlazy_attributes if empty $self;
    return $self;
}

sub DESTROY { local ($., $@, $!, $^E, $?); !in_global_destruction and $_[0]->reset }

=method init

    $kdbx = $kdbx->init(%attributes);

Initialize a L<File::KDBX> with a new set of attributes. Returns itself to allow method chaining.

This is called by L</new>.

=cut

sub init {
    my $self = shift;
    my %args = @_;

    @$self{keys %args} = values %args;

    return $self;
}

=method reset

    $kdbx = $kdbx->reset;

Set a L<File::KDBX> to an empty state, ready to load a KDBX file or build a new one. Returns itself to allow
method chaining.

=cut

sub reset {
    my $self = shift;
    erase $self->headers->{+HEADER_INNER_RANDOM_STREAM_KEY};
    erase $self->inner_headers->{+INNER_HEADER_INNER_RANDOM_STREAM_KEY};
    erase $self->{raw};
    %$self = ();
    $self->_remove_safe;
    return $self;
}

=method clone

    $kdbx_copy = $kdbx->clone;
    $kdbx_copy = File::KDBX->new($kdbx);

Clone a L<File::KDBX>. The clone will be an exact copy and completely independent of the original.

=cut

sub clone {
    my $self = shift;
    require Storable;
    return Storable::dclone($self);
}

sub STORABLE_freeze {
    my $self    = shift;
    my $cloning = shift;

    my $copy = {%$self};

    return '', $copy, $KEYS{$self} // (), $SAFE{$self} // ();
}

sub STORABLE_thaw {
    my $self    = shift;
    my $cloning = shift;
    shift;
    my $clone   = shift;
    my $key     = shift;
    my $safe    = shift;

    @$self{keys %$clone} = values %$clone;
    $KEYS{$self} = $key;
    $SAFE{$self} = $safe;

    # Dualvars aren't cloned as dualvars, so coerce the compression flags.
    $self->compression_flags($self->compression_flags);

    for my $object (@{$self->all_groups}, @{$self->all_entries(history => 1)}) {
        $object->kdbx($self);
    }
}

##############################################################################

=method load

=method load_string

=method load_file

=method load_handle

    $kdbx = KDBX::File->load(\$string, $key);
    $kdbx = KDBX::File->load(*IO, $key);
    $kdbx = KDBX::File->load($filepath, $key);
    $kdbx->load(...);           # also instance method

    $kdbx = File::KDBX->load_string($string, $key);
    $kdbx = File::KDBX->load_string(\$string, $key);
    $kdbx->load_string(...);    # also instance method

    $kdbx = File::KDBX->load_file($filepath, $key);
    $kdbx->load_file(...);      # also instance method

    $kdbx = File::KDBX->load_handle($fh, $key);
    $kdbx = File::KDBX->load_handle(*IO, $key);
    $kdbx->load_handle(...);    # also instance method

Load a KDBX file from a string buffer, IO handle or file from a filesystem.

L<File::KDBX::Loader> does the heavy lifting.

=cut

sub load        { shift->_loader->load(@_) }
sub load_string { shift->_loader->load_string(@_) }
sub load_file   { shift->_loader->load_file(@_) }
sub load_handle { shift->_loader->load_handle(@_) }

sub _loader {
    my $self = shift;
    $self = $self->new if !ref $self;
    require File::KDBX::Loader;
    File::KDBX::Loader->new(kdbx => $self);
}

=method dump

=method dump_string

=method dump_file

=method dump_handle

    $kdbx->dump(\$string, $key);
    $kdbx->dump(*IO, $key);
    $kdbx->dump($filepath, $key);

    $kdbx->dump_string(\$string, $key);
    \$string = $kdbx->dump_string($key);

    $kdbx->dump_file($filepath, $key);

    $kdbx->dump_handle($fh, $key);
    $kdbx->dump_handle(*IO, $key);

Dump a KDBX file to a string buffer, IO handle or file in a filesystem.

L<File::KDBX::Dumper> does the heavy lifting.

=cut

sub dump        { shift->_dumper->dump(@_) }
sub dump_string { shift->_dumper->dump_string(@_) }
sub dump_file   { shift->_dumper->dump_file(@_) }
sub dump_handle { shift->_dumper->dump_handle(@_) }

sub _dumper {
    my $self = shift;
    $self = $self->new if !ref $self;
    require File::KDBX::Dumper;
    File::KDBX::Dumper->new(kdbx => $self);
}

##############################################################################

=method user_agent_string

    $string = $kdbx->user_agent_string;

Get a text string identifying the database client software.

=cut

sub user_agent_string {
    require Config;
    sprintf('%s/%s (%s/%s; %s/%s; %s)',
        __PACKAGE__, $VERSION, @Config::Config{qw(package version osname osvers archname)});
}

has sig1            => KDBX_SIG1,        coerce => \&to_number;
has sig2            => KDBX_SIG2_2,      coerce => \&to_number;
has version         => KDBX_VERSION_3_1, coerce => \&to_number;
has headers         => {};
has inner_headers   => {};
has meta            => {};
has binaries        => {};
has deleted_objects => {};
has raw             => coerce => \&to_string;

# HEADERS
has 'headers.comment'               => '', coerce => \&to_string;
has 'headers.cipher_id'             => CIPHER_UUID_CHACHA20, coerce => \&to_uuid;
has 'headers.compression_flags'     => COMPRESSION_GZIP, coerce => \&to_compression_constant;
has 'headers.master_seed'           => sub { random_bytes(32) }, coerce => \&to_string;
has 'headers.encryption_iv'         => sub { random_bytes(16) }, coerce => \&to_string;
has 'headers.stream_start_bytes'    => sub { random_bytes(32) }, coerce => \&to_string;
has 'headers.kdf_parameters'        => sub {
    +{
        KDF_PARAM_UUID()        => KDF_UUID_AES,
        KDF_PARAM_AES_ROUNDS()  => $_[0]->headers->{+HEADER_TRANSFORM_ROUNDS} // KDF_DEFAULT_AES_ROUNDS,
        KDF_PARAM_AES_SEED()    => $_[0]->headers->{+HEADER_TRANSFORM_SEED} // random_bytes(32),
    };
};
# has 'headers.transform_seed'            => sub { random_bytes(32) };
# has 'headers.transform_rounds'          => 100_000;
# has 'headers.inner_random_stream_key'   => sub { random_bytes(32) }; # 64 ?
# has 'headers.inner_random_stream_id'    => STREAM_ID_CHACHA20;
# has 'headers.public_custom_data'        => {};

# META
has 'meta.generator'                        => '',                          coerce => \&to_string;
has 'meta.header_hash'                      => '',                          coerce => \&to_string;
has 'meta.database_name'                    => '',                          coerce => \&to_string;
has 'meta.database_name_changed'            => sub { gmtime },              coerce => \&to_time;
has 'meta.database_description'             => '',                          coerce => \&to_string;
has 'meta.database_description_changed'     => sub { gmtime },              coerce => \&to_time;
has 'meta.default_username'                 => '',                          coerce => \&to_string;
has 'meta.default_username_changed'         => sub { gmtime },              coerce => \&to_time;
has 'meta.maintenance_history_days'         => 0,                           coerce => \&to_number;
has 'meta.color'                            => '',                          coerce => \&to_string;
has 'meta.master_key_changed'               => sub { gmtime },              coerce => \&to_time;
has 'meta.master_key_change_rec'            => -1,                          coerce => \&to_number;
has 'meta.master_key_change_force'          => -1,                          coerce => \&to_number;
# has 'meta.memory_protection'                => {};
has 'meta.custom_icons'                     => {};
has 'meta.recycle_bin_enabled'              => true,                        coerce => \&to_bool;
has 'meta.recycle_bin_uuid'                 => "\0" x 16,                   coerce => \&to_uuid;
has 'meta.recycle_bin_changed'              => sub { gmtime },              coerce => \&to_time;
has 'meta.entry_templates_group'            => "\0" x 16,                   coerce => \&to_uuid;
has 'meta.entry_templates_group_changed'    => sub { gmtime },              coerce => \&to_time;
has 'meta.last_selected_group'              => "\0" x 16,                   coerce => \&to_uuid;
has 'meta.last_top_visible_group'           => "\0" x 16,                   coerce => \&to_uuid;
has 'meta.history_max_items'                => HISTORY_DEFAULT_MAX_ITEMS,   coerce => \&to_number;
has 'meta.history_max_size'                 => HISTORY_DEFAULT_MAX_SIZE,    coerce => \&to_number;
has 'meta.settings_changed'                 => sub { gmtime },              coerce => \&to_time;
# has 'meta.binaries'                         => {};
# has 'meta.custom_data'                      => {};

has 'memory_protection.protect_title'       => false,   coerce => \&to_bool;
has 'memory_protection.protect_username'    => false,   coerce => \&to_bool;
has 'memory_protection.protect_password'    => true,    coerce => \&to_bool;
has 'memory_protection.protect_url'         => false,   coerce => \&to_bool;
has 'memory_protection.protect_notes'       => false,   coerce => \&to_bool;
# has 'memory_protection.auto_enable_visual_hiding'   => false;

my @ATTRS = (
    HEADER_TRANSFORM_SEED,
    HEADER_TRANSFORM_ROUNDS,
    HEADER_INNER_RANDOM_STREAM_KEY,
    HEADER_INNER_RANDOM_STREAM_ID,
    HEADER_PUBLIC_CUSTOM_DATA,
);
sub _set_nonlazy_attributes {
    my $self = shift;
    $self->$_ for list_attributes(ref $self), @ATTRS;
}

=method memory_protection

    \%settings = $kdbx->memory_protection
    $kdbx->memory_protection(\%settings);

    $bool = $kdbx->memory_protection($string_key);
    $kdbx->memory_protection($string_key => $bool);

Get or set memory protection settings. This globally (for the whole database) configures whether and which of
the standard strings should be memory-protected. The default setting is to memory-protect only I<Password>
strings.

Memory protection can be toggled individually for each entry string, and individual settings take precedence
over these global settings.

=cut

sub memory_protection {
    my $self = shift;
    $self->{meta}{memory_protection} = shift if @_ == 1 && is_plain_hashref($_[0]);
    return $self->{meta}{memory_protection} //= {} if !@_;

    my $string_key = shift;
    my $key = 'protect_' . lc($string_key);

    $self->meta->{memory_protection}{$key} = shift if @_;
    $self->meta->{memory_protection}{$key};
}

=method minimum_version

    $version = $kdbx->minimum_version;

Determine the minimum file version required to save a database losslessly. Using certain databases features
might increase this value. For example, setting the KDF to Argon2 will increase the minimum version to at
least C<KDBX_VERSION_4_0> (i.e. C<0x00040000>) because Argon2 was introduced with KDBX4.

This method never returns less than C<KDBX_VERSION_3_1> (i.e. C<0x00030001>). That file version is so
ubiquitious and well-supported, there are seldom reasons to dump in a lesser format nowadays.

B<WARNING:> If you dump a database with a minimum version higher than the current L</version>, the dumper will
typically issue a warning and automatically upgrade the database. This seems like the safest behavior in order
to avoid data loss, but lower versions have the benefit of being compatible with more software. It is possible
to prevent auto-upgrades by explicitly telling the dumper which version to use, but you do run the risk of
data loss. A database will never be automatically downgraded.

=cut

sub minimum_version {
    my $self = shift;

    return KDBX_VERSION_4_1 if any {
        nonempty $_->{last_modification_time}
    } values %{$self->custom_data};

    return KDBX_VERSION_4_1 if any {
        nonempty $_->{name} || nonempty $_->{last_modification_time}
    } values %{$self->custom_icons};

    return KDBX_VERSION_4_1 if any {
        nonempty $_->previous_parent_group || nonempty $_->tags ||
        any { nonempty $_->{last_modification_time} } values %{$_->custom_data}
    } @{$self->all_groups};

    return KDBX_VERSION_4_1 if any {
        nonempty $_->previous_parent_group || (defined $_->quality_check && !$_->quality_check) ||
        any { nonempty $_->{last_modification_time} } values %{$_->custom_data}
    } @{$self->all_entries(history => 1)};

    return KDBX_VERSION_4_0 if $self->kdf->uuid ne KDF_UUID_AES;

    return KDBX_VERSION_4_0 if nonempty $self->public_custom_data;

    return KDBX_VERSION_4_0 if any {
        nonempty $_->custom_data
    } @{$self->all_groups}, @{$self->all_entries(history => 1)};

    return KDBX_VERSION_3_1;
}

##############################################################################

=method add_group

    $kdbx->add_group($group, %options);
    $kdbx->add_group(%group_attributes, %options);

Add a group to a database. This is equivalent to identifying a parent group and calling
L<File::KDBX::Group/add_group> on the parent group, forwarding the arguments. Available options:

=for :list
* C<group> (aka C<parent>) - Group (object or group UUID) to add the group to (default: root group)

=cut

sub add_group {
    my $self    = shift;
    my $group   = @_ % 2 == 1 ? shift : undef;
    my %args    = @_;

    # find the right group to add the group to
    my $parent = delete $args{group} // delete $args{parent} // $self->root;
    ($parent) = $self->find_groups({uuid => $parent}) if !ref $parent;
    $parent or throw 'Invalid group';

    return $parent->add_group(defined $group ? $group : (), %args, kdbx => $self);
}

sub _wrap_group {
    my $self  = shift;
    my $group = shift;
    require File::KDBX::Group;
    return File::KDBX::Group->wrap($group, $self);
}

=method root

    $group = $kdbx->root;
    $kdbx->root($group);

Get or set a database's root group. You don't necessarily need to explicitly create or set a root group
because it autovivifies when adding entries and groups to the database.

Every database has only a single root group at a time. Some old KDB files might have multiple root groups.
When reading such files, a single implicit root group is created to contain the other explicit groups. When
writing to such a format, if the root group looks like it was implicitly created then it won't be written and
the resulting file might have multiple root groups. This allows working with older files without changing
their written internal structure while still adhering to modern semantics while the database is opened.

B<WARNING:> The root group of a KDBX database contains all of the database's entries and other groups. If you
replace the root group, you are essentially replacing the entire database contents with something else.

=cut

sub root {
    my $self = shift;
    if (@_) {
        $self->{root} = $self->_wrap_group(@_);
        $self->{root}->kdbx($self);
    }
    $self->{root} //= $self->_implicit_root;
    return $self->_wrap_group($self->{root});
}

sub _kpx_groups {
    my $self = shift;
    return [] if !$self->{root};
    return $self->_has_implicit_root ? $self->root->groups : [$self->root];
}

sub _has_implicit_root {
    my $self = shift;
    my $root = $self->root;
    my $temp = __PACKAGE__->_implicit_root;
    # If an implicit root group has been changed in any significant way, it is no longer implicit.
    return $root->name eq $temp->name &&
        $root->is_expanded ^ $temp->is_expanded &&
        $root->notes eq $temp->notes &&
        !@{$root->entries} &&
        !defined $root->custom_icon_uuid &&
        !keys %{$root->custom_data} &&
        $root->icon_id == $temp->icon_id &&
        $root->expires ^ $temp->expires &&
        $root->default_auto_type_sequence eq $temp->default_auto_type_sequence &&
        !defined $root->enable_auto_type &&
        !defined $root->enable_searching;
}

sub _implicit_root {
    my $self = shift;
    require File::KDBX::Group;
    return File::KDBX::Group->new(
        name        => 'Root',
        is_expanded => true,
        notes       => 'Added as an implicit root group by '.__PACKAGE__.'.',
        ref $self ? (kdbx => $self) : (),
    );
}

=method all_groups

    \@groups = $kdbx->all_groups(%options);
    \@groups = $kdbx->all_groups($base_group, %options);

Get all groups deeply in a database, or all groups within a specified base group, in a flat array. Supported
options:

=for :list
* C<base> - Only include groups within a base group (same as C<$base_group>) (default: root)
* C<include_base> - Include the base group in the results (default: true)

=cut

sub all_groups {
    my $self = shift;
    my %args = @_ % 2 == 0 ? @_ : (base => shift, @_);
    my $base = $args{base} // $self->root;

    my @groups = $args{include_base} // 1 ? $self->_wrap_group($base) : ();

    for my $subgroup (@{$base->{groups} || []}) {
        my $more = $self->all_groups($subgroup);
        push @groups, @$more;
    }

    return \@groups;
}

=method trace_lineage

    \@lineage = $kdbx->trace_lineage($group);
    \@lineage = $kdbx->trace_lineage($group, $base_group);
    \@lineage = $kdbx->trace_lineage($entry);
    \@lineage = $kdbx->trace_lineage($entry, $base_group);

Get the direct line of ancestors from C<$base_group> (default: the root group) to a group or entry. The
lineage includes the base group but I<not> the target group or entry. Returns C<undef> if the target is not in
the database structure.

=cut

sub trace_lineage {
    my $self    = shift;
    my $object  = shift;
    return $object->lineage(@_);
}

sub _trace_lineage {
    my $self    = shift;
    my $object  = shift;
    my @lineage = @_;

    push @lineage, $self->root if !@lineage;
    my $base = $lineage[-1] or return [];

    my $uuid = $object->uuid;
    return \@lineage if any { $_->uuid eq $uuid } @{$base->groups || []}, @{$base->entries || []};

    for my $subgroup (@{$base->groups || []}) {
        my $result = $self->_trace_lineage($object, @lineage, $subgroup);
        return $result if $result;
    }
}

=method find_groups

    @groups = $kdbx->find_groups($query, %options);

Find all groups deeply that match to a query. Options are the same as for L</all_groups>.

See L</QUERY> for a description of what C<$query> can be.

=cut

sub find_groups {
    my $self = shift;
    my $query = shift or throw 'Must provide a query';
    my %args = @_;
    my %all_groups = (
        base            => $args{base},
        include_base    => $args{include_base},
    );
    return @{search($self->all_groups(%all_groups), is_arrayref($query) ? @$query : $query)};
}

sub remove {
    my $self = shift;
    my $object = shift;
}

##############################################################################

=method add_entry

    $kdbx->add_entry($entry, %options);
    $kdbx->add_entry(%entry_attributes, %options);

Add a entry to a database. This is equivalent to identifying a parent group and calling
L<File::KDBX::Group/add_entry> on the parent group, forwarding the arguments. Available options:

=for :list
* C<group> (aka C<parent>) - Group (object or group UUID) to add the entry to (default: root group)

=cut

sub add_entry {
    my $self    = shift;
    my $entry   = @_ % 2 == 1 ? shift : undef;
    my %args    = @_;

    # find the right group to add the entry to
    my $parent = delete $args{group} // delete $args{parent} // $self->root;
    ($parent) = $self->find_groups({uuid => $parent}) if !ref $parent;
    $parent or throw 'Invalid group';

    return $parent->add_entry(defined $entry ? $entry : (), %args, kdbx => $self);
}

sub _wrap_entry {
    my $self  = shift;
    my $entry = shift;
    require File::KDBX::Entry;
    return File::KDBX::Entry->wrap($entry, $self);
}

=method all_entries

    \@entries = $kdbx->all_entries(%options);
    \@entries = $kdbx->all_entries($base_group, %options);

Get entries deeply in a database, in a flat array. Supported options:

=for :list
* C<base> - Only include entries within a base group (same as C<$base_group>) (default: root)
* C<auto_type> - Only include entries with auto-type enabled (default: false, include all)
* C<search> - Only include entries within groups with search enabled (default: false, include all)
* C<history> - Also include historical entries (default: false, include only active entries)

=cut

sub all_entries {
    my $self = shift;
    my %args = @_ % 2 == 0 ? @_ : (base => shift, @_);

    my $base        = $args{base} // $self->root;
    my $history     = $args{history};
    my $search      = $args{search};
    my $auto_type   = $args{auto_type};

    my $enable_auto_type = $base->{enable_auto_type} // true;
    my $enable_searching = $base->{enable_searching} // true;

    my @entries;
    if ((!$search || $enable_searching) && (!$auto_type || $enable_auto_type)) {
        push @entries,
            map { $self->_wrap_entry($_) }
            grep { !$auto_type || $_->{auto_type}{enabled} }
            map { $_, $history ? @{$_->{history} || []} : () }
            @{$base->{entries} || []};
    }

    for my $subgroup (@{$base->{groups} || []}) {
        my $more = $self->all_entries($subgroup,
            auto_type   => $auto_type,
            search      => $search,
            history     => $history,
        );
        push @entries, @$more;
    }

    return \@entries;
}

=method find_entries

=method find_entries_simple

    @entries = $kdbx->find_entries($query, %options);

    @entries = $kdbx->find_entries_simple($expression, \@fields, %options);
    @entries = $kdbx->find_entries_simple($expression, $operator, \@fields, %options);

Find all entries deeply that match a query. Options are the same as for L</all_entries>.

See L</QUERY> for a description of what C<$query> can be.

=cut

sub find_entries {
    my $self = shift;
    my $query = shift or throw 'Must provide a query';
    my %args = @_;
    my %all_entries = (
        base        => $args{base},
        auto_type   => $args{auto_type},
        search      => $args{search},
        history     => $args{history},
    );
    my $limit = delete $args{limit};
    if (defined $limit) {
        return @{search_limited($self->all_entries(%all_entries), is_arrayref($query) ? @$query : $query, $limit)};
    }
    else {
        return @{search($self->all_entries(%all_entries), is_arrayref($query) ? @$query : $query)};
    }
}

sub find_entries_simple {
    my $self = shift;
    my $text = shift;
    my $op   = @_ && !is_ref($_[0]) ? shift : undef;
    my $fields = shift;
    is_arrayref($fields) or throw q{Usage: find_entries_simple($expression, [$op,] \@fields)};
    return $self->find_entries([\$text, $op, $fields], @_);
}

##############################################################################

=method custom_icon

    \%icon = $kdbx->custom_icon($uuid);
    $kdbx->custom_icon($uuid => \%icon);
    $kdbx->custom_icon(%icon);
    $kdbx->custom_icon(uuid => $value, %icon);


=cut

sub custom_icon {
    my $self = shift;
    my %args = @_     == 2 ? (uuid => shift, value => shift)
             : @_ % 2 == 1 ? (uuid => shift, @_) : @_;

    if (!$args{key} && !$args{value}) {
        my %standard = (key => 1, value => 1, last_modification_time => 1);
        my @other_keys = grep { !$standard{$_} } keys %args;
        if (@other_keys == 1) {
            my $key = $args{key} = $other_keys[0];
            $args{value} = delete $args{$key};
        }
    }

    my $key = $args{key} or throw 'Must provide a custom_icons key to access';

    return $self->{meta}{custom_icons}{$key} = $args{value} if is_plain_hashref($args{value});

    while (my ($field, $value) = each %args) {
        $self->{meta}{custom_icons}{$key}{$field} = $value;
    }
    return $self->{meta}{custom_icons}{$key};
}

=method custom_icon_data

    $image_data = $kdbx->custom_icon_data($uuid);

Get a custom icon.

=cut

sub custom_icon_data {
    my $self = shift;
    my $uuid = shift // return;
    return if !exists $self->custom_icons->{$uuid};
    return $self->custom_icons->{$uuid}{data};
}

=method add_custom_icon

    $uuid = $kdbx->add_custom_icon($image_data, %attributes);

Add a custom icon and get its UUID. If not provided, a random UUID will be generated. Possible attributes:

=for :list
* C<uuid> - Icon UUID
* C<name> - Name of the icon (text, KDBX4.1+)
* C<last_modification_time> - Just what it says (datetime, KDBX4.1+)

=cut

sub add_custom_icon {
    my $self = shift;
    my $img  = shift or throw 'Must provide image data';
    my %args = @_;

    my $uuid = $args{uuid} // generate_uuid(sub { !$self->custom_icons->{$_} });
    $self->custom_icons->{$uuid} = {
        @_,
        uuid    => $uuid,
        data    => $img,
    };
    return $uuid;
}

=method remove_custom_icon

    $kdbx->remove_custom_icon($uuid);

Remove a custom icon.

=cut

sub remove_custom_icon {
    my $self = shift;
    my $uuid = shift;
    delete $self->custom_icons->{$uuid};
}

##############################################################################

=method custom_data

    \%all_data = $kdbx->custom_data;
    $kdbx->custom_data(\%all_data);

    \%data = $kdbx->custom_data($key);
    $kdbx->custom_data($key => \%data);
    $kdbx->custom_data(%data);
    $kdbx->custom_data(key => $value, %data);

Get and set custom data. Custom data is metadata associated with a database.

Each data item can have a few attributes associated with it.

=for :list
* C<key> - A unique text string identifier used to look up the data item (required)
* C<value> - A text string value (required)
* C<last_modification_time> (optional, KDBX4.1+)

=cut

sub custom_data {
    my $self = shift;
    $self->{meta}{custom_data} = shift if @_ == 1 && is_plain_hashref($_[0]);
    return $self->{meta}{custom_data} //= {} if !@_;

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

    return $self->{meta}{custom_data}{$key} = $args{value} if is_plain_hashref($args{value});

    while (my ($field, $value) = each %args) {
        $self->{meta}{custom_data}{$key}{$field} = $value;
    }
    return $self->{meta}{custom_data}{$key};
}

=method custom_data_value

    $value = $kdbx->custom_data_value($key);

Exactly the same as L</custom_data> except returns just the custom data's value rather than a structure of
attributes. This is a shortcut for:

    my $data = $kdbx->custom_data($key);
    my $value = defined $data ? $data->{value} : undef;

=cut

sub custom_data_value {
    my $self = shift;
    my $data = $self->custom_data(@_) // return;
    return $data->{value};
}

=method public_custom_data

    \%all_data = $kdbx->public_custom_data;
    $kdbx->public_custom_data(\%all_data);

    $value = $kdbx->public_custom_data($key);
    $kdbx->public_custom_data($key => $value);

Get and set public custom data. Public custom data is similar to custom data but different in some important
ways. Public custom data:

=for :list
* can store strings, booleans and up to 64-bit integer values (custom data can only store text values)
* is NOT encrypted within a KDBX file (hence the "public" part of the name)
* is a plain hash/dict of key-value pairs with no other associated fields (like modification times)

=cut

sub public_custom_data {
    my $self = shift;
    $self->{headers}{+HEADER_PUBLIC_CUSTOM_DATA} = shift if @_ == 1 && is_plain_hashref($_[0]);
    return $self->{headers}{+HEADER_PUBLIC_CUSTOM_DATA} //= {} if !@_;

    my $key = shift or throw 'Must provide a public_custom_data key to access';
    $self->{headers}{+HEADER_PUBLIC_CUSTOM_DATA}{$key} = shift if @_;
    return $self->{headers}{+HEADER_PUBLIC_CUSTOM_DATA}{$key};
}

##############################################################################

# TODO

# sub merge_to {
#     my $self = shift;
#     my $other = shift;
#     my %options = @_;   # prefer_old / prefer_new
#     $other->merge_from($self);
# }

# sub merge_from {
#     my $self = shift;
#     my $other = shift;

#     die 'Not implemented';
# }

##############################################################################

=method resolve_reference

    $string = $kdbx->resolve_reference($reference);
    $string = $kdbx->resolve_reference($wanted, $search_in, $expression);

Resolve a L<field reference|https://keepass.info/help/base/fieldrefs.html>. A field reference is a kind of
string placeholder. You can use a field reference to refer directly to a standard field within an entry. Field
references are resolved automatically while expanding entry strings (i.e. replacing placeholders), but you can
use this method to resolve on-the-fly references that aren't part of any actual string in the database.

If the reference does not resolve to any field, C<undef> is returned. If the reference resolves to multiple
fields, only the first one is returned (in the same order as L</all_entries>). To avoid ambiguity, you can
refer to a specific entry by its UUID.

The syntax of a reference is: C<< {REF:<WantedField>@<SearchIn>:<Text>} >>. C<Text> is a
L</"Simple Expression">. C<WantedField> and C<SearchIn> are both single character codes representing a field:

=for :list
* C<T> - Title
* C<U> - UserName
* C<P> - Password
* C<A> - URL
* C<N> - Notes
* C<I> - UUID
* C<O> - Other custom strings

Since C<O> does not represent any specific field, it cannot be used as the C<WantedField>.

Examples:

To get the value of the I<UserName> string of the first entry with "My Bank" in the title:

    my $username = $kdbx->resolve_reference('{REF:U@T:"My Bank"}');
    # OR the {REF:...} wrapper is optional
    my $username = $kdbx->resolve_reference('U@T:"My Bank"');
    # OR separate the arguments
    my $username = $kdbx->resolve_reference(U => T => '"My Bank"');

Note how the text is a L</"Simple Expression">, so search terms with spaces must be surrounded in double
quotes.

To get the I<Password> string of a specific entry (identified by its UUID):

    my $password = $kdbx->resolve_reference('{REF:P@I:46C9B1FFBD4ABC4BBB260C6190BAD20C}');

=cut

sub resolve_reference {
    my $self        = shift;
    my $wanted      = shift // return;
    my $search_in   = shift;
    my $text        = shift;

    if (!defined $text) {
        $wanted =~ s/^\{REF:([^\}]+)\}$/$1/i;
        ($wanted, $search_in, $text) = $wanted =~ /^([TUPANI])\@([TUPANIO]):(.*)$/i;
    }
    $wanted && $search_in && nonempty($text) or return;

    my %fields = (
        T   => 'expanded_title',
        U   => 'expanded_username',
        P   => 'expanded_password',
        A   => 'expanded_url',
        N   => 'expanded_notes',
        I   => 'uuid',
        O   => 'other_strings',
    );
    $wanted     = $fields{$wanted} or return;
    $search_in  = $fields{$search_in} or return;

    my $query = $search_in eq 'uuid' ? query($search_in => uuid($text))
                                     : simple_expression_query($text, '=~', $search_in);

    my ($entry) = $self->find_entries($query, limit => 1);
    $entry or return;

    return $entry->$wanted;
}

our %PLACEHOLDERS = (
    # placeholder         => sub { my ($entry, $arg) = @_; ... };
    'TITLE'             => sub { $_[0]->expanded_title },
    'USERNAME'          => sub { $_[0]->expanded_username },
    'PASSWORD'          => sub { $_[0]->expanded_password },
    'NOTES'             => sub { $_[0]->expanded_notes },
    'S:'                => sub { $_[0]->string_value($_[1]) },
    'URL'               => sub { $_[0]->expanded_url },
    'URL:RMVSCM'        => sub { local $_ = $_[0]->url; s!^[^:/\?\#]+://!!; $_ },
    'URL:WITHOUTSCHEME' => sub { local $_ = $_[0]->url; s!^[^:/\?\#]+://!!; $_ },
    'URL:SCM'           => sub { (split_url($_[0]->url))[0] },
    'URL:SCHEME'        => sub { (split_url($_[0]->url))[0] },  # non-standard
    'URL:HOST'          => sub { (split_url($_[0]->url))[2] },
    'URL:PORT'          => sub { (split_url($_[0]->url))[3] },
    'URL:PATH'          => sub { (split_url($_[0]->url))[4] },
    'URL:QUERY'         => sub { (split_url($_[0]->url))[5] },
    'URL:HASH'          => sub { (split_url($_[0]->url))[6] },  # non-standard
    'URL:FRAGMENT'      => sub { (split_url($_[0]->url))[6] },  # non-standard
    'URL:USERINFO'      => sub { (split_url($_[0]->url))[1] },
    'URL:USERNAME'      => sub { (split_url($_[0]->url))[7] },
    'URL:PASSWORD'      => sub { (split_url($_[0]->url))[8] },
    'UUID'              => sub { local $_ = format_uuid($_[0]->uuid); s/-//g; $_ },
    'REF:'              => sub { $_[0]->kdbx->resolve_reference($_[1]) },
    'INTERNETEXPLORER'  => sub { load_optional('IPC::Cmd'); IPC::Cmd::can_run('iexplore') },
    'FIREFOX'           => sub { load_optional('IPC::Cmd'); IPC::Cmd::can_run('firefox') },
    'GOOGLECHROME'      => sub { load_optional('IPC::Cmd'); IPC::Cmd::can_run('google-chrome') },
    'OPERA'             => sub { load_optional('IPC::Cmd'); IPC::Cmd::can_run('opera') },
    'SAFARI'            => sub { load_optional('IPC::Cmd'); IPC::Cmd::can_run('safari') },
    'APPDIR'            => sub { load_optional('FindBin'); $FindBin::Bin },
    'GROUP'             => sub { my $p = $_[0]->parent; $p ? $p->name : undef },
    'GROUP_PATH'        => sub { $_[0]->path },
    'GROUP_NOTES'       => sub { my $p = $_[0]->parent; $p ? $p->notes : undef },
    # 'GROUP_SEL'
    # 'GROUP_SEL_PATH'
    # 'GROUP_SEL_NOTES'
    # 'DB_PATH'
    # 'DB_DIR'
    # 'DB_NAME'
    # 'DB_BASENAME'
    # 'DB_EXT'
    'ENV:'              => sub { $ENV{$_[1]} },
    'ENV_DIRSEP'        => sub { load_optional('File::Spec')->catfile('', '') },
    'ENV_PROGRAMFILES_X86'  => sub { $ENV{'ProgramFiles(x86)'} || $ENV{'ProgramFiles'} },
    # 'T-REPLACE-RX:'
    # 'T-CONV:'
    'DT_SIMPLE'         => sub { localtime->strftime('%Y%m%d%H%M%S') },
    'DT_YEAR'           => sub { localtime->strftime('%Y') },
    'DT_MONTH'          => sub { localtime->strftime('%m') },
    'DT_DAY'            => sub { localtime->strftime('%d') },
    'DT_HOUR'           => sub { localtime->strftime('%H') },
    'DT_MINUTE'         => sub { localtime->strftime('%M') },
    'DT_SECOND'         => sub { localtime->strftime('%S') },
    'DT_UTC_SIMPLE'     => sub { gmtime->strftime('%Y%m%d%H%M%S') },
    'DT_UTC_YEAR'       => sub { gmtime->strftime('%Y') },
    'DT_UTC_MONTH'      => sub { gmtime->strftime('%m') },
    'DT_UTC_DAY'        => sub { gmtime->strftime('%d') },
    'DT_UTC_HOUR'       => sub { gmtime->strftime('%H') },
    'DT_UTC_MINUTE'     => sub { gmtime->strftime('%M') },
    'DT_UTC_SECOND'     => sub { gmtime->strftime('%S') },
    # 'PICKCHARS'
    # 'PICKCHARS:'
    # 'PICKFIELD'
    # 'NEWPASSWORD'
    # 'NEWPASSWORD:'
    # 'PASSWORD_ENC'
    'HMACOTP'           => sub { $_[0]->hmac_otp },
    'TIMEOTP'           => sub { $_[0]->time_otp },
    'C:'                => sub { '' },  # comment
    # 'BASE'
    # 'BASE:'
    # 'CLIPBOARD'
    # 'CLIPBOARD-SET:'
    # 'CMD:'
);

##############################################################################

=method lock

    $kdbx->lock;

Encrypt all protected strings in a database. The encrypted strings are stored in a L<File::KDBX::Safe>
associated with the database and the actual strings will be replaced with C<undef> to indicate their protected
state. Returns itself to allow method chaining.

=cut

sub _safe {
    my $self = shift;
    $SAFE{$self} = shift if @_;
    $SAFE{$self};
}

sub _remove_safe { delete $SAFE{$_[0]} }

sub lock {
    my $self = shift;

    $self->_safe and return $self;

    my @strings;

    my $entries = $self->all_entries(history => 1);
    for my $entry (@$entries) {
        push @strings, grep { $_->{protect} } values %{$entry->{strings} || {}};
    }

    $self->_safe(File::KDBX::Safe->new(\@strings));

    return $self;
}

=method unlock

    $kdbx->unlock;

Decrypt all protected strings in a database, replacing C<undef> placeholders with unprotected values. Returns
itself to allow method chaining.

=cut

sub unlock {
    my $self = shift;
    my $safe = $self->_safe or return $self;

    $safe->unlock;
    $self->_remove_safe;

    return $self;
}

=method unlock_scoped

    $guard = $kdbx->unlock_scoped;

Unlock a database temporarily, relocking when the guard is released (typically at the end of a scope). Returns
C<undef> if the database is already unlocked.

See L</lock> and L</unlock>.

=cut

sub unlock_scoped {
    throw 'Programmer error: Cannot call unlock_scoped in void context' if !defined wantarray;
    my $self = shift;
    return if !$self->is_locked;
    require Scope::Guard;
    my $guard = Scope::Guard->new(sub { $self->lock });
    $self->unlock;
    return $guard;
}

=method peek

    $string = $kdbx->peek(\%string);
    $string = $kdbx->peek(\%binary);

Peek at the value of a protected string or binary without unlocking the whole database. The argument can be
a string or binary hashref as returned by L<File::KDBX::Entry/string> or L<File::KDBX::Entry/binary>.

=cut

sub peek {
    my $self = shift;
    my $string = shift;
    my $safe = $self->_safe or return;
    return $safe->peek($string);
}

=method is_locked

    $bool = $kdbx->is_locked;

Get whether or not a database's strings are memory-protected. If this is true, then some or all of the
protected strings within the database will be unavailable (literally have C<undef> values) until L</unlock> is
called.

=cut

sub is_locked { $_[0]->_safe ? 1 : 0 }

##############################################################################

=method randomize_seeds

    $kdbx->randomize_seeds;

Set various keys, seeds and IVs to random values. These values are used by the cryptographic functions that
secure the database when dumped. The attributes that will be randomized are:

=for :list
* L</encryption_iv>
* L</inner_random_stream_key>
* L</master_seed>
* L</stream_start_bytes>
* L</transform_seed>

Randomizing these values has no effect on a loaded database. These are only used when a database is dumped.
You normally do not need to call this method explicitly because the dumper does it explicitly by default.

=cut

sub randomize_seeds {
    my $self = shift;
    $self->encryption_iv(random_bytes(16));
    $self->inner_random_stream_key(random_bytes(64));
    $self->master_seed(random_bytes(32));
    $self->stream_start_bytes(random_bytes(32));
    $self->transform_seed(random_bytes(32));
}

##############################################################################

=method key

    $key = $kdbx->key;
    $key = $kdbx->key($key);
    $key = $kdbx->key($primitive);

Get or set a L<File::KDBX::Key>. This is the master key (i.e. a password or a key file that can decrypt
a database). See L<File::KDBX::Key/new> for an explanation of what the primitive can be.

You generally don't need to call this directly because you can provide the key directly to the loader or
dumper when loading or saving a KDBX file.

=cut

sub key {
    my $self = shift;
    $KEYS{$self} = File::KDBX::Key->new(@_) if @_;
    $KEYS{$self};
}

=method composite_key

    $key = $kdbx->composite_key($key);
    $key = $kdbx->composite_key($primitive);

Construct a L<File::KDBX::Key::Composite> from a primitive. See L<File::KDBX::Key/new> for an explanation of
what the primitive can be. If the primitive does not represent a composite key, it will be wrapped.

You generally don't need to call this directly. The parser and writer use it to transform a master key into
a raw encryption key.

=cut

sub composite_key {
    my $self = shift;
    require File::KDBX::Key::Composite;
    return File::KDBX::Key::Composite->new(@_);
}

=method kdf

    $kdf = $kdbx->kdf(%options);
    $kdf = $kdbx->kdf(\%parameters, %options);

Get a L<File::KDBX::KDF> (key derivation function).

Options:

=for :list
* C<params> - KDF parameters, same as C<\%parameters> (default: value of L</kdf_parameters>)

=cut

sub kdf {
    my $self = shift;
    my %args = @_ % 2 == 1 ? (params => shift, @_) : @_;

    my $params = $args{params};
    my $compat = $args{compatible} // 1;

    $params //= $self->kdf_parameters;
    $params = {%{$params || {}}};

    if (empty $params || !defined $params->{+KDF_PARAM_UUID}) {
        $params->{+KDF_PARAM_UUID} = KDF_UUID_AES;
    }
    if ($params->{+KDF_PARAM_UUID} eq KDF_UUID_AES) {
        # AES_CHALLENGE_RESPONSE is equivalent to AES if there are no challenge-response keys, and since
        # non-KeePassXC implementations don't support challenge-response keys anyway, there's no problem with
        # always using AES_CHALLENGE_RESPONSE for all KDBX4+ databases.
        # For compatibility, we should not *write* AES_CHALLENGE_RESPONSE, but the dumper handles that.
        if ($self->version >= KDBX_VERSION_4_0) {
            $params->{+KDF_PARAM_UUID} = KDF_UUID_AES_CHALLENGE_RESPONSE;
        }
        $params->{+KDF_PARAM_AES_SEED}   //= $self->transform_seed;
        $params->{+KDF_PARAM_AES_ROUNDS} //= $self->transform_rounds;
    }

    require File::KDBX::KDF;
    return File::KDBX::KDF->new(%$params);
}

sub transform_seed {
    my $self = shift;
    $self->headers->{+HEADER_TRANSFORM_SEED} =
        $self->headers->{+HEADER_KDF_PARAMETERS}{+KDF_PARAM_AES_SEED} = shift if @_;
    $self->headers->{+HEADER_TRANSFORM_SEED} =
        $self->headers->{+HEADER_KDF_PARAMETERS}{+KDF_PARAM_AES_SEED} //= random_bytes(32);
}

sub transform_rounds {
    my $self = shift;
    $self->headers->{+HEADER_TRANSFORM_ROUNDS} =
        $self->headers->{+HEADER_KDF_PARAMETERS}{+KDF_PARAM_AES_ROUNDS} = shift if @_;
    $self->headers->{+HEADER_TRANSFORM_ROUNDS} =
        $self->headers->{+HEADER_KDF_PARAMETERS}{+KDF_PARAM_AES_ROUNDS} //= 100_000;
}

=method cipher

    $cipher = $kdbx->cipher(key => $key);
    $cipher = $kdbx->cipher(key => $key, iv => $iv, uuid => $uuid);

Get a L<File::KDBX::Cipher> capable of encrypting and decrypting the body of a database file.

A key is required. This should be a raw encryption key made up of a fixed number of octets (depending on the
cipher), not a L<File::KDBX::Key> or primitive.

If not passed, the UUID comes from C<< $kdbx->headers->{cipher_id} >> and the encryption IV comes from
C<< $kdbx->headers->{encryption_iv} >>.

You generally don't need to call this directly. The parser and writer use it to decrypt and encrypt KDBX
files.

=cut

sub cipher {
    my $self = shift;
    my %args = @_;

    $args{uuid} //= $self->headers->{+HEADER_CIPHER_ID};
    $args{iv}   //= $self->headers->{+HEADER_ENCRYPTION_IV};

    require File::KDBX::Cipher;
    return File::KDBX::Cipher->new(%args);
}

=method random_stream

    $cipher = $kdbx->random_stream;
    $cipher = $kdbx->random_stream(id => $stream_id, key => $key);

Get a L<File::KDBX::Cipher::Stream> for decrypting and encrypting protected values.

If not passed, the ID and encryption key comes from C<< $kdbx->headers->{inner_random_stream_id} >> and
C<< $kdbx->headers->{inner_random_stream_key} >> (respectively) for KDBX3 files and from
C<< $kdbx->inner_headers->{inner_random_stream_key} >> and
C<< $kdbx->inner_headers->{inner_random_stream_id} >> (respectively) for KDBX4 files.

You generally don't need to call this directly. The parser and writer use it to scramble protected strings.

=cut

sub random_stream {
    my $self = shift;
    my %args = @_;

    $args{stream_id} //= delete $args{id} // $self->inner_random_stream_id;
    $args{key} //= $self->inner_random_stream_key;

    require File::KDBX::Cipher;
    File::KDBX::Cipher->new(%args);
}

sub inner_random_stream_id {
    my $self = shift;
    $self->inner_headers->{+INNER_HEADER_INNER_RANDOM_STREAM_ID}
        = $self->headers->{+HEADER_INNER_RANDOM_STREAM_ID} = shift if @_;
    $self->inner_headers->{+INNER_HEADER_INNER_RANDOM_STREAM_ID}
        //= $self->headers->{+HEADER_INNER_RANDOM_STREAM_ID} //= do {
        my $version = $self->minimum_version;
        $version < KDBX_VERSION_4_0 ? STREAM_ID_SALSA20 : STREAM_ID_CHACHA20;
    };
}

sub inner_random_stream_key {
    my $self = shift;
    if (@_) {
        # These are probably the same SvPV so erasing one will CoW, but erasing the second should do the
        # trick anyway.
        erase \$self->inner_headers->{+INNER_HEADER_INNER_RANDOM_STREAM_KEY};
        erase \$self->headers->{+HEADER_INNER_RANDOM_STREAM_KEY};
        $self->inner_headers->{+INNER_HEADER_INNER_RANDOM_STREAM_KEY}
            = $self->headers->{+HEADER_INNER_RANDOM_STREAM_KEY} = shift;
    }
    $self->inner_headers->{+INNER_HEADER_INNER_RANDOM_STREAM_KEY}
        //= $self->headers->{+HEADER_INNER_RANDOM_STREAM_KEY} //= random_bytes(64); # 32
}

#########################################################################################

sub check {
# - Fixer tool. Can repair inconsistencies, including:
#   - Orphaned binaries... not really a thing anymore since we now distribute binaries amongst entries
#   - Unused custom icons (OFF, data loss)
#   - Duplicate icons
#   - All data types are valid
#     - date times are correct
#     - boolean fields
#     - All UUIDs refer to things that exist
#       - previous parent group
#       - recycle bin
#       - last selected group
#       - last visible group
#   - Enforce history size limits (ON)
#   - Check headers/meta (ON)
#   - Duplicate deleted objects (ON)
#   - Duplicate window associations (OFF)
#   - Only one root group (ON)
  # - Header UUIDs match known ciphers/KDFs?
}

#########################################################################################

sub _handle_signal {
    my $self    = shift;
    my $object  = shift;
    my $type    = shift;

    my %handlers = (
        'entry.uuid.changed'    => \&_update_entry_uuid,
        'group.uuid.changed'    => \&_update_group_uuid,
    );
    my $handler = $handlers{$type} or return;
    $self->$handler($object, @_);
}

sub _update_group_uuid {
    my $self        = shift;
    my $object      = shift;
    my $new_uuid    = shift;
    my $old_uuid    = shift // return;

    my $meta = $self->meta;
    $self->recycle_bin_uuid($new_uuid) if $old_uuid eq ($meta->{recycle_bin_uuid} // '');
    $self->entry_templates_group($new_uuid) if $old_uuid eq ($meta->{entry_templates_group} // '');
    $self->last_selected_group($new_uuid) if $old_uuid eq ($meta->{last_selected_group} // '');
    $self->last_top_visible_group($new_uuid) if $old_uuid eq ($meta->{last_top_visible_group} // '');

    for my $group (@{$self->all_groups}) {
        $group->last_top_visible_entry($new_uuid) if $old_uuid eq ($group->{last_top_visible_entry} // '');
        $group->previous_parent_group($new_uuid) if $old_uuid eq ($group->{previous_parent_group} // '');
    }
    for my $entry (@{$self->all_entries}) {
        $entry->previous_parent_group($new_uuid) if $old_uuid eq ($entry->{previous_parent_group} // '');
    }
}

sub _update_entry_uuid {
    my $self        = shift;
    my $object      = shift;
    my $new_uuid    = shift;
    my $old_uuid    = shift // return;

    my $old_pretty = format_uuid($old_uuid);
    my $new_pretty = format_uuid($new_uuid);
    my $fieldref_match = qr/\{REF:([TUPANI])\@I:\Q$old_pretty\E\}/is;

    for my $entry (@{$self->all_entries}) {
        $entry->previous_parent_group($new_uuid) if $old_uuid eq ($entry->{previous_parent_group} // '');

        for my $string (values %{$entry->strings}) {
            next if !defined $string->{value} || $string->{value} !~ $fieldref_match;
            my $txn = $entry->begin_work;
            $string->{value} =~ s/$fieldref_match/{REF:$1\@I:$new_pretty}/g;
            $txn->commit;
        }
    }
}

#########################################################################################

=attr comment

A text string associated with the database. Often unset.

=attr cipher_id

The UUID of a cipher used to encrypt the database when stored as a file.

See L</File::KDBX::Cipher>.

=attr compression_flags

Configuration for whether or not and how the database gets compressed. See
L<File::KDBX::Constants/":compression">.

=attr master_seed

The master seed is a string of 32 random bytes that is used as salt in hashing the master key when loading
and saving the database. If a challenge-response key is used in the master key, the master seed is also the
challenge.

The master seed I<should> be changed each time the database is saved to file.

=attr transform_seed

The transform seed is a string of 32 random bytes that is used in the key derivation function, either as the
salt or the key (depending on the algorithm).

The transform seed I<should> be changed each time the database is saved to file.

=attr transform_rounds

The number of rounds or iterations used in the key derivation function. Increasing this number makes loading
and saving the database slower by design in order to make dictionary and brute force attacks more costly.

=attr encryption_iv

The initialization vector used by the cipher.

The encryption IV I<should> be changed each time the database is saved to file.

=attr inner_random_stream_key

The encryption key (possibly including the IV, depending on the cipher) used to encrypt the protected strings
within the database.

=attr stream_start_bytes

A string of 32 random bytes written in the header and encrypted in the body. If the bytes do not match when
loading a file then the wrong master key was used or the file is corrupt. Only KDBX 2 and KDBX 3 files use
this. KDBX 4 files use an improved HMAC method to verify the master key and data integrity of the header and
entire file body.

=attr inner_random_stream_id

A number indicating the cipher algorithm used to encrypt the protected strings within the database, usually
Salsa20 or ChaCha20. See L<File::KDBX::Constants/":random_stream">.

=attr kdf_parameters

A hash/dict of key-value pairs used to configure the key derivation function. This is the KDBX4+ way to
configure the KDF, superceding L</transform_seed> and L</transform_rounds>.

=attr generator

The name of the software used to generate the KDBX file.

=attr header_hash

The header hash used to verify that the file header is not corrupt. (KDBX 2 - KDBX 3.1, removed KDBX 4.0)

=attr database_name

Name of the database.

=attr database_name_changed

Timestamp indicating when the database name was last changed.

=attr database_description

Description of the database

=attr database_description_changed

Timestamp indicating when the database description was last changed.

=attr default_username

When a new entry is created, the I<UserName> string will be populated with this value.

=attr default_username_changed

Timestamp indicating when the default username was last changed.

=attr maintenance_history_days

TODO... not really sure what this is. 😀

=attr color

A color associated with the database (in the form C<#ffffff> where "f" is a hexidecimal digit). Some agents
use this to help users visually distinguish between different databases.

=attr master_key_changed

Timestamp indicating when the master key was last changed.

=attr master_key_change_rec

Number of days until the agent should prompt to recommend changing the master key.

=attr master_key_change_force

Number of days until the agent should prompt to force changing the master key.

Note: This is purely advisory. It is up to the individual agent software to actually enforce it.
C<File::KDBX> does NOT enforce it.

=attr recycle_bin_enabled

Boolean indicating whether removed groups and entries should go to a recycle bin or be immediately deleted.

=attr recycle_bin_uuid

The UUID of a group used to store thrown-away groups and entries.

=attr recycle_bin_changed

Timestamp indicating when the recycle bin was last changed.

=attr entry_templates_group

The UUID of a group containing template entries used when creating new entries.

=attr entry_templates_group_changed

Timestamp indicating when the entry templates group was last changed.

=attr last_selected_group

The UUID of the previously-selected group.

=attr last_top_visible_group

The UUID of the group visible at the top of the list.

=attr history_max_items

The maximum number of historical entries allowed to be saved for each entry.

=attr history_max_size

The maximum total size (in bytes) that each individual entry's history is allowed to grow.

=attr settings_changed

Timestamp indicating when the database settings were last updated.

=attr protect_title

Alias of the L</memory_protection> setting for the I<Title> string.

=attr protect_username

Alias of the L</memory_protection> setting for the I<UserName> string.

=attr protect_password

Alias of the L</memory_protection> setting for the I<Password> string.

=attr protect_url

Alias of the L</memory_protection> setting for the I<URL> string.

=attr protect_notes

Alias of the L</memory_protection> setting for the I<Notes> string.

=cut

#########################################################################################

sub TO_JSON { +{%{$_[0]}} }

1;
__END__

=for Pod::Coverage STORABLE_freeze STORABLE_thaw TO_JSON

=head1 SYNOPSIS

    use File::KDBX;

    my $kdbx = File::KDBX->new;

    my $group = $kdbx->add_group(
        name => 'Passwords',
    );

    my $entry = $group->add_entry(
        title    => 'My Bank',
        password => 's3cr3t',
    );

    $kdbx->dump_file('passwords.kdbx', 'M@st3rP@ssw0rd!');

    $kdbx = File::KDBX->load_file('passwords.kdbx', 'M@st3rP@ssw0rd!');

    for my $entry (@{ $kdbx->all_entries }) {
        say 'Entry: ', $entry->title;
    }

=head1 DESCRIPTION

B<File::KDBX> provides everything you need to work with a KDBX database. A KDBX database is a hierarchical
object database which is commonly used to store secret information securely. It was developed for the KeePass
password safe. See L</"KDBX Introduction"> for more information about KDBX.

This module lets you query entries, create new entries, delete entries and modify entries. The distribution
also includes various parsers and generators for serializing and persisting databases.

This design of this software was influenced by the L<KeePassXC|https://github.com/keepassxreboot/keepassxc>
implementation of KeePass as well as the L<File::KeePass> module. B<File::KeePass> is an alternative module
that works well in most cases but has a small backlog of bugs and security issues and also does not work with
newer KDBX version 4 files. If you're coming here from the B<File::KeePass> world, you might be interested in
L<File::KeePass::KDBX> that is a drop-in replacement for B<File::KeePass> that uses B<File::KDBX> for storage.

=head2 KDBX Introduction

A KDBX database consists of a hierarchical I<group> of I<entries>. Entries can contain zero or more key-value
pairs of I<strings> and zero or more I<binaries> (i.e. octet strings). Groups, entries, strings and binaries:
that's the KDBX vernacular. A small amount of metadata (timestamps, etc.) is associated with each entry, group
and the database as a whole.

You can think of a KDBX database kind of like a file system, where groups are directories, entries are files,
and strings and binaries make up a file's contents.

Databases are typically persisted as a encrypted, compressed files. They are usually accessed directly (i.e.
not over a network). The primary focus of this type of database is data security. It is ideal for storing
relatively small amounts of data (strings and binaries) that must remain secret except to such individuals as
have the correct I<master key>. Even if the database file were to be "leaked" to the public Internet, it
should be virtually impossible to crack with a strong key. See L</SECURITY> for an overview of security
considerations.

=head1 RECIPES

=head2 Create a new database

    my $kdbx = File::KDBX->new;

    my $group = $kdbx->add_group(name => 'Passwords);
    my $entry = $group->add_entry(
        title    => 'WayneCorp',
        username => 'bwayne',
        password => 'iambatman',
        url      => 'https://example.com/login'
    );
    $entry->add_auto_type_window_association('WayneCorp - Mozilla Firefox', '{PASSWORD}{ENTER}');

    $kdbx->dump_file('mypasswords.kdbx', 'master password CHANGEME');

=head2 Read an existing database

    my $kdbx = File::KDBX->load_file('mypasswords.kdbx', 'master password CHANGEME');
    $kdbx->unlock;

    for my $entry (@{ $kdbx->all_entries }) {
        say 'Found password for ', $entry->title, ':';
        say '  Username: ', $entry->username;
        say '  Password: ', $entry->password;
    }

=head2 Search for entries

    my @entries = $kdbx->find_entries({
        title => 'WayneCorp',
    }, search => 1);

See L</QUERY> for many more query examples.

=head2 Search for entries by auto-type window association

    my @entry_key_sequences = $kdbx->find_entries_for_window('WayneCorp - Mozilla Firefox');
    for my $pair (@entry_key_sequences) {
        my ($entry, $key_sequence) = @$pair;
        say 'Entry title: ', $entry->title, ', key sequence: ', $key_sequence;
    }

Example output:

    Entry title: WayneCorp, key sequence: {PASSWORD}{ENTER}

=head1 SECURITY

One of the biggest threats to your database security is how easily the encryption key can be brute-forced.
Strong brute-force protection depends on a couple factors:

=for :list
* Using unguessable passwords, passphrases and key files.
* Using a brute-force resistent key derivation function.

The first factor is up to you. This module does not enforce strong master keys. It is up to you to pick or
generate strong keys.

The KDBX format allows for the key derivation function to be tuned. The idea is that you want each single
brute-foce attempt to be expensive (in terms of time, CPU usage or memory usage), so that making a lot of
attempts (which would be required if you have a strong master key) gets I<really> expensive.

How expensive you want to make each attempt is up to you and can depend on the application.

This and other KDBX-related security issues are covered here more in depth:
L<https://keepass.info/help/base/security.html>

Here are other security risks you should be thinking about:

=head2 Cryptography

This distribution uses the excellent L<CryptX> and L<Crypt::Argon2> packages to handle all crypto-related
functions. As such, a lot of the security depends on the quality of these dependencies. Fortunately these
modules are maintained and appear to have good track records.

The KDBX format has evolved over time to incorporate improved security practices and cryptographic functions.
This package uses the following functions for authentication, hashing, encryption and random number
generation:

=for :list
* AES-128 (legacy)
* AES-256
* Argon2d & Argon2id
* CBC block mode
* HMAC-SHA256
* SHA256
* SHA512
* Salsa20 & ChaCha20
* Twofish

At the time of this writing, I am not aware of any successful attacks against any of these functions. These
are among the most-analyzed and widely-adopted crypto functions available.

The KDBX format allows the body cipher and key derivation function to be configured. If a flaw is discovered
in one of these functions, you can hopefully just switch to a better function without needing to update this
software. A later software release may phase out the use of any functions which are no longer secure.

=head2 Memory Protection

It is not a good idea to keep secret information unencrypted in system memory for longer than is needed. The
address space of your program can generally be read by a user with elevated privileges on the system. If your
system is memory-constrained or goes into a hibernation mode, the contents of your address space could be
written to a disk where it might be persisted for long time.

There might be system-level things you can do to reduce your risk, like using swap encryption and limiting
system access to your program's address space while your program is running.

B<File::KDBX> helps minimize (but not eliminate) risk by keeping secrets encrypted in memory until accessed
and zeroing out memory that holds secrets after they're no longer needed, but it's not a silver bullet.

For one thing, the encryption key is stored in the same address space. If core is dumped, the encryption key
is available to be found out. But at least there is the chance that the encryption key and the encrypted
secrets won't both be paged out while memory-constrained.

Another problem is that some perls (somewhat notoriously) copy around memory behind the scenes willy nilly,
and it's difficult know when perl makes a copy of a secret in order to be able to zero it out later. It might
be impossible. The good news is that perls with SvPV copy-on-write (enabled by default beginning with perl
5.20) are much better in this regard. With COW, it's mostly possible to know what operations will cause perl
to copy the memory of a scalar string, and the number of copies will be significantly reduced. There is a unit
test named F<t/memory-protection.t> in this distribution that can be run on POSIX systems to determine how
well B<File::KDBX> memory protection is working.

Memory protection also depends on how your application handles secrets. If your app code is handling scalar
strings with secret information, it's up to you to make sure its memory is zeroed out when no longer needed.
L<File::KDBX::Util/erase> et al. provide some tools to help accomplish this. Or if you're not too concerned
about the risks memory protection is meant to mitigate, then maybe don't worry about it. The security policy
of B<File::KDBX> is to try hard to keep secrets protected while in memory so that your app might claim a high
level of security, in case you care about that.

There are some memory protection strategies that B<File::KDBX> does NOT use today but could in the future:

Many systems allow programs to mark unswappable pages. Secret information should ideally be stored in such
pages. You could potentially use L<mlockall(2)> (or equivalent for your system) in your own application to
prevent the entire address space from being swapped.

Some systems provide special syscalls for storing secrets in memory while keeping the encryption key outside
of the program's address space, like C<CryptProtectMemory> for Windows. This could be a good option, though
unfortunately not portable.

=head1 QUERY

Several methods take a I<query> as an argument (e.g. L</find_entries>). A query is just a subroutine that you
can either write yourself or have generated for you based on either a simple expression or a declarative
structure. It's easier to have your query generated, so I'll cover that first.

=head2 Simple Expression

A simple expression is mostly compatible with the KeePass 2 implementation
L<described here|https://keepass.info/help/base/search.html#mode_se>.

An expression is a string with one or more space-separated terms. Terms with spaces can be enclosed in double
quotes. Terms are negated if they are prefixed with a minus sign. A record must match every term on at least
one of the given fields.

So a simple expression is something like what you might type into a search engine. You can generate a simple
expression query using L<File::KDBX::Util/simple_expression_query> or by passing the simple expression as
a B<string reference> to search methods like L</find_entries>.

To search for all entries in a database with the word "canyon" appearing anywhere in the title:

    my @entries = $kdbx->find_entries([ \'canyon', qw(title) ]);

Notice the first argument is a B<stringref>. This diambiguates a simple expression from other types of queries
covered below.

As mentioned, a simple expression can have multiple terms. This simple expression query matches any entry that
has the words "red" B<and> "canyon" anywhere in the title:

    my @entries = $kdbx->find_entries([ \'red canyon', qw(title) ]);

Each term in the simple expression must be found for an entry to match.

To search for entries with "red" in the title but B<not> "canyon", just prepend "canyon" with a minus sign:

    my @entries = $kdbx->find_entries([ \'red -canyon', qw(title) ]);

To search over multiple fields simultaneously, just list them. To search for entries with "grocery" in the
title or notes but not "Foodland":

    my @entries = $kdbx->find_entries([ \'grocery -Foodland', qw(title notes) ]);

The default operator is a case-insensitive regexp match, which is fine for searching text loosely. You can use
just about any binary comparison operator that perl supports. To specify an operator, list it after the simple
expression. For example, to search for any entry that has been used at least five times:

    my @entries = $kdbx->find_entries([ \5, '>=', qw(usage_count) ]);

It helps to read it right-to-left, like "usage_count is >= 5".

If you find the disambiguating structures to be confusing, you can also the L</find_entries_simple> method as
a more intuitive alternative. The following example is equivalent to the previous:

    my @entries = $kdbx->find_entries_simple(5, '>=', qw(usage_count));

=head2 Declarative Query

Structuring a declarative query is similar to L<SQL::Abstract/"WHERE CLAUSES">, but you don't have to be
familiar with that module. Just learn by examples.

To search for all entries in a database titled "My Bank":

    my @entries = $kdbx->find_entries({ title => 'My Bank' });

The query here is C<< { title => 'My Bank' } >>. A hashref can contain key-value pairs where the key is
a attribute of the thing being searched for (in this case an entry) and the value is what you want the thing's
attribute to be to consider it a match. In this case, the attribute we're using as our match criteria is
L<File::KDBX::Entry/title>, a text field. If an entry has its title attribute equal to "My Bank", it's
a match.

A hashref can contain multiple attributes. The search candidate will be a match if I<all> of the specified
attributes are equal to their respective values. For example, to search for all entries with a particular URL
B<AND> username:

    my @entries = $kdbx->find_entries({
        url      => 'https://example.com',
        username => 'neo',
    });

To search for entries matching I<any> criteria, just change the hashref to an arrayref. To search for entries
with a particular URL B<OR> a particular username:

    my @entries = $kdbx->find_entries([ # <-- square bracket
        url      => 'https://example.com',
        username => 'neo',
    ]);

You can user different operators to test different types of attributes. The L<File::KDBX::Entry/icon_id>
attribute is a number, so we should use a number comparison operator. To find entries using the smartphone
icon:

    my @entries = $kdbx->find_entries({
        icon_id => { '==', ICON_SMARTPHONE },
    });

Note: L<File::KDBX::Constants/ICON_SMARTPHONE> is just a constant from L<File::KDBX::Constants>. It isn't
special to this example or to queries generally. We could have just used a literal number.

The important thing to notice here is how we wrapped the condition in another arrayref with a single key-pair
where the key is the name of an operator and the value is the thing to match against. The supported operators
are:

=for :list
* C<eq> - String equal
* C<ne> - String not equal
* C<lt> - String less than
* C<gt> - String greater than
* C<le> - String less than or equal
* C<ge> - String greater than or equal
* C<==> - Number equal
* C<!=> - Number not equal
* C<< < >> - Number less than
* C<< > >>> - Number greater than
* C<< <= >> - Number less than or equal
* C<< >= >> - Number less than or equal
* C<=~> - String match regular expression
* C<!~> - String does not match regular expression
* C<!> - Boolean false
* C<!!> - Boolean true

Other special operators:

=for :list
* C<-true> - Boolean true
* C<-false> - Boolean false
* C<-not> - Boolean false (alias for C<-false>)
* C<-defined> - Is defined
* C<-undef> - Is not d efined
* C<-empty> - Is empty
* C<-nonempty> - Is not empty
* C<-or> - Logical or
* C<-and> - Logical and

Let's see another example using an explicit operator. To find all groups except one in particular (identified
by its L<File::KDBX::Group/uuid>), we can use the C<ne> (string not equal) operator:

    my ($group, @other) = $kdbx->find_groups({
        uuid => {
            'ne' => uuid('596f7520-6172-6520-7370-656369616c2e'),
        },
    });
    if (@other) { say "Problem: there can be only one!" }

Note: L<File::KDBX::Util/uuid> is a little helper function to convert a UUID in its pretty form into octets.
This helper function isn't special to this example or to queries generally. It could have been written with
a literal such as C<"\x59\x6f\x75\x20\x61...">, but that's harder to read.

Notice we searched for groups this time. Finding groups works exactly the same as it does for entries.

Testing the truthiness of an attribute is a little bit different because it isn't a binary operation. To find
all entries with the password quality check disabled:

    my @entries = $kdbx->find_entries({ '!' => 'quality_check' });

This time the string after the operator is the attribute name rather than a value to compare the attribute
against. To test that a boolean value is true, use the C<!!> operator (or C<-true> if C<!!> seems a little too
weird for your taste):

    my @entries = $kdbx->find_entries({ '!!'  => 'quality_check' });
    my @entries = $kdbx->find_entries({ -true => 'quality_check' });

Yes, there is also a C<-false> and a C<-not> if you prefer one of those over C<!>. C<-false> and C<-not>
(along with C<-true>) are also special in that you can use them to invert the logic of a subquery. These are
logically equivalent:

    my @entries = $kdbx->find_entries([ -not => { title => 'My Bank' } ]);
    my @entries = $kdbx->find_entries({ title => { 'ne' => 'My Bank' } });

These special operators become more useful when combined with two more special operators: C<-and> and C<-or>.
With these, it is possible to construct more interesting queries with groups of logic. For example:

    my @entries = $kdbx->find_entries({
        title   => { '=~', qr/bank/ },
        -not    => {
            -or     => {
                notes   => { '=~', qr/business/ },
                icon_id => { '==', ICON_TRASHCAN_FULL },
            },
        },
    });

In English, find entries where the word "bank" appears anywhere in the title but also do not have either the
word "business" in the notes or is using the full trashcan icon.

=head2 Subroutine Query

Lastly, as mentioned at the top, you can ignore all this and write your own subroutine. Your subroutine will
be called once for each thing being searched over. The single argument is the search candidate. The subroutine
should match the candidate against whatever criteria you want and return true if it matches. The C<find_*>
methods collect all matching things and return them.

For example, to find all entries in the database titled "My Bank":

    my @entries = $kdbx->find_entries(sub { shift->title eq 'My Bank' });
    # logically the same as this declarative structure:
    my @entries = $kdbx->find_entries({ title => 'My Bank' });
    # as well as this simple expression:
    my @entries = $kdbx->find_entries([ \'My Bank', 'eq', qw{title} ]);

This is a trivial example, but of course your subroutine can be arbitrarily complex.

All of these query mechanisms described in this section are just tools, each with its own set of limitations.
If the tools are getting in your way, you can of course iterate over the contents of a database and implement
your own query logic, like this:

    for my $entry (@{ $kdbx->all_entries }) {
        if (wanted($entry)) {
            do_something($entry);
        }
        else {
            ...
        }
    }

=head1 ERRORS

Errors in this package are constructed as L<File::KDBX::Error> objects and propagated using perl's built-in
mechanisms. Fatal errors are propagated using L<functions/die> and non-fatal errors (a.k.a. warnings) are
propagated using L<functions/warn> while adhering to perl's L<warnings> system. If you're already familiar
with these mechanisms, you can skip this section.

You can catch fatal errors using L<functions/eval> (or something like L<Try::Tiny>) and non-fatal errors using
C<$SIG{__WARN__}> (see L<variables/%SIG>). Examples:

    use File::KDBX::Error qw(error);

    my $key = '';   # uh oh
    eval {
        $kdbx->load_file('whatever.kdbx', $key);
    };
    if (my $error = error($@)) {
        handle_missing_key($error) if $error->type eq 'key.missing';
        $error->throw;
    }

or using C<Try::Tiny>:

    try {
        $kdbx->load_file('whatever.kdbx', $key);
    }
    catch {
        handle_error($_);
    };

Catching non-fatal errors:

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    $kdbx->load_file('whatever.kdbx', $key);

    handle_warnings(@warnings) if @warnings;

By default perl prints warnings to C<STDERR> if you don't catch them. If you don't want to catch them and also
don't want them printed to C<STDERR>, you can suppress them lexically (perl v5.28 or higher required):

    {
        no warnings 'File::KDBX';
        ...
    }

or locally:

    {
        local $File::KDBX::WARNINGS = 0;
        ...
    }

or globally in your program:

    $File::KDBX::WARNINGS = 0;

You cannot suppress fatal errors, and if you don't catch them your program will exit.

=head1 ENVIRONMENT

This software will alter its behavior depending on the value of certain environment variables:

=for :list
* C<PERL_FILE_KDBX_XS> - Do not use L<File::KDBX::XS> if false (default: true)
* C<PERL_ONLY> - Do not use L<File::KDBX::XS> if true (default: false)
* C<NO_FORK> - Do not fork if true (default: false)

=head1 CAVEATS

Some features (e.g. parsing) require 64-bit perl. It should be possible and actually pretty easy to make it
work using L<Math::BigInt>, but I need to build a 32-bit perl in order to test it and frankly I'm still
figuring out how. I'm sure it's simple so I'll mark this one "TODO", but for now an exception will be thrown
when trying to use such features with undersized IVs.

=head1 SEE ALSO

L<File::KeePass> is a much older alternative. It's good but has a backlog of bugs and lacks support for newer
KDBX features.

=attr sig1

=attr sig2

=attr version

=attr headers

=attr inner_headers

=attr meta

=attr binaries

=attr deleted_objects

=attr raw

    $value = $kdbx->$attr;
    $kdbx->$attr($value);

Get and set attributes.

=cut
