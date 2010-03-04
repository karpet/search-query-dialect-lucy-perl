package Search::Query::Dialect::KSx::Compiler;
use strict;
use warnings;
use base qw( KinoSearch::Search::Compiler );
use Carp;
use Search::Query::Dialect::KSx::Scorer;
use Data::Dump qw( dump );

our $VERSION = '0.02';

# inside out vars
my %include;
my ( %idf, %raw_impact, %terms, %query_norm_factor, %normalized_impact, );

=head1 NAME

Search::Query::Dialect::KSx::Compiler - KinoSearch query extension

=head1 SYNOPSIS

    # see KinoSearch::Search::Compiler

=head1 METHODS

This class isa KinoSearch::Search::Compiler subclass . Only new
or overridden methods are documented .

=cut

=head2 new( I<args> )

Returns a new Compiler object.

=cut

sub new {
    my $class   = shift;
    my %args    = @_;
    my $include = delete $args{include} || 0;
    my $self    = $class->SUPER::new(%args);
    $include{$$self} = $include;
    return $self;
}

=head2 make_matcher( I<args> )

Returns a Search::Query::Dialect::KSx::Scorer object.

=cut

sub make_matcher {
    my ( $self, %args ) = @_;
    my $seg_reader = $args{reader};

    # Retrieve low-level components LexiconReader and PostingListReader.
    my $lex_reader = $seg_reader->obtain("KinoSearch::Index::LexiconReader");
    my $plist_reader
        = $seg_reader->obtain("KinoSearch::Index::PostingListReader");

    # Acquire a Lexicon and seek it to our query string.
    my $term    = $self->get_parent->get_term;
    my $regex   = $self->get_parent->get_regex;
    my $field   = $self->get_parent->get_field;
    my $prefix  = $self->get_parent->get_prefix;
    my $lexicon = $lex_reader->lexicon( field => $field );
    return unless $lexicon;
    $lexicon->seek( defined $prefix ? $prefix : '' );

    # Accumulate PostingLists for each matching term.
    my @posting_lists;
    my $include = $include{$$self};
    while ( defined( my $lex_term = $lexicon->get_term ) ) {

        # weed out non-matchers early.
        last if defined $prefix and index( $lex_term, $prefix ) != 0;

        #carp "$term field:$field: term>$lex_term<";
        if ($include) {
            next unless $lex_term =~ $regex;
        }
        else {
            last if $lex_term =~ $regex;
        }
        my $posting_list = $plist_reader->posting_list(
            field => $field,
            term  => $lex_term,
        );

        #carp "check posting_list";
        if ($posting_list) {
            push @posting_lists, $posting_list;
        }
        last unless $lexicon->next;
    }
    return unless @posting_lists;

    #carp dump \@posting_lists;

    return Search::Query::Dialect::KSx::Scorer->new(
        posting_lists => \@posting_lists,
        compiler      => $self,
    );
}

# TODO decipher this
#sub perform_query_normalization {
#
#    # copied from KinoSearch::Search::Weight originally
#    my ( $self, $searcher ) = @_;
#    my $sim = $self->get_similarity;
#
#    my $factor = $self->sum_of_squared_weights;    # factor = ( tf_q * idf_t )
#    $factor = $sim->query_norm($factor);           # factor /= norm_q
#    $self->normalize($factor);                     # impact *= factor
#}

=head2 get_boost

Returns the boost for the parent Query object.

=cut

sub get_boost { shift->get_parent->get_boost }

# TODO decipher this
#sub sum_of_squared_weights { my $self = shift; $raw_impact{$$self}**2 }

# TODO decipher this
#sub normalize {                                    # copied from TermQuery
#    my ( $self, $query_norm_factor ) = @_;
#    $query_norm_factor{$$self} = $query_norm_factor;
#
#    # Multiply raw impact by ( tf_q * idf_q / norm_q )
#    #
#    # Note: factoring in IDF a second time is correct.  See formula.
#    $normalized_impact{$$self}
#        = $raw_impact{$$self} * $idf{$$self} * $query_norm_factor;
#}

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
