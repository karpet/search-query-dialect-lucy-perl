package Search::Query::Dialect::Lucy::Compiler;
use strict;
use warnings;
use base qw( Lucy::Search::Compiler );
use Carp;
use Search::Query::Dialect::Lucy::Scorer;
use Data::Dump qw( dump );

our $VERSION = '0.01';

# inside out vars
my (%include,           %searchable,        %idf,
    %raw_impact,        %lex_terms,         %doc_freq,
    %query_norm_factor, %normalized_impact, %term_freq
);

sub DESTROY {
    my $self = shift;
    delete $include{$$self};
    delete $raw_impact{$$self};
    delete $query_norm_factor{$$self};
    delete $searchable{$$self};
    delete $lex_terms{$$self};
    delete $normalized_impact{$$self};
    delete $idf{$$self};
    delete $doc_freq{$$self};
    delete $term_freq{$$self};
    $self->SUPER::DESTROY;
}

=head1 NAME

Search::Query::Dialect::Lucy::Compiler - Lucy query extension

=head1 SYNOPSIS

    # see Lucy::Search::Compiler

=head1 METHODS

This class isa Lucy::Search::Compiler subclass . Only new
or overridden methods are documented .

=cut

=head2 new( I<args> )

Returns a new Compiler object.

=cut

sub new {
    my $class      = shift;
    my %args       = @_;
    my $include    = delete $args{include} || 0;
    my $searchable = $args{searchable} || $args{searcher};
    if ( !$searchable ) {
        croak "searcher required";
    }
    my $self = $class->SUPER::new(%args);
    $include{$$self}    = $include;
    $searchable{$$self} = $searchable;
    return $self;
}

=head2 make_matcher( I<args> )

Returns a Search::Query::Dialect::Lucy::Scorer object.

=cut

sub make_matcher {
    my ( $self, %args ) = @_;

    my $seg_reader = $args{reader};
    my $searchable = $searchable{$$self};

    # Retrieve low-level components LexiconReader and PostingListReader.
    my $lex_reader = $seg_reader->obtain("Lucy::Index::LexiconReader");
    my $plist_reader
        = $seg_reader->obtain("Lucy::Index::PostingListReader");

    # Acquire a Lexicon and seek it to our query string.
    my $parent  = $self->get_parent;
    my $term    = $parent->get_term;
    my $regex   = $parent->get_regex;
    my $suffix  = $parent->get_suffix;
    my $field   = $parent->get_field;
    my $prefix  = $parent->get_prefix;
    my $lexicon = $lex_reader->lexicon( field => $field );
    return unless $lexicon;

    # Retrieve the correct Similarity for the Query's field.
    my $sim = $args{similarity} || $searchable->get_schema->fetch_sim($field);

    $lexicon->seek( defined $prefix ? $prefix : '' );

    # Accumulate PostingLists for each matching term.
    my @posting_lists;
    my @lex_terms;
    my $include = $include{$$self};
    while ( defined( my $lex_term = $lexicon->get_term ) ) {

        #warn
        #    "lex_term=$lex_term   prefix=$prefix   suffix=$suffix   regex=$regex";

        # weed out non-matchers early.
        if ( defined $suffix and index( $lex_term, $suffix ) < 0 ) {
            last unless $lexicon->next;
            next;
        }
        last if defined $prefix and index( $lex_term, $prefix ) != 0;

        #carp "$term field:$field: term>$lex_term<";

        if ($include) {
            unless ( $lex_term =~ $regex ) {
                last unless $lexicon->next;
                next;
            }
        }
        else {
            if ( $lex_term =~ $regex ) {
                last unless $lexicon->next;
                next;
            }
        }
        my $posting_list = $plist_reader->posting_list(
            field => $field,
            term  => $lex_term,
        );

        #carp "check posting_list";
        if ($posting_list) {
            push @posting_lists, $posting_list;
            push @lex_terms,     $lex_term;
        }
        last unless $lexicon->next;
    }
    return unless @posting_lists;

    $doc_freq{$$self}  = scalar(@posting_lists);
    $lex_terms{$$self} = \@lex_terms;

    #carp dump \@posting_lists;

    # Calculate and store the IDF
    my $max_doc = $searchable->doc_max;
    my $idf     = $idf{$$self}
        = $max_doc
        ? $searchable->get_schema->fetch_type($field)->get_boost
        + log( $max_doc / ( 1 + $doc_freq{$$self} ) )
        : $searchable->get_schema->fetch_type($field)->get_boost;

    $raw_impact{$$self} = $idf * $parent->get_boost;

    #carp "raw_impact{$$self}= $raw_impact{$$self}";

    # make final preparations
    $self->_perform_query_normalization($searchable);

    return Search::Query::Dialect::Lucy::Scorer->new(
        posting_lists => \@posting_lists,
        compiler      => $self,
    );
}

