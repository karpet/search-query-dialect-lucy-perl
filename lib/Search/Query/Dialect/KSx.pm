package Search::Query::Dialect::KSx;
use strict;
use warnings;
use base qw( Search::Query::Dialect::Native );
use Carp;
use Data::Dump qw( dump );
use Scalar::Util qw( blessed );
use Search::Query::Field::KSx;
use KinoSearch::Search::ANDQuery;
use KinoSearch::Search::NoMatchQuery;
use KinoSearch::Search::NOTQuery;
use KinoSearch::Search::ORQuery;
use KinoSearch::Search::PhraseQuery;
use KinoSearch::Search::RangeQuery;
use KinoSearch::Search::TermQuery;
use Search::Query::Dialect::KSx::NOTWildcardQuery;
use Search::Query::Dialect::KSx::WildcardQuery;

our $VERSION = '0.01';

__PACKAGE__->mk_accessors(
    qw(
        wildcard
        fuzzify
        )
);

=head1 NAME

Search::Query::Dialect::KSx - KinoSearch query dialect

=head1 SYNOPSIS

 my $query = Search::Query->parser( dialect => 'KSx' )->parse('foo');
 print $query;
 my $ks_query = $query->as_ks_query();
 my $hits = $ks_searcher->hits( query => $ks_query );

=head1 DESCRIPTION

Search::Query::Dialect::KSx extends the KinoSearch::QueryParser syntax
to support wildcards, proximity and ranges, in addition to the standard
Search::Query features.

=head1 METHODS

This class is a subclass of Search::Query::Dialect. Only new or overridden
methods are documented here.

=cut

=head2 init

Overrides base method and sets SWISH-appropriate defaults.
Can take the following params, also available as standard attribute
methods.

=over

=item wildcard

Default is '*'.

=item fuzzify

If true, a wildcard is automatically appended to each query term.

=back

=cut

sub init {
    my $self = shift;

    $self->SUPER::init(@_);

    #carp dump $self;
    $self->{wildcard} = '*';

    if ( $self->{default_field} and !ref( $self->{default_field} ) ) {
        $self->{default_field} = [ $self->{default_field} ];
    }

    return $self;
}

=head2 stringify

Returns the Query object as a normalized string.

=cut

my %op_map = (
    '+' => 'AND',
    ''  => 'OR',
    '-' => 'NOT',
);

sub stringify {
    my $self = shift;
    my $tree = shift || $self;

    my @q;
    foreach my $prefix ( '+', '', '-' ) {
        my @clauses;
        my $joiner = $op_map{$prefix};
        next unless exists $tree->{$prefix};
        for my $clause ( @{ $tree->{$prefix} } ) {
            push( @clauses, $self->stringify_clause( $clause, $prefix ) );
        }
        next if !@clauses;

        push @q, join( " $joiner ", grep { defined and length } @clauses );
    }

    return join " AND ", @q;
}

sub _doctor_value {
    my ( $self, $clause ) = @_;

    my $value = $clause->{value};

    if ( $self->fuzzify ) {
        $value .= '*' unless $value =~ m/[\*]/;
    }

    return $value;
}

=head2 stringify_clause( I<leaf>, I<prefix> )

Called by stringify() to handle each Clause in the Query tree.

=cut

