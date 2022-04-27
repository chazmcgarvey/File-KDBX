package File::KDBX::Entry;
# ABSTRACT: A KDBX database entry

use warnings;
use strict;

use Crypt::Misc 0.029 qw(decode_b64 encode_b32r);
use Devel::GlobalDestruction;
use Encode qw(encode);
use File::KDBX::Constants qw(:history :icon);
use File::KDBX::Error;
use File::KDBX::Util qw(:class :coercion :function :uri generate_uuid load_optional);
use Hash::Util::FieldHash;
use List::Util qw(first sum0);
use Ref::Util qw(is_coderef is_plain_hashref);
use Scalar::Util qw(looks_like_number);
use Storable qw(dclone);
use Time::Piece;
use boolean;
use namespace::clean;

extends 'File::KDBX::Object';

our $VERSION = '999.999'; # VERSION

my $PLACEHOLDER_MAX_DEPTH = 10;
my %PLACEHOLDERS;
my %STANDARD_STRINGS = map { $_ => 1 } qw(Title UserName Password URL Notes);

sub _parent_container { 'entries' }

=attr uuid

128-bit UUID identifying the entry within the database.

=attr icon_id

Integer representing a default icon. See L<File::KDBX::Constants/":icon"> for valid values.

=attr custom_icon_uuid

128-bit UUID identifying a custom icon within the database.

=attr foreground_color

Text color represented as a string of the form C<#000000>.

=attr background_color

Background color represented as a string of the form C<#FFFFFF>.

=attr override_url

TODO

=attr tags

Text string with arbitrary tags which can be used to build a taxonomy.

=attr auto_type

Auto-type details.

    {
        enabled                     => true,
        data_transfer_obfuscation   => 0,
        default_sequence            => '{USERNAME}{TAB}{PASSWORD}{ENTER}',
        associations                => [
            {
                window              => 'My Bank - Mozilla Firefox',
                keystroke_sequence  => '{PASSWORD}{ENTER}',
            },
        ],
    }

=attr previous_parent_group

128-bit UUID identifying a group within the database.

=attr quality_check

Boolean indicating whether the entry password should be tested for weakness and show up in reports.

=attr strings

Hash with entry strings, including the standard strings as well as any custom ones.

    {
        # Every entry has these five strings:
        Title    => { value => 'Example Entry' },
        UserName => { value => 'jdoe' },
        Password => { value => 's3cr3t', protect => true },
        URL      => { value => 'https://example.com' }
        Notes    => { value => '' },
        # May also have custom strings:
        MySystem => { value => 'The mainframe' },
    }

=attr binaries

Files or attachments.

=attr custom_data

A set of key-value pairs used to store arbitrary data, usually used by software to keep track of state rather
than by end users (who typically work with the strings and binaries).

=attr history

Array of historical entries. Historical entries are prior versions of the same entry so they all share the
same UUID with the current entry.

=attr last_modification_time

Date and time when the entry was last modified.

=attr creation_time

Date and time when the entry was created.

=attr last_access_time

Date and time when the entry was last accessed.

=attr expiry_time

Date and time when the entry expired or will expire.

=attr expires

Boolean value indicating whether or not an entry is expired.

=attr usage_count

The number of times an entry has been used, which typically means how many times the B<Password> string has
been accessed.

=attr location_changed

Date and time when the entry was last moved to a different group.

=attr notes

Alias for the B<Notes> string value.

=attr password

Alias for the B<Password> string value.

=attr title

Alias for the B<Title> string value.

=attr url

Alias for the B<URL> string value.

=attr username

Aliases for the B<UserName> string value.

=cut

sub uuid {
    my $self = shift;
    if (@_ || !defined $self->{uuid}) {
        my %args = @_ % 2 == 1 ? (uuid => shift, @_) : @_;
        my $old_uuid = $self->{uuid};
        my $uuid = $self->{uuid} = delete $args{uuid} // generate_uuid;
        for my $entry (@{$self->history}) {
            $entry->{uuid} = $uuid;
        }
        $self->_signal('uuid.changed', $uuid, $old_uuid) if defined $old_uuid && $self->is_current;
    }
    $self->{uuid};
}

# has uuid                    => sub { generate_uuid(printable => 1) };
has icon_id                 => ICON_PASSWORD,   coerce => \&to_icon_constant;
has custom_icon_uuid        => undef,           coerce => \&to_uuid;
has foreground_color        => '',              coerce => \&to_string;
has background_color        => '',              coerce => \&to_string;
has override_url            => '',              coerce => \&to_string;
has tags                    => '',              coerce => \&to_string;
has auto_type               => {};
has previous_parent_group   => undef,           coerce => \&to_uuid;
has quality_check           => true,            coerce => \&to_bool;
has strings                 => {};
has binaries                => {};
has times                   => {};
# has custom_data             => {};
# has history                 => [];