=head2 get_searchable

Returns the Searchable object for this Compiler.

=cut

sub get_searchable {
    my $self = shift;
    return $searchable{$$self};
}

=head2 get_doc_freq

Returns the document frequency for this Compiler.

=cut

sub get_doc_freq {
    my $self = shift;
    return $doc_freq{$$self};
}

=head2 get_lex_terms

Returns array ref of the terms in the lexicon that matched.

=cut

sub get_lex_terms {
    my $self = shift;
    return $lex_terms{$$self};
}

sub _perform_query_normalization {

    # copied from Lucy::Search::Weight originally
    my ( $self, $searcher ) = @_;
    my $sim    = $self->get_similarity;
    my $factor = $self->sum_of_squared_weights;    # factor = ( tf_q * idf_t )
    $factor = $sim->query_norm($factor);           # factor /= norm_q
    $self->normalize($factor);                     # impact *= factor

    #carp "normalize factor=$factor";
}

=head2 apply_norm_factor( I<factor> )

Overrides base class. Currently just passes I<factor> on to parent method.

=cut

sub apply_norm_factor {

    # pass-through for now
    my ( $self, $factor ) = @_;
    $self->SUPER::apply_norm_factor($factor);
}

=head2 get_boost

Returns the boost for the parent Query object.

=cut

sub get_boost { shift->get_parent->get_boost }

=head2 sum_of_squared_weights

Returns imact of term on score.

=cut

sub sum_of_squared_weights {

    # pass-through for now
    my $self = shift;
    return exists $raw_impact{$$self} ? $raw_impact{$$self}**2 : '1.0';
}

=head2 normalize()

Affects the score of the term. See Lucy::Search::Compiler.

=cut

sub normalize {    # copied from TermQuery
    my ( $self, $query_norm_factor ) = @_;
    $query_norm_factor{$$self} = $query_norm_factor;

    # Multiply raw impact by ( tf_q * idf_q / norm_q )
    #
    # Note: factoring in IDF a second time is correct.  See formula.
    $normalized_impact{$$self}
        = $raw_impact{$$self} * $idf{$$self} * $query_norm_factor;

    #carp "normalized_impact{$$self} = $normalized_impact{$$self}";
    return $normalized_impact{$$self};
}

1;

__END__

=head1 AUTHOR

Peter Karman, C<< <karman at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-search-query-dialect-lucy at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Search-Query-Dialect-Lucy>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Search::Query::Dialect::Lucy


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Search-Query-Dialect-Lucy>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Search-Query-Dialect-Lucy>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Search-Query-Dialect-Lucy>

=item * Search CPAN

L<http://search.cpan.org/dist/Search-Query-Dialect-Lucy/>

=back

=head1 ACKNOWLEDGEMENTS

Based on the sample PrefixQuery code in the Lucy distribution.

=head1 COPYRIGHT & LICENSE

Copyright 2010 Peter Karman.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=cut
