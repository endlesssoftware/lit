package Lit;

use strict;
use warnings;

require 5.006;

use vars qw($VERSION);
$VERSION = '0.01';

1;

__END__

=head1 NAME

Lit - a portable Perl reimplementation of LLVM's lit and FileCheck

=head1 SYNOPSIS

    $ lit.pl -v test/
    $ prog | filecheck.pl checks.txt

=head1 DESCRIPTION

C<Lit> provides two test-suite tools modelled on LLVM's C<lit> (the LLVM
Integrated Tester) and C<FileCheck>, written in pure Perl with no non-core
dependencies.

The distribution exists because the LLVM originals require Python and a
POSIX shell, neither of which can be relied on outside Unix.  Everything
here runs on OpenVMS (VAX, Alpha, I64 and x86-64) as well as Tru64 and
Linux.  In particular:

=over 4

=item *

The code is written to Perl 5.6 rules - no C<//>, C<say>, C<state>, named
captures or post-5.8 core modules - because OpenVMS VAX tops out at Perl
5.8.

=item *

C<RUN:> lines are parsed and executed by an internal shell
(L<Lit::ShLex>, L<Lit::ShRun>).  No F</bin/sh> is required, and pipelines
are staged through temporary files so that hosts without a usable
C<fork()> behave identically.

=item *

A large set of Unix commands is implemented in-process
(L<Lit::Builtins>), including C<FileCheck> itself, so a test suite needs
no GNV or other Unix toolkit.

=item *

Paths are held in Unix syntax internally and converted with
L<VMS::Filespec> only when handed to a foreign command.

=back

=head1 MODULES

=over 4

=item L<Lit::Compat>

Host portability: paths, temp files, exit-status decoding, globbing and
process spawning (POSIX C<fork>/C<exec>, OpenVMS DCL, or a C<system()>
fallback).

=item L<Lit::Pattern>, L<Lit::FileCheck>

The FileCheck pattern compiler and matching engine.

=item L<Lit::ShLex>, L<Lit::ShRun>, L<Lit::Builtins>

The internal shell: lexer/parser, executor and builtin commands.

=item L<Lit::BoolExpr>, L<Lit::Config>, L<Lit::Test>, L<Lit::Discovery>,
L<Lit::TestRunner>, L<Lit::Report>

The test driver: C<REQUIRES:>/C<UNSUPPORTED:>/C<XFAIL:> expressions,
configuration objects, test discovery, script execution and reporting.

=back

=head1 SEE ALSO

L<https://llvm.org/docs/CommandGuide/lit.html>,
L<https://llvm.org/docs/CommandGuide/FileCheck.html>

=head1 LICENSE

Same terms as Perl itself.

=cut
