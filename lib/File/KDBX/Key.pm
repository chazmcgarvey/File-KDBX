package File::KDBX::Key;
# ABSTRACT: A credential that can protect a KDBX file

use warnings;
use strict;

use Devel::GlobalDestruction;
use File::KDBX::Error;
use File::KDBX::Safe;
use File::KDBX::Util qw(erase);
use Module::Load;
use Ref::Util qw(is_arrayref is_coderef is_hashref is_ref is_scalarref);
use Scalar::Util qw(blessed openhandle refaddr);
use namespace::clean;

our $VERSION = '999.999'; # VERSION

my %SAFE;

=method new

    $key = File::KDBX::Key->new({ password => $password });
    $key = File::KDBX::Key->new($password);

    $key = File::KDBX::Key->new({ file => $filepath });
    $key = File::KDBX::Key->new(\$file);
    $key = File::KDBX::Key->new(\*FILE);

    $key = File::KDBX::Key->new({ composite => [...] });
    $key = File::KDBX::Key->new([...]);         # composite key

    $key = File::KDBX::Key->new({ responder => \&responder });
    $key = File::KDBX::Key->new(\&responder);   # challenge-response key

Construct a new key.

The primitive used to construct the key is not saved but is immediately converted to a raw encryption key (see
L</raw_key>).

A L<File::KDBX::Key::Composite> is somewhat special in that it does retain a reference to its component keys,
and its raw key is calculated from its components on demand.

=cut

sub new {
    my $class = shift;
    my %args = @_ % 2 == 1 ? (primitive => shift, @_) : @_;

    my $primitive = $args{primitive};
    delete $args{primitive} if !$args{keep_primitive};
    return $primitive->hide if blessed $primitive && $primitive->isa($class);

    my $self = bless \%args, $class;
    return $self->init($primitive) if defined $primitive;
    return $self;
}

sub DESTROY { !in_global_destruction and do { $_[0]->_clear_raw_key; erase \$_[0]->{primitive} } }

=method init

    $key = $key->init($primitive);

Initialize a L<File::KDBX::Key> with a new primitive. Returns itself to allow method chaining.

=cut

sub init {
    my $self = shift;
    my $primitive = shift // throw 'Missing key primitive';

    my $pkg;

    if (is_arrayref($primitive)) {
        $pkg = __PACKAGE__.'::Composite';
    }
    elsif (is_scalarref($primitive) || openhandle($primitive)) {
        $pkg = __PACKAGE__.'::File';
    }
    elsif (is_coderef($primitive)) {
        $pkg = __PACKAGE__.'::ChallengeResponse';
    }
    elsif (!is_ref($primitive)) {
        $pkg = __PACKAGE__.'::Password';
    }
    elsif (is_hashref($primitive) && defined $primitive->{composite}) {
        $pkg = __PACKAGE__.'::Composite';
        $primitive = $primitive->{composite};
    }
    elsif (is_hashref($primitive) && defined $primitive->{password}) {
        $pkg = __PACKAGE__.'::Password';
        $primitive = $primitive->{password};
    }
    elsif (is_hashref($primitive) && defined $primitive->{file}) {
        $pkg = __PACKAGE__.'::File';
        $primitive = $primitive->{file};
    }
    elsif (is_hashref($primitive) && defined $primitive->{responder}) {
        $pkg = __PACKAGE__.'::ChallengeResponse';
        $primitive = $primitive->{responder};
    }
    else {
        throw 'Invalid key primitive', primitive => $primitive;
    }

    load $pkg;
    bless $self, $pkg;
    return $self->init($primitive);
}

=method reload

    $key = $key->reload;

Reload a key by re-reading the key source and recalculating the raw key. Returns itself to allow method
chaining.

=cut

sub reload { $_[0] }

=method raw_key

    $raw_key = $key->raw_key;
    $raw_key = $key->raw_key($challenge);

Get the raw encryption key. This is calculated based on the primitive(s). The C<$challenge> argument is for
challenge-response type keys and is ignored by other types.

B<NOTE:> The raw key is sensitive information and so is memory-protected while not being accessed. If you
access it, you should L<File::KDBX::Util/erase> it when you're done.

=cut

sub raw_key {
    my $self = shift;
    return $self->{raw_key} if !$self->is_hidden;
    return $self->_safe->peek(\$self->{raw_key});
}

sub _set_raw_key {
    my $self = shift;
    $self->_clear_raw_key;
    $self->{raw_key} = shift;   # after clear
    $self->_new_safe->add(\$self->{raw_key});   # auto-hide
}

sub _clear_raw_key {
    my $self = shift;
    my $safe = $self->_safe;
    $safe->clear if $safe;
    erase \$self->{raw_key};
}

=method hide

    $key = $key->hide;

Encrypt the raw key for L<File::KDBX/"Memory Protection>. Returns itself to allow method chaining.

=cut

sub hide {
    my $self = shift;
    $self->_new_safe->add(\$self->{raw_key}) if defined $self->{raw_key};
    return $self;
}

=method show

    $key = $key->show;

Decrypt the raw key so it can be accessed. Returns itself to allow method chaining.

You normally don't need to call this because L</raw_key> calls this implicitly.

=cut

sub show {
    my $self = shift;
    my $safe = $self->_safe;
    $safe->unlock if $safe;
    return $self;
}

sub is_hidden { !!$SAFE{refaddr($_[0])} }

# sub show_scoped {
#     my $self = shift;
#     require Scope::Guard;
#     $self-
#     return
# }

sub _safe     { $SAFE{refaddr($_[0])} }
sub _new_safe { $SAFE{refaddr($_[0])} = File::KDBX::Safe->new }

1;
__END__

=head1 DESCRIPTION

A master key is one or more credentials that can protect a KDBX database. When you encrypt a database with
a master key, you will need the master key to decrypt it. B<Keep your master key safe!> If someone gains
access to your master key, they can open your database. If you forget or lose any part of your master key, all
data in the database is lost.

There are several different types of keys, each implemented as a subclass:

=for :list
* L<File::KDBX::Key::Password> - Password or passphrase, knowledge of a string of characters
* L<File::KDBX::Key::File> - Possession of a file ("key file") with a secret.
* L<File::KDBX::Key::ChallengeResponse> - Possession of a device that responds correctly when challenged
* L<File::KDBX::Key::YubiKey> - Possession of a YubiKey hardware device (a type of challenge-response)
* L<File::KDBX::Key::Composite> - One or more keys combined as one

A good master key is produced from a high amount of "entropy" (unpredictability). The more entropy the better.
Combining multiple keys into a B<Composite> key combines the entropy of each individual key. For example, if
you have a weak password and you combine it with other keys, the composite key is stronger than the weak
password key by itself. (Of course it's much better to not have any weak components of your master key.)

B<COMPATIBILITY NOTE:> Most KeePass implementations are limited in the types and numbers of keys they support.
B<Password> keys are pretty much universally supported. B<File> keys are pretty well-supported. Many do not
support challenge-response keys. If you are concerned about compatibility, you should stick with one of these
configurations:

=for :list
* One password
* One key file
* One password and one key file

=cut
