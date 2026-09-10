use strict;
use warnings;
use Test::More tests => 46;

use Lit::Compat;
use Lit::ShRun;

my $dir = Lit::Compat::joinp(Lit::Compat::temp_root(), 'littest_' . $$ . '_sh');

Lit::Compat::rmtree($dir);
Lit::Compat::mkpath($dir);

# A helper spawned as a real subprocess.  Using $^X rather than /bin/sh keeps
# these cases meaningful on hosts with no Unix shell.
my $helper = Lit::Compat::joinp($dir, 'helper.pl');
Lit::Compat::write_file($helper, <<'HELPER');
my $mode = shift(@ARGV);
$mode = '' unless defined $mode;
if    ($mode eq 'out')  { print STDOUT "to-stdout\n" }
elsif ($mode eq 'err')  { print STDERR "to-stderr\n" }
elsif ($mode eq 'both') { print STDOUT "to-stdout\n"; print STDERR "to-stderr\n" }
elsif ($mode eq 'env')  { my $n = shift(@ARGV);
                          my $v = defined $ENV{$n} ? $ENV{$n} : '';
                          print STDOUT "$v\n"; }
elsif ($mode eq 'exit') { exit(shift(@ARGV) || 0) }
exit 0;
HELPER
my $PERL = Lit::Compat::to_native($^X);
my $HELP = Lit::Compat::to_native($helper);

sub sh {
    my ($line) = @_;
    my $o = Lit::Compat::joinp($dir, 'out.txt');
    my $e = Lit::Compat::joinp($dir, 'err.txt');
    Lit::Compat::write_file($o, '');
    Lit::Compat::write_file($e, '');
    my %shell = (cwd => $dir, env => { %ENV });
    my $r = Lit::ShRun::run_line($line, \%shell,
                                 { out_file => $o, err_file => $e });
    my $out = Lit::Compat::read_file($o);
    my $err = Lit::Compat::read_file($e);
    return ($r->{code}, (defined $out ? $out : ''), (defined $err ? $err : ''),
            $r->{error});
}

sub rc_is {
    my ($name, $line, $want) = @_;
    my ($rc, $out, $err, $e) = sh($line);
    is($rc, $want, $name) or diag("stderr: $err" . (defined $e ? " error: $e" : ''));
}

sub out_is {
    my ($name, $line, $want) = @_;
    my ($rc, $out, $err, $e) = sh($line);
    is($out, $want, $name) or diag("rc=$rc stderr: $err" . (defined $e ? " error: $e" : ''));
}

# --- words, quoting, redirection
out_is('echo',            'echo hello world',                "hello world\n");
out_is('echo -n',         'echo -n abc',                     'abc');
out_is('quoting kept',    'echo "a  b"',                     "a  b\n");
out_is('redirect+cat',    'echo hi > f1 && cat f1',          "hi\n");
out_is('append',          'echo a > f2; echo b >> f2; cat f2', "a\nb\n");

# --- pipelines
out_is('pipe',            'printf "b\na\nc\n" | sort',       "a\nb\nc\n");
out_is('pipe of three',   'printf "x\ny\nx\n" | sort | uniq', "x\ny\n");
rc_is ('pipefail',        'false | true',                    1);

# --- control operators
rc_is ('false',           'false',                           1);
rc_is ('or recovers',     'false || true',                   0);
out_is('and short-circuits', 'false && echo nope',           '');
rc_is ('not inverts',     'not false',                       0);
rc_is ('not fails on ok', 'not true',                        1);
rc_is ('bang inverts',    '! false',                         0);

# --- text utilities
out_is('grep',            'printf "aa\nbb\n" | grep bb',     "bb\n");
rc_is ('grep no match',   'printf "aa\n" | grep zz',         1);
out_is('grep -v',         'printf "aa\nbb\n" | grep -v aa',  "bb\n");
out_is('sed substitute',  'echo foobar | sed s/foo/BAZ/',    "BAZbar\n");
out_is('sed global',      'echo aaa | sed s/a/b/g',          "bbb\n");
out_is('sed BRE groups',  'echo "a=1" | sed -e "s/\\(.\\)=\\(.\\)/\\2=\\1/"', "1=a\n");
out_is('sed ERE groups',  'echo "a=1" | sed -E -e "s/(.)=(.)/\\2=\\1/"',      "1=a\n");
out_is('sed -n p',        'printf "x\ny\n" | sed -n /y/p',   "y\n");
out_is('head',            'printf "1\n2\n3\n" | head -n 2',  "1\n2\n");
out_is('tail',            'printf "1\n2\n3\n" | tail -n 1',  "3\n");
out_is('wc -l',           'printf "1\n2\n3\n" | wc -l',      "      3\n");

# --- the tree
out_is('mkdir/cd/pwd',    'mkdir -p s/d && cd s/d && pwd',   "$dir/s/d\n");
rc_is ('rm -rf',          'mkdir -p zap && rm -rf zap && test ! -d zap', 0);
out_is('cp then mv',      'echo v > c1 && cp c1 c2 && mv c2 c3 && cat c3', "v\n");
rc_is ('test -f',         'echo x > tf && test -f tf',       0);
rc_is ('test -f absent',  'test -f nosuchfile',              1);
rc_is ('test numeric',    'test 3 -gt 2',                    0);
out_is('glob expands',    'echo g1 > ga.txt && echo g2 > gb.txt && cat g*.txt', "g1\ng2\n");

# --- diff
rc_is ('diff same',       'echo s > d1 && echo s > d2 && diff d1 d2', 0);
out_is('diff unified',
       'echo s > d1 && echo t > d2 && diff -u d1 d2 > dd; cat dd',
       "--- d1\n+++ d2\n\@\@ -1,1 +1,1 \@\@\n-s\n+t\n");

# --- FileCheck as a builtin
rc_is ('FileCheck builtin',
       'echo CHECK: hello > fc && echo hello | FileCheck fc', 0);
rc_is ('FileCheck builtin fails',
       'echo CHECK: hello > fc && echo bye | FileCheck fc 2> /dev/null', 1);

# --- real subprocesses
out_is('subprocess stdout', "$PERL $HELP out",               "to-stdout\n");
out_is('stderr stays separate',
       "$PERL $HELP both 2> e1",                             "to-stdout\n");
out_is('2>&1 merges',      "$PERL $HELP err 2>&1",           "to-stderr\n");
rc_is ('exit code propagates', "$PERL $HELP exit 3",         3);
out_is('env sets a variable',  "env FOO=bar $PERL $HELP env FOO", "bar\n");
rc_is ('command not found', 'no_such_program_xyz_12345',     127);


# A wrapper builtin must not keep the redirection targets open while the
# command it wraps runs: OpenVMS RMS refuses a second write accessor, so the
# nested open failed and "not" inverted that error instead of the command's
# real status - making "not true" and "not false" both report success.
rc_is('not true, output redirected',  'not true  > w1.txt',  1);
rc_is('not false, output redirected', 'not false > w2.txt',  0);
rc_is('env then a builtin',           'env A=1 false',       1);
out_is('wrapper output still lands',  'not false > w3.txt; cat w3.txt', '');

Lit::Compat::rmtree($dir);
