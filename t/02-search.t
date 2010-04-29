#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Data::Dump qw( dump );
use File::Temp qw( tempdir );
my $invindex = tempdir( CLEANUP => 1 );

use KinoSearch::Schema;
use KinoSearch::FieldType::FullTextType;
use KinoSearch::Analysis::PolyAnalyzer;
use KinoSearch::Indexer;
my $schema   = KinoSearch::Schema->new;
my $analyzer = KinoSearch::Analysis::PolyAnalyzer->new( language => 'en', );
my $fulltext = KinoSearch::FieldType::FullTextType->new(
    analyzer => $analyzer,
    sortable => 1,
);
$schema->spec_field( name => 'title',  type => $fulltext );
$schema->spec_field( name => 'color',  type => $fulltext );
$schema->spec_field( name => 'date',   type => $fulltext );
$schema->spec_field( name => 'option', type => $fulltext );

my $indexer = KinoSearch::Indexer->new(
    index    => $invindex,
    schema   => $schema,
    create   => 1,
    truncate => 1,
);

use_ok('Search::Query::Parser');

ok( my $parser = Search::Query::Parser->new(
        fields => {
            title  => { analyzer => $analyzer },
            color  => { analyzer => $analyzer },
            date   => { analyzer => $analyzer },
            option => { analyzer => $analyzer },
        },
        query_class_opts =>
            { default_field => [qw( title color date option )], },
        dialect        => 'KSx',
        croak_on_error => 1,
    ),
    "new parser"
);

my %docs = (
    'doc1' => {
        title  => 'i am doc1',
        color  => 'red blue orange',
        date   => '20100329',
        option => 'a',
    },
    'doc2' => {
        title  => 'i am doc2',
        color  => 'green yellow purple',
        date   => '20100301',
        option => 'b',
    },
    'doc3' => {
        title  => 'i am doc3',
        color  => 'brown black white',
        date   => '19720329',
        option => '',
    },
);

# set up the index
for my $doc ( keys %docs ) {
    $indexer->add_doc( $docs{$doc} );
}

$indexer->commit;

my $searcher = KinoSearch::Searcher->new( index => $invindex, );

# search
my %queries = (
    'title:(i am)'                                       => 3,
    'title:("i am")'                                     => 3,
    'color:red'                                          => 1,
    'brown'                                              => 1,
    'date=(20100301..20100331)'                          => 2,
    'date!=(20100301..20100331)'                         => 1,
    '-date:(20100301..20100331)'                         => 1,
    'am AND (-date=(20100301..20100331))'                => 1,
    'am AND (date=(20100301..20100331))'                 => 2,
    'color:re*'                                          => 1,
    'color:re?'                                          => 1,
    'color:br?wn'                                        => 1,
    'color:*n'                                           => 2,
    'color!=red'                                         => 2,
    'not color=red and not title=doc2'                   => 1,
    '"i doc1"~2'                                         => 1,
    'option!=?*'                                         => 1,
    'NOT option:?*'                                      => 1,
    '(title=am) and (date!=20100301 and date!=20100329)' => 1,     # doc3
    '(re* OR gree*) AND title=am'                        => 2,
    '(re* OR gree*)'                                     => 2,
);

for my $str ( sort keys %queries ) {
    my $query = $parser->parse($str);

    #$query->debug(1);

    my $hits_expected = $queries{$str};
    if ( ref $hits_expected ) {
        $query->debug(1);
        $hits_expected = $hits_expected->[0];
    }

    #diag($query);
    my $hits = $searcher->hits(
        query      => $query->as_ks_query(),
        offset     => 0,
        num_wanted => 5,                       # more than we have
    );

    is( $hits->total_hits, $hits_expected, "$str = $hits_expected" );

    if ( $hits->total_hits != $hits_expected ) {

        $query->debug(1);
        diag($str);
        diag($query);
        diag( dump($query) );

        diag( dump( $query->as_ks_query ) );
        if ( $query->as_ks_query->isa('KinoSearch::Search::NOTQuery') ) {
            diag( dump( $query->as_ks_query->get_negated_query ) );
        }
        diag( $query->as_ks_query->to_string );

    }
}

# exercise some as_ks_query options
my $query = $parser->parse(qq/"orange red"~3/);
$query->ignore_order_in_proximity(1);

#$query->debug(1);
my $ks_query = $query->as_ks_query();
my $hits
    = $searcher->hits( query => $ks_query, offset => 0, num_wanted => 5 );
is( $hits->total_hits, 1, "proximity order ignored" );
$query->ignore_order_in_proximity(0);
$ks_query = $query->as_ks_query();
$hits = $searcher->hits( query => $ks_query, offset => 0, num_wanted => 5 );
is( $hits->total_hits, 0, "proximity order respected" );

# allow for adding new queries without adjusting test count
done_testing( scalar( keys %queries ) + 4 );
