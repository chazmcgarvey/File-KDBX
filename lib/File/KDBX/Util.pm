package File::KDBX::Util;
# ABSTRACT: Utility functions for working with KDBX files

use warnings;
use strict;

use Crypt::PRNG qw(random_bytes random_string);
use Encode qw(decode encode);
use Exporter qw(import);
use File::KDBX::Constants qw(:bool);
use File::KDBX::Error;
use List::Util 1.33 qw(any all);
use Module::Load;
use Ref::Util qw(is_arrayref is_coderef is_hashref is_ref is_refref is_scalarref);
use Scalar::Util qw(blessed looks_like_number readonly);
use Time::Piece;
use boolean;
use namespace::clean -except => 'import';

our $VERSION = '999.999'; # VERSION

our %EXPORT_TAGS = (
    assert      => [qw(DEBUG assert assert_64bit)],
    class       => [qw(extends has list_attributes)],
    clone       => [qw(clone clone_nomagic)],
    coercion    => [qw(to_bool to_number to_string to_time to_tristate to_uuid)],
    crypt       => [qw(pad_pkcs7)],
    debug       => [qw(DEBUG dumper)],
    fork        => [qw(can_fork)],
    function    => [qw(memoize recurse_limit)],
    empty       => [qw(empty nonempty)],
    erase       => [qw(erase erase_scoped)],
    gzip        => [qw(gzip gunzip)],
    io          => [qw(is_readable is_writable read_all)],
    load        => [qw(load_optional load_xs try_load_optional)],
    search      => [qw(query search simple_expression_query)],
    text        => [qw(snakify trim)],
    uuid        => [qw(format_uuid generate_uuid is_uuid uuid UUID_NULL)],
    uri         => [qw(split_url uri_escape_utf8 uri_unescape_utf8)],
);

$EXPORT_TAGS{all} = [map { @$_ } values %EXPORT_TAGS];
our @EXPORT_OK = @{$EXPORT_TAGS{all}};

BEGIN {
    my $debug = $ENV{DEBUG};
    $debug = looks_like_number($debug) ? (0 + $debug) : ($debug ? 1 : 0);
    *DEBUG = $debug == 1 ? sub() { 1 } :
             $debug == 2 ? sub() { 2 } :
             $debug == 3 ? sub() { 3 } :
             $debug == 4 ? sub() { 4 } : sub() { 0 };
}

my %OPS = (
    'eq'        =>  2, # binary
    'ne'        =>  2,
    'lt'        =>  2,
    'gt'        =>  2,
    'le'        =>  2,
    'ge'        =>  2,
    '=='        =>  2,
    '!='        =>  2,
    '<'         =>  2,
    '>'         =>  2,
    '<='        =>  2,
    '>='        =>  2,
    '=~'        =>  2,
    '!~'        =>  2,
    '!'         =>  1, # unary
    '!!'        =>  1,
    '-not'      =>  1, # special
    '-false'    =>  1,
    '-true'     =>  1,
    '-defined'  =>  1,
    '-undef'    =>  1,
    '-empty'    =>  1,
    '-nonempty' =>  1,
    '-or'       => -1,
    '-and'      => -1,
);
my %OP_NEG = (
    'eq'    =>  'ne',
    'ne'    =>  'eq',
    'lt'    =>  'ge',
    'gt'    =>  'le',
    'le'    =>  'gt',
    'ge'    =>  'lt',
    '=='    =>  '!=',
    '!='    =>  '==',
    '<'     =>  '>=',
    '>'     =>  '<=',
    '<='    =>  '>',
    '>='    =>  '<',
    '=~'    =>  '!~',
    '!~'    =>  '=~',
);
my %ATTRIBUTES;

=func load_xs

    $bool = load_xs();
    $bool = load_xs($version);

Attempt to load L<File::KDBX::XS>. Return truthy if C<XS> is loaded. If C<$version> is given, it will check
that at least the given version is loaded.

=cut

my $XS_LOADED;
sub load_xs {
    my $version = shift;

    goto IS_LOADED if defined $XS_LOADED;

    if ($ENV{PERL_ONLY} || (exists $ENV{PERL_FILE_KDBX_XS} && !$ENV{PERL_FILE_KDBX_XS})) {
        return $XS_LOADED = FALSE;
    }

    $XS_LOADED = !!eval { require File::KDBX::XS; 1 };

    IS_LOADED:
    {
        local $@;
        return $XS_LOADED if !$version;
        return !!eval { File::KDBX::XS->VERSION($version); 1 };
    }
}

