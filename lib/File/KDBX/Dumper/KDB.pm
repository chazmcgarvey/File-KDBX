package File::KDBX::Dumper::KDB;
# ABSTRACT: Write KDB files

use warnings;
use strict;

use Crypt::PRNG qw(irand);
use Encode qw(encode);
use File::KDBX::Constants qw(:magic);
use File::KDBX::Error;
use File::KDBX::Loader::KDB;
use File::KDBX::Util qw(:class :uuid load_optional);
use namespace::clean;

extends 'File::KDBX::Dumper';

our $VERSION = '999.999'; # VERSION

sub _write_magic_numbers { '' }
sub _write_headers { '' }

sub _write_body {
    my $self = shift;
    my $fh = shift;
    my $key = shift;

    load_optional(qw{File::KeePass File::KeePass::KDBX});

    my $k = File::KeePass::KDBX->new($self->kdbx)->to_fkp;
    $self->_write_custom_icons($self->kdbx, $k);

    # TODO create a KPX_CUSTOM_ICONS_4 meta stream. FKP itself handles KPX_GROUP_TREE_STATE

    substr($k->header->{seed_rand}, 16) = '';

    $key = $self->kdbx->composite_key($key, keep_primitive => 1);

    my $dump = eval { $k->gen_db(File::KDBX::Loader::KDB::_convert_kdbx_to_keepass_master_key($key)) };
    if (my $err = $@) {
        throw 'Failed to generate KDB file', error => $err;
    }

    $self->kdbx->key($key);

    print $fh $dump;
}

sub _write_custom_icons {
    my $self = shift;
    my $kdbx = shift;
    my $k    = shift;

    return if $kdbx->sig2 != KDBX_SIG2_1;
    return if $k->find_entries({
        title       => 'Meta-Info',
        username    => 'SYSTEM',
        url         => '$',
        comment     => 'KPX_CUSTOM_ICONS_4',
    });

    my @icons;      # icon data
    my %icons;      # icon uuid -> index
    my %entries;    # id -> index
    my %groups;     # id -> index
    my %gid;

    for my $icon (@{$kdbx->custom_icons}) {
        my $uuid = $icon->{uuid};
        my $data = $icon->{data} or next;
        push @icons, $data;
        $icons{$uuid} = $#icons;
    }
    for my $entry ($k->find_entries({})) {
        my $icon_uuid = $entry->{custom_icon_uuid} // next;
        my $icon_index = $icons{$icon_uuid} // next;

        $entry->{id} //= generate_uuid;
        next if $entries{$entry->{id}};

        $entries{$entry->{id}} = $icon_index;
    }
    for my $group ($k->find_groups({})) {
        $gid{$group->{id} || ''}++;
        my $icon_uuid = $group->{custom_icon_uuid} // next;
        my $icon_index = $icons{$icon_uuid} // next;

        if ($group->{id} =~ /^[A-Fa-f0-9]{16}$/) {
            $group->{id} = hex($group->{id});
        }
        elsif ($group->{id} !~ /^\d+$/) {
            do {
                $group->{id} = irand;
            } while $gid{$group->{id}};
        }
        $gid{$group->{id}}++;
        next if $groups{$group->{id}};

        $groups{$group->{id}} = $icon_index;
    }

    return if !@icons;

    my $stream = '';
    $stream .= pack('L<3', scalar @icons, scalar keys %entries, scalar keys %groups);
    for (my $i = 0; $i < @icons; ++$i) {
        $stream .= pack('L<', length($icons[$i]));
        $stream .= $icons[$i];
    }
    while (my ($id, $icon_index) = each %entries) {
        $stream .= pack('a16 L<', $id, $icon_index);
    }
    while (my ($id, $icon_index) = each %groups) {
        $stream .= pack('L<2', $id, $icon_index);
    }

    $k->add_entry({
        comment     => 'KPX_CUSTOM_ICONS_4',
        title       => 'Meta-Info',
        username    => 'SYSTEM',
        url         => '$',
        id          => '0' x 16,
        icon        => 0,
        binary      => {'bin-stream' => $stream},
    });
}

1;
__END__

=head1 DESCRIPTION

Dump older KDB (KeePass 1) files. This feature requires additional modules to be installed:

=for :list
* L<File::KeePass>
* L<File::KeePass::KDBX>

=cut
