use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'Search::Query::Dialect::KSx',
    AUTHOR              => q{Peter Karman <karman@cpan.org>},
    VERSION_FROM        => 'lib/Search/Query/Dialect/KSx.pm',
    ABSTRACT_FROM       => 'lib/Search/Query/Dialect/KSx.pm',
    ($ExtUtils::MakeMaker::VERSION >= 6.3002
      ? ('LICENSE'=> 'perl')
      : ()),
    PL_FILES            => {},
    PREREQ_PM => {
        'Test::More' => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'Search-Query-Dialect-KSx-*' },
);