sub stringify_clause {
    my $self   = shift;
    my $clause = shift;
    my $prefix = shift;

    #warn dump $clause;
    #warn "prefix = '$prefix'";

    if ( $clause->{op} eq '()' ) {
        if ( $clause->has_children and $clause->has_children == 1 ) {
            return $self->stringify( $clause->{value} );
        }
        else {
            return
                ( $prefix eq '-' ? 'NOT ' : '' ) . "("
                . $self->stringify( $clause->{value} ) . ")";
        }
    }

    # make sure we have a field
    my $default_field = $self->default_field || $self->parser->default_field;
    my @fields
        = $clause->{field}
        ? ( $clause->{field} )
        : ( defined $default_field ? @$default_field : () );

    # what value
    my $value
        = ref $clause->{value}
        ? $clause->{value}
        : $self->_doctor_value($clause);

    # if we have no fields, we're done
    return $value unless @fields;

    my $wildcard = $self->wildcard;

    # normalize operator
    my $op = $clause->{op} || ":";
    if ( $op eq '=' ) {
        $op = ':';
    }
    if ( $prefix eq '-' ) {
        $op = '!' . $op;
    }
    if ( $value =~ m/\%/ ) {
        $op = $prefix eq '-' ? '!~' : '~';
    }

    my $quote = $clause->quote || '';

    my @buf;
NAME: for my $name (@fields) {
        my $field = $self->_get_field($name);

        if ( defined $field->callback ) {
            push( @buf, $field->callback->( $field, $op, $value ) );
            next NAME;
        }

        #warn dump [ $name, $op, $quote, $value ];

        # invert fuzzy
        if ( $op eq '!~' ) {
            $value .= $wildcard unless $value =~ m/\Q$wildcard/;
            push( @buf,
                join( '', 'NOT ', $name, '=', qq/$quote$value$quote/ ) );
        }

        # fuzzy
        elsif ( $op eq '~' ) {
            $value .= $wildcard unless $value =~ m/\Q$wildcard/;
            push( @buf, join( '', $name, '=', qq/$quote$value$quote/ ) );
        }

        # invert
        elsif ( $op eq '!:' ) {
            push( @buf,
                join( '', 'NOT ', $name, ':', qq/$quote$value$quote/ ) );
        }

        # range
        elsif ( $op eq '..' ) {
            if ( ref $value ne 'ARRAY' or @$value != 2 ) {
                croak "range of values must be a 2-element ARRAY";
            }

            # we support only numbers at this point
            for my $v (@$value) {
                if ( $v =~ m/\D/ ) {
                    croak "non-numeric range values are not supported: $v";
                }
            }

            my @range = ( $value->[0] .. $value->[1] );
            push( @buf,
                join( '', $name, ':', '(', join( ' OR ', @range ), ')' ) );

        }

        # invert range
        elsif ( $op eq '!..' ) {
            if ( ref $value ne 'ARRAY' or @$value != 2 ) {
                croak "range of values must be a 2-element ARRAY";
            }

            # we support only numbers at this point
            for my $v (@$value) {
                if ( $v =~ m/\D/ ) {
                    croak "non-numeric range values are not supported: $v";
                }
            }

            my @range = ( $value->[0] .. $value->[1] );
            push( @buf,
                join( '', '-', $name, ':', '( ', join( ' ', @range ), ' )' )
            );
        }

        # standard
        else {
            push( @buf, join( '', $name, ':', qq/$quote$value$quote/ ) );
        }
    }
    my $joiner = $prefix eq '-' ? ' AND ' : ' OR ';
    return
          ( scalar(@buf) > 1 ? '(' : '' )
        . join( $joiner, @buf )
        . ( scalar(@buf) > 1 ? ')' : '' );
}

=head2 as_ks_query

Returns the Dialect object as a KinoSearch::Search::Query-based object.
The Dialect object is walked and converted to a 
KinoSearch::Searcher-compatible tree.

=cut

sub as_ks_query {
    my $self = shift;
    my $tree = shift || $self;

    my @q;
    foreach my $prefix ( '+', '', '-' ) {
        my @clauses;
        my $joiner = $op_map{$prefix};
        next unless exists $tree->{$prefix};
        for my $clause ( @{ $tree->{$prefix} } ) {
            push( @clauses, $self->_ks_clause( $clause, $prefix ) );
        }
        next if !@clauses;

        my $ks_class = 'KinoSearch::Search::' . $joiner . 'Query';

        push @q, @clauses == 1
            ? $clauses[0]
            : $ks_class->new( children => [ grep {defined} @clauses ] );
    }

    return @q == 1
        ? $q[0]
        : KinoSearch::Search::ANDQuery->new( children => \@q );
}

