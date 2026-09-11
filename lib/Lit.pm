package Lit;

use strict;
use warnings;

require 5.006;

use vars qw($VERSION);
$VERSION = '1.00';

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

The point of the exercise is portability.  The LLVM originals need Python
and a POSIX shell; neither can be relied on outside Unix.  Everything here
runs on OpenVMS - VAX, Alpha, I64 and x86-64 - as well as Tru64 and Linux.

Concretely, that meant four decisions:

=over 4

=item *

The code is written to Perl 5.6 rules.  No C<//>, C<say>, C<state>, named
captures, or post-5.8 core modules, because OpenVMS VAX tops out at Perl
5.8.

=item *

C<RUN:> lines are parsed and executed by an internal shell, so no
F</bin/sh> is required.  Pipelines are staged through temporary files
rather than real pipes, which behaves identically on hosts without a
usable C<fork()> and cannot deadlock.

=item *

A large set of Unix commands - including C<FileCheck> itself - runs
in-process.  A suite therefore needs no GNV or other Unix toolkit, and the
per-CHECK subprocess cost that would dominate a VMS run disappears.

=item *

Paths are held in Unix syntax internally and converted with
L<VMS::Filespec> only when handed to a foreign command.

=back

=head1 INSTALLATION

The distribution ships as a zip archive, because Info-ZIP's C<unzip> is the
one unpacking tool that can be relied on everywhere this runs - OpenVMS
included, where it also restores file attributes recorded by VMS Zip.

On Unix, Linux and Tru64:

    unzip Lit-1.00.zip
    perl Makefile.PL
    make
    make test
    make install

On OpenVMS:

    $ UNZIP "-a" LIT-1_00.ZIP     ! -a writes text as variable-record files
    $ PERL MAKEFILE.PL
    $ MMK                         ! or MMS, or MAKE
    $ MMK TEST
    $ MMK INSTALL

The two programs install as F<lit.pl> and F<filecheck.pl>.

On OpenVMS you will normally want foreign commands for them.  C<MMK>
generates F<[.VMS]LIT_DEFINE_COMMANDS.COM> for that, filling in the
directory C<MMK INSTALL> actually used and the Perl image that will run
the scripts.  It is not installed automatically, because writing to
F<SYS$STARTUP:> needs privilege; copy it there yourself and call it from
F<SYS$MANAGER:SYLOGIN.COM>, or let users call it from their own
F<LOGIN.COM>.  It has to be one of those rather than
F<SYSTARTUP_VMS.COM>: a symbol defined during system startup belongs to
that process and never reaches a user's.

    $ COPY [.VMS]LIT_DEFINE_COMMANDS.COM SYS$STARTUP:
    $ @SYS$STARTUP:LIT_DEFINE_COMMANDS.COM
    $ LIT -v [.TEST]

The DCL itself is the template in the C<__DATA__> section of
F<vms/mkcom.PL>; edit it there, since the generated F<.com> is rewritten by
every build.

Running from the source tree works too - both scripts locate F<../lib>
themselves, and C<$LIT_PERL_LIB> overrides that if needed.

=head1 GETTING STARTED

A suite is a directory holding a config file and some test files:

    mysuite/lit.cfg
    mysuite/hello.test

F<lit.cfg>:

    $config->name('mysuite');
    $config->suffixes('.test');
    $config->test_source_root($config->dir);
    $config->test_exec_root($config->dir . '/_out');

F<hello.test>:

    RUN: echo hello world | FileCheck %s
    CHECK: hello world

Then:

    $ lit.pl -v mysuite
    PASS: mysuite :: hello.test (1 of 1)

    Testing Time: 0.01s

    Total Discovered Tests: 1
      Passed:                 1 (100.00%)

A complete worked suite is in F<examples/demo>; an annotated OpenVMS
compiler-suite config is in F<examples/openvms-lit.cfg>.

=head1 DOCUMENTATION

=over 4

=item L<lit.pl>, L<filecheck.pl>

The two command line tools and their options.

=item L<Lit::Config>

Writing a F<lit.cfg>: config file names, discovery, and the C<$config> API.

=item L<Lit::LitConfig>

The C<$lit_config> object: C<--param> values, host facts, and the features
every suite gets for free.

=item L<Lit::TestRunner>

Test file directives - C<RUN:>, C<REQUIRES:>, C<XFAIL:>, C<DEFINE:> - and
the substitutions available in a C<RUN:> line.

=item L<Lit::BoolExpr>

The expression language used by C<REQUIRES:>, C<UNSUPPORTED:> and
C<XFAIL:>.

=item L<Lit::ShLex>, L<Lit::ShRun>, L<Lit::Builtins>

The internal shell: what syntax is supported, how commands are executed,
and the full list of builtin commands.

=item L<Lit::FileCheck>, L<Lit::Pattern>

FileCheck's directives, options and pattern syntax.

=item L<Lit::Porting>

Porting an existing Python F<lit.cfg> to Perl by hand.

=item L<Lit::Compat>

Host portability: paths, exit-status decoding, globbing and the three
process-spawning backends.  Mostly of interest when changing the code.

=back

=head1 LIMITATIONS

=over 4

=item *

Per-test timeouts need a real C<fork()>, so C<--timeout> is a no-op on
OpenVMS.  Everything else works there.

=item *

C<-j> runs tests in parallel only where C<fork()> is available; on OpenVMS
the run is serial regardless.

=item *

The DCL backend builds a command procedure per external command, so very
long argument lists can exceed DCL's line limits.  Prefer a response file,
or a wrapper F<.COM>, for pathological cases.

=item *

Test formats other than ShTest (C<RUN:> lines) are not implemented.

=back

=head1 SEE ALSO

L<https://llvm.org/docs/CommandGuide/lit.html>,
L<https://llvm.org/docs/CommandGuide/FileCheck.html>

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2026 Endless Software Solutions

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself: either the GNU General Public
License version 1 (or, at your option, any later version), or the
Artistic License.  See F<LICENSE.md> for the full text of both.

=cut
