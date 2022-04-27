package File::KDBX::Iterator;
# PACKAGE: KDBX database iterator

use warnings;
use strict;

use File::KDBX::Error;
use File::KDBX::Util qw(:class :load :search);
use Iterator::Simple;
use Ref::Util qw(is_arrayref is_coderef is_scalarref);
use namespace::clean;

extends 'Iterator::Simple::Iterator';

our $VERSION = '999.999'; # VERSION

=method new

    \&iterator = File::KDBX::Iterator->new(\&iterator);

Blesses an iterator to augment it with buffering plus some useful utility methods.

=cut

sub new {
    my $class = shift;
    my $code  = is_coderef($_[0]) ? shift : sub { undef };

    my $items = @_ == 1 && is_arrayref($_[0]) ? $_[0] : \@_;
    return $class->SUPER::new(sub {
        if (@_) {   # put back
            if (@_ == 1 && is_arrayref($_[0])) {
                $items = $_[0];
            }
            else {
                unshift @$items, @_;
            }
            return;
        }
        else {
            my $next = shift @$items;
            return $next if defined $next;
            return $code->();
        }
    });
}

=method next

    $item = $iterator->next;
    # OR equivalently
    $item = $iterator->();

    $item = $iterator->next(\&query);
    $item = $iterator->next([\'simple expression', @fields]);

Get the next item or C<undef> if there are no more items. If a query is passed, get the next matching item,
discarding any items before the matching item that do not match. Example:

    my $item = $iterator->next(sub { $_->label =~ /Gym/ });

=cut

sub _create_query {
    my $self = shift;
    my $code = shift;

    if (is_coderef($code) || overload::Method($code, '&{}')) {
        return $code;
    }
    elsif (is_scalarref($code)) {
        return simple_expression_query($$code, @_);
    }
    else {
        return query($code, @_);
    }
}

sub next {
    my $self = shift;
    my $code = shift or return $self->();

    $code = $self->_create_query($code, @_);

    while (defined (local $_ = $self->())) {
        return $_ if $code->($_);
    }
    return;
}

=method peek

    $item = $iterator->peek;

Peek at the next item. Returns C<undef> if the iterator is empty. This allows you to access the next item
without draining it from the iterator. The same item will be returned the next time L</next> is called.

=cut

sub peek {
    my $self = shift;

    my $next = $self->();
    $self->($next) if defined $next;
    return $next;
}

=method unget

    $iterator->unget(\@items);
    $iterator->unget(...);
    # OR equivalently
    $iterator->(\@items);
    $iterator->(...);

Replace the buffer or unshift one or more items to the current buffer.

See L</Buffer>.

=cut

sub unget {
    my $self = shift;   # Must shift in a statement before calling.
    $self->(@_);
}

=method each

    @items = $iterator->each;

    $iterator->each(sub($item, $num) { ... });

Get the rest of the items. There are two forms: Without arguments, C<each> returns a list of the rest of the
items. Or pass a coderef to be called once per item, in order. The item is passed as the first argument to the
given subroutine and is also available as C<$_>.

=cut

sub each {
    my $self = shift;
    my $cb = shift or return @{$self->to_array};

    my $count = 0;
    $cb->($_, $count++) while defined (local $_ = $self->());
    return $self;
}

=method limit

    \&iterator = $iterator->limit($count);

Get a new iterator draining from an existing iterator but providing only a limited number of items.

=cut

sub limit { shift->head(@_) }

=method grep

    \&iterator = $iterator->grep(\&query);
    \&iterator = $iterator->grep([\'simple expression', @fields]);

Get a new iterator draining from an existing iterator but providing only items that pass a test or are matched
by a query.

=cut

sub grep {
    my $self = shift;
    my $code = shift;

    $code = $self->_create_query($code, @_);

    ref($self)->new(sub {
        while (defined (local $_ = $self->())) {
            return $_ if $code->($_);
        }
        return;
    });
}

=method map

    \&iterator = $iterator->map(\&code);

Get a new iterator draining from an existing iterator but providing modified items.

=cut

sub map {
    my $self = shift;
    my $code = shift;

    ref($self)->new(sub {
        local $_ = $self->();
        return if !defined $_;
        return $code->();
    });
}

=method filter

    \&iterator = $iterator->filter(\&query);
    \&iterator = $iterator->filter([\'simple expression', @fields]);

See L<Iterator::Simple/"ifilter $iterable, sub{ CODE }">.

=cut

sub filter {
    my $self = shift;
    my $code = shift;
    return $self->SUPER::filter($self->_create_query($code, @_));
}

=method sort_by

=method order_by

    \&iterator = $iterator->sort_by($field, %options);
    \&iterator = $iterator->sort_by(\&get_value, %options);

Get a new iterator draining from an existing iterator but providing items sorted by an object field. Sorting
is done using L<Unicode::Collate> (if available) or C<cmp> to sort alphanumerically. The C<\&get_value>
subroutine is called once for each item and should return a string value. Options:

=for :list
* C<ascending> - Order ascending if true, descending otherwise (default: true)
* C<case> - If true, take case into account, otherwise ignore case (default: true)
* C<collate> - If true, use B<Unicode::Collate> (if available), otherwise use perl built-ins (default: true)
* Any B<Unicode::Collate> option is also supported.

