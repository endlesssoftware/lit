#!/usr/bin/perl
#
# filecheck.pl -- a portable reimplementation of LLVM's FileCheck.
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
use Lit::FileCheck ();

binmode(STDIN)  unless $^O eq 'VMS';
binmode(STDOUT) unless $^O eq 'VMS';

my $rc = Lit::FileCheck::run([@ARGV], {
    in  => \*STDIN,
    out => \*STDOUT,
    err => \*STDERR,
    cwd => Lit::Compat::getcwd(),
    env => \%ENV,
});

Lit::Compat::exit_with($rc);

__END__

=head1 NAME

filecheck.pl - portable reimplementation of LLVM's FileCheck

=head1 SYNOPSIS

    <command> | filecheck.pl [options] <check-file>

    prog | filecheck.pl checks.txt
    filecheck.pl --check-prefix=OPT --input-file=out.txt checks.txt

=head1 DESCRIPTION

Reads I<check-file> for C<CHECK:> directives and verifies them against
its standard input, in the manner of LLVM's C<FileCheck>.  See L<Lit> and
the distribution's F<README> for the full pattern syntax.

Directives: C<CHECK>, C<CHECK-NEXT>, C<CHECK-SAME>, C<CHECK-NOT>,
C<CHECK-DAG>, C<CHECK-LABEL>, C<CHECK-EMPTY> and C<CHECK-COUNT-E<lt>nE<gt>>.

Pattern syntax: C<{{regex}}> for an embedded regular expression,
C<[[NAME:regex]]> and C<[[NAME]]> for string variables, C<[[#NAME:]]> and
C<[[#expr]]> for numeric ones, and C<[[@LINE+n]]> for the directive's own
line number.

Embedded regexes are Perl regular expressions - a superset of the POSIX
ERE that LLVM's FileCheck accepts.

=head1 OPTIONS

=over 4

=item B<--check-prefix>=I<PREFIX>, B<--check-prefixes>=I<A,B>

Directive prefixes to honour; the default is C<CHECK>.

=item B<--comment-prefixes>=I<A,B>

Prefixes that hide the rest of the line; the default is C<COM,RUN>.

=item B<--input-file>=I<FILE>

Read the input from I<FILE> rather than standard input.

=item B<--strict-whitespace>

Do not canonicalize runs of horizontal whitespace.

=item B<--match-full-lines>

Patterns must match whole lines.

=item B<--ignore-case>

Match case-insensitively.

=item B<--implicit-check-not>=I<PATTERN>

Apply I<PATTERN> as a C<CHECK-NOT> across the whole input.

=item B<--allow-empty>

Permit empty input, which is otherwise an error.

=item B<--enable-var-scope>

Clear variables not named with a leading C<$> at each C<CHECK-LABEL>.

=item B<--allow-unused-prefixes>

Do not warn when a prefix matches nothing.

=item B<-D>I<NAME>=I<VALUE>, B<-D#>I<NAME>=I<VALUE>

Predefine a string or numeric variable.

=item B<--dump-input>=I<never>|I<fail>|I<always>, B<--dump-input-context>=I<N>

Control the input dump printed on failure.

=back

=head1 EXIT STATUS

0 when every directive matched, 1 when one did not, and 2 for a usage
error or an unreadable file.

=head1 SEE ALSO

L<Lit>, L<lit.pl>, L<https://llvm.org/docs/CommandGuide/FileCheck.html>

=cut
