[![Linux](https://github.com/chazmcgarvey/File-KDBX/actions/workflows/linux.yml/badge.svg)](https://github.com/chazmcgarvey/File-KDBX/actions/workflows/linux.yml)
[![macOS](https://github.com/chazmcgarvey/File-KDBX/actions/workflows/macos.yml/badge.svg)](https://github.com/chazmcgarvey/File-KDBX/actions/workflows/macos.yml)
[![Windows](https://github.com/chazmcgarvey/File-KDBX/actions/workflows/windows.yml/badge.svg)](https://github.com/chazmcgarvey/File-KDBX/actions/workflows/windows.yml)

# NAME

File::KDBX - Encrypted database to store secret text and files

# VERSION

version 0.902

# SYNOPSIS

```perl
use File::KDBX;

# Create a new database from scratch
my $kdbx = File::KDBX->new;

# Add some objects to the database
my $group = $kdbx->add_group(
    name => 'Passwords',
);
my $entry = $group->add_entry(
    title    => 'My Bank',
    username => 'mreynolds',
    password => 's3cr3t',
);

# Save the database to the filesystem
$kdbx->dump_file('passwords.kdbx', 'M@st3rP@ssw0rd!');

# Load the database from the filesystem into a new database instance
my $kdbx2 = File::KDBX->load_file('passwords.kdbx', 'M@st3rP@ssw0rd!');

# Iterate over database entries, print entry titles
$kdbx2->entries->each(sub {
    my ($entry) = @_;
    say 'Entry: ', $entry->title;
});
```

See ["RECIPES"](#recipes) for more examples.

# DESCRIPTION

**File::KDBX** provides everything you need to work with KDBX databases. A KDBX database is a hierarchical
object database which is commonly used to store secret information securely. It was developed for the KeePass
password safe. See ["Introduction to KDBX"](#introduction-to-kdbx) for more information about KDBX.

This module lets you query entries, create new entries, delete entries, modify entries and more. The
distribution also includes various parsers and generators for serializing and persisting databases.

The design of this software was influenced by the [KeePassXC](https://github.com/keepassxreboot/keepassxc)
implementation of KeePass as well as the [File::KeePass](https://metacpan.org/pod/File%3A%3AKeePass) module. **File::KeePass** is an alternative module
that works well in most cases but has a small backlog of bugs and security issues and also does not work with
newer KDBX version 4 files. If you're coming here from the **File::KeePass** world, you might be interested in
[File::KeePass::KDBX](https://metacpan.org/pod/File%3A%3AKeePass%3A%3AKDBX) that is a drop-in replacement for **File::KeePass** that uses **File::KDBX** for storage.

This software is a **pre-1.0 release**. The interface should be considered pretty stable, but there might be
minor changes up until a 1.0 release. Breaking changes will be noted in the `Changes` file.

## Features

- ☑ Read and write KDBX version 3 - version 4.1
- ☑ Read and write KDB files (requires [File::KeePass](https://metacpan.org/pod/File%3A%3AKeePass))
- ☑ Unicode character strings
- ☑ ["Simple Expression"](#simple-expression) Searching
- ☑ [Placeholders](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AEntry#Placeholders) and [field references](#resolve_reference)
- ☑ [One-time passwords](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AEntry#One-time-Passwords)
- ☑ [Very secure](#security)
- ☑ ["Memory Protection"](#memory-protection)
- ☑ Challenge-response key components, like [YubiKey](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AKey%3A%3AYubiKey)
- ☑ Variety of [key file](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AKey%3A%3AFile) types: binary, hexed, hashed, XML v1 and v2
- ☑ Pluggable registration of different kinds of ciphers and key derivation functions
- ☑ Built-in database maintenance functions
- ☑ Pretty fast, with [XS optimizations](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AXS) available
- ☒ Database synchronization / merging (not yet)

## Introduction to KDBX

A KDBX database consists of a tree of _groups_ and _entries_, with a single _root_ group. Entries can
contain zero or more key-value pairs of _strings_ and zero or more _binaries_ (i.e. octet strings). Groups,
entries, strings and binaries: that's the KDBX vernacular. A small amount of metadata (timestamps, etc.) is
associated with each entry, group and the database as a whole.

You can think of a KDBX database kind of like a file system, where groups are directories, entries are files,
and strings and binaries make up a file's contents.

Databases are typically persisted as encrypted, compressed files. They are usually accessed directly (i.e.
not over a network). The primary focus of this type of database is data security. It is ideal for storing
relatively small amounts of data (strings and binaries) that must remain secret except to such individuals as
have the correct _master key_. Even if the database file were to be "leaked" to the public Internet, it
should be virtually impossible to crack with a strong key. The KDBX format is most often used by password
managers to store passwords so that users can know a single strong password and not have to reuse passwords
across different websites. See ["SECURITY"](#security) for an overview of security considerations.

# ATTRIBUTES

## sig1

## sig2

## version

## headers

## inner\_headers

## meta

## binaries

## deleted\_objects

Hash of UUIDs for objects that have been deleted. This includes groups, entries and even custom icons.

## raw

Bytes contained within the encrypted layer of a KDBX file. This is only set when using
[File::KDBX::Loader::Raw](https://metacpan.org/pod/File%3A%3AKDBX%3A%3ALoader%3A%3ARaw).

## comment

A text string associated with the database. Often unset.

## cipher\_id

The UUID of a cipher used to encrypt the database when stored as a file.

See [File::KDBX::Cipher](https://metacpan.org/pod/File%3A%3AKDBX%3A%3ACipher).

## compression\_flags

Configuration for whether or not and how the database gets compressed. See
[":compression" in File::KDBX::Constants](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AConstants#compression).

## master\_seed

The master seed is a string of 32 random bytes that is used as salt in hashing the master key when loading
and saving the database. If a challenge-response key is used in the master key, the master seed is also the
challenge.

The master seed _should_ be changed each time the database is saved to file.

## transform\_seed

The transform seed is a string of 32 random bytes that is used in the key derivation function, either as the
salt or the key (depending on the algorithm).

The transform seed _should_ be changed each time the database is saved to file.

## transform\_rounds

The number of rounds or iterations used in the key derivation function. Increasing this number makes loading
and saving the database slower by design in order to make dictionary and brute force attacks more costly.

## encryption\_iv

The initialization vector used by the cipher.

The encryption IV _should_ be changed each time the database is saved to file.

## inner\_random\_stream\_key

The encryption key (possibly including the IV, depending on the cipher) used to encrypt the protected strings
within the database.

## stream\_start\_bytes

A string of 32 random bytes written in the header and encrypted in the body. If the bytes do not match when
loading a file then the wrong master key was used or the file is corrupt. Only KDBX 2 and KDBX 3 files use
this. KDBX 4 files use an improved HMAC method to verify the master key and data integrity of the header and
entire file body.

## inner\_random\_stream\_id

A number indicating the cipher algorithm used to encrypt the protected strings within the database, usually
Salsa20 or ChaCha20. See [":random\_stream" in File::KDBX::Constants](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AConstants#random_stream).

## kdf\_parameters

A hash/dict of key-value pairs used to configure the key derivation function. This is the KDBX4+ way to
configure the KDF, superceding ["transform\_seed"](#transform_seed) and ["transform\_rounds"](#transform_rounds).

## generator

The name of the software used to generate the KDBX file.

## header\_hash

The header hash used to verify that the file header is not corrupt. (KDBX 2 - KDBX 3.1, removed KDBX 4.0)

## database\_name

Name of the database.

## database\_name\_changed

Timestamp indicating when the database name was last changed.

## database\_description

Description of the database

## database\_description\_changed

Timestamp indicating when the database description was last changed.

## default\_username

When a new entry is created, the _UserName_ string will be populated with this value.

## default\_username\_changed

Timestamp indicating when the default username was last changed.

## color

A color associated with the database (in the form `#ffffff` where "f" is a hexidecimal digit). Some agents
use this to help users visually distinguish between different databases.

## master\_key\_changed

Timestamp indicating when the master key was last changed.

## master\_key\_change\_rec

Number of days until the agent should prompt to recommend changing the master key.

## master\_key\_change\_force

Number of days until the agent should prompt to force changing the master key.

Note: This is purely advisory. It is up to the individual agent software to actually enforce it.
**File::KDBX** does NOT enforce it.

## custom\_icons

Array of custom icons that can be associated with groups and entries.

This list can be managed with the methods ["add\_custom\_icon"](#add_custom_icon) and ["remove\_custom\_icon"](#remove_custom_icon).

## recycle\_bin\_enabled

Boolean indicating whether removed groups and entries should go to a recycle bin or be immediately deleted.

## recycle\_bin\_uuid

The UUID of a group used to store thrown-away groups and entries.

## recycle\_bin\_changed

Timestamp indicating when the recycle bin group was last changed.

## entry\_templates\_group

The UUID of a group containing template entries used when creating new entries.

## entry\_templates\_group\_changed

Timestamp indicating when the entry templates group was last changed.

## last\_selected\_group

The UUID of the previously-selected group.

## last\_top\_visible\_group

The UUID of the group visible at the top of the list.

## history\_max\_items

The maximum number of historical entries that should be kept for each entry. Default is 10.

## history\_max\_size

The maximum total size (in bytes) that each individual entry's history is allowed to grow. Default is 6 MiB.

## maintenance\_history\_days

The maximum age (in days) historical entries should be kept. Default it 365.

## settings\_changed

Timestamp indicating when the database settings were last updated.

## protect\_title

Alias of the ["memory\_protection"](#memory_protection) setting for the _Title_ string.

## protect\_username

Alias of the ["memory\_protection"](#memory_protection) setting for the _UserName_ string.

## protect\_password

Alias of the ["memory\_protection"](#memory_protection) setting for the _Password_ string.

## protect\_url

Alias of the ["memory\_protection"](#memory_protection) setting for the _URL_ string.

## protect\_notes

Alias of the ["memory\_protection"](#memory_protection) setting for the _Notes_ string.

# METHODS

## new

```
$kdbx = File::KDBX->new(%attributes);
$kdbx = File::KDBX->new($kdbx); # copy constructor
```

Construct a new [File::KDBX](https://metacpan.org/pod/File%3A%3AKDBX).

## init

```
$kdbx = $kdbx->init(%attributes);
```

Initialize a [File::KDBX](https://metacpan.org/pod/File%3A%3AKDBX) with a set of attributes. Returns itself to allow method chaining.

This is called by ["new"](#new).

## reset

```
$kdbx = $kdbx->reset;
```

Set a [File::KDBX](https://metacpan.org/pod/File%3A%3AKDBX) to an empty state, ready to load a KDBX file or build a new one. Returns itself to allow
method chaining.

## clone

```
$kdbx_copy = $kdbx->clone;
$kdbx_copy = File::KDBX->new($kdbx);
```

Clone a [File::KDBX](https://metacpan.org/pod/File%3A%3AKDBX). The clone will be an exact copy and completely independent of the original.

## load

## load\_string

## load\_file

## load\_handle

```
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
```

Load a KDBX file from a string buffer, IO handle or file from a filesystem.

[File::KDBX::Loader](https://metacpan.org/pod/File%3A%3AKDBX%3A%3ALoader) does the heavy lifting.

## dump

## dump\_string

## dump\_file

## dump\_handle

```
$kdbx->dump(\$string, $key);
$kdbx->dump(*IO, $key);
$kdbx->dump($filepath, $key);

$kdbx->dump_string(\$string, $key);
\$string = $kdbx->dump_string($key);

$kdbx->dump_file($filepath, $key);

$kdbx->dump_handle($fh, $key);
$kdbx->dump_handle(*IO, $key);
```

Dump a KDBX file to a string buffer, IO handle or file in a filesystem.

[File::KDBX::Dumper](https://metacpan.org/pod/File%3A%3AKDBX%3A%3ADumper) does the heavy lifting.

## user\_agent\_string

```perl
$string = $kdbx->user_agent_string;
```

Get a text string identifying the database client software.

## memory\_protection

```perl
\%settings = $kdbx->memory_protection
$kdbx->memory_protection(\%settings);

$bool = $kdbx->memory_protection($string_key);
$kdbx->memory_protection($string_key => $bool);
```

Get or set memory protection settings. This globally (for the whole database) configures whether and which of
the standard strings should be memory-protected. The default setting is to memory-protect only _Password_
strings.

Memory protection can be toggled individually for each entry string, and individual settings take precedence
over these global settings.

## minimum\_version

```
$version = $kdbx->minimum_version;
```

Determine the minimum file version required to save a database losslessly. Using certain databases features
might increase this value. For example, setting the KDF to Argon2 will increase the minimum version to at
least `KDBX_VERSION_4_0` (i.e. `0x00040000`) because Argon2 was introduced with KDBX4.

This method never returns less than `KDBX_VERSION_3_1` (i.e. `0x00030001`). That file version is so
ubiquitous and well-supported, there are seldom reasons to dump in a lesser format nowadays.

**WARNING:** If you dump a database with a minimum version higher than the current ["version"](#version), the dumper will
typically issue a warning and automatically upgrade the database. This seems like the safest behavior in order
to avoid data loss, but lower versions have the benefit of being compatible with more software. It is possible
to prevent auto-upgrades by explicitly telling the dumper which version to use, but you do run the risk of
data loss. A database will never be automatically downgraded.

## root

```
$group = $kdbx->root;
$kdbx->root($group);
```

Get or set a database's root group. You don't necessarily need to explicitly create or set a root group
because it autovivifies when adding entries and groups to the database.

Every database has only a single root group at a time. Some old KDB files might have multiple root groups.
When reading such files, a single implicit root group is created to contain the actual root groups. When
writing to such a format, if the root group looks like it was implicitly created then it won't be written and
the resulting file might have multiple root groups, as it was before loading. This allows working with older
files without changing their written internal structure while still adhering to modern semantics while the
database is opened.

The root group of a KDBX database contains all of the database's entries and other groups. If you replace the
root group, you are essentially replacing the entire database contents with something else.

## trace\_lineage

```
\@lineage = $kdbx->trace_lineage($group);
\@lineage = $kdbx->trace_lineage($group, $base_group);
\@lineage = $kdbx->trace_lineage($entry);
\@lineage = $kdbx->trace_lineage($entry, $base_group);
```

Get the direct line of ancestors from `$base_group` (default: the root group) to a group or entry. The
lineage includes the base group but _not_ the target group or entry. Returns `undef` if the target is not in
the database structure.

## recycle\_bin

```
$group = $kdbx->recycle_bin;
$kdbx->recycle_bin($group);
```

Get or set the recycle bin group. Returns `undef` if there is no recycle bin and ["recycle\_bin\_enabled"](#recycle_bin_enabled) is
false, otherwise the current recycle bin or an autovivified recycle bin group is returned.

## entry\_templates

```
$group = $kdbx->entry_templates;
$kdbx->entry_templates($group);
```

Get or set the entry templates group. May return `undef` if unset.

## last\_selected

```
$group = $kdbx->last_selected;
$kdbx->last_selected($group);
```

Get or set the last selected group. May return `undef` if unset.

## last\_top\_visible

```
$group = $kdbx->last_top_visible;
$kdbx->last_top_visible($group);
```

Get or set the last top visible group. May return `undef` if unset.

## add\_group

```
$kdbx->add_group($group);
$kdbx->add_group(%group_attributes, %options);
```

Add a group to a database. This is equivalent to identifying a parent group and calling
["add\_group" in File::KDBX::Group](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AGroup#add_group) on the parent group, forwarding the arguments. Available options:

- `group` - Group object or group UUID to add the group to (default: root group)

## groups

```
\&iterator = $kdbx->groups(%options);
\&iterator = $kdbx->groups($base_group, %options);
```

Get an [File::KDBX::Iterator](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AIterator) over _groups_ within a database. Options:

- `base` - Only include groups within a base group (same as `$base_group`) (default: ["root"](#root))
- `inclusive` - Include the base group in the results (default: true)
- `algorithm` - Search algorithm, one of `ids`, `bfs` or `dfs` (default: `ids`)

## add\_entry

```
$kdbx->add_entry($entry, %options);
$kdbx->add_entry(%entry_attributes, %options);
```

Add a entry to a database. This is equivalent to identifying a parent group and calling
["add\_entry" in File::KDBX::Group](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AGroup#add_entry) on the parent group, forwarding the arguments. Available options:

- `group` - Group object or group UUID to add the entry to (default: root group)

## entries

```
\&iterator = $kdbx->entries(%options);
\&iterator = $kdbx->entries($base_group, %options);
```

Get an [File::KDBX::Iterator](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AIterator) over _entries_ within a database. Supports the same options as ["groups"](#groups),
plus some new ones:

- `auto_type` - Only include entries with auto-type enabled (default: false, include all)
- `searching` - Only include entries within groups with searching enabled (default: false, include all)
- `history` - Also include historical entries (default: false, include only current entries)

## objects

```
\&iterator = $kdbx->objects(%options);
\&iterator = $kdbx->objects($base_group, %options);
```

Get an [File::KDBX::Iterator](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AIterator) over _objects_ within a database. Groups and entries are considered objects,
so this is essentially a combination of ["groups"](#groups) and ["entries"](#entries). This won't often be useful, but it can be
convenient for maintenance tasks. This method takes the same options as ["groups"](#groups) and ["entries"](#entries).

## custom\_icon

```perl
\%icon = $kdbx->custom_icon($uuid);
$kdbx->custom_icon($uuid => \%icon);
$kdbx->custom_icon(%icon);
$kdbx->custom_icon(uuid => $value, %icon);
```

Get or set custom icons.

## custom\_icon\_data

```
$image_data = $kdbx->custom_icon_data($uuid);
```

Get a custom icon image data.

## add\_custom\_icon

```
$uuid = $kdbx->add_custom_icon($image_data, %attributes);
$uuid = $kdbx->add_custom_icon(%attributes);
```

Add a custom icon and get its UUID. If not provided, a random UUID will be generated. Possible attributes:

- `uuid` - Icon UUID (default: autogenerated)
- `data` - Image data (same as `$image_data`)
- `name` - Name of the icon (text, KDBX4.1+)
- `last_modification_time` - Just what it says (datetime, KDBX4.1+)

## remove\_custom\_icon

```
$kdbx->remove_custom_icon($uuid);
```

Remove a custom icon.

## custom\_data

```perl
\%all_data = $kdbx->custom_data;
$kdbx->custom_data(\%all_data);

\%data = $kdbx->custom_data($key);
$kdbx->custom_data($key => \%data);
$kdbx->custom_data(%data);
$kdbx->custom_data(key => $value, %data);
```

Get and set custom data. Custom data is metadata associated with a database.

Each data item can have a few attributes associated with it.

- `key` - A unique text string identifier used to look up the data item (required)
- `value` - A text string value (required)
- `last_modification_time` (optional, KDBX4.1+)

## custom\_data\_value

```
$value = $kdbx->custom_data_value($key);
```

Exactly the same as ["custom\_data"](#custom_data) except returns just the custom data's value rather than a structure of
attributes. This is a shortcut for:

```perl
my $data = $kdbx->custom_data($key);
my $value = defined $data ? $data->{value} : undef;
```

## public\_custom\_data

```perl
\%all_data = $kdbx->public_custom_data;
$kdbx->public_custom_data(\%all_data);

$value = $kdbx->public_custom_data($key);
$kdbx->public_custom_data($key => $value);
```

Get and set public custom data. Public custom data is similar to custom data but different in some important
ways. Public custom data:

- can store strings, booleans and up to 64-bit integer values (custom data can only store text values)
- is NOT encrypted within a KDBX file (hence the "public" part of the name)
- is a plain hash/dict of key-value pairs with no other associated fields (like modification times)

## add\_deleted\_object

```
$kdbx->add_deleted_object($uuid);
```

Add a UUID to the deleted objects list. This list is used to support automatic database merging.

You typically do not need to call this yourself because the list will be populated automatically as objects
are removed.

## remove\_deleted\_object

```
$kdbx->remove_deleted_object($uuid);
```

Remove a UUID from the deleted objects list. This list is used to support automatic database merging.

You typically do not need to call this yourself because the list will be maintained automatically as objects
are added.

## clear\_deleted\_objects

Remove all UUIDs from the deleted objects list.  This list is used to support automatic database merging, but
if you don't need merging then you can clear deleted objects to reduce the database file size.

## resolve\_reference

```
$string = $kdbx->resolve_reference($reference);
$string = $kdbx->resolve_reference($wanted, $search_in, $expression);
```

Resolve a [field reference](https://keepass.info/help/base/fieldrefs.html). A field reference is a kind of
string placeholder. You can use a field reference to refer directly to a standard field within an entry. Field
references are resolved automatically while expanding entry strings (i.e. replacing placeholders), but you can
use this method to resolve on-the-fly references that aren't part of any actual string in the database.

If the reference does not resolve to any field, `undef` is returned. If the reference resolves to multiple
fields, only the first one is returned (in the same order as iterated by ["entries"](#entries)). To avoid ambiguity, you
can refer to a specific entry by its UUID.

The syntax of a reference is: `{REF:<WantedField>@<SearchIn>:<Text>}`. `Text` is a
["Simple Expression"](#simple-expression). `WantedField` and `SearchIn` are both single character codes representing a field:

- `T` - Title
- `U` - UserName
- `P` - Password
- `A` - URL
- `N` - Notes
- `I` - UUID
- `O` - Other custom strings

Since `O` does not represent any specific field, it cannot be used as the `WantedField`.

Examples:

To get the value of the _UserName_ string of the first entry with "My Bank" in the title:

```perl
my $username = $kdbx->resolve_reference('{REF:U@T:"My Bank"}');
# OR the {REF:...} wrapper is optional
my $username = $kdbx->resolve_reference('U@T:"My Bank"');
# OR separate the arguments
my $username = $kdbx->resolve_reference(U => T => '"My Bank"');
```

Note how the text is a ["Simple Expression"](#simple-expression), so search terms with spaces must be surrounded in double
quotes.

To get the _Password_ string of a specific entry (identified by its UUID):

```perl
my $password = $kdbx->resolve_reference('{REF:P@I:46C9B1FFBD4ABC4BBB260C6190BAD20C}');
```

## lock

```
$kdbx->lock;
```

Encrypt all protected strings and binaries in a database. The encrypted data is stored in
a [File::KDBX::Safe](https://metacpan.org/pod/File%3A%3AKDBX%3A%3ASafe) associated with the database and the actual values will be replaced with `undef` to
indicate their protected state. Returns itself to allow method chaining.

You can call `lock` on an already-locked database to memory-protect any unprotected strings and binaries
added after the last time the database was locked.

## unlock

```
$kdbx->unlock;
```

Decrypt all protected strings and binaries in a database, replacing `undef` value placeholders with their
actual, unprotected values. Returns itself to allow method chaining.

## unlock\_scoped

```
$guard = $kdbx->unlock_scoped;
```

Unlock a database temporarily, relocking when the guard is released (typically at the end of a scope). Returns
`undef` if the database is already unlocked.

See ["lock"](#lock) and ["unlock"](#unlock).

Example:

```perl
{
    my $guard = $kdbx->unlock_scoped;
    ...;
}
# $kdbx is now memory-locked
```

## peek

```
$string = $kdbx->peek(\%string);
$string = $kdbx->peek(\%binary);
```

Peek at the value of a protected string or binary without unlocking the whole database. The argument can be
a string or binary hashref as returned by ["string" in File::KDBX::Entry](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AEntry#string) or ["binary" in File::KDBX::Entry](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AEntry#binary).

## is\_locked

```
$bool = $kdbx->is_locked;
```

Get whether or not a database's contents are in a locked (i.e. memory-protected) state. If this is true, then
some or all of the protected strings and binaries within the database will be unavailable (literally have
`undef` values) until ["unlock"](#unlock) is called.

## remove\_empty\_groups

```
$kdbx->remove_empty_groups;
```

Remove groups with no subgroups and no entries.

## remove\_unused\_icons

```perl
$kdbx->remove_unused_icons;
```

Remove icons that are not associated with any entry or group in the database.

## remove\_duplicate\_icons

```
$kdbx->remove_duplicate_icons;
```

Remove duplicate icons as determined by hashing the icon data.

## prune\_history

```
$kdbx->prune_history(%options);
```

Remove just as many older historical entries as necessary to get under certain limits.

- `max_items` - Maximum number of historical entries to keep (default: value of ["history\_max\_items"](#history_max_items), no limit: -1)
- `max_size` - Maximum total size (in bytes) of historical entries to keep (default: value of ["history\_max\_size"](#history_max_size), no limit: -1)
- `max_age` - Maximum age (in days) of historical entries to keep (default: 365, no limit: -1)

## randomize\_seeds

```
$kdbx->randomize_seeds;
```

Set various keys, seeds and IVs to random values. These values are used by the cryptographic functions that
secure the database when dumped. The attributes that will be randomized are:

- ["encryption\_iv"](#encryption_iv)
- ["inner\_random\_stream\_key"](#inner_random_stream_key)
- ["master\_seed"](#master_seed)
- ["stream\_start\_bytes"](#stream_start_bytes)
- ["transform\_seed"](#transform_seed)

Randomizing these values has no effect on a loaded database. These are only used when a database is dumped.
You normally do not need to call this method explicitly because the dumper does it explicitly by default.

## key

```
$key = $kdbx->key;
$key = $kdbx->key($key);
$key = $kdbx->key($primitive);
```

Get or set a [File::KDBX::Key](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AKey). This is the master key (e.g. a password or a key file that can decrypt
a database). You can also pass a primitive castable to a **Key**. See ["new" in File::KDBX::Key](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AKey#new) for an explanation
of what the primitive can be.

You generally don't need to call this directly because you can provide the key directly to the loader or
dumper when loading or dumping a KDBX file.

## composite\_key

```
$key = $kdbx->composite_key($key);
$key = $kdbx->composite_key($primitive);
```

Construct a [File::KDBX::Key::Composite](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AKey%3A%3AComposite) from a **Key** or primitive. See ["new" in File::KDBX::Key](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AKey#new) for an
explanation of what the primitive can be. If the primitive does not represent a composite key, it will be
wrapped.

You generally don't need to call this directly. The loader and dumper use it to transform a master key into
a raw encryption key.

## kdf

```
$kdf = $kdbx->kdf(%options);
$kdf = $kdbx->kdf(\%parameters, %options);
```

Get a [File::KDBX::KDF](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AKDF) (key derivation function).

Options:

- `params` - KDF parameters, same as `\%parameters` (default: value of ["kdf\_parameters"](#kdf_parameters))

## cipher

```perl
$cipher = $kdbx->cipher(key => $key);
$cipher = $kdbx->cipher(key => $key, iv => $iv, uuid => $uuid);
```

Get a [File::KDBX::Cipher](https://metacpan.org/pod/File%3A%3AKDBX%3A%3ACipher) capable of encrypting and decrypting the body of a database file.

A key is required. This should be a raw encryption key made up of a fixed number of octets (depending on the
cipher), not a [File::KDBX::Key](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AKey) or primitive.

If not passed, the UUID comes from `$kdbx->headers->{cipher_id}` and the encryption IV comes from
`$kdbx->headers->{encryption_iv}`.

You generally don't need to call this directly. The loader and dumper use it to decrypt and encrypt KDBX
files.

## random\_stream

```perl
$cipher = $kdbx->random_stream;
$cipher = $kdbx->random_stream(id => $stream_id, key => $key);
```

Get a [File::KDBX::Cipher::Stream](https://metacpan.org/pod/File%3A%3AKDBX%3A%3ACipher%3A%3AStream) for decrypting and encrypting protected values.

If not passed, the ID and encryption key comes from `$kdbx->headers->{inner_random_stream_id}` and
`$kdbx->headers->{inner_random_stream_key}` (respectively) for KDBX3 files and from
`$kdbx->inner_headers->{inner_random_stream_key}` and
`$kdbx->inner_headers->{inner_random_stream_id}` (respectively) for KDBX4 files.

You generally don't need to call this directly. The loader and dumper use it to scramble protected strings.

# RECIPES

## Create a new database

```perl
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
```

## Read an existing database

```perl
my $kdbx = File::KDBX->load_file('mypasswords.kdbx', 'master password CHANGEME');
$kdbx->unlock;  # cause $entry->password below to be defined

$kdbx->entries->each(sub {
    my ($entry) = @_;
    say 'Found password for: ', $entry->title;
    say '  Username: ', $entry->username;
    say '  Password: ', $entry->password;
});
```

## Search for entries

```perl
my @entries = $kdbx->entries(searching => 1)
    ->grep(title => 'WayneCorp')
    ->each;     # return all matches
```

The `searching` option limits results to only entries within groups with searching enabled. Other options are
also available. See ["entries"](#entries).

See ["QUERY"](#query) for many more query examples.

## Search for entries by auto-type window association

```perl
my $window_title = 'WayneCorp - Mozilla Firefox';

my $entries = $kdbx->entries(auto_type => 1)
    ->filter(sub {
        my ($ata) = grep { $_->{window} =~ /\Q$window_title\E/i } @{$_->auto_type_associations};
        return [$_, $ata->{keystroke_sequence}] if $ata;
    })
    ->each(sub {
        my ($entry, $keys) = @$_;
        say 'Entry title: ', $entry->title, ', key sequence: ', $keys;
    });
```

Example output:

```
Entry title: WayneCorp, key sequence: {PASSWORD}{ENTER}
```

## Remove entries from a database

```perl
$kdbx->entries
    ->grep(notes => {'=~' => qr/too old/i})
    ->each(sub { $_->recycle });
```

Recycle all entries with the string "too old" appearing in the **Notes** string.

## Remove empty groups

```perl
$kdbx->groups(algorithm => 'dfs')
    ->where(-true => 'is_empty')
    ->each('remove');
```

With the search/iteration `algorithm` set to "dfs", groups will be ordered deepest first and the root group
will be last. This allows removing groups that only contain empty groups.

This can also be done with one call to ["remove\_empty\_groups"](#remove_empty_groups).

# SECURITY

One of the biggest threats to your database security is how easily the encryption key can be brute-forced.
Strong brute-force protection depends on:

- Using unguessable passwords, passphrases and key files.
- Using a brute-force resistent key derivation function.

The first factor is up to you. This module does not enforce strong master keys. It is up to you to pick or
generate strong keys.

The KDBX format allows for the key derivation function to be tuned. The idea is that you want each single
brute-foce attempt to be expensive (in terms of time, CPU usage or memory usage), so that making a lot of
attempts (which would be required if you have a strong master key) gets _really_ expensive.

How expensive you want to make each attempt is up to you and can depend on the application.

This and other KDBX-related security issues are covered here more in depth:
[https://keepass.info/help/base/security.html](https://keepass.info/help/base/security.html)

Here are other security risks you should be thinking about:

## Cryptography

This distribution uses the excellent [CryptX](https://metacpan.org/pod/CryptX) and [Crypt::Argon2](https://metacpan.org/pod/Crypt%3A%3AArgon2) packages to handle all crypto-related
functions. As such, a lot of the security depends on the quality of these dependencies. Fortunately these
modules are maintained and appear to have good track records.

The KDBX format has evolved over time to incorporate improved security practices and cryptographic functions.
This package uses the following functions for authentication, hashing, encryption and random number
generation:

- AES-128 (legacy)
- AES-256
- Argon2d & Argon2id
- CBC block mode
- HMAC-SHA256
- SHA256
- SHA512
- Salsa20 & ChaCha20
- Twofish

At the time of this writing, I am not aware of any successful attacks against any of these functions. These
are among the most-analyzed and widely-adopted crypto functions available.

The KDBX format allows the body cipher and key derivation function to be configured. If a flaw is discovered
in one of these functions, you can hopefully just switch to a better function without needing to update this
software. A later software release may phase out the use of any functions which are no longer secure.

## Memory Protection

It is not a good idea to keep secret information unencrypted in system memory for longer than is needed. The
address space of your program can generally be read by a user with elevated privileges on the system. If your
system is memory-constrained or goes into a hibernation mode, the contents of your address space could be
written to a disk where it might be persisted for long time.

There might be system-level things you can do to reduce your risk, like using swap encryption and limiting
system access to your program's address space while your program is running.

**File::KDBX** helps minimize (but not eliminate) risk by keeping secrets encrypted in memory until accessed
and zeroing out memory that holds secrets after they're no longer needed, but it's not a silver bullet.

For one thing, the encryption key is stored in the same address space. If core is dumped, the encryption key
is available to be found out. But at least there is the chance that the encryption key and the encrypted
secrets won't both be paged out together while memory-constrained.

Another problem is that some perls (somewhat notoriously) copy around memory behind the scenes willy nilly,
and it's difficult know when perl makes a copy of a secret in order to be able to zero it out later. It might
be impossible. The good news is that perls with SvPV copy-on-write (enabled by default beginning with perl
5.20) are much better in this regard. With COW, it's mostly possible to know what operations will cause perl
to copy the memory of a scalar string, and the number of copies will be significantly reduced. There is a unit
test named `t/memory-protection.t` in this distribution that can be run on POSIX systems to determine how
well **File::KDBX** memory protection is working.

Memory protection also depends on how your application handles secrets. If your app code is handling scalar
strings with secret information, it's up to you to make sure its memory is zeroed out when no longer needed.
["erase" in File::KDBX::Util](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AUtil#erase) et al. provide some tools to help accomplish this. Or if you're not too concerned
about the risks memory protection is meant to mitigate, then maybe don't worry about it. The security policy
of **File::KDBX** is to try hard to keep secrets protected while in memory so that your app might claim a high
level of security, in case you care about that.

There are some memory protection strategies that **File::KDBX** does NOT use today but could in the future:

Many systems allow programs to mark unswappable pages. Secret information should ideally be stored in such
pages. You could potentially use [mlockall(2)](http://man.he.net/man2/mlockall) (or equivalent for your system) in your own application to
prevent the entire address space from being swapped.

Some systems provide special syscalls for storing secrets in memory while keeping the encryption key outside
of the program's address space, like `CryptProtectMemory` for Windows. This could be a good option, though
unfortunately not portable.

# QUERY

To find things in a KDBX database, you should use a filtered iterator. If you have an iterator, such as
returned by ["entries"](#entries), ["groups"](#groups) or even ["objects"](#objects) you can filter it using ["where" in File::KDBX::Iterator](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AIterator#where).

```perl
my $filtered_entries = $kdbx->entries->where(\&query);
```

A `\&query` is just a subroutine that you can either write yourself or have generated for you from either
a ["Simple Expression"](#simple-expression) or ["Declarative Syntax"](#declarative-syntax). It's easier to have your query generated, so I'll cover
that first.

## Simple Expression

A simple expression is mostly compatible with the KeePass 2 implementation
[described here](https://keepass.info/help/base/search.html#mode_se).

An expression is a string with one or more space-separated terms. Terms with spaces can be enclosed in double
quotes. Terms are negated if they are prefixed with a minus sign. A record must match every term on at least
one of the given fields.

So a simple expression is something like what you might type into a search engine. You can generate a simple
expression query using ["simple\_expression\_query" in File::KDBX::Util](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AUtil#simple_expression_query) or by passing the simple expression as
a **scalar reference** to `where`.

To search for all entries in a database with the word "canyon" appearing anywhere in the title:

```perl
my $entries = $kdbx->entries->where(\'canyon', qw[title]);
```

Notice the first argument is a **scalarref**. This disambiguates a simple expression from other types of
queries covered below.

As mentioned, a simple expression can have multiple terms. This simple expression query matches any entry that
has the words "red" **and** "canyon" anywhere in the title:

```perl
my $entries = $kdbx->entries->where(\'red canyon', qw[title]);
```

Each term in the simple expression must be found for an entry to match.

To search for entries with "red" in the title but **not** "canyon", just prepend "canyon" with a minus sign:

```perl
my $entries = $kdbx->entries->where(\'red -canyon', qw[title]);
```

To search over multiple fields simultaneously, just list them all. To search for entries with "grocery" (but
not "Foodland") in the title or notes:

```perl
my $entries = $kdbx->entries->where(\'grocery -Foodland', qw[title notes]);
```

The default operator is a case-insensitive regexp match, which is fine for searching text loosely. You can use
just about any binary comparison operator that perl supports. To specify an operator, list it after the simple
expression. For example, to search for any entry that has been used at least five times:

```perl
my $entries = $kdbx->entries->where(\5, '>=', qw[usage_count]);
```

It helps to read it right-to-left, like "usage\_count is greater than or equal to 5".

If you find the disambiguating structures to be distracting or confusing, you can also the
["simple\_expression\_query" in File::KDBX::Util](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AUtil#simple_expression_query) function as a more intuitive alternative. The following example is
equivalent to the previous:

```perl
my $entries = $kdbx->entries->where(simple_expression_query(5, '>=', qw[usage_count]));
```

## Declarative Syntax

Structuring a declarative query is similar to ["WHERE CLAUSES" in SQL::Abstract](https://metacpan.org/pod/SQL%3A%3AAbstract#WHERE-CLAUSES), but you don't have to be
familiar with that module. Just learn by examples here.

To search for all entries in a database titled "My Bank":

```perl
my $entries = $kdbx->entries->where({ title => 'My Bank' });
```

The query here is `{ title => 'My Bank' }`. A hashref can contain key-value pairs where the key is an
attribute of the thing being searched for (in this case an entry) and the value is what you want the thing's
attribute to be to consider it a match. In this case, the attribute we're using as our match criteria is
["title" in File::KDBX::Entry](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AEntry#title), a text field. If an entry has its title attribute equal to "My Bank", it's
a match.

A hashref can contain multiple attributes. The search candidate will be a match if _all_ of the specified
attributes are equal to their respective values. For example, to search for all entries with a particular URL
**AND** username:

```perl
my $entries = $kdbx->entries->where({
    url      => 'https://example.com',
    username => 'neo',
});
```

To search for entries matching _any_ criteria, just change the hashref to an arrayref. To search for entries
with a particular URL **OR** username:

```perl
my $entries = $kdbx->entries->where([ # <-- Notice the square bracket
    url      => 'https://example.com',
    username => 'neo',
]);
```

You can use different operators to test different types of attributes. The ["icon\_id" in File::KDBX::Entry](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AEntry#icon_id)
attribute is a number, so we should use a number comparison operator. To find entries using the smartphone
icon:

```perl
my $entries = $kdbx->entries->where({
    icon_id => { '==', ICON_SMARTPHONE },
});
```

Note: ["ICON\_SMARTPHONE" in File::KDBX::Constants](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AConstants#ICON_SMARTPHONE) is just a constant from [File::KDBX::Constants](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AConstants). It isn't
special to this example or to queries generally. We could have just used a literal number.

The important thing to notice here is how we wrapped the condition in another arrayref with a single key-value
pair where the key is the name of an operator and the value is the thing to match against. The supported
operators are:

- `eq` - String equal
- `ne` - String not equal
- `lt` - String less than
- `gt` - String greater than
- `le` - String less than or equal
- `ge` - String greater than or equal
- `==` - Number equal
- `!=` - Number not equal
- `<` - Number less than
- `>` - Number greater than
- `<=` - Number less than or equal
- `>=` - Number less than or equal
- `=~` - String match regular expression
- `!~` - String does not match regular expression
- `!` - Boolean false
- `!!` - Boolean true

Other special operators:

- `-true` - Boolean true
- `-false` - Boolean false
- `-not` - Boolean false (alias for `-false`)
- `-defined` - Is defined
- `-undef` - Is not defined
- `-empty` - Is empty
- `-nonempty` - Is not empty
- `-or` - Logical or
- `-and` - Logical and

Let's see another example using an explicit operator. To find all groups except one in particular (identified
by its ["uuid" in File::KDBX::Group](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AGroup#uuid)), we can use the `ne` (string not equal) operator:

```perl
my $groups = $kdbx->groups->where(
    uuid => {
        'ne' => uuid('596f7520-6172-6520-7370-656369616c2e'),
    },
);
```

Note: ["uuid" in File::KDBX::Util](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AUtil#uuid) is a little utility function to convert a UUID in its pretty form into bytes.
This utility function isn't special to this example or to queries generally. It could have been written with
a literal such as `"\x59\x6f\x75\x20\x61..."`, but that's harder to read.

Notice we searched for groups this time. Finding groups works exactly the same as it does for entries.

Notice also that we didn't wrap the query in hashref curly-braces or arrayref square-braces. Those are
optional. By default it will only match ALL attributes (as if there were curly-braces).

Testing the truthiness of an attribute is a little bit different because it isn't a binary operation. To find
all entries with the password quality check disabled:

```perl
my $entries = $kdbx->entries->where('!' => 'quality_check');
```

This time the string after the operator is the attribute name rather than a value to compare the attribute
against. To test that a boolean value is true, use the `!!` operator (or `-true` if `!!` seems a little too
weird for your taste):

```perl
my $entries = $kdbx->entries->where('!!'  => 'quality_check');
my $entries = $kdbx->entries->where(-true => 'quality_check');  # same thing
```

Yes, there is also a `-false` and a `-not` if you prefer one of those over `!`. `-false` and `-not`
(along with `-true`) are also special in that you can use them to invert the logic of a subquery. These are
logically equivalent:

```perl
my $entries = $kdbx->entries->where(-not => { title => 'My Bank' });
my $entries = $kdbx->entries->where(title => { 'ne' => 'My Bank' });
```

These special operators become more useful when combined with two more special operators: `-and` and `-or`.
With these, it is possible to construct more interesting queries with groups of logic. For example:

```perl
my $entries = $kdbx->entries->where({
    title   => { '=~', qr/bank/ },
    -not    => {
        -or     => {
            notes   => { '=~', qr/business/ },
            icon_id => { '==', ICON_TRASHCAN_FULL },
        },
    },
});
```

In English, find entries where the word "bank" appears anywhere in the title but also do not have either the
word "business" in the notes or are using the full trashcan icon.

## Subroutine Query

Lastly, as mentioned at the top, you can ignore all this and write your own subroutine. Your subroutine will
be called once for each object being searched over. The subroutine should match the candidate against whatever
criteria you want and return true if it matches or false to skip. To do this, just pass your subroutine
coderef to `where`.

To review the different types of queries, these are all equivalent to find all entries in the database titled
"My Bank":

```perl
my $entries = $kdbx->entries->where(\'"My Bank"', 'eq', qw[title]);     # simple expression
my $entries = $kdbx->entries->where(title => 'My Bank');                # declarative syntax
my $entries = $kdbx->entries->where(sub { $_->title eq 'My Bank' });    # subroutine query
```

This is a trivial example, but of course your subroutine can be arbitrarily complex.

All of these query mechanisms described in this section are just tools, each with its own set of limitations.
If the tools are getting in your way, you can of course iterate over the contents of a database and implement
your own query logic, like this:

```perl
my $entries = $kdbx->entries;
while (my $entry = $entries->next) {
    if (wanted($entry)) {
        do_something($entry);
    }
    else {
        ...
    }
}
```

## Iteration

Iterators are the built-in way to navigate or walk the database tree. You get an iterator from ["entries"](#entries),
["groups"](#groups) and ["objects"](#objects). You can specify the search algorithm to iterate over objects in different orders
using the `algorithm` option, which can be one of these [constants](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AConstants#iteration):

- `ITERATION_IDS` - Iterative deepening search (default)
- `ITERATION_DFS` - Depth-first search
- `ITERATION_BFS` - Breadth-first search

When iterating over objects generically, groups always precede their direct entries (if any). When the
`history` option is used, current entries always precede historical entries.

If you have a database tree like this:

```
Database
- Root
    - Group1
        - EntryA
        - Group2
            - EntryB
    - Group3
        - EntryC
```

- IDS order of groups is: Root, Group1, Group2, Group3
- IDS order of entries is: EntryA, EntryB, EntryC
- IDS order of objects is: Root, Group1, EntryA, Group2, EntryB, Group3, EntryC
- DFS order of groups is: Group2, Group1, Group3, Root
- DFS order of entries is: EntryB, EntryA, EntryC
- DFS order of objects is: Group2, EntryB, Group1, EntryA, Group3, EntryC, Root
- BFS order of groups is: Root, Group1, Group3, Group2
- BFS order of entries is: EntryA, EntryC, EntryB
- BFS order of objects is: Root, Group1, EntryA, Group3, EntryC, Group2, EntryB

# SYNCHRONIZING

**TODO** - This is a planned feature, not yet implemented.

# ERRORS

Errors in this package are constructed as [File::KDBX::Error](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AError) objects and propagated using perl's built-in
mechanisms. Fatal errors are propagated using ["die LIST" in perlfunc](https://metacpan.org/pod/perlfunc#die-LIST) and non-fatal errors (a.k.a. warnings)
are propagated using ["warn LIST" in perlfunc](https://metacpan.org/pod/perlfunc#warn-LIST) while adhering to perl's [warnings](https://metacpan.org/pod/warnings) system. If you're already
familiar with these mechanisms, you can skip this section.

You can catch fatal errors using ["eval BLOCK" in perlfunc](https://metacpan.org/pod/perlfunc#eval-BLOCK) (or something like [Try::Tiny](https://metacpan.org/pod/Try%3A%3ATiny)) and non-fatal
errors using `$SIG{__WARN__}` (see ["%SIG" in perlvar](https://metacpan.org/pod/perlvar#SIG)). Examples:

```perl
use File::KDBX::Error qw(error);

my $key = '';   # uh oh
eval {
    $kdbx->load_file('whatever.kdbx', $key);
};
if (my $error = error($@)) {
    handle_missing_key($error) if $error->type eq 'key.missing';
    $error->throw;
}
```

or using `Try::Tiny`:

```perl
try {
    $kdbx->load_file('whatever.kdbx', $key);
}
catch {
    handle_error($_);
};
```

Catching non-fatal errors:

```perl
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, $_[0] };

$kdbx->load_file('whatever.kdbx', $key);

handle_warnings(@warnings) if @warnings;
```

By default perl prints warnings to `STDERR` if you don't catch them. If you don't want to catch them and also
don't want them printed to `STDERR`, you can suppress them lexically (perl v5.28 or higher required):

```
{
    no warnings 'File::KDBX';
    ...
}
```

or locally:

```
{
    local $File::KDBX::WARNINGS = 0;
    ...
}
```

or globally in your program:

```
$File::KDBX::WARNINGS = 0;
```

You cannot suppress fatal errors, and if you don't catch them your program will exit.

# ENVIRONMENT

This software will alter its behavior depending on the value of certain environment variables:

- `PERL_FILE_KDBX_XS` - Do not use [File::KDBX::XS](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AXS) if false (default: true)
- `PERL_ONLY` - Do not use [File::KDBX::XS](https://metacpan.org/pod/File%3A%3AKDBX%3A%3AXS) if true (default: false)
- `NO_FORK` - Do not fork if true (default: false)

# SEE ALSO

- [KeePass Password Safe](https://keepass.info/) - The original KeePass
- [KeePassXC](https://keepassxc.org/) - Cross-Platform Password Manager written in C++
- [File::KeePass](https://metacpan.org/pod/File%3A%3AKeePass) has overlapping functionality. It's good but has a backlog of some pretty critical bugs and lacks support for newer KDBX features.

# BUGS

Please report any bugs or feature requests on the bugtracker website
[https://github.com/chazmcgarvey/File-KDBX/issues](https://github.com/chazmcgarvey/File-KDBX/issues)

When submitting a bug or request, please include a test-file or a
patch to an existing test-file that illustrates the bug or desired
feature.

# AUTHOR

Charles McGarvey <ccm@cpan.org>

# COPYRIGHT AND LICENSE

This software is copyright (c) 2022 by Charles McGarvey.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.
