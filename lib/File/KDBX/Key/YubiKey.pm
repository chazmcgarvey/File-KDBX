package File::KDBX::Key::YubiKey;
# ABSTRACT: A Yubico challenge-response key

use warnings;
use strict;

use File::KDBX::Constants qw(:yubikey);
use File::KDBX::Error;
use File::KDBX::Util qw(pad_pkcs7);
use IPC::Open3;
use Scope::Guard;
use Symbol qw(gensym);
use namespace::clean;

use parent 'File::KDBX::Key::ChallengeResponse';

our $VERSION = '999.999'; # VERSION

my @CONFIG_VALID = (0, CONFIG1_VALID, CONFIG2_VALID);
my @CONFIG_TOUCH = (0, CONFIG1_TOUCH, CONFIG2_TOUCH);

sub challenge {
    my $self = shift;
    my $challenge = shift;
    my %args = @_;

    my @cleanup;

    my $device  = $args{device}  // $self->device;
    my $slot    = $args{slot}    // $self->slot;
    my $timeout = $args{timeout} // $self->timeout;
    local $self->{device}   = $device;
    local $self->{slot}     = $slot;
    local $self->{timeout}  = $timeout;

    my $hooks = $challenge ne 'test';
    if ($hooks and my $hook = $self->{pre_challenge}) {
        $hook->($self, $challenge);
    }

    my @cmd = ($self->ykchalresp, "-n$device", "-$slot", qw{-H -i-}, $timeout == 0 ? '-N' : ());
    my ($pid, $child_in, $child_out, $child_err) = _run_ykpers(@cmd);
    push @cleanup, Scope::Guard->new(sub { kill $pid if defined $pid });

    # Set up an alarm [mostly] safely
    my $prev_alarm = 0;
    local $SIG{ALRM} = sub {
        $prev_alarm -= $timeout;
        throw 'Timed out while waiting for challenge response',
            command     => \@cmd,
            challenge   => $challenge,
            timeout     => $timeout,
    };
    $prev_alarm = alarm $timeout if 0 < $timeout;
    push @cleanup, Scope::Guard->new(sub { alarm($prev_alarm < 1 ? 1 : $prev_alarm) }) if $prev_alarm;

    local $SIG{PIPE} = 'IGNORE';
    binmode($child_in);
    print $child_in pad_pkcs7($challenge, 64);
    close($child_in);

    binmode($child_out);
    binmode($child_err);
    my $resp = do { local $/; <$child_out> };
    my $err  = do { local $/; <$child_err> };
    chomp($resp, $err);

    waitpid($pid, 0);
    undef $pid;
    my $exit_status = $? >> 8;
    alarm 0;

    my $yk_errno = _yk_errno($err);
    $exit_status == 0 or throw 'Failed to receive challenge response: ' . ($err ? $err : ''),
        error       => $err,
        yk_errno    => $yk_errno || 0;

    $resp =~ /^[A-Fa-f0-9]+$/ or throw 'Unexpected response from challenge', response => $resp;
    $resp = pack('H*', $resp);

    # HMAC-SHA1 response is only 20 bytes
    substr($resp, 20) = '';

    if ($hooks and my $hook = $self->{post_challenge}) {
        $hook->($self, $challenge, $resp);
    }

    return $resp;
}

=method scan

    @keys = File::KDBX::Key::YubiKey->scan(%options);

Find connected, configured YubiKeys that are capable of responding to a challenge. This can take several
second.

Options:

=for :list
* C<limit> - Scan for only up to this many YubiKeys (default: 4)

Other options are passed as-is as attributes to the key constructors of found keys (if any).

=cut

sub scan {
    my $self = shift;
    my %args = @_;

    my $limit = delete $args{limit} // 4;

    my @keys;
    for (my $device = 0; $device < $limit; ++$device) {
        my %info = $self->_get_yubikey_info($device) or last;

        for (my $slot = 1; $slot <= 2; ++$slot) {
            my $config = $CONFIG_VALID[$slot] // next;
            next unless $info{touch_level} & $config;

            my $key = $self->new(%args, device => $device, slot => $slot, %info);
            if ($info{product_id} <= NEO_OTP_U2F_CCID_PID) {
                # NEO and earlier always require touch, so forego testing
                $key->touch_level($info{touch_level} | $CONFIG_TOUCH[$slot]);
                push @keys, $key;
            }
            else {
                eval { $key->challenge('test', timeout => 0) };
                if (my $err = $@) {
                    my $yk_errno = ref $err && $err->details->{yk_errno} || 0;
                    if ($yk_errno == YK_EWOULDBLOCK) {
                        $key->touch_level($info{touch_level} | $CONFIG_TOUCH[$slot]);
                    }
                    elsif ($yk_errno != 0) {
                        # alert $err;
                        next;
                    }
                }
                push @keys, $key;
            }
        }
    }

    return @keys;
}

=attr device

    $device = $key->device($device);

Get or set the device number, which is the index number starting and incrementing from zero assigned
to the YubiKey device. If there is only one detected YubiKey device, it's number is C<0>.

