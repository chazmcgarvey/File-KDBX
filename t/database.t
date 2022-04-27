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

    my @objects = $copy->objects->each;
    subtest 'Cloned objects refer to the cloned database' => sub {
        plan tests => scalar @_;
        for my $object (@objects) {
            my $object_kdbx = eval { $object->kdbx };
            is $object_kdbx, $copy, 'Object: ' . $object->label;
        }
    }, @objects;
};

subtest 'Recycle bin' => sub {
    my $kdbx = File::KDBX->new;
    my $entry = $kdbx->add_entry(label => 'Meh');

    my $bin = $kdbx->groups->grep(name => 'Recycle Bin')->next;
    ok !$bin, 'New database has no recycle bin';

    is $kdbx->recycle_bin_enabled, 1, 'Recycle bin is enabled';
    $kdbx->recycle_bin_enabled(0);

    $entry->recycle_or_remove;
    cmp_ok $entry->is_recycled, '==', 0, 'Entry is not recycle if recycle bin is disabled';

    $bin = $kdbx->groups->grep(name => 'Recycle Bin')->next;
    ok !$bin, 'Recycle bin not autovivified if recycle bin is disabled';
    is $kdbx->entries->size, 0, 'Database is empty after removing entry';

    $kdbx->recycle_bin_enabled(1);

    $entry = $kdbx->add_entry(label => 'Another one');
    $entry->recycle_or_remove;
    cmp_ok $entry->is_recycled, '==', 1, 'Entry is recycled';

    $bin = $kdbx->groups->grep(name => 'Recycle Bin')->next;
    ok $bin, 'Recycle bin group autovivifies';
    cmp_ok $bin->icon_id, '==', 43, 'Recycle bin has the trash icon';
    cmp_ok $bin->enable_auto_type, '==', 0, 'Recycle bin has auto type disabled';
    cmp_ok $bin->enable_searching, '==', 0, 'Recycle bin has searching disabled';

    is $kdbx->entries->size, 1, 'Database is not empty';
    is $kdbx->entries(searching => 1)->size, 0, 'Database has no entries if searching';
    cmp_ok $bin->entries_deeply->size, '==', 1, 'Recycle bin has an entry';

    $entry->recycle_or_remove;
    is $kdbx->entries->size, 0, 'Remove entry if it is already in the recycle bin';
};

done_testing;
