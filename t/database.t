#!/usr/bin/env perl

use utf8;
use warnings;
use strict;

use FindBin qw($Bin);
use lib "$Bin/lib";
use TestCommon;

use File::KDBX;
use Test::Deep;
use Test::More;

subtest 'Create a new database' => sub {
    my $kdbx = File::KDBX->new;

    $kdbx->add_group(name => 'Meh');
    ok $kdbx->_has_implicit_root, 'Database starts off with implicit root';

    my $entry = $kdbx->add_entry({
        username    => 'hello',
        password    => {value => 'This is a secret!!!!!', protect => 1},
    });

    ok !$kdbx->_has_implicit_root, 'Adding an entry to the root group makes it explicit';

    $entry->remove;
    ok $kdbx->_has_implicit_root, 'Removing group makes the root group implicit again';
};

subtest 'Clone' => sub {
    my $kdbx = File::KDBX->new;
    $kdbx->add_group(name => 'Passwords')->add_entry(title => 'My Entry');

    my $copy = $kdbx->clone;
    cmp_deeply $copy, $kdbx, 'Clone keeps the same structure and data' or dumper $copy;

    isnt $kdbx, $copy, 'Clone is a different object';
    isnt $kdbx->root, $copy->root,
        'Clone root group is a different object';
    isnt $kdbx->root->groups->[0], $copy->root->groups->[0],
        'Clone group is a different object';
    isnt $kdbx->root->groups->[0]->entries->[0], $copy->root->groups->[0]->entries->[0],
        'Clone entry is a different object';

    my @objects = (@{$copy->all_groups}, @{$copy->all_entries});
    subtest 'Cloned objects refer to the cloned database' => sub {
        plan tests => scalar @_;
        for my $object (@objects) {
            my $object_kdbx = eval { $object->kdbx };
            is $object_kdbx, $copy, 'Object: ' . $object->label;
        }
    }, @objects;
};

done_testing;
