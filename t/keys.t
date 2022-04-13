#!/usr/bin/env perl

use warnings;
use strict;

use lib 't/lib';
use TestCommon;

use Crypt::Misc 0.029 qw(decode_b64 encode_b64);
use Test::More;

BEGIN { use_ok 'File::KDBX::Key' }

subtest 'Primitives' => sub {
    my $pkey = File::KDBX::Key->new('password');
    isa_ok $pkey, 'File::KDBX::Key::Password';
    is $pkey->raw_key, decode_b64('XohImNooBHFR0OVvjcYpJ3NgPQ1qq73WKhHvch0VQtg='),
        'Can calculate raw key from password' or diag encode_b64($pkey->raw_key);

    my $fkey = File::KDBX::Key->new(\'password');
    isa_ok $fkey, 'File::KDBX::Key::File';
    is $fkey->raw_key, decode_b64('XohImNooBHFR0OVvjcYpJ3NgPQ1qq73WKhHvch0VQtg='),
        'Can calculate raw key from file' or diag encode_b64($fkey->raw_key);

    my $ckey = File::KDBX::Key->new([
        $pkey,
        $fkey,
        'another password',
        File::KDBX::Key::File->new(testfile(qw{keys hashed.key})),
    ]);
    isa_ok $ckey, 'File::KDBX::Key::Composite';
    is $ckey->raw_key, decode_b64('FLV8/zOT9mEL8QKkzizq7mJflnb25ITblIPq608MGrk='),
        'Can calculate raw key from composite' or diag encode_b64($ckey->raw_key);
};

subtest 'File keys' => sub {
    my $key = File::KDBX::Key::File->new(testfile(qw{keys xmlv1.key}));
    is $key->raw_key, decode_b64('OF9tj+tfww1kHNWQaJlZWIlBdoTVXOazP8g/vZK7NcI='),
        'Can calculate raw key from XML file' or diag encode_b64($key->raw_key);
    is $key->type, 'xml', 'file type is detected as xml';
    is $key->version, '1.0', 'file version is detected as xml';

    $key = File::KDBX::Key::File->new(testfile(qw{keys xmlv2.key}));
    is $key->raw_key, decode_b64('OF9tj+tfww1kHNWQaJlZWIlBdoTVXOazP8g/vZK7NcI='),
        'Can calculate raw key from XML file' or diag encode_b64($key->raw_key);
    is $key->type, 'xml', 'file type is detected as xml';
    is $key->version, '2.0', 'file version is detected as xml';

    $key = File::KDBX::Key::File->new(testfile(qw{keys binary.key}));
    is $key->raw_key, decode_b64('QlkDxuYbDPDpDXdK1470EwVBL+AJBH2gvPA9lxNkFEk='),
        'Can calculate raw key from binary file' or diag encode_b64($key->raw_key);
    is $key->type, 'binary', 'file type is detected as binary';

    $key = File::KDBX::Key::File->new(testfile(qw{keys hex.key}));
    is $key->raw_key, decode_b64('QlkDxuYbDPDpDXdK1470EwVBL+AJBH2gvPA9lxNkFEk='),
        'Can calculate raw key from hex file' or diag encode_b64($key->raw_key);
    is $key->type, 'hex', 'file type is detected as hex';

    $key = File::KDBX::Key::File->new(testfile(qw{keys hashed.key}));
    is $key->raw_key, decode_b64('8vAO4mrMeq6iCa1FHeWm/Mj5al8HIv2ajqsqsSeUC6U='),
        'Can calculate raw key from binary file' or diag encode_b64($key->raw_key);
    is $key->type, 'hashed', 'file type is detected as hashed';

    my $buf = 'password';
    open(my $fh, '<', \$buf) or die "open failed: $!\n";

    $key = File::KDBX::Key::File->new($fh);
    is $key->raw_key, decode_b64('XohImNooBHFR0OVvjcYpJ3NgPQ1qq73WKhHvch0VQtg='),
        'Can calculate raw key from file handle' or diag encode_b64($key->raw_key);
    is $key->type, 'hashed', 'file type is detected as hashed';

    is exception { File::KDBX::Key::File->new }, undef, 'Can instantiate uninitialized';

    like exception { File::KDBX::Key::File->init },
        qr/^Missing key primitive/, 'Throws if no primitive is provided';

    like exception { File::KDBX::Key::File->new(testfile(qw{keys nonexistent})) },
        qr/^Failed to open key file/, 'Throws if file is missing';

    like exception { File::KDBX::Key::File->new({}) },
        qr/^Unexpected primitive type/, 'Throws if primitive is the wrong type';
};

done_testing;
