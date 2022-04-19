#!/usr/bin/env perl

use warnings;
use strict;

use lib 't/lib';
use TestCommon;

use File::KDBX::Entry;
use File::KDBX::Util qw(:uuid);
use File::KDBX;
use Test::Deep;
use Test::More;

subtest 'Cloning' => sub {
    my $kdbx = File::KDBX->new;
    my $entry = File::KDBX::Entry->new;

    my $copy = $entry->clone;
    like exception { $copy->kdbx }, qr/disassociated/, 'Disassociated entry copy is also disassociated';
    cmp_deeply $copy, $entry, 'Disassociated entry and its clone are identical';

    $entry->kdbx($kdbx);
    $copy = $entry->clone;
    is $entry->kdbx, $copy->kdbx, 'Associated entry copy is also associated';
    cmp_deeply $copy, $entry, 'Associated entry and its clone are identical';

    my $txn = $entry->begin_work;
    $entry->title('foo');
    $entry->username('bar');
    $entry->password('baz');
    $txn->commit;

    $copy = $entry->clone;
    is @{$copy->history}, 1, 'Copy has a historical entry';
    cmp_deeply $copy, $entry, 'Entry with history and its clone are identical';

    $copy = $entry->clone(history => 0);
    is @{$copy->history}, 0, 'Copy excluding history has no history';

    $copy = $entry->clone(new_uuid => 1);
    isnt $copy->uuid, $entry->uuid, 'Entry copy with new UUID has a different UUID';

    $copy = $entry->clone(reference_username => 1);
    my $ref = sprintf('{REF:U@I:%s}', format_uuid($entry->uuid));
    is $copy->username, $ref, 'Copy has username reference';
    is $copy->expanded_username, $ref, 'Entry copy does not expand username because entry is not in database';

    my $group = $kdbx->add_group(label => 'Passwords');
    $group->add_entry($entry);
    is $copy->expanded_username, $entry->username,
        'Entry in database and its copy with username ref have same expanded username';

    $copy = $entry->clone;
    is @{$kdbx->all_entries}, 1, 'Still only one entry after cloning';

    $copy = $entry->clone(parent => 1);
    is @{$kdbx->all_entries}, 2, 'New copy added to database if clone with parent option';
    my ($e1, $e2) = @{$kdbx->all_entries};
    isnt $e1, $e2, 'Entry and its copy in the database are different objects';
    is $e1->title, $e2->title, 'Entry copy has the same title as the original entry';

    $copy = $entry->clone(parent => 1, relabel => 1);
    is @{$kdbx->all_entries}, 3, 'New copy added to database if clone with parent option';
    is $kdbx->all_entries->[2], $copy, 'New copy and new entry in the database match';
    is $kdbx->all_entries->[2]->title, "foo - Copy", 'New copy has a modified title';

    $copy = $group->clone;
    cmp_deeply $copy, $group, 'Group and its clone are identical';
    is @{$copy->entries}, 3, 'Group copy has as many entries as the original';
    is @{$copy->entries->[0]->history}, 1, 'Entry in group copy has history';

    $copy = $group->clone(history => 0);
    is @{$copy->entries}, 3, 'Group copy without history has as many entries as the original';
    is @{$copy->entries->[0]->history}, 0, 'Entry in group copy has no history';

    $copy = $group->clone(entries => 0);
    is @{$copy->entries}, 0, 'Group copy without entries has no entries';
    is $copy->name, 'Passwords', 'Group copy label is the same as the original';

    $copy = $group->clone(relabel => 1);
    is $copy->name, 'Passwords - Copy', 'Group copy relabeled from the original title';
    is @{$kdbx->all_entries}, 3, 'No new entries were added to the database';

    $copy = $group->clone(relabel => 1, parent => 1);
    is @{$kdbx->all_entries}, 6, 'Copy a group within parent doubles the number of entries in the database';
    isnt $group->entries->[0]->uuid, $copy->entries->[0]->uuid,
        'First entry in group and its copy are different';
};

done_testing;