C<sort_by> and C<order_by> are aliases.

B<NOTE:> This method drains the iterator completely but adds items back onto the buffer, so the iterator is
still usable afterward. Nevertheless, you mustn't call this on an infinite iterator or it will run until
available memory is depleted.

=cut

sub sort_by  { shift->order_by(@_)  }
sub nsort_by { shift->norder_by(@_) }

sub order_by {
    my $self    = shift;
    my $field   = shift;
    my %args    = @_;

    my $ascending = delete $args{ascending} // !delete $args{descending} // 1;
    my $case = delete $args{case} // !delete $args{no_case} // 1;
    my $collate = (delete $args{collate} // !delete $args{no_collate} // 1)
        && try_load_optional('Unicode::Collate');

    if ($collate && !$case) {
        $case = 1;
        # use a proper Unicode::Collate level to ignore case
        $args{level} //= 2;
    }
    $args{upper_before_lower} //= 1;

    my $value = $field;
    $value = $case ? sub { $_[0]->$field // '' } : sub { uc($_[0]->$field) // '' } if !is_coderef($value);
    my @all = CORE::map { [$_, $value->($_)] } @{$self->to_array};

    if ($collate) {
        my $c = Unicode::Collate->new(%args);
        if ($ascending) {
            @all = CORE::map { $_->[0] } CORE::sort { $c->cmp($a->[1], $b->[1]) } @all;
        } else {
            @all = CORE::map { $_->[0] } CORE::sort { $c->cmp($b->[1], $a->[1]) } @all;
        }
    } else {
        if ($ascending) {
            @all = CORE::map { $_->[0] } CORE::sort { $a->[1] cmp $b->[1] } @all;
        } else {
            @all = CORE::map { $_->[0] } CORE::sort { $b->[1] cmp $a->[1] } @all;
        }
    }

    $self->(\@all);
    return $self;
}

=method nsort_by

=method norder_by

    \&iterator = $iterator->nsort_by($field, %options);
    \&iterator = $iterator->nsort_by(\&get_value, %options);

Get a new iterator draining from an existing iterator but providing items sorted by an object field. Sorting
is done numerically using C<< <=> >>. The C<\&get_value> subroutine is called once for each item and should
return a numerical value. Options:

=for :list
* C<ascending> - Order ascending if true, descending otherwise (default: true)

C<nsort_by> and C<norder_by> are aliases.

B<NOTE:> This method drains the iterator completely but adds items back onto the buffer, so the iterator is
still usable afterward. Nevertheless, you mustn't call this on an infinite iterator or it will run until
available memory is depleted.

=cut

sub norder_by {
    my $self    = shift;
    my $field   = shift;
    my %args    = @_;

    my $ascending = $args{ascending} // !$args{descending} // 1;

    my $value = $field;
    $value = sub { $_[0]->$field // 0 } if !is_coderef($value);
    my @all = CORE::map { [$_, $value->($_)] } @{$self->to_array};

    if ($ascending) {
        @all = CORE::map { $_->[0] } CORE::sort { $a->[1] <=> $b->[1] } @all;
    } else {
        @all = CORE::map { $_->[0] } CORE::sort { $b->[1] <=> $a->[1] } @all;
    }

    $self->(\@all);
    return $self;
}

=method to_array

    \@array = $iterator->to_array;

Get the rest of the items from an iterator as an arrayref.

B<NOTE:> This method drains the iterator completely, leaving the iterator empty. You mustn't call this on an
infinite iterator or it will run until available memory is depleted.

=cut

sub to_array {
    my $self = shift;

    my @all;
    push @all, $_ while defined (local $_ = $self->());
    return \@all;
}

=method count

=method size

    $size = $iterator->count;

Count the rest of the items from an iterator.

B<NOTE:> This method drains the iterator completely but adds items back onto the buffer, so the iterator is
still usable afterward. Nevertheless, you mustn't call this on an infinite iterator or it will run until
available memory is depleted.

=cut

sub size {
    my $self = shift;

    my $items = $self->to_array;
    $self->($items);
    return scalar @$items;
}

sub count { shift->size }

sub TO_JSON { $_[0]->to_array }

1;
__END__

=for Pod::Coverage TO_JSON

=head1 SYNOPSIS

    $kdbx->entries
        ->grep(sub { $_->title =~ /bank/i })
        ->sort_by('title')
        ->limit(5)
        ->each(sub {
            say $_->title;
        });

=head1 DESCRIPTION

A buffered iterator compatible with and expanding upon L<Iterator::Simple>, this provides an easy way to
navigate a L<File::KDBX> database.

=head2 Buffer

This iterator is buffered, meaning it can drain from an iterator subroutine under the hood, storing items
temporarily to be accessed later. This allows features like L</peek> and L</sort> which might be useful in the
context of KDBX databases which are normally pretty small so draining an iterator isn't cost-prohibitive.

The way this works is that if you call an iterator without arguments, it acts like a normal iterator. If you
call it with arguments, however, the arguments are added to the buffer. When called without arguments, the
buffer is drained before the iterator function is. Using L</unget> is equivalent to calling the iterator with
arguments, and as L</next> is equivalent to calling the iterator without arguments.

=cut