has last_modification_time  => sub { gmtime }, store => 'times', coerce => \&to_time;
has creation_time           => sub { gmtime }, store => 'times', coerce => \&to_time;
has last_access_time        => sub { gmtime }, store => 'times', coerce => \&to_time;
has expiry_time             => sub { gmtime }, store => 'times', coerce => \&to_time;
has expires                 => false,          store => 'times', coerce => \&to_bool;
has usage_count             => 0,              store => 'times', coerce => \&to_number;
has location_changed        => sub { gmtime }, store => 'times', coerce => \&to_time;

my %ATTRS_STRINGS = (
    title                   => 'Title',
    username                => 'UserName',
    password                => 'Password',
    url                     => 'URL',
    notes                   => 'Notes',
);
while (my ($attr, $string_key) = each %ATTRS_STRINGS) {
    no strict 'refs'; ## no critic (ProhibitNoStrict)
    *{$attr} = sub { shift->string_value($string_key, @_) };
    *{"expanded_${attr}"} = sub { shift->expanded_string_value($string_key, @_) };
}

my @ATTRS = qw(uuid custom_data history);
sub _set_nonlazy_attributes {
    my $self = shift;
    $self->$_ for @ATTRS, keys %ATTRS_STRINGS, list_attributes(ref $self);
}

sub init {
    my $self = shift;
    my %args = @_;

    while (my ($key, $val) = each %args) {
        if (my $method = $self->can($key)) {
            $self->$method($val);
        }
        else {
            $self->string($key => $val);
        }
    }

    return $self;
}

##############################################################################

=method string

    \%string = $entry->string($string_key);

    $entry->string($string_key, \%string);
    $entry->string($string_key, %attributes);
    $entry->string($string_key, $value); # same as: value => $value

Get or set a string. Every string has a unique (to the entry) key and flags and so are returned as a hash
structure. For example:

    $string = {
        value   => 'Password',
        protect => true,    # optional
    };

Every string should have a value (but might be C<undef> due to memory protection) and these optional flags
which might exist:

=for :list
* C<protect> - Whether or not the string value should be memory-protected.

=cut

sub string {
    my $self = shift;
    my %args = @_     == 2 ? (key => shift, value => shift)
             : @_ % 2 == 1 ? (key => shift, @_) : @_;

    if (!defined $args{key} && !defined $args{value}) {
        my %standard = (value => 1, protect => 1);
        my @other_keys = grep { !$standard{$_} } keys %args;
        if (@other_keys == 1) {
            my $key = $args{key} = $other_keys[0];
            $args{value} = delete $args{$key};
        }
    }

    my $key = delete $args{key} or throw 'Must provide a string key to access';

    return $self->{strings}{$key} = $args{value} if is_plain_hashref($args{value});

    while (my ($field, $value) = each %args) {
        $self->{strings}{$key}{$field} = $value;
    }

    # Auto-vivify the standard strings.
    if ($STANDARD_STRINGS{$key}) {
        return $self->{strings}{$key} //= {value => '', $self->_protect($key) ? (protect => true) : ()};
    }
    return $self->{strings}{$key};
}

### Get whether or not a standard string is configured to be protected
sub _protect {
    my $self = shift;
    my $key  = shift;
    return false if !$STANDARD_STRINGS{$key};
    if (my $kdbx = eval { $self->kdbx }) {
        my $protect = $kdbx->memory_protection($key);
        return $protect if defined $protect;
    }
    return $key eq 'Password';
}

=method string_value

    $string = $entry->string_value;

Access a string value directly. Returns C<undef> if the string is not set.

=cut

sub string_value {
    my $self = shift;
    my $string = $self->string(@_) // return undef;
    return $string->{value};
}

=method expanded_string_value

    $string = $entry->expanded_string_value;

Same as L</string_value> but will substitute placeholders and resolve field references. Any placeholders that
do not expand to values are left as-is.

See L</Placeholders>.

Some placeholders (notably field references) require the entry be connected to a database and will throw an
error if it is not.

=cut

sub _expand_placeholder {
    my $self = shift;
    my $placeholder = shift;
    my $arg = shift;

    require File::KDBX;

    my $placeholder_key = $placeholder;
    if (defined $arg) {
        $placeholder_key = $File::KDBX::PLACEHOLDERS{"${placeholder}:${arg}"} ? "${placeholder}:${arg}"
                                                                              : "${placeholder}:";
    }
    return if !defined $File::KDBX::PLACEHOLDERS{$placeholder_key};

    my $local_key = join('/', Hash::Util::FieldHash::id($self), $placeholder_key);
    local $PLACEHOLDERS{$local_key} = my $handler = $PLACEHOLDERS{$local_key} // do {
        my $handler = $File::KDBX::PLACEHOLDERS{$placeholder_key} or next;
        memoize recurse_limit($handler, $PLACEHOLDER_MAX_DEPTH, sub {
            alert "Detected deep recursion while expanding $placeholder placeholder",
                placeholder => $placeholder;
            return; # undef
        });
    };

    return $handler->($self, $arg, $placeholder);
}

