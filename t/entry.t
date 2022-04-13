#!/usr/bin/env perl

use warnings;
use strict;

use lib 't/lib';
use TestCommon;

use File::KDBX;
use Test::Deep;
use Test::More;

BEGIN { use_ok 'File::KDBX::Entry' }

subtest 'Construction' => sub {
    my $entry = File::KDBX::Entry->new(my $data = {username => 'foo'});
    is $entry, $data, 'Provided data structure becomes the object';
    isa_ok $data, 'File::KDBX::Entry', 'Data structure is blessed';
    is $entry->{username}, 'foo', 'username is in the object still';
    is $entry->username, '', 'username is not the UserName string';

    like exception { $entry->kdbx }, qr/disassociated from a KDBX database/, 'Dies if disassociated';
    $entry->kdbx(my $kdbx = File::KDBX->new);
    is $entry->kdbx, $kdbx, 'Set a database after instantiation';

    is_deeply $entry, {username => 'foo', strings => {UserName => {value => ''}}},
        'Entry data contains what was provided to the constructor plus vivified username';

    $entry = File::KDBX::Entry->new(username => 'bar');
    is $entry->{username}, undef, 'username is not set on the data';
    is $entry->username, 'bar', 'username is set correctly as the UserName string';

    cmp_deeply $entry, noclass({
        auto_type => {},
        background_color => "",
        binaries => {},
        custom_data => {},
        custom_icon_uuid => undef,
        foreground_color => "",
        icon_id => "Password",
        override_url => "",
        previous_parent_group => undef,
        quality_check => bool(1),
        strings => {
            Notes => {
                value => "",
            },
            Password => {
                protect => bool(1),
                value => "",
            },
            Title => {
                value => "",
            },
            URL => {
                value => "",
            },
            UserName => {
                value => "bar",
            },
        },
        tags => "",
        times => {
            last_modification_time => isa('Time::Piece'),
            creation_time => isa('Time::Piece'),
            last_access_time => isa('Time::Piece'),
            expiry_time => isa('Time::Piece'),
            expires => bool(0),
            usage_count => 0,
            location_changed => isa('Time::Piece'),
        },
        uuid => re('^(?s:.){16}$'),
    }), 'Entry data contains UserName string and the rest default attributes';
};

subtest 'Custom icons' => sub {
    plan tests => 10;
    my $gif = pack('H*', '4749463839610100010000ff002c00000000010001000002003b');

    my $entry = File::KDBX::Entry->new(my $kdbx = File::KDBX->new, icon_id => 42);
    is $entry->custom_icon_uuid, undef, 'UUID is undef if no custom icon is set';
    is $entry->custom_icon, undef, 'Icon is undef if no custom icon is set';
    is $entry->icon_id, 42, 'Default icon is set to something';

    is $entry->custom_icon($gif), $gif, 'Setting a custom icon returns icon';
    is $entry->custom_icon, $gif, 'Henceforth the icon is set';
    is $entry->icon_id, 0, 'Default icon got changed to first icon';
    my $uuid = $entry->custom_icon_uuid;
    isnt $uuid, undef, 'UUID is now set';

    my $found = $entry->kdbx->custom_icon_data($uuid);
    is $entry->custom_icon, $found, 'Custom icon on entry matches the database';

    is $entry->custom_icon(undef), undef, 'Unsetting a custom icon returns undefined';
    $found = $entry->kdbx->custom_icon_data($uuid);
    is $found, $gif, 'Custom icon still exists in the database';
};

done_testing;
