use strict;
use warnings;
use Test::More tests => 18;

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