=func assert

    assert { ... };

Write an executable comment. Only executed if C<DEBUG> is set in the environment.

=cut

sub assert(&) { ## no critic (ProhibitSubroutinePrototypes)
    return if !DEBUG;
    my $code = shift;
    return if $code->();

    (undef, my $file, my $line) = caller;
    $file =~ s!([^/\\]+)$!$1!;
    my $assertion = '';
    if (try_load_optional('B::Deparse')) {
        my $deparse = B::Deparse->new(qw{-P -x9});
        $assertion = $deparse->coderef2text($code);
        $assertion =~ s/^\{(?:\s*(?:package[^;]+|use[^;]+);)*\s*(.*?);\s*\}$/$1/s;
        $assertion =~ s/\s+/ /gs;
        $assertion = ": $assertion";
    }
    die "$0: $file:$line: Assertion failed$assertion\n";
}

=func assert_64bit

    assert_64bit();

Throw if perl doesn't support 64-bit IVs.

=cut

sub assert_64bit() {
    require Config;
    $Config::Config{ivsize} < 8
        and throw "64-bit perl is required to use this feature.\n", ivsize => $Config::Config{ivsize};
}

=func can_fork

    $bool = can_fork;

Determine if perl can fork, with logic lifted from L<Test2::Util/CAN_FORK>.

=cut

sub can_fork {
    require Config;
    return 1 if $Config::Config{d_fork};
    return 0 if $^O ne 'MSWin32' && $^O ne 'NetWare';
    return 0 if !$Config::Config{useithreads};
    return 0 if $Config::Config{ccflags} !~ /-DPERL_IMPLICIT_SYS/;
    return 0 if $] < 5.008001;
    if ($] == 5.010000 && $Config::Config{ccname} eq 'gcc' && $Config::Config{gccversion}) {
        return 0 if $Config::Config{gccversion} !~ m/^(\d+)\.(\d+)/;
        my @parts = split(/[\.\s]+/, $Config::Config{gccversion});
        return 0 if $parts[0] > 4 || ($parts[0] == 4 && $parts[1] >= 8);
    }
    return 0 if $INC{'Devel/Cover.pm'};
    return 1;
}

=func clone

    $clone = clone($thing);

Clone deeply. This is an unadorned alias to L<Storable> C<dclone>.

=cut

sub clone {
    require Storable;
    goto &Storable::dclone;
}

=func clone_nomagic

    $clone = clone_nomagic($thing);

Clone deeply without keeping [most of] the magic.

B<WARNING:> At the moment the implementation is naïve and won't respond well to nontrivial data or recursive
structures.

=cut

sub clone_nomagic {
    my $thing = shift;
    if (is_arrayref($thing)) {
        my @arr = map { clone_nomagic($_) } @$thing;
        return \@arr;
    }
    elsif (is_hashref($thing)) {
        my %hash;
        $hash{$_} = clone_nomagic($thing->{$_}) for keys %$thing;
        return \%hash;
    }
    elsif (is_ref($thing)) {
        return clone($thing);
    }
    return $thing;
}

=func dumper

    $str = dumper $thing;
    dumper $thing;  # in void context, prints to STDERR

Like L<Data::Dumper> but slightly terser in some cases relevent to L<File::KDBX>.

=cut

sub dumper {
    require Data::Dumper;
    # avoid "once" warnings
    local $Data::Dumper::Deepcopy = $Data::Dumper::Deepcopy = 1;
    local $Data::Dumper::Deparse = $Data::Dumper::Deparse = 1;
    local $Data::Dumper::Indent = 1;
    local $Data::Dumper::Quotekeys = 0;
    local $Data::Dumper::Sortkeys = 1;
    local $Data::Dumper::Terse = 1;
    local $Data::Dumper::Trailingcomma = 1;
    local $Data::Dumper::Useqq = 1;

    my @dumps;
    for my $struct (@_) {
        my $str = Data::Dumper::Dumper($struct);

        # boolean
        $str =~ s/bless\( do\{\\\(my \$o = ([01])\)\}, 'boolean' \)/boolean($1)/gs;
        # Time::Piece
        $str =~ s/bless\([^\)]+?(\d+)'?,\s+\d+,?\s+\], 'Time::Piece' \),/
            "scalar gmtime($1), # " . scalar gmtime($1)->datetime/ges;

        print STDERR $str if !defined wantarray;
        push @dumps, $str;
        return $str;
    }
    return join("\n", @dumps);
}

