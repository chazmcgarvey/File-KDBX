#!/usr/bin/env perl

use warnings;
use strict;

use lib 't/lib';
use TestCommon qw(:no_warnings_test);

use File::KDBX::Util qw(can_fork);
use IO::Handle;
use PerlIO::via::File::KDBX::HmacBlock;
use Test::More;

my $KEY = "\x01" x 64;

{
    my $expected_plaintext = 'Tiny food from Spain!';

    pipe(my $read, my $write) or die "pipe failed: $!\n";

    PerlIO::via::File::KDBX::HmacBlock->push($write, block_size => 3, key => $KEY);
    print $write $expected_plaintext;
    binmode($write, ':pop');    # finish stream
    close($write) or die "close failed: $!";

    PerlIO::via::File::KDBX::HmacBlock->push($read, key => $KEY);
    my $plaintext = do { local $/; <$read> };
    close($read);

    is $plaintext, $expected_plaintext, 'HMAC-block just a little bit';
}

SKIP: {
    skip 'Tests require fork' if !can_fork;

    my $expected_plaintext = "\x64" x (1024*1024*12 - 57);

    pipe(my $read, my $write) or die "pipe failed: $!\n";

    defined(my $pid = fork) or die "fork failed: $!\n";
    if ($pid == 0) {
        PerlIO::via::File::KDBX::HmacBlock->push($write, key => $KEY);
        print $write $expected_plaintext;
        binmode($write, ':pop');    # finish stream
        close($write) or die "close failed: $!";
        exit;
    }

    PerlIO::via::File::KDBX::HmacBlock->push($read, key => $KEY);
    my $plaintext = do { local $/; <$read> };
    close($read);

    is $plaintext, $expected_plaintext, 'HMAC-block a lot';

    waitpid($pid, 0) or die "wait failed: $!\n";
}

subtest 'Error handling' => sub {
    pipe(my $read, my $write) or die "pipe failed: $!\n";

    PerlIO::via::File::KDBX::HmacBlock->push($read, key => $KEY);

    print $write 'blah blah blah';
    close($write) or die "close failed: $!";

    is $read->error, 0, 'Read handle starts out fine';
    my $data = do { local $/; <$read> };
    is $read->error, 1, 'Read handle can enter and error state';

    like $PerlIO::via::File::KDBX::HmacBlock::ERROR, qr/failed to read HMAC/i,
        'Error object is available';
};

done_testing;
