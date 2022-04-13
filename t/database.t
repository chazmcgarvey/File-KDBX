#!/usr/bin/env perl

use utf8;
use warnings;
use strict;

use FindBin qw($Bin);
use lib "$Bin/lib";
use TestCommon;

use Test::More;

BEGIN { use_ok 'File::KDBX' }

subtest 'Create a new database' => sub {
    my $kdbx = File::KDBX->new;

    $kdbx->add_group(name => 'Meh');
    ok $kdbx->_is_implicit_root, 'Database starts off with implicit root';

    $kdbx->add_entry({
        username    => 'hello',
        password    => {value => 'This is a secret!!!!!', protect => 1},
    });

    ok !$kdbx->_is_implicit_root, 'Adding an entry to the root group makes it explicit';

    $kdbx->unlock;

    # dumper $kdbx->groups;

    pass;
};

done_testing;
