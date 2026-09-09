use strict;
use warnings;
use Test::More tests => 22;

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
    dcl    => [ 'mmk := $DISK:[MMK]MMK.EXE',
                'mmk/extended_syntax/description=x.mms all' ],
    stdout => '/work/out', stderr => '&1', cwd => '/work',
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

like($multi, qr{\$ SET DEFAULT /work}, 'cwd becomes SET DEFAULT');
like($multi, qr{\$ EXIT __lit_sts\n\z}, 'the procedure ends by exiting with the status');

# ---- single command: the pre-existing path is unchanged ------------------

my $single = proc_for(
    argv   => [ '/sys$system/brcob.exe', '-c', 'hello.cob' ],
    stdout => '/work/out', stderr => '/work/err', cwd => '/work',
);
like($single, qr{DEFINE/USER/NOLOG SYS\$OUTPUT}, 'a single command still uses DEFINE/USER');
unlike($single, qr{DEASSIGN}, 'and needs no deassign');
like($single, qr{__lit_cmd :== \$/sys\$system/brcob\.exe}, 'foreign command defined');
like($single, qr{__lit_cmd "-c" "hello\.cob"}, 'arguments quoted to preserve case');

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

# ---- the builtin ---------------------------------------------------------

my $dir = Lit::Compat::joinp(Lit::Compat::temp_root(), 'littest_' . $$ . '_dcl');
Lit::Compat::rmtree($dir);
Lit::Compat::mkpath($dir);

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
