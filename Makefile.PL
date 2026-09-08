# Makefile.PL for Lit - portable lit / FileCheck in Perl.
#
# Usage:
#   Unix/Tru64:  perl Makefile.PL && make && make test && make install
#   OpenVMS:     PERL MAKEFILE.PL
#                MMK        (or MMS, or MAKE)
#                MMK TEST
#                MMK INSTALL
#
# Written against the old ExtUtils::MakeMaker API so that it works with the
# MakeMaker shipped with Perl 5.8 on OpenVMS VAX; newer keys are added only
# when the installed MakeMaker is known to understand them.

use strict;
use ExtUtils::MakeMaker;

my $mm = eval { $ExtUtils::MakeMaker::VERSION } || 0;
$mm =~ s/_//g;

my %args = (
    NAME          => 'Lit',
    VERSION_FROM  => 'lib/Lit.pm',
    ABSTRACT      => 'Portable Perl reimplementation of LLVM lit and FileCheck',
    AUTHOR        => 'Tim Sneddon <tim.sneddon@es.solutions>',
    EXE_FILES     => [ 'bin/lit.pl', 'bin/filecheck.pl' ],
    PL_FILES      => {},
    PREREQ_PM     => {},          # core modules only, by design
    # Ship a zip rather than a tarball: Info-ZIP's unzip is the de-facto
    # standard on OpenVMS, and MM_VMS's zipfile target defaults ZIPFLAGS
    # to -Vu, which preserves VMS file attributes.  Only DIST_DEFAULT is
    # set here so that each platform keeps its own ZIP and ZIPFLAGS
    # defaults; "make tardist" still works if a tarball is wanted.
    dist          => { DIST_DEFAULT => 'zipdist' },
    # Do NOT list Lit-* here.  "make dist" depends on $(FIRST_MAKEFILE),
    # whose rebuild rule runs "make -f Makefile.old clean", which would
    # then delete the archive that had just been built.  MakeMaker already
    # removes the staging directory itself.
    clean         => { FILES => 't/tmp examples/demo/_out' },
);

# MIN_PERL_VERSION arrived in 6.48; LICENSE in 6.31.
$args{MIN_PERL_VERSION} = '5.006' if $mm >= 6.48;
$args{LICENSE}          = 'perl'  if $mm >= 6.31;

if ($mm >= 6.64) {
    $args{TEST_REQUIRES}      = { 'Test::More' => 0 };
    $args{CONFIGURE_REQUIRES} = { 'ExtUtils::MakeMaker' => 0 };
}
elsif ($mm >= 6.55) {
    $args{BUILD_REQUIRES}     = { 'Test::More' => 0 };
}
else {
    $args{PREREQ_PM}{'Test::More'} = 0;
}

if ($mm >= 6.46) {
    $args{META_MERGE} = {
        'meta-spec' => { version => 2 },
        resources   => {},
        no_index    => { directory => [ 't', 'examples' ] },
    };
}

WriteMakefile(%args);
