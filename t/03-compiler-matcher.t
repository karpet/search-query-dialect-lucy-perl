#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Data::Dump qw( dump );
use File::Temp qw( tempdir );
my $invindex = tempdir( CLEANUP => 1 );

use Lucy;    # gets everything, really
use Lucy::Plan::Schema;
use Lucy::Plan::FullTextType;
use Lucy::Analysis::PolyAnalyzer;
use Lucy::Index::Indexer;
use Lucy::Search::IndexSearcher;

##########################################################################
#    custom query/compiler/matcher troika
##########################################################################
{

    package MyTermQuery;
    use base qw( Lucy::Search::TermQuery );

    sub make_compiler {
        my $self        = shift;
        my %args        = @_;
        my $subordinate = delete $args{subordinate};    # new in Lucy 0.2.2
        $args{parent} = $self;

        #warn Data::Dump::dump( \%args );
        my $compiler = MyCompiler->new(%args);
        $compiler->normalize unless $subordinate;

        return $compiler;
    }
}

{

    package MyCompiler;
    use base qw( Lucy::Search::Compiler );

    my %reader;
    my %searchable;
    my %doc_freq;
    my %idf;
    my %raw_weight;

    sub new {
        my $class      = shift;
        my %args       = @_;
        my $searchable = $args{searchable} || $args{searcher};
        if ( !$searchable ) {
            Carp::croak "searcher required";
        }

        #warn Data::Dump::dump( \%args );
        my $self = $class->SUPER::new(%args);
        $searchable{$$self} = $searchable;
        return $self;
    }

    sub make_matcher {
        my $self = shift;
        my %args = @_;

        my $need_score = delete $args{need_score};
        $reader{$$self} = delete $args{reader};

        my $plist_reader
            = $reader{$$self}->obtain("Lucy::Index::PostingListReader");
        my $lex_reader
            = $reader{$$self}->obtain("Lucy::Index::LexiconReader");
        my $parent = $self->get_parent;
        my $term   = $parent->get_term;
        my $field  = $parent->get_field;

        #warn "$self field=$field term=$term";
        my $lexicon = $lex_reader->lexicon( field => $field );
        return unless $lexicon;

        my $posting_list = $plist_reader->posting_list(
            field => $field,
            term  => $term,
        );
        return unless $posting_list;

        my %hits;
        my $doc_reader = $reader{$$self}->obtain("Lucy::Index::DocReader");
        my $searchable = $searchable{$$self};
        while ( my $doc_id = $posting_list->next ) {
            my $posting = $posting_list->get_posting;
            $hits{$doc_id} = { freq => $posting->get_freq, };

            # here's where we do magic scoring
            my $doc = $doc_reader->fetch_doc($doc_id);
            $hits{$doc_id}->{magic} = $doc->{option};
        }

        $doc_freq{$$self} = scalar( keys %hits );
        return unless $doc_freq{$$self};

        # Calculate and store the IDF
        my $max_doc = $searchable->doc_max;
        my $idf     = $idf{$$self}
            = $max_doc
            ? ( $searchable->get_schema->fetch_type($field)->get_boost
                + log( $max_doc / ( 1 + $doc_freq{$$self} ) ) )
            : $searchable->get_schema->fetch_type($field)->get_boost;

        $raw_weight{$$self} = $idf * $parent->get_boost;

#warn
#    "term=$term doc_freq=$doc_freq{$$self} raw_weight=$raw_weight{$$self} idf=$idf";

        return MyMatcher->new(
            %args,
            hits     => \%hits,
            compiler => $self
        );
    }

    sub sum_of_squared_weights {
        my $self = shift;
        return exists $raw_weight{$$self} ? $raw_weight{$$self}**2 : '1.0';
    }

    sub normalize {
        my $self   = shift;
        my $sim    = $self->get_similarity;
        my $factor = $self->sum_of_squared_weights;
        $factor = $sim->query_norm($factor);

        #warn "raw_weight=$raw_weight{$$self}";
        #warn "idf=$idf{$$self}";
        #warn "factor=$factor";
        $self->apply_norm_factor($factor);
    }

    sub apply_norm_factor {
        my $self   = shift;
        my $factor = shift;
        if ( !defined $factor ) {
            Carp::croak "factor required";
        }
        if ( exists $raw_weight{$$self} ) {
            return $raw_weight{$$self} * $idf{$$self} * $factor;
        }
        else {
            return 1.0;
        }
    }

    sub get_doc_freq {
        my $self = shift;
        return $doc_freq{$$self};
    }

    sub DESTROY {
        my $self = shift;
        delete $reader{$$self};
        delete $doc_freq{$$self};
        delete $idf{$$self};
        delete $searchable{$$self};
        delete $raw_weight{$$self};
        $self->SUPER::DESTROY;
    }
}

