#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 59;
use Data::Dump qw( dump );

use KinoSearch::Analysis::PolyAnalyzer;
my $analyzer = KinoSearch::Analysis::PolyAnalyzer->new( language => 'en', );

use_ok('Search::Query::Parser');

ok( my $parser = Search::Query::Parser->new(
        fields => {
            foo   => { analyzer => $analyzer },
            color => { analyzer => $analyzer },
            name  => { analyzer => $analyzer },
        },
        default_field  => 'name',
        dialect        => 'KSx',
        croak_on_error => 1,
    ),
    "new parser"
);

#dump $parser;

ok( my $query1 = $parser->parse('foo=BAR'), "query1" );

is( $query1, qq/foo:BAR/, "query1 string" );

ok( my $ks_query1 = $query1->as_ks_query(), "as_ks_query" );
ok( $ks_query1->isa('KinoSearch::Search::TermQuery'),
    "ks_query isa TermQuery" );
is( $ks_query1->to_string, "foo:bar", "KS query analyzer applied" );

ok( my $query2 = $parser->parse('foo:BaR'), "query2" );

is( $query2, qq/foo:BaR/, "query2 string" );

ok( my $query3 = $parser->parse('FoO bar'), "query3" );

is( $query3, qq/name:FoO AND name:bar/, "query3 string" );

my $str = '-color:red (name:john OR foo:bar)';

ok( my $query4 = $parser->parse($str), "query4" );

#dump $query4;

is( $query4, qq/(name:john OR foo:bar) AND NOT color:red/, "query4 string" );

ok( my $parser2 = Search::Query::Parser->new(
        fields         => [qw( first_name last_name email )],
        dialect        => 'KSx',
        croak_on_error => 1,
        default_boolop => '',
    ),
    "parser2"
);

ok( my $query5 = $parser2->parse("joe smith"), "query5" );

is( $query5, qq/joe OR smith/, "query5 string" );

ok( my $query6 = $parser2->parse(qq/"joe smith"/), "query6" );

is( $query6, qq/joe smith/, "query6 string" );

ok( my $parser3 = Search::Query::Parser->new(
        fields         => [qw( foo bar )],
        dialect        => 'KSx',
        croak_on_error => 1,
    ),
    "parser3"
);

ok( my $query7 = $parser3->parse('green'), "query7" );

is( $query7, qq/green/, "query7 string" );

ok( my $gardenq = $parser3->parse('(garden) AND (-foo=(20100208..20100309))'),
    "parse complex garden query with range"
);

is( $gardenq,
    qq/garden AND (NOT foo:(20100208..20100309))/,
    "parsed garden query"
);

ok( my $parser4 = Search::Query::Parser->new(
        fields         => [qw( foo )],
        dialect        => 'KSx',
        croak_on_error => 1,
    ),
    "strict parser4"
);

eval { $parser4->parse('bar=123') };
my $errstr = $@;
ok( $errstr, "croak on invalid query" );
like( $errstr, qr/No such field: bar/, "caught exception we expected" );

ok( my $parser5 = Search::Query::Parser->new(
        fields => {
            foo => { type => 'char' },
            bar => { type => 'int' },
        },
        dialect          => 'KSx',
        query_class_opts => { fuzzify => 1, },
        croak_on_error   => 1,
    ),
    "parser5"
);

ok( my $query8 = $parser5->parse('foo:bar'), "query8" );

is( $query8, qq/foo:bar*/, "query8 string" );

ok( $query8 = $parser5->parse('bar:1*'), "query8 fuzzy int with wildcard" );

is( $query8, qq/bar:1*/, "query8 fuzzy int with wildcard string" );

ok( $query8 = $parser5->parse('bar=1'), "query8 fuzzy int no wildcard" );

is( $query8, qq/bar:1*/, "query8 fuzzy int no wildcard string" );

ok( my $parser6 = Search::Query::Parser->new(
        fields           => [qw( foo )],
        dialect          => 'KSx',
        query_class_opts => { fuzzify => 1, },
        croak_on_error   => 1,
    ),
    "parser6"
);

ok( my $query9 = $parser6->parse('foo:bar'), "query9" );

is( $query9, qq/foo:bar*/, "query9 string" );

# range expansion
ok( my $range_parser = Search::Query::Parser->new(
        dialect       => 'KSx',
        fields        => [qw( date swishdefault )],
        default_field => 'swishdefault',
    ),
    "range_parser"
);

ok( my $range_query = $range_parser->parse("date=(1..10)"), "parse range" );

#dump $range_query;

is( $range_query, qq/date:(1..10)/, "range expanded" );

ok( my $range_not_query = $range_parser->parse("-(date=( 1..3 ))"),
    "parse !range" );

#dump $range_not_query;
is( $range_not_query, qq/NOT (date:(1..3))/, "!range expanded" );

# operators
ok( my $or_pipe_query = $range_parser->parse("date:( 1 | 2 )"),
    "parse piped OR" );

#dump $or_pipe_query;
is( $or_pipe_query, qq/(date:1 OR date:2)/, "or_pipe_query $or_pipe_query" );

ok( my $and_amp_query = $range_parser->parse("date:( 1 & 2 )"),
    "parse ampersand AND" );

is( $and_amp_query, qq/(date:1 AND date:2)/, "and_amp_query $and_amp_query" );

ok( my $not_bang_query = $range_parser->parse(qq/! date:("1 3" | 2)/),
    "parse bang NOT" );

#dump $not_bang_query;

is( $not_bang_query,
    qq/NOT (date:"1 3" OR date:2)/,
    "not_bang_query $not_bang_query"
);

ok( my $parser_alias_for = Search::Query->parser(
        fields => {
            field1 => { alias_for => 'field2', },
            field2 => 1,
        },
        dialect => 'KSx',
    ),
    "new parser2"
);

ok( my $query_alias_for = $parser_alias_for->parse('field1=foo'),
    "parse alias_for with no default field" );
is( $query_alias_for, qq/field2:foo/, "straight up aliasing" );
ok( my $query_alias_for2 = $parser_alias_for->parse('foo'),
    "parse alias_for with no default field and no field specified"
);
is( $query_alias_for2, qq/foo/, "query expanded omits aliases" );

# wildcards
ok( my $fuzzy_parser = Search::Query->parser(
        dialect          => 'KSx',
        query_class_opts => { default_field => 'field1' }
    ),
    "new fuzzy parser"
);
ok( my $fuzzy_query = $fuzzy_parser->parse('foo*'), "parse foo*" );
ok( my $fuzzy_ks    = $fuzzy_query->as_ks_query,    "fuzzy as_ks_query" );
is( $fuzzy_ks->to_string, $fuzzy_query->stringify,
    "stringification matches" );

# no fields defined
ok( my $nofields_parser = Search::Query->parser( dialect => 'KSx', ),
    "nofields parser" );
ok( my $nofields_query = $nofields_parser->parse('foo'), "parse nofields" );
is( $nofields_query, "foo", "stringify nofields_query" );
