use strict;
use warnings;
use Test::More tests => 29;

use Lit::Compat;
use Lit::Driver;

# --- the JSON emitter, checked directly ----------------------------------
#
# Hand-rolled because JSON::PP is only core from 5.14 and OpenVMS VAX tops
# out at 5.8, so the escaping deserves its own tests.

is(Lit::Driver::_json_string('plain'),      '"plain"',        'plain string');
is(Lit::Driver::_json_string('a"b'),        '"a\\"b"',        'double quote');
is(Lit::Driver::_json_string('a\\b'),       '"a\\\\b"',       'backslash');
is(Lit::Driver::_json_string("a\nb"),       '"a\\nb"',        'newline');
is(Lit::Driver::_json_string("a\tb"),       '"a\\tb"',        'tab');
is(Lit::Driver::_json_string("a\rb"),       '"a\\rb"',        'carriage return');
is(Lit::Driver::_json_string("a\x01b"),     '"a\\u0001b"',    'other control chars');
is(Lit::Driver::_json_string(undef),        '""',             'undef becomes empty');
# A backslash must be escaped before anything that introduces one, or the
# escapes would themselves be escaped.
is(Lit::Driver::_json_string("\\n"),        '"\\\\n"',
   'a literal backslash-n is not confused with a newline');

is(Lit::Driver::_json_num(0),     '0',        'integer zero');
is(Lit::Driver::_json_num(2),     '2',        'whole numbers stay integral');
is(Lit::Driver::_json_num(1.5),   '1.5',      'fractions keep no trailing zeros');
is(Lit::Driver::_json_num(1.23),  '1.23',     'and read as written');
is(Lit::Driver::_json_num(undef), '0',        'undef becomes zero');

# --- end to end ----------------------------------------------------------

my $root = Lit::Compat::joinp(Lit::Compat::temp_root(), 'littest_' . $$ . '_out');
Lit::Compat::rmtree($root);
Lit::Compat::mkpath($root);

sub put {
    my ($rel, $text) = @_;
    my $p = Lit::Compat::joinp($root, $rel);
    Lit::Compat::mkpath(Lit::Compat::dirname_of($p));
    Lit::Compat::write_file($p, $text);
}

put('lit.cfg', join("\n",
    q{$config->name('demo');},
    q{$config->suffixes('.test');},
    q{$config->test_source_root($config->dir);},
    q{$config->test_exec_root($config->dir . '/_out');}, ''));
put('a_pass.test',  "RUN: echo hi | FileCheck %s\nCHECK: hi\n");
put('b_fail.test',  "RUN: echo bye | FileCheck %s\nCHECK: hi\n");
put('c_xfail.test', "XFAIL: *\nRUN: false\n");
put('d_metrics.test',
    "RUN: metrics compile_time=1.23 size=4096 tool=mmk-3.1\n"
  . "RUN: printf 'parse_ms=17\\n' | metrics\n"
  . "RUN: true\n");

my $json  = Lit::Compat::joinp($root, 'last-run.json');
my $xunit = Lit::Compat::joinp($root, 'results.xml');
my $devnull = Lit::Compat::joinp($root, 'driver.out');

open(my $fh, '>', $devnull) or die $!;
my $rc = Lit::Driver::run(
    [ '-j1', '--order=lexical', "--output=$json", "--xunit-xml-output=$xunit", $root ],
    { out => $fh, err => $fh });
close $fh;

is($rc, 1, 'the run reports failure');
ok(-f $json,  'the JSON results file was written');
ok(-f $xunit, 'the JUnit XML file was written');

my $text = Lit::Compat::read_file($json);
like($text, qr/^\{"__version__": \[1, 0, 0\],/,
     'the format version matches the last-run.json consumers expect');
like($text, qr/"elapsed": [0-9]/, 'a run elapsed time is present');
like($text, qr/\{"name": "demo :: a_pass\.test", "code": "PASS", "elapsed": [0-9.]+\}/,
     'a passing test records name, code and elapsed, and no output');
like($text, qr/"name": "demo :: b_fail\.test", "code": "FAIL", .*"output": "Script/,
     'a failing test carries its output too');
like($text, qr/"name": "demo :: c_xfail\.test", "code": "XFAIL"/,
     'XFAIL is reported as its own code');

# Metrics are the one thing a RUN: line can contribute to the results,
# because they concern only its own test.
like($text, qr/"name": "demo :: d_metrics\.test".*"metrics": \{/,
     'metrics recorded from a RUN: line reach the results file');
like($text, qr/"compile_time": 1\.23/,  'a fractional metric stays a number');
like($text, qr/"size": 4096/,           'an integral one stays integral');
like($text, qr/"tool": "mmk-3\.1"/,   'a non-numeric one is quoted');
like($text, qr/"parse_ms": 17/,         'metrics can be piped in on stdin');
unlike($text, qr/"name": "demo :: a_pass\.test"[^\n]*"metrics"/,
       'a test that recorded none has no metrics key at all');

# One test per line: VMS text files are record oriented, and a single very
# long record is asking for trouble.
my @lines = split(/\n/, $text);
ok(scalar(@lines) >= 5, 'the file is written a test per line, not one long record');

Lit::Compat::rmtree($root);
