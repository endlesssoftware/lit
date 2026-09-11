package Lit::Builtins;

# Unix commands implemented in-process.
#
# Two reasons this exists.  First, OpenVMS has none of these, and requiring
# GNV to run a test suite is a poor trade.  Second, process creation on VMS
# is expensive enough that spawning a subprocess per CHECK step would
# dominate the run time; running FileCheck in-process avoids that entirely.
#
# Every builtin has the signature
#
#     sub { my ($argv, $ctx) = @_; return $exit_code }
#
# where $argv includes argv[0] and $ctx provides:
#
#     in  out  err     filehandles already pointed at the right places
#     shell            { cwd => $dir, env => \%env }   - mutable
#     exec             coderef to run a nested command (used by not/env)
#
# Builtins must resolve relative paths against $ctx->{shell}{cwd} themselves:
# the Perl process's own working directory is never changed.

use strict;
use warnings;

require 5.006;

use Lit::Compat ();

use vars qw($VERSION);
$VERSION = '1.00';

my %BUILTIN;

sub lookup {
    my ($name) = @_;
    return undef unless defined $name;
    return $BUILTIN{$name} if exists $BUILTIN{$name};
    my $lc = lc $name;
    return $BUILTIN{$lc} if exists $BUILTIN{$lc};
    return undef;
}

sub names { return sort keys %BUILTIN }

# ------------------------------------------------------------------ helpers

sub _p {
    my ($ctx, $file) = @_;
    return $file unless defined $file;
    return $file if $file eq '-';
    return $file if Lit::Compat::is_absolute($file);
    return Lit::Compat::clean_path(
        Lit::Compat::joinp($ctx->{shell}{cwd}, $file));
}

sub _die {
    my ($ctx, $prog, $msg) = @_;
    print { $ctx->{err} } "$prog: $msg\n";
    return 1;
}

sub _slurp_lines {
    my ($ctx, $prog, $files) = @_;
    my @lines;
    my $rc = 0;
    my @f = @$files;
    @f = ('-') unless @f;
    foreach my $f (@f) {
        if ($f eq '-') {
            my $fh = $ctx->{in};
            while (defined(my $l = <$fh>)) { push @lines, $l }
            next;
        }
        my $path = _p($ctx, $f);
        local *FH;
        unless (open(FH, '<', $path)) {
            print { $ctx->{err} } "$prog: $f: $!\n";
            $rc = 1;
            next;
        }
        while (defined(my $l = <FH>)) { push @lines, $l }
        close(FH);
    }
    return (\@lines, $rc);
}

# Split an argv into leading option letters and the remaining operands.
# Understands clustered short options and "--".
sub _getopt {
    my ($argv, $spec) = @_;     # $spec: 'abc' flags, 'n:' takes a value
    my %flag;
    my @rest;
    my %takes;
    while ($spec =~ /(.)(:?)/g) { $takes{$1} = ($2 eq ':') }
    my @a = @$argv;
    shift @a;                   # argv[0]
    while (@a) {
        my $x = shift @a;
        if ($x eq '--') { push @rest, @a; last }
        if ($x =~ /^-(.+)$/ && $x ne '-') {
            my $body = $1;
            if ($body =~ /^-/) { push @rest, $x; next }   # long option: caller's problem
            my @c = split //, $body;
            while (@c) {
                my $c = shift @c;
                unless (exists $takes{$c}) { return (undef, undef, "invalid option -- '$c'") }
                if ($takes{$c}) {
                    my $v = @c ? join('', @c) : (@a ? shift @a : undef);
                    @c = ();
                    return (undef, undef, "option requires an argument -- '$c'")
                        unless defined $v;
                    $flag{$c} = $v;
                } else {
                    $flag{$c} = 1;
                }
            }
            next;
        }
        push @rest, $x;
    }
    return (\%flag, \@rest, undef);
}

# ------------------------------------------------------------- trivial verbs

$BUILTIN{':'}     = sub { return 0 };
$BUILTIN{'true'}  = sub { return 0 };
$BUILTIN{'false'} = sub { return 1 };

$BUILTIN{'pwd'} = sub {
    my ($argv, $ctx) = @_;
    print { $ctx->{out} } $ctx->{shell}{cwd} . "\n";
    return 0;
};

$BUILTIN{'echo'} = sub {
    my ($argv, $ctx) = @_;
    my @a = @$argv;
    shift @a;
    my ($nonl, $esc) = (0, 0);
    while (@a && $a[0] =~ /^-[neE]+$/) {
        my $o = shift @a;
        $nonl = 1 if $o =~ /n/;
        $esc  = 1 if $o =~ /e/;
        $esc  = 0 if $o =~ /E/;
    }
    my $s = join(' ', @a);
    if ($esc) {
        $s =~ s/\\n/\n/g;  $s =~ s/\\t/\t/g;  $s =~ s/\\r/\r/g;
        $s =~ s/\\0/\0/g;  $s =~ s/\\\\/\\/g;
    }
    print { $ctx->{out} } $s;
    print { $ctx->{out} } "\n" unless $nonl;
    return 0;
};

$BUILTIN{'printf'} = sub {
    my ($argv, $ctx) = @_;
    my @a = @$argv;
    shift @a;
    return _die($ctx, 'printf', 'missing format') unless @a;
    my $fmt = shift @a;
    $fmt =~ s/\\n/\n/g; $fmt =~ s/\\t/\t/g; $fmt =~ s/\\r/\r/g;
    $fmt =~ s/\\\\/\\/g;
    my $out = eval { sprintf($fmt, @a) };
    return _die($ctx, 'printf', 'bad format') unless defined $out;
    print { $ctx->{out} } $out;
    return 0;
};

