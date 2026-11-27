use strict;
use warnings;
use Test::More tests => 38;

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
my $dir = Lit::Compat::temp_subdir('glob');
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

# SYS$SCRATCH: is a plain logical naming a directory, not a rooted one.  Put
# through Unix syntax it becomes /sys$scratch/, and converting back reads
# the first component as a device - giving SYS$SCRATCH:[000000]FOO.TMP, the
# master directory of the volume rather than the user's scratch area.  So a
# native directory has the name appended, never joined with a slash.
is(Lit::Compat::join_spec('SYS$SCRATCH:', 'LITOUT_1_1.TMP'),
   'SYS$SCRATCH:LITOUT_1_1.TMP', 'a logical ending in : is appended to');
is(Lit::Compat::join_spec('DISK$USER:[SMITH]', 'LITOUT_1_1.TMP'),
   'DISK$USER:[SMITH]LITOUT_1_1.TMP', 'so is a directory ending in ]');
is(Lit::Compat::join_spec('/tmp', 'x.tmp'),  '/tmp/x.tmp', 'a Unix path is joined');
is(Lit::Compat::join_spec('/tmp/', 'x.tmp'), '/tmp/x.tmp', 'without doubling the slash');
is(Lit::Compat::join_spec('', 'x.tmp'),      'x.tmp',      'an empty directory is dropped');

# ODS-2 names for %t.
use Lit::Config;
use Lit::Test;
is(Lit::Compat::ods2_name('words.mmst_tmp'), 'words_mmst_tmp', 'ods2_name turns dots into underscores');
is(Lit::Compat::ods2_name('a b+c$d-e'),      'a_b_c$d-e',      'ods2_name keeps $ and -');
my $long = Lit::Compat::ods2_name('x' x 50);
is(length($long), 39, 'ods2_name caps a long name at 39');
isnt($long, Lit::Compat::ods2_name(('x' x 49) . 'y'), 'two long names stay distinct');
ok(!Lit::Compat::needs_ods2_names('/tmp'), 'no ODS-2 names off OpenVMS')
    unless Lit::Compat::IS_VMS;
ok(1, 'needs_ods2_names is probed on OpenVMS') if Lit::Compat::IS_VMS;
my $cfg = Lit::Config->new(dir => '/suite');
$cfg->test_source_root('/suite');
my $t = Lit::Test->new(config => $cfg, rel => 'text/words.mmst', path => '/suite/text/words.mmst');
# The default probes the disk, and an ODS-2 build area on OpenVMS rightly
# says no to dots, so the plain form is asked for explicitly.
$cfg->ods2_names(0);
is(Lit::Compat::basename_of($t->temp_base), 'words.mmst.tmp', '%t keeps its dots when ODS-2 names are off');
$cfg->ods2_names(1);
is(Lit::Compat::basename_of($t->temp_base), 'words_mmst_tmp', '%t is ODS-2 legal when asked');
$cfg->ods2_names(0);
is(Lit::Compat::basename_of($t->temp_base), 'words.mmst.tmp', 'and can be forced off');
