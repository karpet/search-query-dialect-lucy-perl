package Search::Query::Dialect::KSx::Compiler;
use strict;
use warnings;
use base qw( KinoSearch::Search::Compiler );
use Carp;
use Search::Query::Dialect::KSx::Scorer;

our $VERSION = '0.01';

# inside out vars
my %include;

=head1 NAME

Search::Query::Dialect::KSx::Compiler - KinoSearch query extension

=head1 SYNOPSIS

 # see KinoSearch::Search::Compiler

=head1 METHODS

This class isa KinoSearch::Search::Compiler subclass.
Only new or overridden methods are documented.

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
    my $substring = $self->get_parent->get_query_string;
    $substring =~ s/\*.\s*$//;
    my $field = $self->get_parent->get_field;
    my $lexicon = $lex_reader->lexicon( field => $field );
    return unless $lexicon;
    $lexicon->seek($substring);

    # Accumulate PostingLists for each matching term.
    my @posting_lists;
    my $include = $include{$$self};
    while ( defined( my $term = $lexicon->get_term ) ) {
        if ($include) {
            last unless $term =~ m/^\Q$substring/;
        }
        else {
            last if $term =~ m/^\Q$substring/;
        }
        my $posting_list = $plist_reader->posting_list(
            field => $field,
            term  => $term,
        );
        if ($posting_list) {
            push @posting_lists, $posting_list;
        }
        last unless $lexicon->next;
    }
    return unless @posting_lists;

    return Search::Query::Dialect::KSx::Scorer->new(
        posting_lists => \@posting_lists );
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