Defaults to C<0>.

=attr slot

    $slot = $key->slot($slot);

Get or set the slot number, which is a number starting and incrementing from one. A YubiKey can have
multiple slots (often just two) which can be independently configured.

Defaults to C<1>.

=attr timeout

    $timeout = $key->timeout($timeout);

Get or set the timeout, in seconds. If the challenge takes longer than this, the challenge will be
cancelled and an error is thrown.

If the timeout is zero, the challenge is non-blocking; an error is thrown if the challenge would
block. If the timeout is negative, timeout is disabled and the challenge will block forever or until
a response is received.

Defaults to C<0>.

=attr pre_challenge

    $callback = $key->pre_challenge($callback);

Get or set a callback function that will be called immediately before any challenge is issued. This might be
used to prompt the user so they are aware that they are expected to interact with their YubiKey.

    $key->pre_challenge(sub {
        my ($key, $challenge) = @_;

        if ($key->requires_interaction) {
            say 'Please touch your key device to proceed with decrypting your KDBX file.';
        }
        say 'Key: ', $key->name;
        if (0 < $key->timeout) {
            say 'Key access request expires: ' . localtime(time + $key->timeout);
        }
    });

You can throw from this subroutine to abort the challenge. If the challenge is part of loading or dumping
a KDBX database, the entire load/dump will be aborted.

=attr post_challenge

    $callback = $key->post_challenge($callback);

Get or set a callback function that will be called immediately after a challenge response has been received.

You can throw from this subroutine to abort the challenge. If the challenge is part of loading or dumping
a KDBX database, the entire load/dump will be aborted.

=attr ykchalresp

    $program = $key->ykchalresp;

Get or set the L<ykchalresp(1)> program name or filepath. Defaults to C<$ENV{YKCHALRESP}> or C<ykchalresp>.

=attr ykinfo

    $program = $key->ykinfo;

Get or set the L<ykinfo(1)> program name or filepath. Defaults to C<$ENV{YKINFO}> or C<ykinfo>.

=cut

my %ATTRS = (
    device          => 0,
    slot            => 1,
    timeout         => 10,
    pre_challenge   => undef,
    post_challenge  => undef,
    ykchalresp      => sub { $ENV{YKCHALRESP} || 'ykchalresp' },
    ykinfo          => sub { $ENV{YKINFO} || 'ykinfo' },
);
while (my ($subname, $default) = each %ATTRS) {
    no strict 'refs'; ## no critic (ProhibitNoStrict)
    *{$subname} = sub {
        my $self = shift;
        $self->{$subname} = shift if @_;
        $self->{$subname} //= (ref $default eq 'CODE') ? $default->($self) : $default;
    };
}

my %INFO = (
    serial      => undef,
    version     => undef,
    touch_level => undef,
    vendor_id   => undef,
    product_id  => undef,
);
while (my ($subname, $default) = each %INFO) {
    no strict 'refs'; ## no critic (ProhibitNoStrict)
    *{$subname} = sub {
        my $self = shift;
        $self->{$subname} = shift if @_;
        defined $self->{$subname} or $self->_set_yubikey_info;
        $self->{$subname} // $default;
    };
}

=method serial

Get the device serial number, as a number, or C<undef> if there is no such device.

=method version

Get the device firmware version (or C<undef>).

=method touch_level

Get the "touch level" value for the device associated with this key (or C<undef>).

=method vendor_id

=method product_id

Get the vendor ID or product ID for the device associated with this key (or C<undef>).

=method name

    $name = $key->name;

Get a human-readable string identifying the YubiKey (or C<undef>).

=cut

