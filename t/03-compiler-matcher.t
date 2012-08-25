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

{

    package MyTermQuery;
    use base qw( Lucy::Search::TermQuery );

    sub make_compiler {
        my $self        = shift;
        my %args        = @_;
        my $subordinate = delete $args{subordinate};    # new in Lucy 0.2.2
        $args{parent} = $self;
        my $compiler = MyCompiler->new(%args);
        $compiler->normalize unless $subordinate;

        return $compiler;
    }
}

{

    package MyCompiler;
    use base qw( Lucy::Search::Compiler );

    my %reader;

    sub make_matcher {
        my $self = shift;
        my %args = @_;

        #Data::Dump::dump( \%args );
        $reader{$$self} = delete $args{reader};

        # Retrieve low-level components LexiconReader and PostingListReader.
        my $lex_reader
            = $reader{$$self}->obtain("Lucy::Index::LexiconReader");
        my $plist_reader
            = $reader{$$self}->obtain("Lucy::Index::PostingListReader");

        # Acquire a Lexicon and seek it to our query string.
        my $parent  = $self->get_parent;
        my $term    = $parent->get_term;
        my $field   = $parent->get_field;
        my $lexicon = $lex_reader->lexicon( field => $field );
        return unless $lexicon;

        #warn "term=$term";
        my $posting_list = $plist_reader->posting_list(
            field => $field,
            term  => $term,
        );
        return unless $posting_list;

        my %hits;
        my $doc_reader = $reader{$$self}->obtain("Lucy::Index::DocReader");
        while ( my $doc_id = $posting_list->next ) {
            my $posting = $posting_list->get_posting;
            $hits{$doc_id} = { freq => $posting->get_freq, };

            # here's where we do magic scoring
            my $doc = $doc_reader->fetch_doc($doc_id);
            $hits{$doc_id}->{magic} = $doc->{option};
        }

        return MyMatcher->new(
            %args,
            hits     => \%hits,
            compiler => $self
        );
    }

    sub DELETE {
        my $self = shift;
        delete $reader{$$self};
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
        delete $args{need_score};
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
        if ( !$magic ) {
            return 0;
        }
        elsif ( $magic eq 'a' ) {
            return 100;
        }
        elsif ( $magic eq 'b' ) {
            return 200;
        }
        elsif ( $magic eq 'c' ) {
            return 300;
        }
        elsif ( $magic eq 'd' ) {
            return 400;
        }
        else {
            return $base_score;
        }
    }

    sub DELETE {
        my $self = shift;
        delete $compiler{$$self};
        delete $hits{$$self};
        delete $pos{$$self};
        delete $doc_ids{$$self};
        delete $boosts{$$self};
        delete $sim{$$self};
    }

}

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

use_ok('Search::Query::Parser');

ok( my $parser = Search::Query::Parser->new(
        fields => {
            title  => { analyzer => $analyzer },
            color  => { analyzer => $analyzer },
            date   => { analyzer => $analyzer },
            option => {
                analyzer         => $analyzer,
                term_query_class => 'MyTermQuery',
            },
        },
        query_class_opts =>
            { default_field => [qw( title color date option )], },
        dialect        => 'Lucy',
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

# set up the index
for my $doc ( keys %docs ) {
    $indexer->add_doc( $docs{$doc} );
}

$indexer->commit;

my $searcher = Lucy::Search::IndexSearcher->new( index => $invindex, );

# search
my %queries = (
    'option=a'                   => 100,
    'option=b'                   => 200,
    'option=c'                   => 300,
    'option=d'                   => 400,
    'option!=(a or b or c or d)' => 0,
);

for my $str ( sort keys %queries ) {
    my $query = $parser->parse($str);

    #$query->debug(1);

    my $score_expected = $queries{$str};

    #diag($query);
    my $lucy_query = $query->as_lucy_query();
    if ( !$lucy_query ) {
        diag("No lucy_query for $str");
        next;
    }
    my $hits = $searcher->hits(
        query      => $lucy_query,
        offset     => 0,
        num_wanted => 5,             # more than we have
    );

    my $result = $hits->next;
    is( $result->get_score, $score_expected, "got expected score for $str" );
}

# allow for adding new queries without adjusting test count
done_testing( scalar( keys %queries ) + 2 );
