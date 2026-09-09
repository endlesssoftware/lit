#!/usr/bin/perl
#
# lit.pl -- a portable reimplementation of LLVM's lit test driver.
#
# Runs anywhere Perl 5.6+ runs; developed for OpenVMS (VAX, Alpha, I64,
# x86-64) and also usable on Tru64 and Linux.

use strict;
use warnings;

BEGIN {
    # Locate lib/ relative to this script without relying on FindBin,
    # which is unreliable under VMS.
    my $me = $0;
    if ($^O eq 'VMS') {
        eval { require VMS::Filespec; $me = VMS::Filespec::unixify($0); 1 };
    }
    $me =~ s{\\}{/}g;
    my $dir = ($me =~ m{^(.*)/[^/]+$}) ? $1 : '.';
    unshift @INC, $dir . '/../lib';
    unshift @INC, $ENV{LIT_PERL_LIB} if defined $ENV{LIT_PERL_LIB};
}

use Lit::Compat ();
use Lit::Driver ();

select(STDOUT); $| = 1;

my $rc = Lit::Driver::run([@ARGV], {
    out => \*STDOUT,
    err => \*STDERR,
});

Lit::Compat::exit_with($rc);

__END__

=head1 NAME

lit.pl - portable reimplementation of LLVM's lit test driver

=head1 SYNOPSIS

    lit.pl [options] <test paths>

    lit.pl -v test/
    lit.pl -j4 --filter='codegen' test/
    lit.pl --param build=/tmp/build --xunit-xml-output=results.xml test/

=head1 DESCRIPTION

Discovers and runs a test suite described by C<lit.cfg> files and C<RUN:>
lines, in the manner of LLVM's C<lit>, but in pure Perl and without
needing a POSIX shell.  See L<Lit> and the distribution's F<README> for
the configuration file API, the supported test directives and the
internal shell's syntax.

=head1 OPTIONS

=over 4

=item B<--filter>=I<REGEX>, B<--filter-out>=I<REGEX>

Only run, or skip, tests whose name matches I<REGEX>.

=item B<--max-failures>=I<N>

Stop after I<N> failures.

=item B<--order>=I<found>|I<lexical>|I<random>

Test execution order; the default is C<lexical>.

=item B<--show-suites>, B<--show-tests>

List what was discovered and exit without running anything.

=item B<-j> I<N>, B<--threads>=I<N>

Run I<N> tests in parallel.  Requires a working C<fork()>, so this is
always 1 on OpenVMS.  The default is the CPU count where that is
available.

=item B<--timeout>=I<N>

Per-test time limit in seconds.  Also requires C<fork()>.

=item B<--param> I<NAME>=I<VALUE>, B<-D>I<NAME>=I<VALUE>

Set a parameter that config files read with
C<< $lit_config->param($name, $default) >>.

=item B<--path>=I<DIR>

Prepend I<DIR> to C<PATH> for the tests.

=item B<--no-execute>

Discover and report, but run nothing.

=item B<-q>, B<-s>, B<-v>, B<-a>

Quiet (failures only), succinct (no per-test lines), verbose (show
failing tests' output), and show-all (show every test's output).

=item B<--time-tests>

Print each test's elapsed time.

=item B<--output>=I<FILE>

Write JSON results to I<FILE>, in lit's own results-file format:

    {"__version__": [1, 0, 0],
     "elapsed": 12.3,
     "tests": [
      {"name": "suite :: a.test", "code": "PASS", "elapsed": 0.01},
      {"name": "suite :: b.test", "code": "FAIL", "elapsed": 0.02,
       "output": "..."}
     ]}

C<output> is present only where there is some, which in practice means the
failures.  Tests that never started - because C<--max-failures> stopped the
run - are omitted rather than invented.

This is the replacement for a Python test format writing its own
F<last-run.json>: a whole-run summary has to be produced by the driver,
which is the only thing that sees every result.

=item B<--xunit-xml-output>=I<FILE>

Write JUnit XML results to I<FILE>.

=back

=head1 EXIT STATUS

0 if every test passed or failed as expected, 1 if any test failed, and 2
for a usage or discovery error.

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2026 Endless Software Solutions

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself: either the GNU General Public
License version 1 (or, at your option, any later version), or the
Artistic License.  See F<LICENSE.md> for the full text of both.

=head1 SEE ALSO

L<Lit>, L<filecheck.pl>, L<https://llvm.org/docs/CommandGuide/lit.html>

=cut
