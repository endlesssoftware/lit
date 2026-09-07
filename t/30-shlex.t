use strict;
use warnings;
use Test::More tests => 16;

use Lit::ShLex;

sub words {
    my ($line) = @_;
    my ($list, $err) = Lit::ShLex::parse($line);
    return "ERR: $err" if defined $err;
    return join('|', map { $_->[0] } @{ $list->[0]{pipeline}[0]{argv} });
}

is(words('a b c'),            'a|b|c',   'plain words');
is(words('a "b c" d'),        'a|b c|d', 'double quotes');
is(words("a 'b c' d"),        'a|b c|d', 'single quotes');
is(words('a b\\ c'),          'a|b c',   'backslash escape');
is(words('a "b\\"c"'),        'a|b"c',   'escaped quote inside quotes');

my ($l, $e) = Lit::ShLex::parse('a | b | c');
is(scalar @{ $l->[0]{pipeline} }, 3, 'three pipeline stages');

($l, $e) = Lit::ShLex::parse('a && b || c ; d');
is(scalar @$l, 4, 'four list items');
is($l->[1]{sep}, '&&', 'and separator');
is($l->[2]{sep}, '||', 'or separator');
is($l->[3]{sep}, ';',  'sequence separator');

($l, $e) = Lit::ShLex::parse('a > out 2> err < in');
my $r = $l->[0]{pipeline}[0]{redirs};
is(scalar @$r, 3, 'three redirections');
is($r->[0]{fd} . $r->[0]{mode}, '1>', 'stdout redirect');
is($r->[1]{fd} . $r->[1]{mode}, '2>', 'stderr redirect');
is($r->[2]{fd} . $r->[2]{mode}, '0<', 'stdin redirect');

($l, $e) = Lit::ShLex::parse('echo "unterminated');
like($e, qr/unterminated double quote/, 'unterminated quote is an error');

($l, $e) = Lit::ShLex::parse('(a; b)');
like($e, qr/subshell/, 'subshells are diagnosed, not mis-run');