=func empty

=func nonempty

    $bool = empty $thing;

    $bool = nonempty $thing;

Test whether a thing is empty (or nonempty). An empty thing is one of these:

=for :list
* nonexistent
* C<undef>
* zero-length string
* zero-length array
* hash with zero keys
* reference to an empty thing (recursive)

Note in particular that zero C<0> is not considered empty because it is an actual value.

=cut

sub empty    {  _empty(@_) }
sub nonempty { !_empty(@_) }

sub _empty {
    return 1 if @_ == 0;
    local $_ = shift;
    return !defined $_
        || $_ eq ''
        || (is_arrayref($_)  && @$_ == 0)
        || (is_hashref($_)   && keys %$_ == 0)
        || (is_scalarref($_) && (!defined $$_ || $$_ eq ''))
        || (is_refref($_)    && _empty($$_));
}

=func erase

    erase($string, ...);
    erase(\$string, ...);

Overwrite the memory used by one or more string.

=cut

BEGIN {
    if (load_xs) {
        *_CowREFCNT = \&File::KDBX::XS::CowREFCNT;
    }
    elsif (eval { require B::COW; 1 }) {
        *_CowREFCNT = \&B::COW::cowrefcnt;
    }
    else {
        *_CowREFCNT = sub { undef };
    }
}

sub erase {
    # Only bother zeroing out memory if we have the last SvPV COW reference, otherwise we'll end up just
    # creating a copy and erasing the copy.
    # TODO - Is this worth doing? Need some benchmarking.
    for (@_) {
        if (!is_ref($_)) {
            next if !defined $_ || readonly $_;
            my $cowrefcnt = _CowREFCNT($_);
            goto FREE_NONREF if defined $cowrefcnt && 1 < $cowrefcnt;
            # if (__PACKAGE__->can('erase_xs')) {
            #     erase_xs($_);
            # }
            # else {
                substr($_, 0, length($_), "\0" x length($_));
            # }
            FREE_NONREF: {
                no warnings 'uninitialized';
                undef $_;
            }
        }
        elsif (is_scalarref($_)) {
            next if !defined $$_ || readonly $$_;
            my $cowrefcnt = _CowREFCNT($$_);
            goto FREE_REF if defined $cowrefcnt && 1 < $cowrefcnt;
            # if (__PACKAGE__->can('erase_xs')) {
            #     erase_xs($$_);
            # }
            # else {
                substr($$_, 0, length($$_), "\0" x length($$_));
            # }
            FREE_REF: {
                no warnings 'uninitialized';
                undef $$_;
            }
        }
        elsif (is_arrayref($_)) {
            erase(@$_);
            @$_ = ();
        }
        elsif (is_hashref($_)) {
            erase(values %$_);
            %$_ = ();
        }
        else {
            throw 'Cannot erase this type of scalar', type => ref $_, what => $_;
        }
    }
}

=func erase_scoped

    $scope_guard = erase_scoped($string, ...);
    $scope_guard = erase_scoped(\$string, ...);
    undef $scope_guard; # erase happens here

Get a scope guard that will cause scalars to be erased later (i.e. when the scope ends). This is useful if you
want to make sure a string gets erased after you're done with it, even if the scope ends abnormally.

See L</erase>.

=cut

sub erase_scoped {
    throw 'Programmer error: Cannot call erase_scoped in void context' if !defined wantarray;
    my @args;
    for (@_) {
        !is_ref($_) || is_arrayref($_) || is_hashref($_) || is_scalarref($_)
            or throw 'Cannot erase this type of scalar', type => ref $_, what => $_;
        push @args, is_ref($_) ? $_ : \$_;
    }
    require Scope::Guard;
    return Scope::Guard->new(sub { erase(@args) });
}

=func extends

    extends $class;

Set up the current module to inheret from another module.

=cut