$BUILTIN{'cat'} = sub {
    my ($argv, $ctx) = @_;
    my ($lines, $rc) = _slurp_lines($ctx, 'cat', [ @$argv[1 .. $#$argv] ]);
    print { $ctx->{out} } join('', @$lines);
    return $rc;
};

$BUILTIN{'basename'} = sub {
    my ($argv, $ctx) = @_;
    return _die($ctx, 'basename', 'missing operand') unless defined $argv->[1];
    my $b = Lit::Compat::basename_of($argv->[1]);
    if (defined $argv->[2]) {
        my $suf = quotemeta $argv->[2];
        $b =~ s/$suf$//;
    }
    print { $ctx->{out} } $b . "\n";
    return 0;
};

$BUILTIN{'dirname'} = sub {
    my ($argv, $ctx) = @_;
    return _die($ctx, 'dirname', 'missing operand') unless defined $argv->[1];
    print { $ctx->{out} } Lit::Compat::dirname_of($argv->[1]) . "\n";
    return 0;
};

# --------------------------------------------------------------- shell state

$BUILTIN{'cd'} = sub {
    my ($argv, $ctx) = @_;
    my $d = defined $argv->[1] ? $argv->[1] : $ctx->{shell}{env}{HOME};
    return _die($ctx, 'cd', 'no directory given') unless defined $d;
    my $abs = _p($ctx, $d);
    $abs = Lit::Compat::clean_path($abs);
    return _die($ctx, 'cd', "$d: no such directory") unless -d $abs;
    $ctx->{shell}{cwd} = $abs;
    return 0;
};

$BUILTIN{'export'} = sub {
    my ($argv, $ctx) = @_;
    my @a = @$argv;
    shift @a;
    foreach my $x (@a) {
        if ($x =~ /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s) {
            $ctx->{shell}{env}{$1} = $2;
        } else {
            return _die($ctx, 'export', "invalid assignment '$x'");
        }
    }
    return 0;
};

$BUILTIN{'unset'} = sub {
    my ($argv, $ctx) = @_;
    my @a = @$argv;
    shift @a;
    delete $ctx->{shell}{env}{$_} foreach @a;
    return 0;
};

$BUILTIN{'env'} = sub {
    my ($argv, $ctx) = @_;
    my @a = @$argv;
    shift @a;
    my %env = %{ $ctx->{shell}{env} };
    my $ignore = 0;

    while (@a) {
        if ($a[0] eq '-i' || $a[0] eq '--ignore-environment') { shift @a; %env = (); next }
        if ($a[0] eq '-u' || $a[0] eq '--unset') {
            shift @a;
            return _die($ctx, 'env', 'option -u requires an argument') unless @a;
            delete $env{ shift @a };
            next;
        }
        if ($a[0] =~ /^-u(.+)$/) { shift @a; delete $env{$1}; next }
        if ($a[0] =~ /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s) {
            $env{$1} = $2;
            shift @a;
            next;
        }
        last;
    }

    unless (@a) {
        foreach my $k (sort keys %env) { print { $ctx->{out} } "$k=$env{$k}\n" }
        return 0;
    }
    return _die($ctx, 'env', 'cannot run a command here') unless $ctx->{exec};
    my %sub = %$ctx;
    $sub{shell} = { cwd => $ctx->{shell}{cwd}, env => \%env };
    return $ctx->{exec}->(\@a, \%sub);
};

$BUILTIN{'not'} = sub {
    my ($argv, $ctx) = @_;
    my @a = @$argv;
    shift @a;
    my $crash = 0;
    while (@a && $a[0] =~ /^--crash$/) { $crash = 1; shift @a }
    return 1 unless @a;                       # bare "not" is a failure
    return _die($ctx, 'not', 'cannot run a command here') unless $ctx->{exec};
    my $rc = $ctx->{exec}->(\@a, $ctx);
    if ($crash) {
        # --crash demands an abnormal termination (a signal, or >= 128).
        return ($rc >= 128) ? 0 : 1;
    }
    return $rc == 0 ? 1 : 0;
};

# LLVM's count(1): succeed when stdin holds exactly <n> lines.
$BUILTIN{'count'} = sub {
    my ($argv, $ctx) = @_;
    my @a = @$argv;
    shift @a;
    return _die($ctx, 'count', 'missing count')
        unless @a && $a[0] =~ /^[0-9]+$/;
    my $want = 0 + shift @a;
    my ($lines, $rc) = _slurp_lines($ctx, 'count', \@a);
    my $got = scalar @$lines;
    return $rc if $rc;
    if ($got != $want) {
        print { $ctx->{err} } "Expected $want lines, got $got.\n";
        return 1;
    }
    return 0;
};

# ------------------------------------------------------------------ the tree

$BUILTIN{'mkdir'} = sub {
    my ($argv, $ctx) = @_;
    my ($f, $rest, $e) = _getopt($argv, 'p');
    return _die($ctx, 'mkdir', $e) if defined $e;
    return _die($ctx, 'mkdir', 'missing operand') unless @$rest;
    my $rc = 0;
    foreach my $d (@$rest) {
        my $abs = _p($ctx, $d);
        if ($f->{p}) {
            next if -d $abs;
            unless (Lit::Compat::mkpath($abs)) {
                print { $ctx->{err} } "mkdir: cannot create '$d': $!\n"; $rc = 1;
            }
        } else {
            if (-d $abs) { print { $ctx->{err} } "mkdir: '$d' exists\n"; $rc = 1; next }
            unless (mkdir($abs)) {
                print { $ctx->{err} } "mkdir: cannot create '$d': $!\n"; $rc = 1;
            }
        }
    }
    return $rc;
};

$BUILTIN{'rmdir'} = sub {
    my ($argv, $ctx) = @_;
    my ($f, $rest, $e) = _getopt($argv, 'p');
    return _die($ctx, 'rmdir', $e) if defined $e;
    my $rc = 0;
    foreach my $d (@$rest) {
        unless (rmdir(_p($ctx, $d))) {
            print { $ctx->{err} } "rmdir: cannot remove '$d': $!\n"; $rc = 1;
        }
    }
    return $rc;
};

$BUILTIN{'rm'} = sub {
    my ($argv, $ctx) = @_;
    my ($f, $rest, $e) = _getopt($argv, 'rRfv');
    return _die($ctx, 'rm', $e) if defined $e;
    my $force = $f->{f} ? 1 : 0;
    my $recur = ($f->{r} || $f->{R}) ? 1 : 0;
    unless (@$rest) { return $force ? 0 : _die($ctx, 'rm', 'missing operand') }
    my $rc = 0;
    foreach my $t (@$rest) {
        my $abs = _p($ctx, $t);
        unless (-e $abs || -l $abs) {
            next if $force;
            print { $ctx->{err} } "rm: '$t': no such file or directory\n"; $rc = 1;
            next;
        }
        if (-d $abs) {
            unless ($recur) {
                print { $ctx->{err} } "rm: '$t' is a directory\n"; $rc = 1; next;
            }
            Lit::Compat::rmtree($abs);
            if (-e $abs) { print { $ctx->{err} } "rm: cannot remove '$t'\n"; $rc = 1 }
        } else {
            unless (unlink($abs)) {
                next if $force;
                print { $ctx->{err} } "rm: cannot remove '$t': $!\n"; $rc = 1;
            }
        }
    }
    return $rc;
};

$BUILTIN{'touch'} = sub {
    my ($argv, $ctx) = @_;
    my $rc = 0;
    foreach my $t (@$argv[1 .. $#$argv]) {
        my $abs = _p($ctx, $t);
        if (-e $abs) { utime(undef, undef, $abs); next }
        local *FH;
        unless (open(FH, '>', $abs)) {
            print { $ctx->{err} } "touch: cannot create '$t': $!\n"; $rc = 1; next;
        }
        close(FH);
    }
    return $rc;
};

sub _copy_file {
    my ($src, $dst) = @_;
    my $data = Lit::Compat::read_file($src);
    return 0 unless defined $data;
    return Lit::Compat::write_file($dst, $data);
}

sub _copy_tree {
    my ($src, $dst) = @_;
    if (-d $src) {
        Lit::Compat::mkpath($dst) unless -d $dst;
        local *DH;
        opendir(DH, $src) or return 0;
        my @e = grep { $_ ne '.' && $_ ne '..' } readdir(DH);
        closedir(DH);
        foreach my $e (@e) {
            return 0 unless _copy_tree(Lit::Compat::joinp($src, $e),
                                       Lit::Compat::joinp($dst, $e));
        }
        return 1;
    }
    return _copy_file($src, $dst);
}

$BUILTIN{'cp'} = sub {
    my ($argv, $ctx) = @_;
    my ($f, $rest, $e) = _getopt($argv, 'rRfpv');
    return _die($ctx, 'cp', $e) if defined $e;
    return _die($ctx, 'cp', 'missing operand') if @$rest < 2;
    my $dst = pop @$rest;
    my $adst = _p($ctx, $dst);
    my $into = -d $adst;
    return _die($ctx, 'cp', "target '$dst' is not a directory")
        if @$rest > 1 && !$into;
    my $rc = 0;
    foreach my $s (@$rest) {
        my $asrc = _p($ctx, $s);
        my $target = $into
            ? Lit::Compat::joinp($adst, Lit::Compat::basename_of($s)) : $adst;
        if (-d $asrc && !($f->{r} || $f->{R})) {
            print { $ctx->{err} } "cp: '$s' is a directory\n"; $rc = 1; next;
        }
        unless (_copy_tree($asrc, $target)) {
            print { $ctx->{err} } "cp: cannot copy '$s': $!\n"; $rc = 1;
        }
    }
    return $rc;
};

$BUILTIN{'mv'} = sub {
    my ($argv, $ctx) = @_;
    my ($f, $rest, $e) = _getopt($argv, 'fv');
    return _die($ctx, 'mv', $e) if defined $e;
    return _die($ctx, 'mv', 'missing operand') if @$rest < 2;
    my $dst = pop @$rest;
    my $adst = _p($ctx, $dst);
    my $into = -d $adst;
    my $rc = 0;
    foreach my $s (@$rest) {
        my $asrc = _p($ctx, $s);
        my $target = $into
            ? Lit::Compat::joinp($adst, Lit::Compat::basename_of($s)) : $adst;
        unlink($target) if -e $target && !-d $target;
        next if rename($asrc, $target);
        # Cross-device, or VMS renaming across directories: copy then remove.
        if (_copy_tree($asrc, $target)) {
            if (-d $asrc) { Lit::Compat::rmtree($asrc) } else { unlink($asrc) }
            next;
        }
        print { $ctx->{err} } "mv: cannot move '$s': $!\n";
        $rc = 1;
    }
    return $rc;
};

# ln has no portable meaning on ODS-2, so copy instead of linking.
$BUILTIN{'ln'} = sub {
    my ($argv, $ctx) = @_;
    my ($f, $rest, $e) = _getopt($argv, 'sf');
    return _die($ctx, 'ln', $e) if defined $e;
    return _die($ctx, 'ln', 'missing operand') if @$rest < 2;
    my ($src, $dst) = @$rest;
    my $adst = _p($ctx, $dst);
    $adst = Lit::Compat::joinp($adst, Lit::Compat::basename_of($src)) if -d $adst;
    unlink($adst) if -e $adst;
    return _copy_tree(_p($ctx, $src), $adst) ? 0
         : _die($ctx, 'ln', "cannot link '$src': $!");
};

# ------------------------------------------------------------------ text

$BUILTIN{'wc'} = sub {
    my ($argv, $ctx) = @_;
    my ($f, $rest, $e) = _getopt($argv, 'lwcm');
    return _die($ctx, 'wc', $e) if defined $e;
    my ($lines, $rc) = _slurp_lines($ctx, 'wc', $rest);
    my $nl = scalar @$lines;
    my $nc = 0; my $nw = 0;
    foreach my $l (@$lines) {
        $nc += length($l);
        my @w = split(/\s+/, $l);
        @w = grep { length } @w;
        $nw += scalar @w;
    }
    my $any = ($f->{l} || $f->{w} || $f->{c} || $f->{m}) ? 1 : 0;
    my @out;
    push @out, $nl if !$any || $f->{l};
    push @out, $nw if !$any || $f->{w};
    push @out, $nc if !$any || $f->{c} || $f->{m};
    print { $ctx->{out} } join(' ', map { sprintf('%7d', $_) } @out) . "\n";
    return $rc;
};

$BUILTIN{'head'} = sub { return _head_tail(@_, 'head') };
$BUILTIN{'tail'} = sub { return _head_tail(@_, 'tail') };

sub _head_tail {
    my ($argv, $ctx, $which) = @_;
    my @a = @$argv;
    shift @a;
    my $n = 10;
    my @files;
    while (@a) {
        my $x = shift @a;
        if ($x =~ /^-n(.*)$/)  { $n = length($1) ? $1 : shift(@a); next }
        if ($x =~ /^-([0-9]+)$/) { $n = $1; next }
        push @files, $x;
    }
    $n =~ s/^\+//;
    my ($lines, $rc) = _slurp_lines($ctx, $which, \@files);
    my @sel = ($which eq 'head')
            ? @$lines[0 .. ($n - 1 < $#$lines ? $n - 1 : $#$lines)]
            : (@$lines <= $n ? @$lines : @$lines[$#$lines - $n + 1 .. $#$lines]);
    @sel = () if $n <= 0;
    print { $ctx->{out} } join('', grep { defined } @sel);
    return $rc;
}

$BUILTIN{'sort'} = sub {
    my ($argv, $ctx) = @_;
    my ($f, $rest, $e) = _getopt($argv, 'urnfb');
    return _die($ctx, 'sort', $e) if defined $e;
    my ($lines, $rc) = _slurp_lines($ctx, 'sort', $rest);
    my @l = @$lines;
    chomp @l;
    my $cmp;
    if ($f->{n}) { $cmp = sub { (0 + $_[0]) <=> (0 + $_[1]) } }
    elsif ($f->{f}) { $cmp = sub { lc($_[0]) cmp lc($_[1]) } }
    else { $cmp = sub { $_[0] cmp $_[1] } }
    @l = sort { $cmp->($a, $b) } @l;
    @l = reverse @l if $f->{r};
    if ($f->{u}) {
        my @u; my $prev;
        foreach my $x (@l) { push @u, $x unless defined $prev && $x eq $prev; $prev = $x }
        @l = @u;
    }
    print { $ctx->{out} } map { "$_\n" } @l;
    return $rc;
};

$BUILTIN{'uniq'} = sub {
    my ($argv, $ctx) = @_;
    my ($f, $rest, $e) = _getopt($argv, 'cdu');
    return _die($ctx, 'uniq', $e) if defined $e;
    my ($lines, $rc) = _slurp_lines($ctx, 'uniq', $rest);
    my @l = @$lines;
    chomp @l;
    my @out;
    my $i = 0;
    while ($i < @l) {
        my $j = $i;
        $j++ while $j + 1 < @l && $l[$j + 1] eq $l[$i];
        my $n = $j - $i + 1;
        my $keep = 1;
        $keep = 0 if $f->{d} && $n < 2;
        $keep = 0 if $f->{u} && $n > 1;
        push @out, ($f->{c} ? sprintf('%7d %s', $n, $l[$i]) : $l[$i]) if $keep;
        $i = $j + 1;
    }
    print { $ctx->{out} } map { "$_\n" } @out;
    return $rc;
};

$BUILTIN{'grep'} = sub {
    my ($argv, $ctx) = @_;
    my @a = @$argv;
    shift @a;
    my %o;
    my $pat;
    my @files;
    while (@a) {
        my $x = shift @a;
        if ($x eq '--') { push @files, @a; last }
        if ($x eq '-e') { $pat = shift @a; next }
        if ($x =~ /^-([a-zA-Z]+)$/ && !defined $pat) {
            foreach my $c (split //, $1) { $o{$c} = 1 }
            next;
        }
        if (!defined $pat) { $pat = $x; next }
        push @files, $x;
    }
    return _die($ctx, 'grep', 'missing pattern') unless defined $pat;

    my $re;
    if ($o{F}) { $re = qr/\Q$pat\E/ }
    else {
        my $p = $pat;
        $p = "(?i)$p" if $o{i};
        $re = eval { qr/$p/ };
        return _die($ctx, 'grep', "invalid pattern '$pat'") unless defined $re;
    }
    if ($o{i} && $o{F}) { $re = qr/(?i)\Q$pat\E/ }

    my ($lines, $rc) = _slurp_lines($ctx, 'grep', \@files);
    return 2 if $rc;
    my $hits = 0;
    foreach my $l (@$lines) {
        my $m = ($l =~ $re) ? 1 : 0;
        $m = !$m if $o{v};
        next unless $m;
        $hits++;
        next if $o{q} || $o{c};
        print { $ctx->{out} } $l;
        print { $ctx->{out} } "\n" if $l !~ /\n$/;
    }
    print { $ctx->{out} } "$hits\n" if $o{c};
    return $hits ? 0 : 1;
};

# A useful subset of sed: -n, -e, and the s/// d p q commands, with optional
# line-number or /regex/ addresses.  Replacements are compiled into a parts
# list rather than eval'd, which keeps this safe and fast on old Perls.
$BUILTIN{'sed'} = sub {
    my ($argv, $ctx) = @_;
    my @a = @$argv;
    shift @a;
    my $quiet = 0;
    my $ere   = 0;
    my @script;
    my @files;
    while (@a) {
        my $x = shift @a;
        if ($x eq '-n')       { $quiet = 1; next }
        if ($x eq '-E' || $x eq '-r') { $ere = 1; next }
        if ($x eq '-e')       { push @script, shift @a; next }
        if ($x =~ /^-e(.+)$/) { push @script, $1; next }
        if ($x eq '--')       { push @files, @a; last }
        if (!@script && $x !~ /^-/) { push @script, $x; next }
        push @files, $x;
    }
    return _die($ctx, 'sed', 'missing script') unless @script;

    my @prog;
    foreach my $s (@script) {
        foreach my $stmt (_sed_split($s)) {
            next unless $stmt =~ /\S/;
            my ($cmd, $err) = _sed_compile($stmt, $ere);
            return _die($ctx, 'sed', $err) if defined $err;
            push @prog, $cmd;
        }
    }

    my ($lines, $rc) = _slurp_lines($ctx, 'sed', \@files);
    my $n = 0;
    LINE: foreach my $raw (@$lines) {
        $n++;
        my $l  = $raw;
        my $nl = ($l =~ s/\n$//) ? "\n" : '';
        foreach my $c (@prog) {
            next unless _sed_addr_match($c, $l, $n);
            if ($c->{op} eq 's') {
                my $re = $c->{re};
                if ($c->{global}) { $l =~ s/$re/_sed_build($c->{parts})/ge }
                else              { $l =~ s/$re/_sed_build($c->{parts})/e  }
            }
            elsif ($c->{op} eq 'd') { next LINE }
            elsif ($c->{op} eq 'p') { print { $ctx->{out} } $l . "\n" }
            elsif ($c->{op} eq 'q') {
                print { $ctx->{out} } $l . $nl unless $quiet;
                last LINE;
            }
        }
        print { $ctx->{out} } $l . $nl unless $quiet;
    }
    return $rc;
};

# Split a script on ';' without breaking inside an s/// command.
sub _sed_split {
    my ($s) = @_;
    my @out;
    my $cur = '';
    my $i   = 0;
    my $len = length $s;
    while ($i < $len) {
        my $c = substr($s, $i, 1);
        if ($c eq '\\' && $i + 1 < $len) { $cur .= substr($s, $i, 2); $i += 2; next }
        if ($c eq ';') { push @out, $cur; $cur = ''; $i++; next }
        if ($c eq 's' && substr($s, $i + 1, 1) =~ m{[/,|#!]}) {
            my $d     = substr($s, $i + 1, 1);
            my $seen  = 0;
            my $j     = $i + 1;
            while ($j < $len && $seen < 3) {
                my $cc = substr($s, $j, 1);
                if ($cc eq '\\') { $j += 2; next }
                $seen++ if $cc eq $d;
                $j++;
            }
            $j++ while $j < $len && substr($s, $j, 1) =~ /[gipI]/;
            $cur .= substr($s, $i, $j - $i);
            $i = $j;
            next;
        }
        $cur .= $c;
        $i++;
    }
    push @out, $cur;
    return @out;
}

# Interpolate a compiled replacement using the current capture variables.
sub _sed_build {
    my ($parts) = @_;
    my $out = '';
    foreach my $p (@$parts) {
        if ($p->[0] eq 'lit') { $out .= $p->[1]; next }
        my $g = $p->[1];
        no strict 'refs';
        my $v = ($g == 0) ? $& : ${$g};
        $out .= defined $v ? $v : '';
    }
    return $out;
}

sub _sed_compile {
    my ($stmt, $ere) = @_;
    $stmt =~ s/^\s+//;
    my %c;

    if ($stmt =~ s{^/((?:[^/\\]|\\.)*)/}{}) {
        my $ar = $ere ? $1 : _bre_to_perl($1);
        $c{addr_re} = eval { qr/$ar/ };
        return (undef, "bad address /$1/") unless $c{addr_re};
    }
    elsif ($stmt =~ s/^([0-9]+)//) { $c{addr_line} = 0 + $1 }
    elsif ($stmt =~ s/^\$//)       { $c{addr_last} = 1 }
    $stmt =~ s/^\s+//;

    if ($stmt =~ m{^s(.)}s) {
        my $raw = quotemeta($1);
        unless ($stmt =~ m{^s$raw((?:[^\\]|\\.)*?)$raw((?:[^\\]|\\.)*?)$raw([gipI]*)\s*$}s) {
            return (undef, "unterminated s command: $stmt");
        }
        my ($pat, $rep, $flags) = ($1, $2, $3);
        $pat = _bre_to_perl($pat) unless $ere;
        $pat = "(?i)$pat" if $flags =~ /[iI]/;
        my $re = eval { qr/$pat/ };
        return (undef, "bad regex in s command: $pat") unless $re;

        my @parts;
        my $lit = '';
        my $i   = 0;
        while ($i < length $rep) {
            my $ch = substr($rep, $i, 1);
            if ($ch eq '\\') {
                my $nx = substr($rep, $i + 1, 1);
                if ($nx =~ /^[0-9]$/) {
                    push @parts, ['lit', $lit] if length $lit;
                    $lit = '';
                    push @parts, ['grp', 0 + $nx];
                }
                elsif ($nx eq 'n') { $lit .= "\n" }
                elsif ($nx eq 't') { $lit .= "\t" }
                else               { $lit .= $nx }
                $i += 2;
                next;
            }
            if ($ch eq '&') {
                push @parts, ['lit', $lit] if length $lit;
                $lit = '';
                push @parts, ['grp', 0];
                $i++;
                next;
            }
            $lit .= $ch;
            $i++;
        }
        push @parts, ['lit', $lit] if length $lit;

        $c{op}     = 's';
        $c{re}     = $re;
        $c{parts}  = \@parts;
        $c{global} = ($flags =~ /g/) ? 1 : 0;
        return (\%c, undef);
    }

    if ($stmt =~ /^d\s*$/) { $c{op} = 'd'; return (\%c, undef) }
    if ($stmt =~ /^p\s*$/) { $c{op} = 'p'; return (\%c, undef) }
    if ($stmt =~ /^q\s*$/) { $c{op} = 'q'; return (\%c, undef) }
    return (undef, "unsupported sed command: $stmt");
}

sub _sed_addr_match {
    my ($c, $line, $n) = @_;
    return 1 unless defined $c->{addr_re} || defined $c->{addr_line};
    return ($n == $c->{addr_line}) ? 1 : 0 if defined $c->{addr_line};
    return ($line =~ $c->{addr_re}) ? 1 : 0;
}

# ------------------------------------------------------------------ diff

$BUILTIN{'diff'} = sub {
    my ($argv, $ctx) = @_;
    my @a = @$argv;
    shift @a;
    my %o;
    my @files;
    while (@a) {
        my $x = shift @a;
        if ($x eq '--strip-trailing-cr') { $o{cr} = 1; next }
        if ($x eq '--ignore-all-space')  { $o{w}  = 1; next }
        if ($x eq '--brief')             { $o{q}  = 1; next }
        if ($x eq '--unified')           { $o{u}  = 1; next }
        if ($x =~ /^-([ubwiqr]+)$/)      { $o{$_} = 1 foreach split(//, $1); next }
        if ($x =~ /^-U([0-9]+)$/)        { $o{u} = 1; $o{ctx} = 0 + $1; next }
        if ($x eq '--') { push @files, @a; last }
        push @files, $x;
    }
    return _die($ctx, 'diff', 'need exactly two operands') if @files != 2;

    my @abs = map { _p($ctx, $_) } @files;
    foreach my $i (0, 1) {
        unless (-e $abs[$i]) {
            print { $ctx->{err} } "diff: $files[$i]: no such file or directory\n";
            return 2;
        }
    }

    my $ta = Lit::Compat::read_file($abs[0]);
    my $tb = Lit::Compat::read_file($abs[1]);
    return _die($ctx, 'diff', 'cannot read input') unless defined $ta && defined $tb;

    my @la = split(/\n/, $ta, -1);
    my @lb = split(/\n/, $tb, -1);
    pop @la if @la && $la[-1] eq '';
    pop @lb if @lb && $lb[-1] eq '';

    my $norm = sub {
        my ($s) = @_;
        $s =~ s/\r$//;
        if    ($o{w}) { $s =~ s/[ \t]+//g }
        elsif ($o{b}) { $s =~ s/[ \t]+/ /g; $s =~ s/^ //; $s =~ s/ $// }
        $s = lc $s if $o{i};
        return $s;
    };
    my @na = map { $norm->($_) } @la;
    my @nb = map { $norm->($_) } @lb;

    my $ops   = _diff_ops(\@na, \@nb);
    my $nctx  = defined $o{ctx} ? $o{ctx} : 3;
    my $hunks = _diff_hunks($ops, $nctx);
    return 0 unless @$hunks;
    if ($o{q}) {
        print { $ctx->{out} } "Files $files[0] and $files[1] differ\n";
        return 1;
    }

    if ($o{u}) {
        print { $ctx->{out} } "--- $files[0]\n+++ $files[1]\n";
        foreach my $h (@$hunks) {
            printf { $ctx->{out} } "\@\@ -%d,%d +%d,%d \@\@\n",
                $h->{as}, $h->{an}, $h->{bs}, $h->{bn};
            foreach my $r (@{ $h->{rows} }) {
                my $text = defined $r->[1] ? $la[ $r->[1] ] : $lb[ $r->[2] ];
                print { $ctx->{out} } $r->[0] . $text . "\n";
            }
        }
    } else {
        foreach my $h (@$hunks) {
            foreach my $r (@{ $h->{rows} }) {
                next if $r->[0] eq ' ';
                my $text = defined $r->[1] ? $la[ $r->[1] ] : $lb[ $r->[2] ];
                print { $ctx->{out} } (($r->[0] eq '-') ? '< ' : '> ') . $text . "\n";
            }
        }
    }
    return 1;
};

# Build the full edit script as a list of [tag, a_index, b_index] rows, where
# tag is ' ', '-' or '+' and the unused index is undef.
#
# Common prefix and suffix are trimmed first so the quadratic LCS only ever
# sees the genuinely differing middle -- which keeps this usable on the large
# compiler listings these suites tend to compare.
sub _diff_ops {
    my ($a, $b) = @_;
    my $na = scalar @$a;
    my $nb = scalar @$b;

    my $lo = 0;
    $lo++ while $lo < $na && $lo < $nb && $a->[$lo] eq $b->[$lo];
    my $hi = 0;
    $hi++ while $hi < ($na - $lo) && $hi < ($nb - $lo)
             && $a->[$na - 1 - $hi] eq $b->[$nb - 1 - $hi];

    my @ops;
    push @ops, [' ', $_, $_] foreach (0 .. $lo - 1);

    my @ma = ($lo <= $na - $hi - 1) ? @$a[$lo .. $na - $hi - 1] : ();
    my @mb = ($lo <= $nb - $hi - 1) ? @$b[$lo .. $nb - $hi - 1] : ();

    if (@ma > 3000 || @mb > 3000) {
        push @ops, ['-', $lo + $_, undef] foreach (0 .. $#ma);
        push @ops, ['+', undef, $lo + $_] foreach (0 .. $#mb);
    } else {
        push @ops, _lcs_ops(\@ma, \@mb, $lo, $lo);
    }

    foreach my $k (0 .. $hi - 1) {
        push @ops, [' ', $na - $hi + $k, $nb - $hi + $k];
    }
    return \@ops;
}

sub _lcs_ops {
    my ($a, $b, $aoff, $boff) = @_;
    my $n = scalar @$a;
    my $m = scalar @$b;
    return () unless $n || $m;

    my @L;
    foreach my $i (0 .. $n) { $L[$i][$m] = 0 }
    foreach my $j (0 .. $m) { $L[$n][$j] = 0 }
    for (my $i = $n - 1; $i >= 0; $i--) {
        for (my $j = $m - 1; $j >= 0; $j--) {
            if ($a->[$i] eq $b->[$j]) { $L[$i][$j] = $L[$i + 1][$j + 1] + 1 }
            else {
                my $x = $L[$i + 1][$j];
                my $y = $L[$i][$j + 1];
                $L[$i][$j] = ($x >= $y) ? $x : $y;
            }
        }
    }

    my @ops;
    my ($i, $j) = (0, 0);
    while ($i < $n && $j < $m) {
        if ($a->[$i] eq $b->[$j]) {
            push @ops, [' ', $aoff + $i, $boff + $j]; $i++; $j++;
        } elsif ($L[$i + 1][$j] >= $L[$i][$j + 1]) {
            push @ops, ['-', $aoff + $i, undef]; $i++;
        } else {
            push @ops, ['+', undef, $boff + $j]; $j++;
        }
    }
    while ($i < $n) { push @ops, ['-', $aoff + $i, undef]; $i++ }
    while ($j < $m) { push @ops, ['+', undef, $boff + $j]; $j++ }
    return @ops;
}

# Group changed rows into hunks with $nctx lines of context, merging hunks
# whose context regions would touch.
sub _diff_hunks {
    my ($ops, $nctx) = @_;
    my @changed = grep { $ops->[$_][0] ne ' ' } (0 .. $#$ops);
    return [] unless @changed;

    my @groups;
    my ($start, $end) = ($changed[0], $changed[0]);
    foreach my $i (@changed[1 .. $#changed]) {
        if ($i - $end <= 2 * $nctx + 1) { $end = $i }
        else { push @groups, [$start, $end]; ($start, $end) = ($i, $i) }
    }
    push @groups, [$start, $end];

    my @hunks;
    foreach my $g (@groups) {
        my $s = $g->[0] - $nctx; $s = 0        if $s < 0;
        my $e = $g->[1] + $nctx; $e = $#$ops   if $e > $#$ops;
        my @rows = @$ops[$s .. $e];

        my ($as, $bs, $an, $bn) = (undef, undef, 0, 0);
        foreach my $r (@rows) {
            if (defined $r->[1]) { $as = $r->[1] unless defined $as; $an++ }
            if (defined $r->[2]) { $bs = $r->[2] unless defined $bs; $bn++ }
        }
        push @hunks, {
            as   => (defined $as ? $as + 1 : 0), an => $an,
            bs   => (defined $bs ? $bs + 1 : 0), bn => $bn,
            rows => \@rows,
        };
    }
    return \@hunks;
}

# ------------------------------------------------------------------- test(1)

$BUILTIN{'test'} = sub { return _test_cmd($_[0], $_[1]) };
$BUILTIN{'['}    = sub {
    my ($argv, $ctx) = @_;
    my @a = @$argv;
    return _die($ctx, '[', "missing ']'") unless @a && $a[-1] eq ']';
    pop @a;
    return _test_cmd(\@a, $ctx);
};

sub _test_cmd {
    my ($argv, $ctx) = @_;
    my @a = @$argv;
    shift @a;
    my $neg = 0;
    while (@a && $a[0] eq '!') { $neg = !$neg; shift @a }
    my $r = _test_eval(\@a, $ctx);
    $r = $r ? 0 : 1 if $neg;
    return $r ? 0 : 1;
}

sub _test_eval {
    my ($a, $ctx) = @_;
    return 0 unless @$a;
    if (@$a == 1) { return length($a->[0]) ? 1 : 0 }
    if (@$a == 2) {
        my ($op, $x) = @$a;
        my $p = _p($ctx, $x);
        return (-e $p)             ? 1 : 0 if $op eq '-e';
        return (-f $p)             ? 1 : 0 if $op eq '-f';
        return (-d $p)             ? 1 : 0 if $op eq '-d';
        return (-s $p)             ? 1 : 0 if $op eq '-s';
        return (-r $p)             ? 1 : 0 if $op eq '-r';
        return (-w $p)             ? 1 : 0 if $op eq '-w';
        return (-x $p)             ? 1 : 0 if $op eq '-x';
        return (length($x) == 0)   ? 1 : 0 if $op eq '-z';
        return (length($x) != 0)   ? 1 : 0 if $op eq '-n';
        return 0;
    }
    if (@$a == 3) {
        my ($l, $op, $r) = @$a;
        return ($l eq $r) ? 1 : 0 if $op eq '=' || $op eq '==';
        return ($l ne $r) ? 1 : 0 if $op eq '!=';
        return (0 + $l == 0 + $r) ? 1 : 0 if $op eq '-eq';
        return (0 + $l != 0 + $r) ? 1 : 0 if $op eq '-ne';
        return (0 + $l <  0 + $r) ? 1 : 0 if $op eq '-lt';
        return (0 + $l <= 0 + $r) ? 1 : 0 if $op eq '-le';
        return (0 + $l >  0 + $r) ? 1 : 0 if $op eq '-gt';
        return (0 + $l >= 0 + $r) ? 1 : 0 if $op eq '-ge';
        return 0;
    }
    return 0;
}

# ----------------------------------------------------------------- metrics

# Record a measurement against the running test, for the JSON results file.
#
# This is the one thing a RUN: line can legitimately contribute to the
# results, because it concerns only its own test.  A whole-run summary
# cannot be assembled from here and belongs to the driver (--output).
#
#     RUN: metrics compile_time=1.23 object_size=4096
#     RUN: %{build} | grep '^[a-z_]*=' | metrics
#
# The file is named by LIT_METRICS_FILE, which the runner puts in each
# test's environment, so an external tool can append to it too.
$BUILTIN{'metrics'} = sub {
    my ($argv, $ctx) = @_;
    my @a = @$argv;
    shift @a;

    my $file = $ctx->{shell}{env}{LIT_METRICS_FILE};
    unless (defined $file && length $file) {
        return _die($ctx, 'metrics',
            'LIT_METRICS_FILE is not set; metrics can only be recorded from '
          . 'inside a test');
    }

    # With no arguments, read NAME=VALUE lines from standard input, so a
    # tool that already prints its own measurements can be piped straight in.
    my @pairs = @a;
    unless (@pairs) {
        my $fh = $ctx->{in};
        if ($fh) {
            while (defined(my $l = <$fh>)) {
                $l =~ s/\r?\n$//;
                push @pairs, $l if $l =~ /\S/;
            }
        }
    }
    return _die($ctx, 'metrics', 'nothing to record') unless @pairs;

    my $text = '';
    foreach my $p (@pairs) {
        unless ($p =~ /^([A-Za-z_][A-Za-z0-9_.\-]*)=(.*)$/s) {
            return _die($ctx, 'metrics', "expected NAME=VALUE, got '$p'");
        }
        my ($name, $value) = ($1, $2);
        $value =~ s/[\r\n]+/ /g;           # one record per metric
        $text .= "$name=$value\n";
    }

    local *FH;
    unless (open(FH, '>>', _p($ctx, $file))) {
        return _die($ctx, 'metrics', "cannot write '$file': $!");
    }
    print FH $text;
    close FH;
    return 0;
};

# ----------------------------------------------------------------- OpenVMS

# Run one or more DCL command lines verbatim, in a single command
# procedure, with the shell's redirections applied.
#
# Three things make this necessary rather than merely convenient:
#
#   * DCL symbols are local to a procedure, so a foreign command definition
#     has to share a procedure with the command that uses it.  The ordinary
#     path writes one procedure per command, which cannot express that.
#
#   * DCL attaches qualifiers without a space, as in
#     "mms/description=x.mms all".  Word-splitting that as an argv gives a
#     first word full of slashes, which the spawner would mistake for an
#     image path.
#
#   * Passing a DCL line through argv quoting risks changing it.  Here the
#     text reaches DCL exactly as written.
#
# Each argument is one DCL line; an argument may itself contain newlines.
$BUILTIN{'dcl'} = sub {
    my ($argv, $ctx) = @_;
    my @a = @$argv;
    shift @a;
    @a = grep { defined && /\S/ } @a;
    return _die($ctx, 'dcl', 'no DCL command given') unless @a;

    unless (Lit::Compat::IS_VMS) {
        print { $ctx->{err} }
            "dcl: DCL commands need OpenVMS; this host is $^O.\n",
            "dcl: guard such tests with 'REQUIRES: vms'.\n";
        return 127;
    }

    my $fd = $ctx->{fd};
    my $merge = (defined $fd->{2}{file} && defined $fd->{1}{file}
                 && $fd->{2}{file} eq $fd->{1}{file}) ? 1 : 0;

    my ($code, $timedout, $err) = Lit::Compat::spawn({
        dcl        => \@a,
        stdin      => $fd->{0}{file},
        stdout     => $fd->{1}{file},
        stderr     => ($merge ? '&1' : $fd->{2}{file}),
        append_out => $fd->{1}{append},
        append_err => $fd->{2}{append},
        cwd        => $ctx->{shell}{cwd},
        env        => $ctx->{shell}{env},
    });

    if (defined $err) { print { $ctx->{err} } "dcl: $err\n"; return 127 }
    return $code;
};

# ---------------------------------------------------------------- FileCheck

my $FILECHECK = sub {
    my ($argv, $ctx) = @_;
    require Lit::FileCheck;
    my @a = @$argv;
    shift @a;
    # Resolve the check-file operand against the shell's cwd.
    my @fixed = map { (/^-/ || !length) ? $_ : _p($ctx, $_) } @a;
    return Lit::FileCheck::run(\@fixed, {
        in  => $ctx->{in},
        out => $ctx->{out},
        err => $ctx->{err},
        cwd => $ctx->{shell}{cwd},
        env => $ctx->{shell}{env},
    });
};
$BUILTIN{'FileCheck'}    = $FILECHECK;
$BUILTIN{'filecheck'}    = $FILECHECK;
$BUILTIN{'filecheck.pl'} = $FILECHECK;


# sed uses POSIX basic regular expressions by default, where \( groups and a
# bare ( is literal -- the exact opposite of Perl.  Swap the two, leaving
# bracket expressions alone.  With sed -E/-r the pattern is already ERE, which
# Perl accepts as-is.
sub _bre_to_perl {
    my ($p) = @_;
    my $out = '';
    my $i   = 0;
    my $n   = length $p;

    while ($i < $n) {
        my $c = substr($p, $i, 1);

        if ($c eq '\\') {
            my $x = substr($p, $i + 1, 1);
            if (!length $x)             { $out .= '\\\\' }
            elsif ($x =~ /^[(){}|+?]$/) { $out .= $x }        # BRE group -> Perl group
            else                        { $out .= '\\' . $x }
            $i += 2;
            next;
        }

        if ($c eq '[') {                                      # copy verbatim
            my $j = $i + 1;
            $j++ if $j < $n && substr($p, $j, 1) eq '^';
            $j++ if $j < $n && substr($p, $j, 1) eq ']';
            $j++ while $j < $n && substr($p, $j, 1) ne ']';
            $j = $n - 1 if $j >= $n;
            $out .= substr($p, $i, $j - $i + 1);
            $i = $j + 1;
            next;
        }

        if ($c =~ /^[(){}|+?]$/) { $out .= '\\' . $c; $i++; next }   # literal in BRE
        $out .= $c;
        $i++;
    }
    return $out;
}


1;

__END__

=head1 NAME

Lit::Builtins - Unix commands implemented in-process

=head1 DESCRIPTION

Two reasons this exists.  First, OpenVMS has none of these, and requiring
GNV to run a test suite is a poor trade.  Second, process creation on VMS
is expensive enough that spawning a subprocess per CHECK step would
dominate the run time; running C<FileCheck> in-process avoids that
entirely.

A builtin is preferred over an external program of the same name.

=head1 COMMANDS

    :  true  false  echo  printf  cat  pwd  cd  export  unset  env
    basename  dirname  mkdir  rmdir  rm  touch  cp  mv  ln
    head  tail  sort  uniq  wc  grep  sed  diff  test  [
    not  count  dcl  metrics  FileCheck

Notes on the ones that differ from their Unix namesakes:

=over 4

=item FileCheck

Runs in-process - the single biggest win on OpenVMS.  Takes the same
options as F<filecheck.pl>; see L<Lit::FileCheck>.

=item not

Inverts the exit status of the command it is given.  C<not --crash>
instead requires abnormal termination.

=item count I<n>

LLVM's C<count>: succeeds when its input holds exactly I<n> lines.

=item sed

Supports C<-n>, C<-e>, C<-E>/C<-r>, and the C<s///>, C<d>, C<p> and C<q>
commands with optional line-number or C</regex/> addresses.  Patterns are
POSIX basic regular expressions by default - so C<\(> groups and a bare
C<(> is literal - and extended ones under C<-E>.  Replacements understand
C<&> and C<\1>..C<\9>.

=item diff

Unified output with C<-u>, and C<-b>, C<-w>, C<-i>, C<-q> and
C<--strip-trailing-cr>.  Common prefix and suffix are trimmed before the
quadratic comparison, which keeps it usable on the large listings a
compiler suite tends to compare.

=item ln

Copies, because ODS-2 has no links.

=item grep

C<-v>, C<-i>, C<-c>, C<-q>, C<-F> and C<-e>.  Patterns are Perl regular
expressions, a superset of what C<grep -E> accepts.

=back

=head1 THE dcl BUILTIN

    RUN: dcl '<line>' ['<line>' ...] > %t.out 2>&1

Runs one or more DCL command lines verbatim, in a I<single> command
procedure, with the shell's redirections applied.  Each argument is one
DCL line, and an argument may itself contain newlines.  Off OpenVMS it
refuses with status 127 rather than guessing, so guard such tests with
C<REQUIRES: vms>.

Three things make it necessary rather than merely convenient:

=over 4

=item *

A DCL symbol is local to the procedure that defines it, so a foreign
command definition has to share a procedure with the command that uses it.
The ordinary path writes one procedure per command and cannot express
that:

    RUN: dcl 'mmk := $DISK$TOOLS:[MMK]MMK.EXE' \
    RUN:     'mmk/extended_syntax/description=%t.mms all' > %t.out 2>&1

=item *

DCL attaches qualifiers without a space.  Word-splitting
C<mms/description=x.mms all> as an argv yields a first word full of
slashes, which the spawner would take for an image path.  Inside C<dcl>
the text is never split.

=item *

An ordinary argv is quoted on the way to DCL, because DCL upcases unquoted
parameters.  That is right for a program's arguments and wrong for a DCL
command line; C<dcl> passes the text through untouched.

=back

Redirection differs from the ordinary path in a way worth knowing:
C<DEFINE/USER> lasts only until the next image exits, so a fragment
running two images would lose it halfway through.  C<dcl> therefore uses a
process-level C<DEFINE> and an explicit C<DEASSIGN> before the exit.

The generated procedure establishes C<ON WARNING THEN GOTO> a cleanup
label before running any of your lines, so the first failure ends the
sequence and is reported.  Without that, a failing C<SET DEFAULT> would be
followed by a build running in the wrong directory, which might then
"succeed" - a test passing for the wrong reason.

The threshold is WARNING rather than ERROR because that is exactly what
the exit-status mapping treats as failure: odd VMS severities (SUCCESS,
INFO) succeed, even ones (WARNING, ERROR, FATAL) do not.  Anything
reported as a non-zero exit therefore also stops the sequence.

A fragment that wants the older, keep-going behaviour can say so itself,
since these lines are passed through verbatim:

    RUN: dcl 'ON WARNING THEN CONTINUE' 'DELETE/NOLOG old.tmp;*' '%{build}'

Do not C<EXIT> from a fragment.  The redirection is deassigned after the
last line, and exiting early would skip that.

Long lines are passed through exactly as written.  If one needs to exceed
DCL's record limit, write the continuation yourself with a trailing
hyphen; the following record is emitted raw, without the leading C<$> that
DCL would otherwise take as part of the command.

=head1 WRITING A BUILTIN

Each has the signature

    sub { my ($argv, $ctx) = @_; return $exit_code }

where C<$argv> includes C<argv[0]> and C<$ctx> provides C<in>, C<out> and
C<err> filehandles already pointed at the right places, a mutable
C<shell> holding C<cwd> and C<env>, and C<exec> for running a nested
command as C<not> and C<env> do.

A builtin must resolve relative paths against C<< $ctx->{shell}{cwd} >>
itself: the Perl process's own working directory is never changed, because
that would not survive parallel execution.

=head1 SEE ALSO

L<Lit>, L<Lit::ShRun>, L<Lit::FileCheck>

=cut
