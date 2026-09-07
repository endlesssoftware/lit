use strict;
use warnings;
use Test::More tests => 14;

use Lit::BoolExpr;

my @f = qw(linux asserts x86_64);

sub ev {
    my ($e) = @_;
    my ($v, $err) = Lit::BoolExpr::evaluate($e, \@f);
    return defined $err ? "ERR" : $v;
}

is(ev('linux'),                1, 'known feature');
is(ev('windows'),              0, 'unknown feature');
is(ev('!windows'),             1, 'negation');
is(ev('linux && asserts'),     1, 'and');
is(ev('linux && windows'),     0, 'and with a missing feature');
is(ev('windows || linux'),     1, 'or');
is(ev('!(windows || darwin)'), 1, 'parenthesised negation');
is(ev('*'),                    1, 'star is always true');
is(ev('true'),                 1, 'true literal');
is(ev('false'),                0, 'false literal');
is(ev('{{x86.*}}'),            1, 'regex feature match');
is(ev('{{arm.*}}'),            0, 'regex feature miss');
is(ev('windows, linux'),       1, 'comma means or');
is(ev('linux &&'),         'ERR', 'syntax error is reported');