sub extends {
    my $parent  = shift;
    my $caller  = caller;
    load $parent;
    no strict 'refs'; ## no critic (ProhibitNoStrict)
    @{"${caller}::ISA"} = $parent;
}

=func has

    has $name => %options;

Create an attribute getter/setter. Possible options:

=for :list
* C<is> - Either "rw" (default) or "ro"
* C<default> - Default value
* C<coerce> - Coercive function

=cut

sub has {
    my $name = shift;
    my %args = @_ % 2 == 1 ? (default => shift, @_) : @_;

    my ($package, $file, $line) = caller;

    my $d = $args{default};
    my $default = is_arrayref($d) ? sub { [@$d] } : is_hashref($d) ? sub { +{%$d} } : $d;
    my $coerce  = $args{coerce};
    my $is      = $args{is} || 'rw';

    my $store = $args{store};
    ($store, $name) = split(/\./, $name, 2) if $name =~ /\./;
    push @{$ATTRIBUTES{$package} //= []}, $name;

    my $store_code = '';
    $store_code = qq{->$store} if $store;
    my $member = qq{\$_[0]$store_code\->{'$name'}};

    my $default_code = is_coderef $default ? q{scalar $default->($_[0])}
                        : defined $default ? q{$default}
                                           : q{undef};
    my $get = qq{$member //= $default_code;};

    my $set = '';
    if ($is eq 'rw') {
        $set = is_coderef $coerce ? qq{$member = scalar \$coerce->(\@_[1..\$#_]) if \$#_;}
                : defined $coerce ? qq{$member = do { local @_ = (\@_[1..\$#_]); $coerce } if \$#_;}
                                  : qq{$member = \$_[1] if \$#_;};
    }

    $line -= 4;
    my $code = <<END;
# line $line "$file"
sub ${package}::${name} {
    return $default_code if !Scalar::Util::blessed(\$_[0]);
    $set
    $get
}
END
    eval $code; ## no critic (ProhibitStringyEval)
}

=func format_uuid

    $string_uuid = format_uuid($raw_uuid);
    $string_uuid = format_uuid($raw_uuid, $delimiter);

Format a 128-bit UUID (given as a string of 16 octets) into a hexidecimal string, optionally with a delimiter
to break up the UUID visually into five parts. Examples:

    my $uuid = uuid('01234567-89AB-CDEF-0123-456789ABCDEF');
    say format_uuid($uuid);         # -> 0123456789ABCDEF0123456789ABCDEF
    say format_uuid($uuid, '-');    # -> 01234567-89AB-CDEF-0123-456789ABCDEF

This is the inverse of L</uuid>.

=cut

sub format_uuid {
    local $_    = shift // "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0";
    my $delim   = shift // '';
    length($_) == 16 or throw 'Must provide a 16-bytes UUID', size => length($_), str => $_;
    return uc(join($delim, unpack('H8 H4 H4 H4 H12', $_)));
}

=func generate_uuid

    $uuid = generate_uuid;
    $uuid = generate_uuid(\%set);
    $uuid = generate_uuid(\&test_uuid);

Generate a new random UUID. It's pretty unlikely that this will generate a repeat, but if you're worried about
that you can provide either a set of existing UUIDs (as a hashref where the keys are the elements of a set) or
a function to check for existing UUIDs, and this will be sure to not return a UUID already in provided set.
Perhaps an example will make it clear:

    my %uuid_set = (
        uuid('12345678-9ABC-DEFG-1234-56789ABCDEFG') => 'whatever',
    );
    $uuid = generate_uuid(\%uuid_set);
    # OR
    $uuid = generate_uuid(sub { !$uuid_set{$_} });

Here, C<$uuid> can't be "12345678-9ABC-DEFG-1234-56789ABCDEFG". This example uses L</uuid> to easily pack
a 16-byte UUID from a literal, but it otherwise is not a consequential part of the example.

=cut

sub generate_uuid {
    my $set  = @_ % 2 == 1 ? shift : undef;
    my %args = @_;
    my $test = $set //= $args{test};
    $test   = sub { !$set->{$_} } if is_hashref($test);
    $test //= sub { 1 };
    my $printable = $args{printable} // $args{print};
    local $_ = '';
    do {
        $_ = $printable ? random_string(16) : random_bytes(16);
    } while (!$test->($_));
    return $_;
}

=func gunzip

    $unzipped = gunzip($string);

Decompress an octet stream.

=cut

sub gunzip {
    load_optional('Compress::Raw::Zlib');
    local $_ = shift;
    my ($i, $status) = Compress::Raw::Zlib::Inflate->new(-WindowBits => 31);
    $status == Compress::Raw::Zlib::Z_OK()
        or throw 'Failed to initialize compression library', status => $status;
    $status = $i->inflate($_, my $out);
    $status == Compress::Raw::Zlib::Z_STREAM_END()
        or throw 'Failed to decompress data', status => $status;
    return $out;
}

=func gzip

    $zipped = gzip($string);

Compress an octet stream.

=cut

sub gzip {
    load_optional('Compress::Raw::Zlib');
    local $_ = shift;
    my ($d, $status) = Compress::Raw::Zlib::Deflate->new(-WindowBits => 31, -AppendOutput => 1);
    $status == Compress::Raw::Zlib::Z_OK()
        or throw 'Failed to initialize compression library', status => $status;
    $status = $d->deflate($_, my $out);
    $status == Compress::Raw::Zlib::Z_OK()
        or throw 'Failed to compress data', status => $status;
    $status = $d->flush($out);
    $status == Compress::Raw::Zlib::Z_OK()
        or throw 'Failed to compress data', status => $status;
    return $out;
}

=func is_readable

=func is_writable

    $bool = is_readable($mode);
    $bool = is_writable($mode);

Determine of an C<fopen>-style mode is readable, writable or both.

=cut

sub is_readable { $_[0] !~ /^[aw]b?$/ }
sub is_writable { $_[0] !~ /^rb?$/ }

=func is_uuid

    $bool = is_uuid($thing);

Check if a thing is a UUID (i.e. scalar string of length 16).

=cut

sub is_uuid { defined $_[0] && !is_ref($_[0]) && length($_[0]) == 16 }

=func list_attributes

    @attributes = list_attributes($package);

Get a list of attributes for a class.

=cut

sub list_attributes {
    my $package = shift;
    return @{$ATTRIBUTES{$package} // []};
}

=func load_optional

    $package = load_optional($package);

Load a module that isn't required but can provide extra functionality. Throw if the module is not available.

=cut

sub load_optional {
    for my $module (@_) {
        eval { load $module };
        if (my $err = $@) {
            throw "Missing dependency: Please install $module to use this feature.\n",
                module  => $module,
                error   => $err;
        }
    }
    return wantarray ? @_ : $_[0];
}

=func memoize

    \&memoized_code = memoize(\&code, ...);

Memoize a function. Extra arguments are passed through to C<&code> when it is called.

=cut

sub memoize {
    my $func = shift;
    my @args = @_;
    my %cache;
    return sub { $cache{join("\0", grep { defined } @_)} //= $func->(@args, @_) };
}

=func pad_pkcs7

    $padded_string = pad_pkcs7($string, $block_size),

Pad a block using the PKCS#7 method.

=cut

sub pad_pkcs7 {
    my $data = shift // throw 'Must provide a string to pad';
    my $size = shift or throw 'Must provide block size';

    0 <= $size && $size < 256
        or throw 'Cannot add PKCS7 padding to a large block size', size => $size;

    my $pad_len = $size - length($data) % $size;
    $data .= chr($pad_len) x $pad_len;
}

=func query

    $query = query(@where);
    $query->(\%data);

Generate a function that will run a series of tests on a passed hashref and return true or false depending on
if the data record in the hash matched the specified logic.

The logic can be specified in a manner similar to L<SQL::Abstract/"WHERE CLAUSES"> which was the inspiration
for this function, but this code is distinct, supporting an overlapping but not identical feature set and
having its own bugs.

See L<File::KDBX/QUERY> for examples.

=cut

sub query { _query(undef, '-or', \@_) }

=func read_all

    $size = read_all($fh, my $buffer, $size);
    $size = read_all($fh, my $buffer, $size, $offset);

Like L<functions/read> but returns C<undef> if not all C<$size> bytes are read. This is considered an error,
distinguishable from other errors by C<$!> not being set.

=cut

sub read_all($$$;$) { ## no critic (ProhibitSubroutinePrototypes)
    my $result = @_ == 3 ? read($_[0], $_[1], $_[2])
                         : read($_[0], $_[1], $_[2], $_[3]);
    return if !defined $result;
    return if $result != $_[2];
    return $result;
}

=func recurse_limit

    \&limited_code = recurse_limit(\&code);
    \&limited_code = recurse_limit(\&code, $max_depth);
    \&limited_code = recurse_limit(\&code, $max_depth, \&error_handler);

Wrap a function with a guard to prevent deep recursion.

=cut

sub recurse_limit {
    my $func        = shift;
    my $max_depth   = shift // 200;
    my $error       = shift // sub {};
    my $depth = 0;
    return sub { return $error->(@_) if $max_depth < ++$depth; $func->(@_) };
};

=func search

    # Generate a query on-the-fly:
    \@matches = search(\@records, @where);

    # Use a pre-compiled query:
    $query = query(@where);
    \@matches = search(\@records, $query);

    # Use a simple expression:
    \@matches = search(\@records, \'query terms', @fields);
    \@matches = search(\@records, \'query terms', $operator, @fields);

    # Use your own subroutine:
    \@matches = search(\@records, \&query);
    \@matches = search(\@records, sub { $record = shift; ... });

Execute a linear search over an array of records using a L</query>. A "record" is usually a hash.

This is the search engine described with many examples at L<File::KDBX/QUERY>.

=cut

sub search {
    my $list    = shift;
    my $query   = shift;

    if (is_coderef($query) && !@_) {
        # already a query
    }
    elsif (is_scalarref($query)) {
        $query = simple_expression_query($$query, @_);
    }
    else {
        $query = query($query, @_);
    }

    my @match;
    for my $item (@$list) {
        push @match, $item if $query->($item);
    }
    return \@match;
}

=func simple_expression_query

    $query = simple_expression_query($expression, @fields);
    $query = simple_expression_query($expression, $operator, @fields);

Generate a query, like L</query>, to be used with L</search> but built from a "simple expression" as
L<described here|https://keepass.info/help/base/search.html#mode_se>.

An expression is a string with one or more space-separated terms. Terms with spaces can be enclosed in double
quotes. Terms are negated if they are prefixed with a minus sign. A record must match every term on at least
one of the given fields.

=cut

sub simple_expression_query {
    my $expr = shift;
    my $op   = @_ && ($OPS{$_[0] || ''} || 0) == 2 ? shift : '=~';

    my $neg_op = $OP_NEG{$op};
    my $is_re  = $op eq '=~' || $op eq '!~';

    require Text::ParseWords;
    my @terms = Text::ParseWords::shellwords($expr);

    my @query = qw(-and);

    for my $term (@terms) {
        my @subquery = qw(-or);

        my $neg = $term =~ s/^-//;
        my $condition = [($neg ? $neg_op : $op) => ($is_re ? qr/\Q$term\E/i : $term)];

        for my $field (@_) {
            push @subquery, $field => $condition;
        }

        push @query, \@subquery;
    }

    return query(\@query);
}

=func snakify

    $string = snakify($string);

Turn a CamelCase string into snake_case.

=cut

sub snakify {
    local $_ = shift;
    s/UserName/Username/g;
    s/([a-z])([A-Z0-9])/${1}_${2}/g;
    s/([A-Z0-9]+)([A-Z0-9])(?![A-Z0-9]|$)/${1}_${2}/g;
    return lc($_);
}

=func split_url

    ($scheme, $auth, $host, $port, $path, $query, $hash, $usename, $password) = split_url($url);

Split a URL into its parts.

For example, C<http://user:pass@localhost:4000/path?query#hash> gets split like:

=for :list
* C<http>
* C<user:pass>
* C<host>
* C<4000>
* C</path>
* C<?query>
* C<#hash>
* C<user>
* C<pass>

=cut

sub split_url {
    local $_ = shift;
    my ($scheme, $auth, $host, $port, $path, $query, $hash) =~ m!
        ^([^:/\?\#]+) ://
        (?:([^\@]+)\@)
        ([^:/\?\#]*)
        (?::(\d+))?
        ([^\?\#]*)
        (\?[^\#]*)?
        (\#(.*))?
    !x;

    $scheme = lc($scheme);

    $host ||= 'localhost';
    $host = lc($host);

    $path = "/$path" if $path !~ m!^/!;

    $port ||= $scheme eq 'http' ? 80 : $scheme eq 'https' ? 433 : undef;

    my ($username, $password) = split($auth, ':', 2);

    return ($scheme, $auth, $host, $port, $path, $query, $hash, $username, $password);
}

=func to_bool

=func to_number

=func to_string

=func to_time

=func to_tristate

=func to_uuid

Various typecasting / coercive functions.

=cut

sub to_bool   { $_[0] // return; boolean($_[0]) }
sub to_number { $_[0] // return; 0+$_[0] }
sub to_string { $_[0] // return; "$_[0]" }
sub to_time   {
    $_[0] // return;
    return gmtime($_[0]) if looks_like_number($_[0]);
    return Time::Piece->strptime($_[0], '%Y-%m-%d %H:%M:%S') if !blessed $_[0];
    return $_[0];
}
sub to_tristate { $_[0] // return; boolean($_[0]) }
sub to_uuid {
    my $str = to_string(@_) // return;
    return sprintf('%016s', $str) if length($str) < 16;
    return substr($str, 0, 16) if 16 < length($str);
    return $str;
}

=func trim

    $string = trim($string);

The ubiquitous C<trim> function. Removes all whitespace from both ends of a string.

=cut

sub trim($) { ## no critic (ProhibitSubroutinePrototypes)
    local $_ = shift // return;
    s/^\s*//;
    s/\s*$//;
    return $_;
}

=func try_load_optional

    $package = try_load_optional($package);

Try to load a module that isn't required but can provide extra functionality, and return true if successful.

=cut

sub try_load_optional {
    for my $module (@_) {
        eval { load $module };
        if (my $err = $@) {
            warn $err if 3 <= DEBUG;
            return;
        }
    }
    return @_;
}

=func uri_escape_utf8

    $string = uri_escape_utf8($string);

Percent-encode arbitrary text strings, like for a URI.

=cut

my %ESC = map { chr($_) => sprintf('%%%02X', $_) } 0..255;
sub uri_escape_utf8 {
    local $_ = shift // return;
    $_ = encode('UTF-8', $_);
    # RFC 3986 section 2.3 unreserved characters
    s/([^A-Za-z0-9\-\._~])/$ESC{$1}/ge;
    return $_;
}

=func uri_unescape_utf8

    $string = uri_unescape_utf8($string);

Inverse of L</uri_escape_utf8>.

=cut

sub uri_unescape_utf8 {
    local $_ = shift // return;
    s/\%([A-Fa-f0-9]{2})/chr(hex($1))/;
    return decode('UTF-8', $_);
}

=func uuid

    $raw_uuid = uuid($string_uuid);

Pack a 128-bit UUID (given as a hexidecimal string with optional C<->'s, like
C<12345678-9ABC-DEFG-1234-56789ABCDEFG>) into a string of exactly 16 octets.

This is the inverse of L</format_uuid>.

=cut

sub uuid {
    local $_ = shift // return "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0";
    s/-//g;
    /^[A-Fa-f0-9]{32}$/ or throw 'Must provide a formatted 128-bit UUID';
    return pack('H32', $_);

}

=func UUID_NULL

Get the null UUID (i.e. string of 16 null bytes).

=cut

sub UUID_NULL() { "\0" x 16 }

### --------------------------------------------------------------------------

# Determine if an array looks like keypairs from a hash.
sub _looks_like_keypairs {
    my $arr = shift;
    return 0 if @$arr % 2 == 1;
    for (my $i = 0; $i < @$arr; $i += 2) {
        return 0 if is_ref($arr->[$i]);
    }
    return 1;
}

sub _is_operand_plain {
    local $_ = shift;
    return !(is_hashref($_) || is_arrayref($_));
}

sub _query {
    # dumper \@_;
    my $subject = shift;
    my $op      = shift // throw 'Must specify a query operator';
    my $operand = shift;

    return _query_simple($op, $subject) if defined $subject && !is_ref($op) && ($OPS{$subject} || 2) < 2;
    return _query_simple($subject, $op, $operand) if _is_operand_plain($operand);
    return _query_inverse(_query($subject, '-or', $operand)) if $op eq '-not' || $op eq '-false';
    return _query($subject, '-and', [%$operand]) if is_hashref($operand);

    my @queries;

    my @atoms = @$operand;
    while (@atoms) {
        if (_looks_like_keypairs(\@atoms)) {
            my ($atom, $operand) = splice @atoms, 0, 2;
            if (my $op_type = $OPS{$atom}) {
                if ($op_type == 1 && _is_operand_plain($operand)) { # unary
                    push @queries, _query_simple($operand, $atom);
                }
                else {
                    push @queries, _query($subject, $atom, $operand);
                }
            }
            elsif (!is_ref($atom)) {
                push @queries, _query($atom, 'eq', $operand);
            }
        }
        else {
            my $atom = shift @atoms;
            if ($OPS{$atom}) {     # apply new operator over the rest
                push @queries, _query($subject, $atom, \@atoms);
                last;
            }
            else {  # apply original operator over this one
                push @queries, _query($subject, $op, $atom);
            }
        }
    }

    if (@queries == 1) {
        return $queries[0];
    }
    elsif ($op eq '-and') {
        return _query_all(@queries);
    }
    elsif ($op eq '-or') {
        return _query_any(@queries);
    }
    throw 'Malformed query';
}

sub _query_simple {
    my $subject = shift;
    my $op      = shift // 'eq';
    my $operand = shift;

    # these special operators can also act as simple operators
    $op = '!!' if $op eq '-true';
    $op = '!'  if $op eq '-false';
    $op = '!'  if $op eq '-not';

    defined $subject or throw 'Subject is not set in query';
    $OPS{$op} >= 0   or throw 'Cannot use a non-simple operator in a simple query';
    if (empty($operand)) {
        if ($OPS{$op} < 2) {
            # no operand needed
        }
        # Allow field => undef and field => {'ne' => undef} to do the (arguably) right thing.
        elsif ($op eq 'eq' || $op eq '==') {
            $op = '-empty';
        }
        elsif ($op eq 'ne' || $op eq '!=') {
            $op = '-nonempty';
        }
        else {
            throw 'Operand is required';
        }
    }

    my $field = sub { blessed $_[0] && $_[0]->can($subject) ? $_[0]->$subject : $_[0]->{$subject} };

    my %map = (
        'eq'        => sub { local $_ = $field->(@_); defined && $_ eq $operand },
        'ne'        => sub { local $_ = $field->(@_); defined && $_ ne $operand },
        'lt'        => sub { local $_ = $field->(@_); defined && $_ lt $operand },
        'gt'        => sub { local $_ = $field->(@_); defined && $_ gt $operand },
        'le'        => sub { local $_ = $field->(@_); defined && $_ le $operand },
        'ge'        => sub { local $_ = $field->(@_); defined && $_ ge $operand },
        '=='        => sub { local $_ = $field->(@_); defined && $_ == $operand },
        '!='        => sub { local $_ = $field->(@_); defined && $_ != $operand },
        '<'         => sub { local $_ = $field->(@_); defined && $_ <  $operand },
        '>'         => sub { local $_ = $field->(@_); defined && $_ >  $operand },
        '<='        => sub { local $_ = $field->(@_); defined && $_ <= $operand },
        '>='        => sub { local $_ = $field->(@_); defined && $_ >= $operand },
        '=~'        => sub { local $_ = $field->(@_); defined && $_ =~ $operand },
        '!~'        => sub { local $_ = $field->(@_); defined && $_ !~ $operand },
        '!'         => sub { local $_ = $field->(@_); ! $_ },
        '!!'        => sub { local $_ = $field->(@_); !!$_ },
        '-defined'  => sub { local $_ = $field->(@_);  defined $_ },
        '-undef'    => sub { local $_ = $field->(@_); !defined $_ },
        '-nonempty' => sub { local $_ = $field->(@_); nonempty $_ },
        '-empty'    => sub { local $_ = $field->(@_); empty    $_ },
    );

    return $map{$op} // throw "Unexpected operator in query: $op",
        subject     => $subject,
        operator    => $op,
        operand     => $operand;
}

sub _query_inverse {
    my $query = shift;
    return sub { !$query->(@_) };
}

sub _query_all {
    my @queries = @_;
    return sub {
        my $val = shift;
        all { $_->($val) } @queries;
    };
}

sub _query_any {
    my @queries = @_;
    return sub {
        my $val = shift;
        any { $_->($val) } @queries;
    };
}

1;