{

    package MyMatcher;
    use base qw( Lucy::Search::Matcher );

    my %compiler;
    my %hits;
    my %pos;
    my %doc_ids;
    my %boosts;
    my %sim;

    sub new {
        my $class = shift;
        my %args  = @_;

        #Data::Dump::dump( \%args );
        my $compiler = delete $args{compiler};
        my $hits     = delete $args{hits};
        my $self     = $class->SUPER::new(%args);
        $compiler{$$self} = $compiler;
        $hits{$$self}     = $hits;
        $pos{$$self}      = -1;
        $doc_ids{$$self}  = [ sort { $a <=> $b } keys %$hits ];
        $boosts{$$self}   = $compiler->get_boost;
        $sim{$$self}      = $compiler->get_similarity;

        return $self;

    }

    sub next {
        my $self    = shift;
        my $doc_ids = $doc_ids{$$self};
        return 0 if $pos{$$self} >= $#$doc_ids;
        return $doc_ids->[ ++$pos{$$self} ];
    }

    sub get_doc_id {
        my $self = shift;
        my $pos  = $pos{$$self};
        my $dids = $doc_ids{$$self};
        return $pos < scalar @$dids ? $$dids[$pos] : 0;
    }

    sub score {
        my $self      = shift;
        my $pos       = $pos{$$self};
        my $dids      = $doc_ids{$$self};
        my $boost     = $boosts{$$self};
        my $doc_id    = $$dids[$pos];
        my $term_freq = $hits{$$self}->{$doc_id};

        #Carp::carp "doc_id=$doc_id  term_freq=$term_freq  boost=$boost";
        my $base_score = ( $boost * $sim{$$self}->tf($term_freq) ) / 10;

        # custom scoring section.
        # get the magic
        my $magic = $hits{$$self}->{$doc_id}->{magic};
        my $magic_score;
        if ( !$magic ) {
            $magic_score = 0;
        }
        elsif ( $magic eq 'a' ) {
            $magic_score = 100;
        }
        elsif ( $magic eq 'b' ) {
            $magic_score = 200;
        }
        elsif ( $magic eq 'c' ) {
            $magic_score = 300;
        }
        elsif ( $magic eq 'd' ) {
            $magic_score = 400;
        }
        else {
            $magic_score = $base_score;
        }

        #warn "magic_score=$magic_score";
        return $magic_score;
    }

    sub DESTROY {
        my $self = shift;
        delete $compiler{$$self};
        delete $hits{$$self};
        delete $pos{$$self};
        delete $doc_ids{$$self};
        delete $boosts{$$self};
        delete $sim{$$self};
        $self->SUPER::DESTROY;
    }

}

