package File::KDBX::Error;
# ABSTRACT: Represents something bad that happened

use warnings;
use strict;

use Exporter qw(import);
use Scalar::Util qw(blessed);
use namespace::clean -except => 'import';

our $VERSION = '999.999'; # VERSION

our @EXPORT = qw(alert error throw);

my $WARNINGS_CATEGORY;
BEGIN {
    $WARNINGS_CATEGORY = 'File::KDBX';
    if (warnings->can('register_categories')) {
        warnings::register_categories($WARNINGS_CATEGORY);
    }
    else {
        eval qq{package $WARNINGS_CATEGORY; use warnings::register; 1}; ## no critic ProhibitStringyEval
    }
}

use overload '""' => 'to_string', cmp => '_cmp';

=method new

    $error = File::KDBX::Error->new($message, %details);

Construct a new error.

=cut

sub new {
    my $class = shift;
    my %args = @_ % 2 == 0 ? @_ : (_error => shift, @_);

    my $error = delete $args{_error};
    my $e = $error;
    # $e =~ s/ at \H+ line \d+.*//g;

    my $self = bless {
        details     => \%args,
        error      => $e // 'Something happened',
        errno      => $!,
        previous   => $@,
        trace      => do {
            require Carp;
            local $Carp::CarpInternal{''.__PACKAGE__} = 1;
            my $mess = $error =~ /at \H+ line \d+/ ? $error : Carp::longmess($error);
            [map { /^\h*(.*?)\.?$/ ? $1 : $_ } split(/\n/, $mess)];
        },
    }, $class;
    chomp $self->{error};
    return $self;
}

=method error

    $error = error($error);
    $error = error($message, %details);
    $error = File::KDBX::Error->error($error);
    $error = File::KDBX::Error->error($message, %details);

Wrap a thing to make it an error object. If the thing is already an error, it gets returned. Otherwise what is
passed will be forwarded to L</new> to create a new error object.

This can be convenient for error handling when you're not sure what the exception is but you want to treat it
as a B<File::KDBX::Error>. Example:

    eval { .... };
    if (my $error = error(@_)) {
        if ($error->type eq 'key.missing') {
            handle_missing_key($error);
        }
        else {
            handle_other_error($error);
        }
    }

=cut

sub error {
    my $class = @_ && $_[0] eq __PACKAGE__ ? shift : undef;
    my $self = (blessed($_[0]) && $_[0]->isa('File::KDBX::Error'))
        ? shift
        : $class
            ? $class->new(@_)
            : __PACKAGE__->new(@_);
    return $self;
}

=attr details

    \%details = $error->details;

Get the error details.

=cut

sub details {
    my $self = shift;
    my %args = @_;
    my $details = $self->{details} //= {};
    @$details{keys %args} = values %args;
    return $details;
}

sub errno { $_[0]->{errno} }

sub previous { $_[0]->{previous} }

sub trace { $_[0]->{trace} // [] }

sub type { $_[0]->details->{type} // '' }

=method to_string

    $message = $error->to_string;
    $message = "$error";

Stringify an error.

This does not contain a stack trace, but you can set the C<DEBUG> environment
variable to truthy to stringify the whole error object.

=cut

sub _cmp { "$_[0]" cmp "$_[1]" }

sub PROPAGATE {
    'wat';
}

sub to_string {
    my $self = shift;
    # return "uh oh\n";
    my $msg = "$self->{trace}[0]";
    $msg .= '.' if $msg !~ /[\.\!\?]$/; # Why does this cause infinite recursion on some perls?
    # $msg .= '.' if $msg !~ /(?:\.|!|\?)$/;
    if ($ENV{DEBUG}) {
        require Data::Dumper;
        local $Data::Dumper::Indent = 1;
        local $Data::Dumper::Quotekeys = 0;
        local $Data::Dumper::Sortkeys = 1;
        local $Data::Dumper::Terse = 1;
        local $Data::Dumper::Trailingcomma = 1;
        local $Data::Dumper::Useqq = 1;
        $msg .= "\n" . Data::Dumper::Dumper $self;
    }
    $msg .= "\n" if $msg !~ /\n$/;
    return $msg;
}

=method throw

    File::KDBX::Error::throw($message, %details);
    $error->throw;

Throw an error.

=cut

sub throw {
    my $self = error(@_);
    die $self;
}

=method warn

    File::KDBX::Error::warn($message, %details);
    $error->warn;

Log a warning.

=cut

sub warn {
    return if !($File::KDBX::WARNINGS // 1);

    my $self = error(@_);

    # Use die and warn directly instead of warnings::warnif because the latter only provides the stringified
    # error to the warning signal handler (perl 5.34). Maybe that's a warnings.pm bug?

    if (my $fatal = warnings->can('fatal_enabled_at_level')) {
        my $blame = _find_blame_frame();
        die $self if $fatal->($WARNINGS_CATEGORY, $blame);
    }

    if (my $enabled = warnings->can('enabled_at_level')) {
        my $blame = _find_blame_frame();
        warn $self if $enabled->($WARNINGS_CATEGORY, $blame);
    }
    elsif ($enabled = warnings->can('enabled')) {
        warn $self if $enabled->($WARNINGS_CATEGORY);
    }
    else {
        warn $self;
    }
    return $self;
}

=method alert

    alert $error;

Importable alias for L</warn>.

=cut

sub alert { goto &warn }

sub _find_blame_frame {
    my $frame = 1;
    while (1) {
        my ($package) = caller($frame);
        last if !$package;
        return $frame - 1 if $package !~ /^\Q$WARNINGS_CATEGORY\E/;
        $frame++;
    }
    return 0;
}

1;
