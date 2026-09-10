use strict;
use warnings;
use Test::More tests => 25;

use Lit::Compat;

is(Lit::Compat::joinp('a', 'b', 'c'),        'a/b/c',   'joinp');
is(Lit::Compat::joinp('a/', '/b/', 'c'),     'a/b/c',   'joinp strips separators');
is(Lit::Compat::joinp('/', 'a'),             '/a',      'joinp keeps root');
is(Lit::Compat::clean_path('a/./b/../c'),    'a/c',     'clean_path');
is(Lit::Compat::clean_path('/a//b/'),        '/a/b',    'clean_path collapses');
is(Lit::Compat::clean_path('./'),            '.',       'clean_path of dot');
is(Lit::Compat::dirname_of('/a/b/c.txt'),    '/a/b',    'dirname_of');
is(Lit::Compat::dirname_of('c.txt'),         '.',       'dirname_of bare name');
is(Lit::Compat::basename_of('/a/b/c.txt'),   'c.txt',   'basename_of');
ok(Lit::Compat::is_absolute('/a'),                      'is_absolute unix');
ok(!Lit::Compat::is_absolute('a/b'),                    'relative path');

# Exit status decoding.  On VMS this goes through the POSIX-exit encoding,
# so only assert what is true everywhere.
is(Lit::Compat::exit_code_from_status(0), 0, 'status 0 is success');
ok(Lit::Compat::exit_code_from_status(-1) != 0, 'status -1 is a failure');

# Temp file names must stay legal on ODS-2: at most one dot, <= 39 chars.
my $tf = Lit::Compat::basename_of(Lit::Compat::temp_file('mytag'));
ok(length($tf) <= 39, "temp name fits ODS-2 (got '$tf')");
is(scalar(() = $tf =~ /\./g), 1, 'temp name has exactly one dot');

# Globbing.
my $dir = Lit::Compat::joinp(Lit::Compat::temp_root(),
                             'littest_' . $$ . '_glob');
Lit::Compat::mkpath($dir);
Lit::Compat::write_file(Lit::Compat::joinp($dir, $_), 'x')
    foreach ('a1.txt', 'a2.txt', 'b1.dat');
my @hits = Lit::Compat::glob_expand('a*.txt', $dir);
is(scalar @hits, 2, 'glob matched two files');
is($hits[0], 'a1.txt', 'glob results are relative and sorted');
my @none = Lit::Compat::glob_expand('zz*.txt', $dir);
is($none[0], 'zz*.txt', 'unmatched glob returns the pattern');
Lit::Compat::rmtree($dir);

# --- regressions found on OpenVMS ----------------------------------------

# Every absolute VMS path contains '[' and ']'.  Reading them as a character
# class turned $^X into a regex with an invalid "l-5" range, which killed
# the run outright rather than failing a test.
my $vmspath = '$5$DKA0:[SYS0.SYSCOMMON.perl-5_34]perl.exe';

my $re = eval { Lit::Compat::_glob_to_re($vmspath) };
ok(!$@ && defined $re, 'a bracket run that is not a valid class does not die')
    or diag($@);

my @g = eval { Lit::Compat::glob_expand($vmspath, '.') };
ok(!$@, 'nor does globbing such a word') or diag($@);
is(scalar @g, 1, 'it expands to exactly itself');
is($g[0], $vmspath, 'unchanged');

# '?' and '[' are Unix glob characters; on VMS only '*' marks a pattern.
if (Lit::Compat::IS_VMS) {
    ok(!Lit::Compat::is_glob($vmspath), 'a VMS path is not treated as a glob');
    ok(Lit::Compat::is_glob('foo*.obj'), 'but a VMS wildcard still is');
} else {
    ok(Lit::Compat::is_glob('a[bc]d'), 'a character class is a glob here');
    ok(Lit::Compat::is_glob('foo*.o'), 'as is a star');
}
ok(!Lit::Compat::is_glob('plain.txt'), 'an ordinary name is not');