sub _expand_string {
    my $self    = shift;
    my $str     = shift;

    my $expand = memoize $self->can('_expand_placeholder'), $self;

    # placeholders (including field references):
    $str =~ s!\{([^:\}]+)(?::([^\}]*))?\}!$expand->(uc($1), $2, @_) // $&!egi;

    # environment variables (alt syntax):
    my $vars = join('|', map { quotemeta($_) } keys %ENV);
    $str =~ s!\%($vars)\%!$expand->(ENV => $1, @_) // $&!eg;

    return $str;
}

sub expanded_string_value {
    my $self = shift;
    my $str  = $self->string_value(@_) // return undef;
    return $self->_expand_string($str);
}

=method other_strings

    $other = $entry->other_strings;
    $other = $entry->other_strings($delimiter);

Get a concatenation of all non-standard string values. The default delimiter is a newline. This is is useful
for executing queries to search for entities based on the contents of these other strings (if any).

=cut

sub other_strings {
    my $self    = shift;
    my $delim   = shift // "\n";

    my @strings = map { $self->string_value($_) } grep { !$STANDARD_STRINGS{$_} } sort keys %{$self->strings};
    return join($delim, @strings);
}

sub string_peek {
    my $self = shift;
    my $string = $self->string(@_);
    return defined $string->{value} ? $string->{value} : $self->kdbx->peek($string);
}

sub password_peek { $_[0]->string_peek('Password') }

##############################################################################

sub binary {
    my $self = shift;
    my $key  = shift or throw 'Must provide a binary key to access';
    if (@_) {
        my $arg = @_ == 1 ? shift : undef;
        my %args;
        @args{keys %$arg} = values %$arg if ref $arg eq 'HASH';
        $args{value} = $arg if !ref $arg;
        while (my ($field, $value) = each %args) {
            $self->{binaries}{$key}{$field} = $value;
        }
    }
    my $binary = $self->{binaries}{$key} //= {value => ''};
    if (defined (my $ref = $binary->{ref})) {
        $binary = $self->{binaries}{$key} = dclone($self->kdbx->binaries->{$ref});
    }
    return $binary;
}

sub binary_novivify {
    my $self = shift;
    my $binary_key = shift;
    return if !$self->{binaries}{$binary_key} && !@_;
    return $self->binary($binary_key, @_);
}

sub binary_value {
    my $self = shift;
    my $binary = $self->binary_novivify(@_) // return undef;
    return $binary->{value};
}

sub searching_enabled {
    my $self = shift;
    my $parent = $self->parent;
    return $parent->effective_enable_searching if $parent;
    return true;
}

sub auto_type_enabled {
    my $self = shift;
    return false if !$self->auto_type->{enabled};
    my $parent = $self->parent;
    return $parent->effective_enable_auto_type if $parent;
    return true;
}

##############################################################################

=method hmac_otp

    $otp = $entry->hmac_otp(%options);

Generate an HMAC-based one-time password, or C<undef> if HOTP is not configured for the entry. The entry's
strings generally must first be unprotected, just like when accessing the password. Valid options are:

=for :list
* C<counter> - Specify the counter value

To configure HOTP, see L</"One-time Passwords">.

=cut

sub hmac_otp {
    my $self = shift;
    load_optional('Pass::OTP');

    my %params = ($self->_hotp_params, @_);
    return if !defined $params{type} || !defined $params{secret};

    $params{secret} = encode_b32r($params{secret}) if !$params{base32};
    $params{base32} = 1;

    my $otp = eval {Pass::OTP::otp(%params, @_) };
    if (my $err = $@) {
        throw 'Unable to generate HOTP', error => $err;
    }

    $self->_hotp_increment_counter($params{counter});

    return $otp;
}

=method time_otp

    $otp = $entry->time_otp(%options);

Generate a time-based one-time password, or C<undef> if TOTP is not configured for the entry. The entry's
strings generally must first be unprotected, just like when accessing the password. Valid options are:

=for :list
* C<now> - Specify the value for determining the time-step counter

To configure TOTP, see L</"One-time Passwords">.

=cut

