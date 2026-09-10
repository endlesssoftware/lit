use strict;
use warnings;
use Test::More tests => 43;

use Lit::Compat;
use Lit::ShRun;

# The generated command procedure is the one part of the OpenVMS path that
# can be checked without OpenVMS, so check it thoroughly.

sub proc_for {
    my (%job) = @_;
    return Lit::Compat::build_dcl_procedure(\%job, '/tmp/o.tmp', '/tmp/e.tmp');
}

# ---- multi-line DCL ------------------------------------------------------

my $multi = proc_for(
    dcl    => [ q{SET DEFAULT [.nosuchdir]},
                q{mmk := $DISK:[MMK]MMK.EXE},
                'mmk/extended_syntax/description=x.mms all' ],
    stdout => '/work/out', stderr => '&1',
           cwd    => 'DISK$SCRATCH:[BUILD.TEST.OUTPUT]',
);

# DEFINE/USER lasts only until the next image exits, so a fragment with two
# images would lose its redirection halfway through.
unlike($multi, qr{DEFINE/USER}, 'multi-line DCL does not use DEFINE/USER');
like($multi, qr{\$ DEFINE/NOLOG SYS\$OUTPUT }, 'it defines SYS$OUTPUT process-wide');
like($multi, qr{\$ DEASSIGN SYS\$OUTPUT}, 'and deassigns it again');
like($multi, qr{DEASSIGN SYS\$OUTPUT.*EXIT __lit_sts}s, 'deassign comes before the exit');
like($multi, qr{DEFINE/NOLOG SYS\$ERROR SYS\$OUTPUT}, 'stderr merge maps to SYS$ERROR');
unlike($multi, qr{DEASSIGN SYS\$ERROR}, 'a merged stderr needs no deassign');

# Both lines must land in ONE procedure: a DCL symbol is local to the
# procedure that defines it.
like($multi, qr{^\$ mmk := \$DISK:\[MMK\]MMK\.EXE$}m, 'the symbol definition is present');
like($multi, qr{^\$ mmk/extended_syntax/description=x\.mms all$}m,
     'and the build line follows it verbatim, qualifiers intact');
like($multi, qr{mmk :=.*mmk/extended_syntax}s, 'in that order, in the same procedure');

like($multi, qr{\$ SET DEFAULT DISK\$SCRATCH:\[BUILD\.TEST\.OUTPUT\]},
     'cwd becomes SET DEFAULT in VMS directory syntax');
like($multi, qr{\$ EXIT __lit_sts\n\z}, 'the procedure ends by exiting with the status');

# ---- single command: the pre-existing path is unchanged ------------------

my $prog   = '/mmk_dir/mmk.exe';
my $single = proc_for(
    argv   => [ $prog, '-c', 'hello.mms' ],
    stdout => '/work/out', stderr => '/work/err',
           cwd    => 'DISK$SCRATCH:[BUILD.TEST.OUTPUT]',
);
like($single, qr{DEFINE/USER/NOLOG SYS\$OUTPUT}, 'a single command still uses DEFINE/USER');
unlike($single, qr{DEASSIGN}, 'and needs no deassign');
my $native = Lit::Compat::to_native($prog);
like($single, qr{\Q__lit_cmd := \E\$\Q$native\E},
     'foreign command defined with := , which is local to the procedure');
unlike($single, qr{__lit_cmd :==},
       'not :== , which would leave a global symbol behind');
like($single, qr{__lit_cmd "-c" "hello\.mms"}, 'arguments quoted to preserve case');

# ---- failure handling ----------------------------------------------------

# An intermediate failure must end the sequence, not be swallowed while
# later commands run against a broken state.
for my $p ([multi => $multi], [single => $single]) {
    my ($what, $text) = @$p;
    like($text, qr{^\$ ON WARNING THEN GOTO __lit_done$}m,
         "$what: a failure jumps to the cleanup label");
    like($text, qr{^\$ __lit_done:\n\$ __lit_sts = \$STATUS$}m,
         "$what: \$STATUS is captured first, before SET NOON could clobber it");
    like($text, qr{__lit_sts = \$STATUS\n\$ SET NOON},
         "$what: cleanup itself cannot be cut short");
    unlike($text, qr{\A\$ SET NOON}, "$what: SET NOON no longer disables checking up front");
}
like($multi, qr{ON WARNING.*SET DEFAULT \[\.nosuchdir\].*__lit_done:}s,
     'the guard is established before any user line runs');

# ---- record formatting ---------------------------------------------------

my $recs = Lit::Compat::_dcl_verbatim([
    "\$ LINK/EXE=x.exe -\n    a.obj,b.obj",
    "RUN x.exe",
    "",
]);
is($recs->[0], '$ LINK/EXE=x.exe -', 'a line already starting with $ is left alone');
is($recs->[1], '    a.obj,b.obj',
   'a continuation record gets no $ prefix, since DCL concatenates it raw');