sub name {
    my $self = shift;
    my $name = _product_name($self->vendor_id, $self->product_id // return);
    my $serial = $self->serial;
    my $version = $self->version || '?';
    my $slot = $self->slot;
    my $touch = $self->requires_interaction ? ' - Interaction required' : '';
    return sprintf('%s v%s [%d] (slot #%d)', $name, $version, $serial, $slot);
}

=method requires_interaction

Get whether or not the key requires interaction (e.g. a touch) to provide a challenge response (or C<undef>).

=cut

sub requires_interaction {
    my $self = shift;
    my $touch = $self->touch_level // return;
    return $touch & $CONFIG_TOUCH[$self->slot];
}

##############################################################################

### Call ykinfo to get some information about a YubiKey
sub _get_yubikey_info {
    my $self = shift;
    my $device = shift;

    my @cmd = ($self->ykinfo, "-n$device", qw{-a});

    my $try = 0;
    TRY:
    my ($pid, $child_in, $child_out, $child_err) = _run_ykpers(@cmd);

    close($child_in);

    local $SIG{PIPE} = 'IGNORE';
    binmode($child_out);
    binmode($child_err);
    my $out = do { local $/; <$child_out> };
    my $err = do { local $/; <$child_err> };
    chomp $err;

    waitpid($pid, 0);
    my $exit_status = $? >> 8;

    if ($exit_status != 0) {
        my $yk_errno = _yk_errno($err);
        return if $yk_errno == YK_ENOKEY;
        if ($yk_errno == YK_EWOULDBLOCK && ++$try <= 3) {
            sleep 0.1;
            goto TRY;
        }
        alert 'Failed to get YubiKey device info: ' . ($err ? $err : 'Something happened'),
            error       => $err,
            yk_errno    => $yk_errno || 0;
        return;
    }

    if (!$out) {
        alert 'Failed to get YubiKey device info: no output';
        return;
    }

    my %info = map { $_ => ($out =~ /^\Q$_\E: (.+)$/m)[0] }
        qw(serial version touch_level vendor_id product_id);
    $info{vendor_id}    = hex($info{vendor_id})  if defined $info{vendor_id};
    $info{product_id}   = hex($info{product_id}) if defined $info{product_id};

    return %info;
}

### Set the YubiKey information as attributes of a Key object
sub _set_yubikey_info {
    my $self = shift;
    my %info = $self->_get_yubikey_info($self->device);
    @$self{keys %info} = values %info;
}

sub _run_ykpers {
    my ($child_err, $child_in, $child_out) = (gensym);
    my $pid = eval { open3($child_in, $child_out, $child_err, @_) };
    if (my $err = $@) {
        throw "Failed to run $_[0] - Make sure you have the YubiKey Personalization Tool (CLI) package installed.\n",
            error   => $err;
    }
    return ($pid, $child_in, $child_out, $child_err);
}

sub _yk_errno {
    local $_ = shift or return 0;
    return YK_EUSBERR       if $_ =~ YK_EUSBERR;
    return YK_EWRONGSIZ     if $_ =~ YK_EWRONGSIZ;
    return YK_EWRITEERR     if $_ =~ YK_EWRITEERR;
    return YK_ETIMEOUT      if $_ =~ YK_ETIMEOUT;
    return YK_ENOKEY        if $_ =~ YK_ENOKEY;
    return YK_EFIRMWARE     if $_ =~ YK_EFIRMWARE;
    return YK_ENOMEM        if $_ =~ YK_ENOMEM;
    return YK_ENOSTATUS     if $_ =~ YK_ENOSTATUS;
    return YK_ENOTYETIMPL   if $_ =~ YK_ENOTYETIMPL;
    return YK_ECHECKSUM     if $_ =~ YK_ECHECKSUM;
    return YK_EWOULDBLOCK   if $_ =~ YK_EWOULDBLOCK;
    return YK_EINVALIDCMD   if $_ =~ YK_EINVALIDCMD;
    return YK_EMORETHANONE  if $_ =~ YK_EMORETHANONE;
    return YK_ENODATA       if $_ =~ YK_ENODATA;
    return -1;
}

my %PIDS;
for my $pid (
    YUBIKEY_PID, NEO_OTP_PID, NEO_OTP_CCID_PID, NEO_CCID_PID, NEO_U2F_PID, NEO_OTP_U2F_PID, NEO_U2F_CCID_PID,
    NEO_OTP_U2F_CCID_PID, YK4_OTP_PID, YK4_U2F_PID, YK4_OTP_U2F_PID, YK4_CCID_PID, YK4_OTP_CCID_PID,
    YK4_U2F_CCID_PID, YK4_OTP_U2F_CCID_PID, PLUS_U2F_OTP_PID, ONLYKEY_PID,
) {
    $PIDS{$pid} = $PIDS{0+$pid} = $pid;
}
sub _product_name { $PIDS{$_[1]} // 'Unknown' }

1;
__END__

=head1 SYNOPSIS

    use File::KDBX::Key::YubiKey;
    use File::KDBX;

    my $yubikey = File::KDBX::Key::YubiKey->new(%attributes);

    my $kdbx = File::KDBX->load_file('database.kdbx', $yubikey);
    # OR
    my $kdbx = File::KDBX->load_file('database.kdbx', ['password', $yubikey]);

    # Scan for USB YubiKeys:
    my ($first_key, @other_keys) = File::KDBX::Key::YubiKey->scan;

    my $response = $first_key->challenge('hello');

=head1 DESCRIPTION

A L<File::KDBX::Key::YubiKey> is a type of challenge-response key. This module follows the KeePassXC-style
challenge-response implementation, so this might not work at all with incompatible challenge-response
implementations (e.g. KeeChallenge).

To use this type of key to secure a L<File::KDBX> database, you also need to install the
L<YubiKey Personalization Tool (CLI)|https://developers.yubico.com/yubikey-personalization/> and configure at
least one of the slots on your YubiKey for HMAC-SHA1 challenge response mode. You can use the YubiKey
Personalization Tool GUI to do this.

See L<https://keepassxc.org/docs/#faq-yubikey-howto> for more information.

=head1 ENVIRONMENT

=for :list
* C<YKCHALRESP> - Path to the L<ykchalresp(1)> program
* C<YKINFO> - Path to the L<ykinfo(1)> program

C<YubiKey> searches for these programs in the same way perl typically searches for executables (using the
C<PATH> environment variable on many platforms). If the programs aren't installed normally, or if you want to
override the default programs, these environment variables can be used.

=cut
