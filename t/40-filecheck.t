use strict;
use warnings;
use Test::More tests => 33;

use Lit::Compat;
use Lit::FileCheck;

my $dir = Lit::Compat::temp_subdir('fc');

my $seq = 0;
sub check {
    my ($name, $want, $input, $checks, @args) = @_;
    $seq++;
    my $in = Lit::Compat::joinp($dir, "in$seq.txt");
    my $cf = Lit::Compat::joinp($dir, "ck$seq.txt");
    Lit::Compat::write_file($in, $input);
    Lit::Compat::write_file($cf, $checks);

    my $outfile = Lit::Compat::joinp($dir, "o$seq.txt");
    open(my $of, '>', $outfile) or die $!;
    open(my $ifh, '<', $in) or die $!;
    my $rc = Lit::FileCheck::run([ @args, '--dump-input=never', $cf ],
                                 { in => $ifh, out => $of, err => $of });
    close $ifh;
    close $of;
    is($rc, $want, $name)
        or diag(Lit::Compat::read_file($outfile));
}

check('plain match',      0, "hello world\n",       "CHECK: hello\n");
check('plain miss',       1, "goodbye\n",           "CHECK: hello\n");
check('regex',            0, "value 42\n",          "CHECK: value {{[0-9]+}}\n");
check('next ok',          0, "a\nb\n",              "CHECK: a\nCHECK-NEXT: b\n");
check('next gap',         1, "a\n\nb\n",            "CHECK: a\nCHECK-NEXT: b\n");
check('same ok',          0, "a b\n",               "CHECK: a\nCHECK-SAME: b\n");
check('same across line', 1, "a\nb\n",              "CHECK: a\nCHECK-SAME: b\n");
check('empty ok',         0, "a\n\nb\n",            "CHECK: a\nCHECK-EMPTY:\nCHECK-NEXT: b\n");
check('empty miss',       1, "a\nb\n",              "CHECK: a\nCHECK-EMPTY:\n");
check('not clean',        0, "a\nc\n",              "CHECK: a\nCHECK-NOT: b\nCHECK: c\n");
check('not violated',     1, "a\nb\nc\n",           "CHECK: a\nCHECK-NOT: b\nCHECK: c\n");
check('dag any order',    0, "a\nc\nb\n",           "CHECK-DAG: b\nCHECK-DAG: c\n");
check('dag no overlap',   1, "xx\n",                "CHECK-DAG: xx\nCHECK-DAG: xx\n");
check('count ok',         0, "x\nx\nx\n",           "CHECK-COUNT-3: x\n");
check('count short',      1, "x\nx\n",              "CHECK-COUNT-3: x\n");
check('label blocks',     0, "f a\n x\nf b\n y\n",
      "CHECK-LABEL: f a\nCHECK: x\nCHECK-LABEL: f b\nCHECK: y\n");
check('label confines',   1, "f a\n y\nf b\n x\n",
      "CHECK-LABEL: f a\nCHECK: x\nCHECK-LABEL: f b\nCHECK: y\n");

check('string var',       0, "def %r1\nuse %r1\n",
      "CHECK: def %[[R:[a-z0-9]+]]\nCHECK: use %[[R]]\n");
check('string var miss',  1, "def %r1\nuse %r2\n",
      "CHECK: def %[[R:[a-z0-9]+]]\nCHECK: use %[[R]]\n");
check('numeric var',      0, "reg 7\nnext 8\n",
      "CHECK: reg [[#N:]]\nCHECK: next [[#N+1]]\n");
check('numeric miss',     1, "reg 7\nnext 9\n",
      "CHECK: reg [[#N:]]\nCHECK: next [[#N+1]]\n");
check('numeric hex',      0, "addr 0000BEEF\n",     "CHECK: addr [[#%.8X,A:]]\n");
# A variable is not available until its own match completes, so a use must
# be on a later line than the definition -- as in real FileCheck.
check('numeric funcs',    0, "a 4\nb 12\n",
      "CHECK: a [[#N:]]\nCHECK: b [[#mul(N,3)]]\n");
check('same-line use',    1, "a 4 b 12\n",
      "CHECK: a [[#N:]] b [[#mul(N,3)]]\n");
check('line number',      0, "err at line 3\n",     "CHECK: err at line [[\@LINE+2]]\n");
check('capture groups',   0, "aa 12 bb\n",
      "CHECK: {{(aa|zz)}} [[N:[0-9]+]] bb\n");

check('whitespace loose', 0, "a      b\n",          "CHECK: a b\n");
check('strict whitespace',1, "a      b\n",          "CHECK: a b\n", '--strict-whitespace');
check('match full lines', 1, "xabcx\n",             "CHECK: abc\n",  '--match-full-lines');
check('multiple prefixes',0, "foo\nbar\n",          "A: foo\nB: bar\n", '--check-prefixes=A,B');
check('implicit not',     1, "foo\nbad\nbar\n",     "CHECK: foo\nCHECK: bar\n",
      '--implicit-check-not=bad');
check('ignore case',      0, "FOO\n",               "CHECK: foo\n", '--ignore-case');
check('-D define',        0, "value=42\n",          "CHECK: value=[[V]]\n", '-DV=42');

Lit::Compat::rmtree($dir);