#############################################################################
#     setup temp index
#############################################################################
my $schema     = Lucy::Plan::Schema->new;
my $stopfilter = Lucy::Analysis::SnowballStopFilter->new( language => 'en', );
my $stemmer    = Lucy::Analysis::SnowballStemmer->new( language => 'en' );
my $case_folder = Lucy::Analysis::CaseFolder->new;
my $tokenizer   = Lucy::Analysis::RegexTokenizer->new;
my $analyzer    = Lucy::Analysis::PolyAnalyzer->new(
    analyzers => [
        $case_folder,
        $tokenizer,

        # our existing tests have too many stopwords to refactor
        # but this is helpful when debugging related code in Dialect::Lucy

        #$stopfilter,

        $stemmer,
    ]
);
my $fulltext = Lucy::Plan::FullTextType->new(
    analyzer => $analyzer,
    sortable => 1,
);
$schema->spec_field( name => 'uri',    type => $fulltext );
$schema->spec_field( name => 'title',  type => $fulltext );
$schema->spec_field( name => 'color',  type => $fulltext );
$schema->spec_field( name => 'date',   type => $fulltext );
$schema->spec_field( name => 'option', type => $fulltext );

my $indexer = Lucy::Index::Indexer->new(
    index    => $invindex,
    schema   => $schema,
    create   => 1,
    truncate => 1,
);

#######################################################################
#   set up our parser tests
#######################################################################
use_ok('Search::Query::Parser');

ok( my $parser = Search::Query::Parser->new(
        fields => {
            title => { analyzer => $analyzer },
            color => {
                analyzer         => $analyzer,
                term_query_class => 'MyTermQuery',
            },
            date   => { analyzer => $analyzer },
            option => {
                analyzer         => $analyzer,
                term_query_class => 'MyTermQuery',
            },
        },
        query_class_opts => { default_field => [qw( color )], },
        dialect          => 'Lucy',
        croak_on_error   => 1,
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
    'doc4' => {
        title  => 'i am doc4',
        color  => 'white',
        date   => '20100510',
        option => 'c',
    },
    'doc5' => {
        title  => 'unlike the others',
        color  => 'teal',
        date   => '19000101',
        option => 'd',
    },
);

# create the index
for my $doc ( keys %docs ) {
    $indexer->add_doc( { uri => $doc, %{ $docs{$doc} } } );
}

$indexer->commit;

########################################################################
#           run the tests
########################################################################

my $searcher = Lucy::Search::IndexSearcher->new( index => $invindex, );

# search
my %queries = (
    'option=a'                      => { uri => 'doc1', score => 100 },
    'option=b'                      => { uri => 'doc2', score => 200 },
    'option=c'                      => { uri => 'doc4', score => 300 },
    'option=d'                      => { uri => 'doc5', score => 400 },
    'option!=(a and b and c and d)' => { uri => 'doc3', score => 0 },
    'white'                         => [
        {   uri   => 'doc4',
            score => 300,
        },
        {   uri   => 'doc3',
            score => 0,
        },
    ]
);

my $expected_tests = 0;
for my $str ( sort keys %queries ) {
    my $query = $parser->parse($str);

    #$query->debug(1);

    my $expected = $queries{$str};
    if ( ref $expected ne 'ARRAY' ) {
        $expected = [$expected];
    }

    $expected_tests += scalar @$expected;

    #diag($query);
    my $lucy_query = $query->as_lucy_query();

    #diag( dump $lucy_query->dump );
    if ( !$lucy_query ) {
        diag("No lucy_query for $str");
        next;
    }
    my $hits = $searcher->hits(
        query      => $lucy_query,
        offset     => 0,
        num_wanted => 5,             # more than we have
    );

    my $i = 0;
    while ( my $result = $hits->next ) {
        is( $result->get_score,
            $expected->[$i]->{score},
            sprintf(
                "doc '%s' got expected score for '%s'",
                $result->{uri}, $str
            )
        );
        is( $result->{uri},
            $expected->[$i]->{uri},
            "got rank expected for $result->{uri}"
        );
        $i++;
    }
}

#diag("expected_tests=$expected_tests");

# allow for adding new queries without adjusting test count
done_testing( ( $expected_tests * 2 ) + 2 );
