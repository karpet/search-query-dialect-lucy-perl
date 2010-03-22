use strict;
use warnings;
use Test::More tests => 18;
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
$schema->spec_field( name => 'title', type => $fulltext );
$schema->spec_field( name => 'color', type => $fulltext );
$schema->spec_field( name => 'date',  type => $fulltext );

my $indexer = KinoSearch::Indexer->new(
    index    => $invindex,
    schema   => $schema,
    create   => 1,
    truncate => 1,
);

use_ok('Search::Query::Parser');

ok( my $parser = Search::Query::Parser->new(
        fields => {
            title => { analyzer => $analyzer },
            color => { analyzer => $analyzer },
            date  => { analyzer => $analyzer },
        },
        query_class_opts => { default_field => [qw( title color date)], },
        dialect          => 'KSx',
        croak_on_error   => 1,
    ),
    "new parser"
);

my %docs = (
    'doc1' => {
        title => 'i am doc1',
        color => 'red',
        date  => '20100329',
    },
    'doc2' => {
        title => 'i am doc2',
        color => 'green',
        date  => '20100301',
    },
    'doc3' => {
        title => 'i am doc3',
        color => 'brown',
        date  => '19720329',
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
    'title:(i am)'                        => 3,
    'title:("i am")'                      => 3,
    'color:red'                           => 1,
    'brown'                               => 1,
    'date=(20100301..20100331)'           => 2,
    'date!=(20100301..20100331)'          => 1,
    '-date:(20100301..20100331)'          => 1,
    'am AND (-date=(20100301..20100331))' => 1,
    'am AND (date=(20100301..20100331))'  => 2,
    'color:re*'                           => 1,
    'color:re?'                           => 1,
    'color:br?wn'                         => 1,
    'color:*n'                            => 2,
    'color!=red'                          => 2,
    'not color=red and not title=doc2'    => 1,
    '"i doc1"~2'                          => 1,
);

for my $str ( sort keys %queries ) {
    my $query = $parser->parse($str);

    #diag($query);
    my $hits = $searcher->hits(
        query      => $query->as_ks_query(),
        offset     => 0,
        num_wanted => 5,                       # more than we have
    );

    is( $hits->total_hits, $queries{$str}, "$str = $queries{$str}" );

    if ( $hits->total_hits != $queries{$str} ) {

        diag($query);
        diag( dump($query) );

        #diag( dump( $query->as_ks_query ) );
        diag( $query->as_ks_query->to_string );

    }
}