is($recs->[2], '$ RUN x.exe', 'a bare line gains its $ prefix');
is(scalar @$recs, 3, 'blank separators are dropped');

# ---- unconverted paths are refused --------------------------------------
#
# to_native_dir() is an identity function off OpenVMS, so a Unix path
# survives unchanged here - which is exactly the state the guard exists to
# catch, and lets it be tested on any host.

is(Lit::Compat::dcl_path_problem({ cwd => 'DISK$SCRATCH:[X]' }, undef, undef),
   undef, 'a VMS directory spec is accepted');

is(Lit::Compat::dcl_path_problem({ cwd => 'X:[Y]', stderr => '&1' }, 'X:[Y]O.TMP', undef),
   undef, 'a merged stderr is not mistaken for a path');

SKIP: {
    # On OpenVMS vmspath() turns /work into WORK:[000000] quite happily, so
    # there is nothing left for the guard to catch.  It fires only where the
    # conversion did not happen, which off VMS is every path.
    skip 'paths do convert on OpenVMS, so the guard has nothing to catch', 3
        if Lit::Compat::IS_VMS;

    like(Lit::Compat::dcl_path_problem({ cwd => '/work' }, undef, undef),
         qr/cannot express the working directory '\/work' in VMS syntax/,
         'a Unix path would give "SET DEFAULT /work", which is not DCL');

    like(Lit::Compat::dcl_path_problem({ stdin => '/tmp/in' }, undef, undef),
         qr/standard input/, 'the same check covers SYS$INPUT');

    like(Lit::Compat::dcl_path_problem({}, '/tmp/o.tmp', undef),
         qr/scratch file/, 'and the scratch files interpolated into the procedure');
}

# ---- the builtin ---------------------------------------------------------

my $dir = Lit::Compat::temp_subdir('dcl');

sub sh {
    my ($line) = @_;
    my $o = Lit::Compat::joinp($dir, 'out');
    my $e = Lit::Compat::joinp($dir, 'err');
    Lit::Compat::write_file($o, '');
    Lit::Compat::write_file($e, '');
    my %shell = (cwd => $dir, env => { %ENV });
    my $r = Lit::ShRun::run_line($line, \%shell, { out_file => $o, err_file => $e });
    my $err = Lit::Compat::read_file($e);
    return ($r->{code}, defined $err ? $err : '');
}

my ($rc, $err) = sh('dcl');
isnt($rc, 0, 'dcl with no command fails');

SKIP: {
    skip 'this host is OpenVMS, where dcl really runs', 2 if Lit::Compat::IS_VMS;

    ($rc, $err) = sh("dcl 'WRITE SYS\$OUTPUT \"hi\"'");
    is($rc, 127, 'off OpenVMS the dcl builtin refuses rather than guessing');
    like($err, qr/REQUIRES: vms/, 'and says how to guard the test');
}

Lit::Compat::rmtree($dir);

# ---- the generated startup procedure -------------------------------------
#
# vms/mkcom.PL is run by make (PL_FILES) to produce
# vms/lit_define_commands.com, which has to name the directory the scripts
# were installed into.  Generating it from a test on any host keeps the
# template honest.

SKIP: {
    skip 'mkcom.PL not present (running from an installed copy?)', 6
        unless -f 'vms/mkcom.PL';

    # A file, not a directory: appended to the native scratch root.
    my $gen = Lit::Compat::join_spec(Lit::Compat::temp_root(),
                                     'littest_' . $$ . '_com.com');

    # With paths supplied, as an OpenVMS build would.
    system($^X, 'vms/mkcom.PL', $gen,
           'DISK$TOOLS:[PERL.BIN]', 'DISK$TOOLS:[PERL]PERL.EXE');
    my $com = Lit::Compat::read_file($gen);
    ok(defined $com, 'the procedure is generated');
    like($com, qr/LIT_ROOT = "DISK\$TOOLS:\[PERL\.BIN\]"/,
         'the install directory is baked in');
    like($com, qr/LIT_PERL = "DISK\$TOOLS:\[PERL\]PERL\.EXE"/,
         'as is the Perl image');
    like($com, qr/^\$ LIT       :== \$'LIT_PERL' 'LIT_ROOT'LIT\.PL$/m,
         'LIT is defined as a foreign command');
    unlink $gen;

    # Built off OpenVMS the paths cannot be meaningful, so they are left
    # empty rather than baking in a Unix path that DCL could not use.
    # "-" rather than "": OpenVMS drops a zero-length argument entirely, so
    # a test cannot ask for an empty one by passing "".
    system($^X, 'vms/mkcom.PL', $gen, '-', '-');
    $com = Lit::Compat::read_file($gen);
    like($com, qr/LIT_ROOT = ""/, 'an unknown path is left empty');
    unlike($com, qr/\@LIT_(?:ROOT|PERL)\@/,
           'no placeholder survives substitution');
    unlink $gen;
}
