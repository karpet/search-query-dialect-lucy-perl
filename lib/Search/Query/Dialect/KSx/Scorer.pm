package Search::Query::Dialect::KSx::Scorer;
use strict;
use warnings;
use base qw( KinoSearch::Search::Matcher );
use Carp;

our $VERSION = '0.01';

# Inside-out member vars.
my %doc_ids;
my %tally;
my %tick;

=head1 NAME

Search::Query::Dialect::KSx::Scorer - KinoSearch query extension

=head1 SYNOPSIS

 # see KinoSearch::Search::Matcher

=head1 METHODS

This class isa KinoSearch::Search::Matcher subclass.
Only new or overridden methods are documented.

=cut

=head2 new( I<args> )

Returns a new Scorer object.

=cut

sub new {
    my ( $class, %args ) = @_;
    my $posting_lists = delete $args{posting_lists};
    my $self          = $class->SUPER::new(%args);

    # Cheesy but simple way of interleaving PostingList doc sets.
    my %all_doc_ids;
    for my $posting_list (@$posting_lists) {
        while ( my $doc_id = $posting_list->next ) {
            $all_doc_ids{$doc_id} = undef;
        }
    }
    my @doc_ids = sort { $a <=> $b } keys %all_doc_ids;
    $doc_ids{$$self} = \@doc_ids;

    $tick{$$self}  = -1;
    $tally{$$self} = KinoSearch::Search::Tally->new;
    $tally{$$self}->set_score(1.0);    # fixed score of 1.0

    return $self;
}

sub DESTROY {
    my $self = shift;
    delete $doc_ids{$$self};
    delete $tick{$$self};
    delete $tally{$$self};
    $self->SUPER::DESTROY;
}

=head2 next

Returns the next doc_id or 0.

=cut

sub next {
    my $self    = shift;
    my $doc_ids = $doc_ids{$$self};
    my $tick    = ++$tick{$$self};
    return 0 if $tick >= scalar @$doc_ids;
    return $doc_ids->[$tick];
}

=head2 get_doc_id

Returns a doc_id.

=cut

sub get_doc_id {
    my $self    = shift;
    my $tick    = $tick{$$self};
    my $doc_ids = $doc_ids{$$self};
    return $tick < scalar @$doc_ids ? $doc_ids->[$tick] : 0;
}

=head2 tally

Returns the tally for the Scorer (a KinoSearch::Search::Tally object).

=cut

sub tally {
    my $self = shift;
    return $tally{$$self};
}

1;

__END__

=head1 AUTHOR

Peter Karman, C<< <karman at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-search-query-dialect-ksx at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Search-Query-Dialect-KSx>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Search::Query::Dialect::KSx


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Search-Query-Dialect-KSx>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Search-Query-Dialect-KSx>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Search-Query-Dialect-KSx>

=item * Search CPAN

L<http://search.cpan.org/dist/Search-Query-Dialect-KSx/>

=back

=head1 ACKNOWLEDGEMENTS

Based on the sample PrefixQuery code in the KinoSearch distribution.

=head1 COPYRIGHT & LICENSE

Copyright 2010 Peter Karman.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=cut
