#!/usr/bin/env perl

use warnings;
use strict;

use lib 't/lib';
use TestCommon;

use File::KDBX::Constants qw(:kdf);
use Test::More;

BEGIN {
    $ENV{PERL_FILE_KDBX_XS} = 0;
    use_ok('File::KDBX::KDF');
}

my $kdf = File::KDBX::KDF->new(uuid => KDF_UUID_AES, seed => "\1" x 32, rounds => 10);

is File::KDBX::XS_LOADED(), 0, 'XS can be avoided';

my $r = $kdf->transform("\2" x 32);
is $r, "\342\234cp\375\\p\253]\213\f\246\345\230\266\260\r\222j\332Z\204:\322 p\224mhm\360\222",
    'AES KDF works without XS';

like exception { $kdf->transform("\2" x 33) }, qr/raw key must be 32 bytes/i,
    'Transformation requires valid arguments';

done_testing;
