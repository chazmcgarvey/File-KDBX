#!/usr/bin/env perl

use warnings;
use strict;

use lib 't/lib';
use TestCommon;

use IO::Handle;
use PerlIO::via::File::KDBX::Compression;
use Test::More;

eval { require Compress::Raw::Zlib }
    or plan skip_all => 'Compress::Zlib::Raw required to test compression';

my $expected_plaintext = 'Tiny food from Spain!';

pipe(my $read, my $write) or die "pipe failed: $!";
PerlIO::via::File::KDBX::Compression->push($read);
PerlIO::via::File::KDBX::Compression->push($write);

print $write $expected_plaintext or die "print failed: $!";
binmode($write, ':pop');    # finish stream
close($write) or die "close failed: $!";

my $plaintext = do { local $/; <$read> };
close($read);
is $plaintext, $expected_plaintext, 'Deflate and inflate a string';

{
    pipe(my $read, my $write) or die "pipe failed: $!";
    PerlIO::via::File::KDBX::Compression->push($read);

    print $write 'blah blah blah' or die "print failed: $!";
    close($write) or die "close failed: $!";

    is $read->error, 0, 'Read handle starts out fine';
    my $plaintext = do { local $/; <$read> };
    is $read->error, 1, 'Read handle can enter and error state';

    like $PerlIO::via::File::KDBX::Compression::ERROR, qr/failed to uncompress/i,
        'Error object is available';
}

done_testing;