sub time_otp {
    my $self = shift;
    load_optional('Pass::OTP');

    my %params = ($self->_totp_params, @_);
    return if !defined $params{type} || !defined $params{secret};

    $params{secret} = encode_b32r($params{secret}) if !$params{base32};
    $params{base32} = 1;

    my $otp = eval {Pass::OTP::otp(%params, @_) };
    if (my $err = $@) {
        throw 'Unable to generate TOTP', error => $err;
    }

    return $otp;
}

=method hmac_otp_uri

=method time_otp_uri

    $uri_string = $entry->hmac_otp_uri;
    $uri_string = $entry->time_otp_uri;

Get a HOTP or TOTP otpauth URI for the entry, if available.

To configure OTP, see L</"One-time Passwords">.

=cut

sub hmac_otp_uri { $_[0]->_otp_uri($_[0]->_hotp_params) }
sub time_otp_uri { $_[0]->_otp_uri($_[0]->_totp_params) }

sub _otp_uri {
    my $self = shift;
    my %params = @_;

    return if 4 != grep { defined } @params{qw(type secret issuer account)};
    return if $params{type} !~ /^[ht]otp$/i;

    my $label = delete $params{label};
    $params{$_} = uri_escape_utf8($params{$_}) for keys %params;

    my $type    = lc($params{type});
    my $issuer  = $params{issuer};
    my $account = $params{account};

    $label //= "$issuer:$account";

    my $secret = $params{secret};
    $secret = uc(encode_b32r($secret)) if !$params{base32};

    delete $params{algorithm} if defined $params{algorithm} && $params{algorithm} eq 'sha1';
    delete $params{period}    if defined $params{period} && $params{period} == 30;
    delete $params{digits}    if defined $params{digits} && $params{digits} == 6;
    delete $params{counter}   if defined $params{counter} && $params{counter} == 0;

    my $uri = "otpauth://$type/$label?secret=$secret&issuer=$issuer";

    if (defined $params{encoder}) {
        $uri .= "&encoder=$params{encoder}";
        return $uri;
    }
    $uri .= '&algorithm=' . uc($params{algorithm}) if defined $params{algorithm};
    $uri .= "&digits=$params{digits}"   if defined $params{digits};
    $uri .= "&counter=$params{counter}" if defined $params{counter};
    $uri .= "&period=$params{period}"   if defined $params{period};

    return $uri;
}

sub _hotp_params {
    my $self = shift;

    my %params = (
        type    => 'hotp',
        issuer  => $self->title     || 'KDBX',
        account => $self->username  || 'none',
        digits  => 6,
        counter => $self->string_value('HmacOtp-Counter') // 0,
        $self->_otp_secret_params('Hmac'),
    );
    return %params if $params{secret};

    my %otp_params = $self->_otp_params;
    return () if !$otp_params{secret} || $otp_params{type} ne 'hotp';

    # $otp_params{counter} = 0

    return (%params, %otp_params);
}

sub _totp_params {
    my $self = shift;

    my %algorithms = (
        'HMAC-SHA-1'    => 'sha1',
        'HMAC-SHA-256'  => 'sha256',
        'HMAC-SHA-512'  => 'sha512',
    );
    my %params = (
        type        => 'totp',
        issuer      => $self->title     || 'KDBX',
        account     => $self->username  || 'none',
        digits      => $self->string_value('TimeOtp-Length') // 6,
        algorithm   => $algorithms{$self->string_value('TimeOtp-Algorithm') || ''} || 'sha1',
        period      => $self->string_value('TimeOtp-Period') // 30,
        $self->_otp_secret_params('Time'),
    );
    return %params if $params{secret};

    my %otp_params = $self->_otp_params;
    return () if !$otp_params{secret} || $otp_params{type} ne 'totp';

    return (%params, %otp_params);
}

