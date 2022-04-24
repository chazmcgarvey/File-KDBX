package File::KDBX::KDF;
# ABSTRACT: A key derivation function

use warnings;
use strict;

use Crypt::PRNG qw(random_bytes);
use File::KDBX::Constants qw(:version :kdf);
use File::KDBX::Error;
use File::KDBX::Util qw(format_uuid);
use Module::Load;
use Scalar::Util qw(blessed);
use namespace::clean;

our $VERSION = '999.999'; # VERSION

my %KDFS;

=method new

    $kdf = File::KDBX::KDF->new(parameters => \%params);

Construct a new KDF.

=cut

sub new {
    my $class = shift;
    my %args = @_;

    my $uuid = $args{+KDF_PARAM_UUID} //= delete $args{uuid} or throw 'Missing KDF UUID', args => \%args;
    my $formatted_uuid = format_uuid($uuid);

    my $kdf = $KDFS{$uuid} or throw "Unsupported KDF ($formatted_uuid)", uuid => $uuid;
    ($class, my %registration_args) = @$kdf;

    load $class;
    my $self = bless {KDF_PARAM_UUID() => $uuid}, $class;
    return $self->init(%args, %registration_args);
}

=method init

    $kdf = $kdf->init(%attributes);

Called by method to set attributes. You normally shouldn't call this.

=cut

sub init {
    my $self = shift;
    my %args = @_;

    @$self{keys %args} = values %args;

    return $self;
}

=attr uuid

    $uuid => $kdf->uuid;

Get the UUID used to determine which function to use.

=cut

sub uuid { $_[0]->{+KDF_PARAM_UUID} }

=attr seed

    $seed = $kdf->seed;

Get the seed (or salt, depending on the function).

=cut

sub seed { die 'Not implemented' }

=method transform

    $transformed_key = $kdf->transform($key);
    $transformed_key = $kdf->transform($key, $challenge);

Transform a key. The input key can be either a L<File::KDBX::Key> or a raw binary key, and the
transformed key will be a raw key.

This can take awhile, depending on the KDF parameters.

If a challenge is provided (and the KDF is AES except for the KeePassXC variant), it will be passed to the key
so challenge-response keys can produce raw keys. See L<File::KDBX::Key/raw_key>.

=cut

sub transform {
    my $self = shift;
    my $key  = shift;

    if (blessed $key && $key->can('raw_key')) {
        return $self->_transform($key->raw_key) if $self->uuid eq KDF_UUID_AES;
        return $self->_transform($key->raw_key($self->seed, @_));
    }

    return $self->_transform($key);
}

sub _transform { die 'Not implemented' }

=method randomize_seed

    $kdf->randomize_seed;

Generate a new random seed/salt.

=cut

sub randomize_seed {
    my $self = shift;
    $self->{+KDF_PARAM_AES_SEED} = random_bytes(length($self->seed));
}

=method register

    File::KDBX::KDF->register($uuid => $package, %args);

Register a KDF. Registered KDFs can be used to encrypt and decrypt KDBX databases. A KDF's UUID B<must> be
unique and B<musn't change>. A KDF UUID is written into each KDBX file and the associated KDF must be
registered with the same UUID in order to decrypt the KDBX file.

C<$package> should be a Perl package relative to C<File::KDBX::KDF::> or prefixed with a C<+> if it is
a fully-qualified package. C<%args> are passed as-is to the KDF's L</init> method.

=cut

sub register {
    my $class   = shift;
    my $id      = shift;
    my $package = shift;
    my @args    = @_;

    my $formatted_id = format_uuid($id);
    $package = "${class}::${package}" if $package !~ s/^\+// && $package !~ /^\Q${class}::\E/;

    my %blacklist = map { File::KDBX::Util::uuid($_) => 1 } split(/,/, $ENV{FILE_KDBX_KDF_BLACKLIST} // '');
    if ($blacklist{$id} || $blacklist{$package}) {
        alert "Ignoring blacklisted KDF ($formatted_id)", id => $id, package => $package;
        return;
    }

    if (defined $KDFS{$id}) {
        alert "Overriding already-registered KDF ($formatted_id) with package $package",
            id      => $id,
            package => $package;
    }

    $KDFS{$id} = [$package, @args];
}

=method unregister

    File::KDBX::KDF->unregister($uuid);

Unregister a KDF. Unregistered KDFs can no longer be used to encrypt and decrypt KDBX databases, until
reregistered (see L</register>).

=cut

sub unregister {
    delete $KDFS{$_} for @_;
}

BEGIN {
    __PACKAGE__->register(KDF_UUID_AES,                     'AES');
    __PACKAGE__->register(KDF_UUID_AES_CHALLENGE_RESPONSE,  'AES');
    __PACKAGE__->register(KDF_UUID_ARGON2D,                 'Argon2');
    __PACKAGE__->register(KDF_UUID_ARGON2ID,                'Argon2');
}

1;
__END__

=head1 DESCRIPTION

A KDF (key derivation function) is used in the transformation of a master key (i.e. one or more component
keys) to produce the final encryption key protecting a KDBX database. The L<File::KDBX> distribution comes
with several pre-registered KDFs ready to go:

=for :list
* C<C9D9F39A-628A-4460-BF74-0D08C18A4FEA> - AES
* C<7C02BB82-79A7-4AC0-927D-114A00648238> - AES (challenge-response variant)
* C<EF636DDF-8C29-444B-91F7-A9A403E30A0C> - Argon2d
* C<9E298B19-56DB-4773-B23D-FC3EC6F0A1E6> - Argon2id

B<NOTE:> If you want your KDBX file to be readable by other KeePass implementations, you must use a UUID and
algorithm that they support. From the list above, all are well-supported except the AES challenge-response
variant which is kind of a pseudo KDF and isn't usually written into files. All of these are good. AES has
a longer track record, but Argon2 has better ASIC resistance.

You can also L</register> your own KDF. Here is a skeleton:

    package File::KDBX::KDF::MyKDF;

    use parent 'File::KDBX::KDF';

    File::KDBX::KDF->register(
        # $uuid, $package, %args
        "\x12\x34\x56\x78\x9a\xbc\xde\xfg\x12\x34\x56\x78\x9a\xbc\xde\xfg" => __PACKAGE__,
    );

    sub init { ... } # optional

    sub _transform { my ($key) = @_; ... }

=cut