sub _ks_clause {
    my $self   = shift;
    my $clause = shift;
    my $prefix = shift;

    #warn dump $clause;
    #warn "prefix = '$prefix'";

    if ( $clause->{op} eq '()' ) {
        return $self->as_ks_query( $clause->{value} );
    }

    # make sure we have a field
    my $default_field = $self->default_field || $self->parser->default_field;
    my @fields
        = $clause->{field}
        ? ( $clause->{field} )
        : ( defined $default_field ? @$default_field : () );

    # what value
    my $value
        = ref $clause->{value}
        ? $clause->{value}
        : $self->_doctor_value($clause);

    # if we have no fields, we can't proceed, because KS
    # requires a field for every term.
    if ( !@fields ) {
        croak
            "No field specified for term '$value' -- set a default_field in Parser or Dialect";
    }

    my $wildcard = $self->wildcard;

    # normalize operator
    my $op = $clause->{op} || ":";
    if ( $op eq '=' ) {
        $op = ':';
    }
    if ( $prefix eq '-' ) {
        $op = '!' . $op;
    }
    if ( $value =~ m/\%/ ) {
        $op = $prefix eq '-' ? '!~' : '~';
    }

    my $quote = $clause->quote || '';
    my $is_phrase = $quote eq '"' ? 1 : 0;

    my @buf;
FIELD: for my $name (@fields) {
        my $field = $self->_get_field($name);

        if ( defined $field->callback ) {
            push( @buf, $field->callback->( $field, $op, $value ) );
            next FIELD;
        }

        #warn dump [ $name, $op, $quote, $value ];

        # range is un-analyzed
        if ( $op eq '..' ) {
            if ( ref $value ne 'ARRAY' or @$value != 2 ) {
                croak "range of values must be a 2-element ARRAY";
            }

            my $range_query = KinoSearch::Search::RangeQuery->new(
                field         => $name,
                lower_term    => $value->[0],
                upper_term    => $value->[1],
                include_lower => 1,
                include_upper => 1,
            );

            push( @buf, $range_query );
            next FIELD;

        }

        # invert range
        elsif ( $op eq '!..' ) {
            if ( ref $value ne 'ARRAY' or @$value != 2 ) {
                croak "range of values must be a 2-element ARRAY";
            }

            croak "NOT Range query not yet supported";
            next FIELD;    # haha. never get here.
        }

        $self->debug and warn "value before:$value";
        my @values = ($value);

        # if the field has an analyzer, use it on $value
        if ( blessed( $field->analyzer ) && !ref $value ) {

            # preserve any wildcards
            if ( $value =~ m/[$wildcard\*\?]/ ) {

                # assume CaseFolder
                $value = lc($value);

                # split on whitespace, not token regex
                my @tok = split( m/\s+/, $value );

                # if stemmer, apply only to prefix if at all.
                my $stemmer;
                if ($field->analyzer->isa(
                        'KinoSearch::Analysis::PolyAnalyzer')
                    )
                {

    # KS currently broken with no get_analyzers() method.
    #                    my $analyzers = $field->analyzer->get_analyzers();
    #                    for my $ana (@$analyzers) {
    #                        if (   $ana->isa('KinoSearch::Analysis::Stemmer')
    #                            or $ana->can('stem') )
    #                        {
    #                            $stemmer = $ana;
    #                            last;
    #                        }
    #                    }
                }
                elsif ($field->analyzer->isa('KinoSearch::Analysis::Stemmer')
                    or $field->analyzer->can('stem') )
                {
                    $stemmer = $field->analyzer;
                }

                if ($stemmer) {
                    carp "found stemmer";
                    for my $tok (@tok) {
                        if ( $tok =~ m/^\w\*$/ ) {
                            $tok = $stemmer->stem($tok);
                        }
                    }
                }

            }
            else {
                @values = grep { defined and length }
                    @{ $field->analyzer->split($value) };
            }
        }

        $self->debug and warn "value after :" . dump( \@values );

        if ( $is_phrase or @values > 1 ) {
            push(
                @buf,
                KinoSearch::Search::PhraseQuery->new(
                    field => $name,
                    terms => \@values,
                )
            );
        }
        else {
            my $term = $values[0];

            # invert fuzzy
            if ( $op eq '!~'
                || ( $op eq '!:' and $term =~ m/[$wildcard\*\?]/ ) )
            {
                $term .= $wildcard unless $term =~ m/\Q$wildcard/;

                push(
                    @buf,
                    Search::Query::Dialect::KSx::NOTWildcardQuery->new(
                        field => $name,
                        term  => $term,
                    )
                );
            }

            # fuzzy
            elsif ( $op eq '~'
                || ( $op eq ':' and $term =~ m/[$wildcard\*\?]/ ) )
            {
                $term .= $wildcard unless $term =~ m/\Q$wildcard/;

                push(
                    @buf,
                    Search::Query::Dialect::KSx::WildcardQuery->new(
                        field => $name,
                        term  => $term,
                    )
                );
            }

            # invert
            elsif ( $op eq '!:' ) {
                push(
                    @buf,
                    KinoSearch::Search::NOTQuery->new(
                        field => $name,
                        term  => $term,
                    )
                );
            }

            # standard
            else {
                push(
                    @buf,
                    KinoSearch::Search::TermQuery->new(
                        field => $name,
                        term  => $term,
                    )
                );
            }

        }    # TERM
    }
    if ( @buf == 1 ) {
        return $buf[0];
    }
    my $joiner = $prefix eq '-' ? 'AND' : 'OR';
    my $ks_class = 'KinoSearch::Search::' . $joiner . 'Query';
    return $ks_class->new( children => \@buf );
}

=head2 field_class

Returns "Search::Query::Field::KSx".

=cut

sub field_class {'Search::Query::Field::KSx'}

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

=head1 COPYRIGHT & LICENSE

Copyright 2010 Peter Karman.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut
