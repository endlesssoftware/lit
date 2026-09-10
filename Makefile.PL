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
    # Generate the OpenVMS startup procedure at build time: it has to name
    # the directory "make install" actually uses, and the Perl image that
    # will run the scripts.  The generator is mkcom.PL rather than
    # lit_define_commands.com.PL because the latter has two dots, which
    # ODS-2 will not accept.
    PL_FILES      => { 'vms/mkcom.PL' => 'vms/lit_define_commands.com' },
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
    clean         => { FILES => 't/tmp examples/demo/_out '
                             . 'vms/lit_define_commands.com' },
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

# ---------------------------------------------------------------------------
# MMS compatibility on OpenVMS.
#
# MakeMaker emits
#
#     subdirs-test_dynamic :: dynamic pure_all
#
# with dependencies but no actions.  MMK shrugs at that; MMS refuses with
#
#     %MMS-F-GWKNOACTS, Actions to update SUBDIRS-TEST_DYNAMIC are unknown.
#
# and the whole test target dies.  Which of the two MakeMaker writes for
# depends on how the local Perl was built ($Config{make}), not on which is
# installed - so a kit generated for MMK can easily be all a site has to
# build with MMS.  Give the degenerate targets an explicit no-op, which MMS
# accepts and MMK does not care about.
{
    package MY;

    sub test {
        my ($self, %attribs) = @_;
        my $frag = $self->SUPER::test(%attribs);
        $frag =~ s/^(subdirs-test_\w+\s*::[^\n]*)\n(?![\t ])/$1\n\t\$(NOECHO) \$(NOOP)\n/mg;
        return $frag;
    }
}

WriteMakefile(%args);
