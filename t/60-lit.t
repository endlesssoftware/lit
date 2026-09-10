use strict;
use warnings;
use Test::More tests => 21;

use Lit::Compat;
use Lit::Config;
use Lit::Driver;

my $root = Lit::Compat::temp_subdir('lit');

sub put {
    my ($rel, $text) = @_;
    my $p = Lit::Compat::joinp($root, $rel);
    Lit::Compat::mkpath(Lit::Compat::dirname_of($p));
    Lit::Compat::write_file($p, $text);
}

put('lit.cfg', <<'CFG');
$config->name('demo');
$config->suffixes('.test');
$config->test_source_root($config->dir);
$config->test_exec_root($config->dir . '/_out');
$config->add_feature('demo-feature');
$config->add_substitution('%greet', 'echo hello');
CFG

put('a_pass.test',      "RUN: echo hello world | FileCheck %s\nCHECK: hello world\n");
put('b_fail.test',      "RUN: echo goodbye | FileCheck %s\nCHECK: hello\n");
put('c_temp.test',      "RUN: echo abc > %t.txt\nRUN: cat %t.txt | FileCheck %s\nCHECK: abc\n");
put('d_continue.test',  "RUN: echo aaa \\\nRUN:   bbb | FileCheck %s\nCHECK: aaa bbb\n");
put('e_xfail.test',     "XFAIL: *\nRUN: false\n");
put('f_xpass.test',     "XFAIL: *\nRUN: true\n");
put('g_unsup.test',     "UNSUPPORTED: demo-feature\nRUN: echo never\n");
put('h_require.test',   "REQUIRES: demo-feature\nRUN: %greet | FileCheck %s\nCHECK: hello\n");
put('i_missing.test',   "REQUIRES: no-such-feature\nRUN: echo never\n");
put('j_norun.test',     "; nothing here\n");
put('k_define.test',    "DEFINE: %{g} = echo hi there\nRUN: %{g} | FileCheck %s\nCHECK: hi there\n");
put('l_subst.test',     "RUN: echo %basename_s | FileCheck %s\nCHECK: l_subst.test\n");
put('m_pct.test',       "RUN: echo 100%% | FileCheck %s\nCHECK: 100%\n");
put('sub/n_nested.test',"RUN: echo nested | FileCheck %s\nCHECK: nested\n");
put('sub/litlocal.cfg', "\$config->add_feature('in-subdir');\n");
put('sub/o_local.test', "REQUIRES: in-subdir\nRUN: true\n");

# Run the driver, capturing its output.
sub lit {
    my (@args) = @_;
    my $of = Lit::Compat::joinp($root, 'driver.out');
    open(my $fh, '>', $of) or die $!;
    my $rc = Lit::Driver::run([ @args ], { out => $fh, err => $fh });
    close $fh;
    my $text = Lit::Compat::read_file($of);
    return ($rc, defined $text ? $text : '');
}

sub result_of {
    my ($text, $name) = @_;
    return $1 if $text =~ /^([A-Z]+): demo :: \Q$name\E \(/m;
    return '<none>';
}

my ($rc, $out) = lit('-j1', '--order=lexical', $root);

is($rc, 1, 'exit status is 1 when a test fails');

is(result_of($out, 'a_pass.test'),      'PASS',        'a passing test');
is(result_of($out, 'b_fail.test'),      'FAIL',        'a failing test');
is(result_of($out, 'c_temp.test'),      'PASS',        '%t substitution');
is(result_of($out, 'd_continue.test'),  'PASS',        'RUN line continuation');
is(result_of($out, 'e_xfail.test'),     'XFAIL',       'XFAIL on a failing test');
is(result_of($out, 'f_xpass.test'),     'XPASS',       'XFAIL on a passing test');
is(result_of($out, 'g_unsup.test'),     'UNSUPPORTED', 'UNSUPPORTED expression');
is(result_of($out, 'h_require.test'),   'PASS',        'REQUIRES met');
is(result_of($out, 'i_missing.test'),   'UNSUPPORTED', 'REQUIRES unmet');
is(result_of($out, 'j_norun.test'),     'UNRESOLVED',  'no RUN line');
is(result_of($out, 'k_define.test'),    'PASS',        'DEFINE substitution');
is(result_of($out, 'l_subst.test'),     'PASS',        '%basename_s substitution');
is(result_of($out, 'm_pct.test'),       'PASS',        '%% escapes to a literal percent');
is(result_of($out, 'sub/n_nested.test'),'PASS',        'nested directory');
is(result_of($out, 'sub/o_local.test'), 'PASS',        'local config adds a feature');

like($out, qr/Total Discovered Tests: 15/, 'summary counts every test');

# The failure report should carry the FileCheck diagnostic.
like($out, qr/expected string not found in input/,
     'failure output includes the FileCheck diagnostic');

Lit::Compat::rmtree($root);

# The Output directory must be skipped whatever case readdir reports it in:
# on OpenVMS an exact match would miss, and lit would then walk its own
# scratch directory looking for tests.
my $cfg = Lit::Config->new(dir => '.');
ok($cfg->is_excluded('Output'), 'Output is excluded');
if (Lit::Compat::IS_VMS || Lit::Compat::IS_WIN) {
    ok($cfg->is_excluded('output'), 'and in whatever case readdir reports');
    ok($cfg->is_excluded('OUTPUT'), 'either way');
} else {
    ok(!$cfg->is_excluded('output'), 'case matters where the filesystem cares');
    ok(!$cfg->is_excluded('nothing'), 'an unrelated name is not excluded');
}