# KeePassXC style
sub _otp_params {
    my $self = shift;
    load_optional('Pass::OTP::URI');

    my $uri = $self->string_value('otp') || '';
    my %params;
    %params = Pass::OTP::URI::parse($uri) if $uri =~ m!^otpauth://!;
    return () if !$params{secret} || !$params{type};

    if (($params{encoder} // '') eq 'steam') {
        $params{digits} = 5;
        $params{chars}  = '23456789BCDFGHJKMNPQRTVWXY';
    }

    # Pass::OTP::URI doesn't provide the issuer and account separately, so get them from the label
    my ($issuer, $user) = split(':', $params{label} // ':', 2);
    $params{issuer}  //= uri_unescape_utf8($issuer);
    $params{account} //= uri_unescape_utf8($user);

    $params{algorithm}  = lc($params{algorithm}) if $params{algorithm};
    $params{counter}    = $self->string_value('HmacOtp-Counter') if $params{type} eq 'hotp';

    return %params;
}

sub _otp_secret_params {
    my $self = shift;
    my $type = shift // return ();

    my $secret_txt = $self->string_value("${type}Otp-Secret");
    my $secret_hex = $self->string_value("${type}Otp-Secret-Hex");
    my $secret_b32 = $self->string_value("${type}Otp-Secret-Base32");
    my $secret_b64 = $self->string_value("${type}Otp-Secret-Base64");

    my $count = grep { defined } ($secret_txt, $secret_hex, $secret_b32, $secret_b64);
    return () if $count == 0;
    alert "Found multiple ${type}Otp-Secret strings", count => $count if 1 < $count;

    return (secret => $secret_b32, base32 => 1) if defined $secret_b32;
    return (secret => decode_b64($secret_b64))  if defined $secret_b64;
    return (secret => pack('H*', $secret_hex))  if defined $secret_hex;
    return (secret => encode('UTF-8', $secret_txt));
}

sub _hotp_increment_counter {
    my $self    = shift;
    my $counter = shift // $self->string_value('HmacOtp-Counter') || 0;

    looks_like_number($counter) or throw 'HmacOtp-Counter value must be a number', value => $counter;
    my $next = $counter + 1;
    $self->string('HmacOtp-Counter', $next);
    return $next;
}

##############################################################################

=method size

    $size = $entry->size;

Get the size (in bytes) of an entry.

B<NOTE:> This is not an exact figure because there is no canonical serialization of an entry. This size should
only be used as a rough estimate for comparison with other entries or to impose data size limitations.

=cut

sub size {
    my $self = shift;

    my $size = 0;

    # tags
    $size += length(encode('UTF-8', $self->tags // ''));

    # attributes (strings)
    while (my ($key, $string) = each %{$self->strings}) {
        next if !defined $string->{value};
        $size += length(encode('UTF-8', $key)) + length(encode('UTF-8', $string->{value} // ''));
    }

    # custom data
    while (my ($key, $item) = each %{$self->custom_data}) {
        next if !defined $item->{value};
        $size += length(encode('UTF-8', $key)) + length(encode('UTF-8', $item->{value} // ''));
    }

    # binaries
    while (my ($key, $binary) = each %{$self->binaries}) {
        next if !defined $binary->{value};
        my $value_len = utf8::is_utf8($binary->{value}) ? length(encode('UTF-8', $binary->{value}))
            : length($binary->{value});
        $size += length(encode('UTF-8', $key)) + $value_len;
    }

    # autotype associations
    for my $association (@{$self->auto_type->{associations} || []}) {
        $size += length(encode('UTF-8', $association->{window}))
            + length(encode('UTF-8', $association->{keystroke_sequence} // ''));
    }

    return $size;
}

##############################################################################

sub history {
    my $self = shift;
    my $entries = $self->{history} //= [];
    # FIXME - Looping through entries on each access is too expensive.
    @$entries = map { $self->_wrap_entry($_, $self->kdbx) } @$entries;
    return $entries;
}

=method history_size

    $size = $entry->history_size;

Get the size (in bytes) of all historical entries combined.

=cut

sub history_size {
    my $self = shift;
    return sum0 map { $_->size } @{$self->history};
}

=method prune_history

    $entry->prune_history(%options);

Remove as many older historical entries as necessary to get under the database limits. The limits are taken
from the connected database (if any) or can be overridden with C<%options>:

=for :list
* C<max_items> - Maximum number of historical entries to keep (default: 10, no limit: -1)
* C<max_size> - Maximum total size (in bytes) of historical entries to keep (default: 6 MiB, no limit: -1)

=cut

sub prune_history {
    my $self = shift;
    my %args = @_;

    my $max_items = $args{max_items} // eval { $self->kdbx->history_max_items }
        // HISTORY_DEFAULT_MAX_ITEMS;
    my $max_size  = $args{max_size} // eval { $self->kdbx->history_max_size }
        // HISTORY_DEFAULT_MAX_SIZE;

    # history is ordered oldest to youngest
    my $history = $self->history;

    if (0 <= $max_items && $max_items < @$history) {
        splice @$history, -$max_items;
    }

    if (0 <= $max_size) {
        my $current_size = $self->history_size;
        while ($max_size < $current_size) {
            my $entry = shift @$history;
            $current_size -= $entry->size;
        }
    }
}

=method add_historical_entry

    $entry->add_historical_entry($entry);

Add an entry to the history.

=cut

sub add_historical_entry {
    my $self = shift;
    delete $_->{history} for @_;
    push @{$self->{history} //= []}, map { $self->_wrap_entry($_) } @_;
}

=method current_entry

    $current_entry = $entry->current_entry;

Get an entry's current entry. If the entry itself is current (not historical), itself is returned.

=cut

sub current_entry {
    my $self    = shift;
    my $group   = $self->parent;

    if ($group) {
        my $id = $self->uuid;
        my $entry = first { $id eq $_->uuid } @{$group->entries};
        return $entry if $entry;
    }

    return $self;
}

=method is_current

    $bool = $entry->is_current;

Get whether or not an entry is considered current (i.e. not historical). An entry is current if it is directly
in the parent group's entry list.

=cut

sub is_current {
    my $self    = shift;
    my $current = $self->current_entry;
    return Hash::Util::FieldHash::id($self) == Hash::Util::FieldHash::id($current);
}

=method is_historical

    $bool = $entry->is_historical;

Get whether or not an entry is considered historical (i.e. not current).

This is just the inverse of L</is_current>.

=cut

sub is_historical { !$_[0]->is_current }

##############################################################################

sub _signal {
    my $self = shift;
    my $type = shift;
    return $self->SUPER::_signal("entry.$type", @_);
}

sub _commit {
    my $self = shift;
    my $orig = shift;
    $self->add_historical_entry($orig);
    my $time = gmtime;
    $self->last_modification_time($time);
    $self->last_access_time($time);
}

sub label { shift->expanded_title(@_) }

1;
__END__

=head1 DESCRIPTION

An entry in a KDBX database is a record that can contains strings (also called "fields") and binaries (also
called "files" or "attachments"). Every string and binary has a key or name. There is a default set of strings
that every entry has:

=for :list
* B<Title>
* B<UserName>
* B<Password>
* B<URL>
* B<Notes>

Beyond this, you can store any number of other strings and any number of binaries that you can use for
whatever purpose you want.

There is also some metadata associated with an entry. Each entry in a database is identified uniquely by
a UUID. An entry can also have an icon associated with it, and there are various timestamps. Take a look at
the attributes to see what's available.

A B<File::KDBX::Entry> is a subclass of L<File::KDBX::Object>.

=head2 Placeholders

Entry string and auto-type key sequences can have placeholders or template tags that can be replaced by other
values. Placeholders can appear like C<{PLACEHOLDER}>. For example, a B<URL> string might have a value of
C<http://example.com?user={USERNAME}>. C<{USERNAME}> is a placeholder for the value of the B<UserName> string
of the same entry. If the B<UserName> string had a value of "batman", the B<URL> string would expand to
C<http://example.com?user=batman>.

Some placeholders take an argument, where the argument follows the tag after a colon but before the closing
brace, like C<{PLACEHOLDER:ARGUMENT}>.

Placeholders are documented in the L<KeePass Help Center|https://keepass.info/help/base/placeholders.html>.
This software supports many (but not all) of the placeholders documented there.

=head3 Entry Placeholders

=for :list
* ☑ C<{TITLE}> - B<Title> string
* ☑ C<{USERNAME}> - B<UserName> string
* ☑ C<{PASSWORD}> - B<Password> string
* ☑ C<{NOTES}> - B<Notes> string
* ☑ C<{URL}> - B<URL> string
* ☑ C<{URL:SCM}> / C<{URL:SCHEME}>
* ☑ C<{URL:USERINFO}>
* ☑ C<{URL:USERNAME}>
* ☑ C<{URL:PASSWORD}>
* ☑ C<{URL:HOST}>
* ☑ C<{URL:PORT}>
* ☑ C<{URL:PATH}>
* ☑ C<{URL:QUERY}>
* ☑ C<{URL:FRAGMENT}> / C<{URL:HASH}>
* ☑ C<{URL:RMVSCM}> / C<{URL:WITHOUTSCHEME}>
* ☑ C<{S:Name}> - Custom string where C<Name> is the name or key of the string
* ☑ C<{UUID}> - Identifier (32 hexidecimal characters)
* ☑ C<{HMACOTP}> - Generate an HMAC-based one-time password (its counter B<will> be incremented)
* ☑ C<{TIMEOTP}> - Generate a time-based one-time password
* ☑ C<{GROUP_NOTES}> - Notes of the parent group
* ☑ C<{GROUP_PATH}> - Full path of the parent group
* ☑ C<{GROUP}> - Name of the parent group

=head3 Field References

=for :list
* ☑ C<{REF:Wanted@SearchIn:Text}> - See L<File::KDBX/resolve_reference>

=head3 File path Placeholders

=for :list
* ☑ C<{APPDIR}> - Program directory path
* ☑ C<{FIREFOX}> - Path to the Firefox browser executable
* ☑ C<{GOOGLECHROME}> - Path to the Chrome browser executable
* ☑ C<{INTERNETEXPLORER}> - Path to the Firefox browser executable
* ☑ C<{OPERA}> - Path to the Opera browser executable
* ☑ C<{SAFARI}> - Path to the Safari browser executable
* ☒ C<{DB_PATH}> - Full file path of the database
* ☒ C<{DB_DIR}> - Directory path of the database
* ☒ C<{DB_NAME}> - File name (including extension) of the database
* ☒ C<{DB_BASENAME}> - File name (excluding extension) of the database
* ☒ C<{DB_EXT}> - File name extension
* ☑ C<{ENV_DIRSEP}> - Directory separator
* ☑ C<{ENV_PROGRAMFILES_X86}> - One of C<%ProgramFiles(x86)%> or C<%ProgramFiles%>

=head3 Date and Time Placeholders

=for :list
* ☑ C<{DT_SIMPLE}> - Current local date and time as a sortable string
* ☑ C<{DT_YEAR}> - Year component of the current local date
* ☑ C<{DT_MONTH}> - Month component of the current local date
* ☑ C<{DT_DAY}> - Day component of the current local date
* ☑ C<{DT_HOUR}> - Hour component of the current local time
* ☑ C<{DT_MINUTE}> - Minute component of the current local time
* ☑ C<{DT_SECOND}> - Second component of the current local time
* ☑ C<{DT_UTC_SIMPLE}> - Current UTC date and time as a sortable string
* ☑ C<{DT_UTC_YEAR}> - Year component of the current UTC date
* ☑ C<{DT_UTC_MONTH}> - Month component of the current UTC date
* ☑ C<{DT_UTC_DAY}> - Day component of the current UTC date
* ☑ C<{DT_UTC_HOUR}> - Hour component of the current UTC time
* ☑ C<{DT_UTC_MINUTE}> Minute Year component of the current UTC time
* ☑ C<{DT_UTC_SECOND}> - Second component of the current UTC time

If the current date and time is <2012-07-25 17:05:34>, the "simple" form would be C<20120725170534>.

=head3 Special Key Placeholders

Certain placeholders for use in auto-type key sequences are not supported for replacement, but they will
remain as-is so that an auto-type engine (not included) can parse and replace them with the appropriate
virtual key presses. For completeness, here is the list that the KeePass program claims to support:

C<{TAB}>, C<{ENTER}>, C<{UP}>, C<{DOWN}>, C<{LEFT}>, C<{RIGHT}>, C<{HOME}>, C<{END}>, C<{PGUP}>, C<{PGDN}>,
C<{INSERT}>, C<{DELETE}>, C<{SPACE}>

C<{BACKSPACE}>, C<{BREAK}>, C<{CAPSLOCK}>, C<{ESC}>, C<{WIN}>, C<{LWIN}>, C<{RWIN}>, C<{APPS}>, C<{HELP}>,
C<{NUMLOCK}>, C<{PRTSC}>, C<{SCROLLLOCK}>

C<{F1}>, C<{F2}>, C<{F3}>, C<{F4}>, C<{F5}>, C<{F6}>, C<{F7}>, C<{F8}>, C<{F9}>, C<{F10}>, C<{F11}>, C<{F12}>,
C<{F13}>, C<{F14}>, C<{F15}>, C<{F16}>

C<{ADD}>, C<{SUBTRACT}>, C<{MULTIPLY}>, C<{DIVIDE}>, C<{NUMPAD0}>, C<{NUMPAD1}>, C<{NUMPAD2}>, C<{NUMPAD3}>,
C<{NUMPAD4}>, C<{NUMPAD5}>, C<{NUMPAD6}>, C<{NUMPAD7}>, C<{NUMPAD8}>, C<{NUMPAD9}>

=head3 Miscellaneous Placeholders

=for :list
* ☒ C<{BASE}>
* ☒ C<{BASE:SCM}> / C<{BASE:SCHEME}>
* ☒ C<{BASE:USERINFO}>
* ☒ C<{BASE:USERNAME}>
* ☒ C<{BASE:PASSWORD}>
* ☒ C<{BASE:HOST}>
* ☒ C<{BASE:PORT}>
* ☒ C<{BASE:PATH}>
* ☒ C<{BASE:QUERY}>
* ☒ C<{BASE:FRAGMENT}> / C<{BASE:HASH}>
* ☒ C<{BASE:RMVSCM}> / C<{BASE:WITHOUTSCHEME}>
* ☒ C<{CLIPBOARD-SET:/Text/}>
* ☒ C<{CLIPBOARD}>
* ☒ C<{CMD:/CommandLine/Options/}>
* ☑ C<{C:Comment}> - Comments are simply replaced by nothing
* ☑ C<{ENV:}> and C<%ENV%> - Environment variables
* ☒ C<{GROUP_SEL_NOTES}>
* ☒ C<{GROUP_SEL_PATH}>
* ☒ C<{GROUP_SEL}>
* ☒ C<{NEWPASSWORD}>
* ☒ C<{NEWPASSWORD:/Profile/}>
* ☒ C<{PASSWORD_ENC}>
* ☒ C<{PICKCHARS}>
* ☒ C<{PICKCHARS:Field:Options}>
* ☒ C<{PICKFIELD}>
* ☒ C<{T-CONV:/Text/Type/}>
* ☒ C<{T-REPLACE-RX:/Text/Type/Replace/}>

Some of these that remain unimplemented, such as C<{CLIPBOARD}>, cannot be implemented portably. Some of these
I haven't implemented (yet) just because they don't seem very useful. You can create your own placeholder to
augment the list of default supported placeholders or to replace a built-in placeholder handler. To create
a placeholder, just set it in the C<%File::KDBX::PLACEHOLDERS> hash. For example:

    $File::KDBX::PLACEHOLDERS{'MY_PLACEHOLDER'} = sub {
        my ($entry) = @_;
        ...;
    };

If the placeholder is expanded in the context of an entry, C<$entry> is the B<File::KDBX::Entry> object in
context. Otherwise it is C<undef>. An entry is in context if, for example, the placeholder is in an entry's
strings or auto-complete key sequences.

    $File::KDBX::PLACEHOLDERS{'MY_PLACEHOLDER:'} = sub {
        my ($entry, $arg) = @_;         #    ^ Notice the colon here
        ...;
    };

If the name of the placeholder ends in a colon, then it is expected to receive an argument. During expansion,
everything after the colon and before the end of the placeholder is passed to your placeholder handler
subroutine. So if the placeholder is C<{MY_PLACEHOLDER:whatever}>, C<$arg> will have the value B<whatever>.

An argument is required for placeholders than take one. I.e. The placeholder handler won't be called if there
is no argument. If you want a placeholder to support an optional argument, you'll need to set the placeholder
both with and without a colon (or they could be different subroutines):

    $File::KDBX::PLACEHOLDERS{'RAND'} = $File::KDBX::PLACEHOLDERS{'RAND:'} = sub {
        (undef, my $arg) = @_;
        return defined $arg ? rand($arg) : rand;
    };

You can also remove placeholder handlers. If you want to disable placeholder expansion entirely, just delete
all the handlers:

    %File::KDBX::PLACEHOLDERS = ();

=head2 One-time Passwords

An entry can be configured to generate one-time passwords, both HOTP (HMAC-based) and TOTP (time-based). The
configuration storage isn't completely standardized, but this module supports two predominant configuration
styles:

=for :list
* L<KeePass 2|https://keepass.info/help/base/placeholders.html#otp>
* KeePassXC

B<NOTE:> To use this feature, you must install the suggested dependency:

=for :list
* L<Pass::OTP>

To configure TOTP in the KeePassXC style, there is only one string to set: C<otp>. The value should be any
valid otpauth URI. When generating an OTP, all of the relevant OTP properties are parsed from the URI.

To configure TOTP in the KeePass 2 style, set the following strings:

=for :list
* C<TimeOtp-Algorithm> - Cryptographic algorithm, one of C<HMAC-SHA-1> (default), C<HMAC-SHA-256> and
    C<HMAC-SHA-512>
* C<TimeOtp-Length> - Number of digits each one-time password is (default: 6, maximum: 8)
* C<TimeOtp-Period> - Time-step size in seconds (default: 30)
* C<TimeOtp-Secret> - Text string secret, OR
* C<TimeOtp-Secret-Hex> - Hexidecimal-encoded secret, OR
* C<TimeOtp-Secret-Base32> - Base32-encoded secret (most common), OR
* C<TimeOtp-Secret-Base64> - Base64-encoded secret

To configure HOTP in the KeePass 2 style, set the following strings:

=for :list
* C<HmacOtp-Counter> - Counting value in decimal, starts on C<0> by default and increments when L</hmac_otp>
    is called
* C<HmacOtp-Secret> - Text string secret, OR
* C<HmacOtp-Secret-Hex> - Hexidecimal-encoded secret, OR
* C<HmacOtp-Secret-Base32> - Base32-encoded secret (most common), OR
* C<HmacOtp-Secret-Base64> - Base64-encoded secret

B<NOTE:> The multiple "Secret" strings are simply a way to store a secret in different formats. Only one of
these should actually be set or an error will be thrown.

Here's a basic example:

    $entry->string(otp => 'otpauth://totp/Issuer:user?secret=NBSWY3DP&issuer=Issuer');
    # OR
    $entry->string('TimeOtp-Secret-Base32' => 'NBSWY3DP');

    my $otp = $entry->time_otp;

=cut
