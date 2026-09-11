package Lit::FileCheck;

# A reimplementation of LLVM's FileCheck.
#
# Entry point:  Lit::FileCheck::run(\@argv, \%ctx) -> exit code
# where %ctx supplies in/out/err filehandles, cwd and env.  Keeping the
# engine callable in-process matters on OpenVMS, where creating a subprocess
# for every CHECK step would dominate the run time.

use strict;
use warnings;

require 5.006;

use Lit::Compat ();
use Lit::Pattern ();

use vars qw($VERSION);
$VERSION = '1.00';

my @DIR_TYPES = qw(LABEL NOT DAG SAME NEXT EMPTY COUNT PLAIN);

# ----------------------------------------------------------------- arguments

sub _usage {
    return <<'USAGE';
usage: FileCheck [options] <check-file>

  --check-prefix=PREFIX      Prefix to use (default CHECK); repeatable
  --check-prefixes=A,B,...   Comma separated list of prefixes
  --comment-prefixes=A,B     Comment prefixes (default COM,RUN)
  --input-file=FILE          Read input from FILE instead of stdin
  --strict-whitespace        Do not canonicalize horizontal whitespace
  --match-full-lines         Patterns must match whole lines
  --ignore-case              Case insensitive matching
  --implicit-check-not=PAT   Implicit CHECK-NOT applied everywhere
  --allow-empty              Permit empty input
  --enable-var-scope         Clear non-$ variables at each CHECK-LABEL
  --allow-unused-prefixes    Do not fail when a prefix matches nothing
  -DNAME=VALUE               Predefine a string variable
  -D#NAME=VALUE              Predefine a numeric variable
  --dump-input=MODE          never | fail | always
  --dump-input-context=N     Lines of context to dump (default 5)
  -v / -vv                   Verbose diagnostics
  --version                  Print version and exit
USAGE
}

sub _parse_args {
    my ($argv, $opt, $err) = @_;
    my @rest;
    my @args = @$argv;

    while (@args) {
        my $a = shift @args;

        if ($a eq '--') { push @rest, @args; last }

        # Accept both -opt and --opt spellings, as LLVM tools do.
        my $norm = $a;
        if ($norm =~ /^--?([A-Za-z][-A-Za-z0-9_]*)(?:=(.*))?$/s) {
            my ($name, $val) = ($1, $2);
            my $has = defined $val;

            my $need = sub {
                return $val if $has;
                return shift @args if @args;
                print $err "FileCheck: option --$name requires a value\n";
                return undef;
            };

            if ($name eq 'check-prefix') {
                my $v = $need->(); return -1 unless defined $v;
                push @{ $opt->{prefixes} }, $v; next;
            }
            if ($name eq 'check-prefixes') {
                my $v = $need->(); return -1 unless defined $v;
                push @{ $opt->{prefixes} }, grep { length } split(/,/, $v); next;
            }
            if ($name eq 'comment-prefixes') {
                my $v = $need->(); return -1 unless defined $v;
                $opt->{comments} = [ grep { length } split(/,/, $v) ]; next;
            }
            if ($name eq 'input-file') {
                my $v = $need->(); return -1 unless defined $v;
                $opt->{input_file} = $v; next;
            }
            if ($name eq 'implicit-check-not') {
                my $v = $need->(); return -1 unless defined $v;
                push @{ $opt->{implicit_not} }, $v; next;
            }
            if ($name eq 'dump-input') {
                my $v = $has ? $val : (@args ? shift @args : 'fail');
                $opt->{dump_input} = $v; next;
            }
            if ($name eq 'dump-input-context') {
                my $v = $need->(); return -1 unless defined $v;
                $opt->{dump_context} = 0 + $v; next;
            }
            if ($name eq 'strict-whitespace')     { $opt->{strict}   = 1; next }
            if ($name eq 'match-full-lines')      { $opt->{full}     = 1; next }
            if ($name eq 'ignore-case')           { $opt->{nocase}   = 1; next }
            if ($name eq 'allow-empty')           { $opt->{allow_empty} = 1; next }
            if ($name eq 'enable-var-scope')      { $opt->{var_scope}   = 1; next }
            if ($name eq 'allow-unused-prefixes') { $opt->{allow_unused} = 1; next }
            if ($name eq 'allow-deprecated-dag-overlap') { next }
            if ($name eq 'no-color' || $name eq 'color') { next }
            if ($name eq 'help' || $name eq 'h')  { $opt->{help} = 1; next }
            if ($name eq 'version')               { $opt->{version} = 1; next }
            if ($name eq 'v')                     { $opt->{verbose}++; next }
            if ($name eq 'vv')                    { $opt->{verbose} += 2; next }
            if ($name =~ /^D(.*)$/s) {
                my $body = $1;
                $body .= '=' . $val if $has;
                push @{ $opt->{defines} }, $body;
                next;
            }
            print $err "FileCheck: unknown option '$a'\n";
            return -1;
        }
        push @rest, $a;
    }
    return \@rest;
}

# ------------------------------------------------------------------ run

sub run {
    my ($argv, $ctx) = @_;
    $ctx = {} unless defined $ctx;
    my $out = defined $ctx->{out} ? $ctx->{out} : \*STDOUT;
    my $err = defined $ctx->{err} ? $ctx->{err} : \*STDERR;

    my %opt = (
        prefixes     => [],
        comments     => undef,
        implicit_not => [],
        defines      => [],
        strict       => 0,
        full         => 0,
        nocase       => 0,
        allow_empty  => 0,
        var_scope    => 0,
        allow_unused => 0,
        verbose      => 0,
        dump_input   => 'fail',
        dump_context => 5,
    );

    my $rest = _parse_args($argv, \%opt, $err);
    return 2 if !ref $rest;

    if ($opt{version}) { print $out "FileCheck (perl) $VERSION\n"; return 0 }
    if ($opt{help})    { print $out _usage(); return 0 }

    if (@$rest != 1) {
        print $err "FileCheck: exactly one check-file argument is required\n";
        print $err _usage();
        return 2;
    }
    my $check_file = $rest->[0];
    @{ $opt{prefixes} } = ('CHECK') unless @{ $opt{prefixes} };
    $opt{comments} = ['COM', 'RUN'] unless defined $opt{comments};

    foreach my $p (@{ $opt{prefixes} }) {
        unless ($p =~ /^[A-Za-z0-9_-]+$/) {
            print $err "FileCheck: invalid check prefix '$p'\n";
            return 2;
        }
    }

    # ---- read the check file
    my $cf_text = Lit::Compat::read_file($check_file);
    unless (defined $cf_text) {
        print $err "FileCheck: could not open check file '$check_file': $!\n";
        return 2;
    }

    # ---- predefined variables
    my %vars = (str => {}, num => {});
    foreach my $d (@{ $opt{defines} }) {
        if ($d =~ /^#(?:%([-.0-9]*[udxX]),)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s) {
            my ($fmt, $n, $v) = ($1, $2, $3);
            $fmt = 'u' unless defined $fmt;
            $vars{num}{$n} = { value => ($v =~ /^0[xX]/ ? hex($v) : 0 + $v), fmt => $fmt };
        }
        elsif ($d =~ /^(\$?[A-Za-z_][A-Za-z0-9_]*)=(.*)$/s) {
            $vars{str}{$1} = $2;
        }
        else {
            print $err "FileCheck: invalid -D argument '$d'\n";
            return 2;
        }
    }

    # ---- parse directives
    my ($checks, $used, $perr) = _read_checks($cf_text, $check_file, \%opt, $err);
    return 2 unless defined $checks;

    unless (@$checks) {
        unless ($opt{allow_unused}) {
            my $names = join(', ', map { "'$_'" } @{ $opt{prefixes} });
            print $err "FileCheck: no check strings found with prefix(es) $names\n";
            return 2;
        }
    }

    # ---- read the input
    my $input;
    if (defined $opt{input_file} && $opt{input_file} ne '-') {
        $input = Lit::Compat::read_file($opt{input_file});
        unless (defined $input) {
            print $err "FileCheck: could not open input file '$opt{input_file}': $!\n";
            return 2;
        }
    } else {
        my $fh = defined $ctx->{in} ? $ctx->{in} : \*STDIN;
        local $/ = undef;
        $input = <$fh>;
        $input = '' unless defined $input;
    }

    if ($input !~ /\S/ && !$opt{allow_empty}) {
        print $err "FileCheck: input is empty (use --allow-empty to permit this)\n";
        return 2;
    }

    my $buf = _canonicalize($input, $opt{strict});

    my $st = {
        buf        => \$buf,
        lines      => _line_starts($buf),
        vars       => \%vars,
        opt        => \%opt,
        err        => $err,
        out        => $out,
        check_file => $check_file,
        input_name => (defined $opt{input_file} ? $opt{input_file} : '<stdin>'),
        failed     => 0,
    };

    # implicit CHECK-NOT directives, compiled once as pseudo-checks
    my @implicit;
    foreach my $p (@{ $opt{implicit_not} }) {
        push @implicit, Lit::Pattern->new(
            prefix => 'implicit', type => 'NOT', text => $p,
            line => 0, file => '<command line>',
            strict => $opt{strict}, full => 0, nocase => $opt{nocase},
        );
    }
    $st->{implicit} = \@implicit;

    my $ok = _check_input($st, $checks);

    if (!$ok && $opt{dump_input} eq 'fail') { _dump_input($st) }
    if ($opt{dump_input} eq 'always')       { _dump_input($st) }

    return $ok ? 0 : 1;
}

# --------------------------------------------------------- check-file parsing

sub _read_checks {
    my ($text, $file, $opt, $err) = @_;

    my @checks;
    my %used;
    my @lines = split(/\n/, $text, -1);

    my $prefix_alt  = join('|', map { quotemeta } sort { length($b) <=> length($a) } @{ $opt->{prefixes} });
    my $comment_alt = join('|', map { quotemeta } @{ $opt->{comments} });

    my $lineno = 0;
    foreach my $raw (@lines) {
        $lineno++;
        my $line = $raw;
        $line =~ s/\r$//;

        # A comment directive hides everything after it on the line.
        if (length $comment_alt && $line =~ /(?:^|[^A-Za-z0-9_-])(?:$comment_alt):/) {
            my $cpos = $-[0];
            my $cand = _find_directive($line, $prefix_alt);
            next if !defined $cand || $cand->{pos} > $cpos;
        }

        my $d = _find_directive($line, $prefix_alt);
        next unless defined $d;

        $used{ $d->{prefix} } = 1;

        my $body = $d->{rest};
        $body =~ s/^[ \t]+//;
        $body =~ s/[ \t\r]+$//;

        if ($d->{type} eq 'EMPTY') {
            if (length $body) {
                print $err "$file:$lineno: error: "
                    . "$d->{prefix}-EMPTY: is not allowed to have a pattern\n";
                return (undef, undef, 1);
            }
        }
        elsif (!length $body) {
            print $err "$file:$lineno: error: found empty check string with prefix '"
                . $d->{prefix} . ($d->{type} eq 'PLAIN' ? '' : '-' . $d->{type}) . ":'\n";
            return (undef, undef, 1);
        }

        push @checks, Lit::Pattern->new(
            prefix => $d->{prefix},
            type   => $d->{type},
            count  => $d->{count},
            text   => $body,
            line   => $lineno,
            file   => $file,
            strict => $opt->{strict},
            full   => ($d->{type} eq 'EMPTY' ? 0 : $opt->{full}),
            nocase => $opt->{nocase},
        );
    }

    # A NEXT/SAME/EMPTY directive cannot be the first of its prefix.
    my %seen_positive;
    foreach my $c (@checks) {
        my $t = $c->type;
        if ($t eq 'NEXT' || $t eq 'SAME' || $t eq 'EMPTY') {
            unless ($seen_positive{ $c->prefix }) {
                print $err $c->{file} . ':' . $c->line . ': error: found '
                    . $c->prefix . '-' . $t . ": without previous '"
                    . $c->prefix . ":' line\n";
                return (undef, undef, 1);
            }
        }
        $seen_positive{ $c->prefix } = 1 if $t ne 'NOT';
    }

    unless ($opt->{allow_unused}) {
        foreach my $p (@{ $opt->{prefixes} }) {
            next if $used{$p};
            next unless @checks;   # the "no checks at all" case is reported later
            print $err "FileCheck: warning: prefix '$p' is unused in the check file\n";
        }
    }

    return (\@checks, \%used, undef);
}

# Locate the first PREFIX[-SUFFIX]: directive on a line.
sub _find_directive {
    my ($line, $prefix_alt) = @_;
    return undef unless length $prefix_alt;

    while ($line =~ /(?:^|[^A-Za-z0-9_-])($prefix_alt)(-(?:NEXT|SAME|NOT|DAG|LABEL|EMPTY|COUNT-[0-9]+))?:/g) {
        my $prefix = $1;
        my $suffix = $2;
        my $start  = $-[1];
        my $rest   = substr($line, $+[0]);

        my ($type, $count) = ('PLAIN', 1);
        if (defined $suffix) {
            my $s = substr($suffix, 1);
            if ($s =~ /^COUNT-([0-9]+)$/) {
                $type  = 'COUNT';
                $count = 0 + $1;
                return undef if $count == 0;   # CHECK-COUNT-0 is invalid; ignore line
            } else {
                $type = $s;
            }
        }
        return { prefix => $prefix, type => $type, count => $count,
                 rest => $rest, pos => $start };
    }
    return undef;
}

# --------------------------------------------------------------- input prep

sub _canonicalize {
    my ($text, $strict) = @_;
    $text =~ s/\r\n/\n/g;
    return $text if $strict;
    $text =~ s/[ \t]+/ /g;
    return $text;
}

sub _line_starts {
    my ($buf) = @_;
    my @starts = (0);
    my $p = 0;
    while (($p = index($buf, "\n", $p)) >= 0) { $p++; push @starts, $p }
    return \@starts;
}

sub _line_col {
    my ($st, $off) = @_;
    my $starts = $st->{lines};
    my ($lo, $hi) = (0, $#$starts);
    while ($lo < $hi) {
        my $mid = int(($lo + $hi + 1) / 2);
        if ($starts->[$mid] <= $off) { $lo = $mid } else { $hi = $mid - 1 }
    }
    return ($lo + 1, $off - $starts->[$lo] + 1);
}

sub _line_text {
    my ($st, $lineno) = @_;
    my $starts = $st->{lines};
    return '' if $lineno < 1 || $lineno > @$starts;
    my $s = $starts->[$lineno - 1];
    my $e = ($lineno < @$starts) ? $starts->[$lineno] - 1 : length(${ $st->{buf} });
    return substr(${ $st->{buf} }, $s, $e - $s);
}

# ------------------------------------------------------------------ matching

sub _search {
    my ($st, $qr, $from) = @_;
    my $bufref = $st->{buf};
    my $len = length $$bufref;
    return () if $from > $len;
    pos($$bufref) = $from;
    if ($$bufref =~ /$qr/g) {
        my @s = @-;
        my @e = @+;
        pos($$bufref) = undef;
        return (\@s, \@e);
    }
    pos($$bufref) = undef;
    return ();
}

# Compile a pattern and try to match it at or after $from.
# Returns ($start, $end) on success, or () after reporting the error.
sub _try_match {
    my ($st, $pat, $from, $quiet) = @_;

    my ($qr, $ops, $cerr) = $pat->compile($st->{vars});
    unless (defined $qr) {
        _report_pattern_error($st, $pat, $cerr);
        return ();
    }

    my ($s, $e) = _search($st, $qr, $from);
    unless (defined $s) { return (undef, undef, $ops) }

    return ($s->[0], $e->[0], $ops, $s, $e);
}

sub _apply_ops {
    my ($st, $pat, $ops, $s, $e) = @_;
    my $bufref = $st->{buf};
    foreach my $op (@$ops) {
        my $g = $op->{group};
        my $txt = (defined $s->[$g] && defined $e->[$g])
                ? substr($$bufref, $s->[$g], $e->[$g] - $s->[$g]) : '';
        if ($op->{kind} eq 'def_str') {
            $st->{vars}{str}{ $op->{name} } = $txt;
        }
        elsif ($op->{kind} eq 'def_num') {
            $st->{vars}{num}{ $op->{name} } =
                { value => Lit::Pattern::parse_num($txt, $op->{fmt}), fmt => $op->{fmt} };
        }
        elsif ($op->{kind} eq 'check_num') {
            my $got = Lit::Pattern::parse_num($txt, $op->{fmt});
            if ($got != $op->{want}) {
                return "numeric value $got does not equal expected "
                     . $op->{want} . " (from '" . $op->{text} . "')";
            }
        }
    }
    return undef;
}

sub _check_input {
    my ($st, $checks) = @_;

    my $len = length ${ $st->{buf} };
    my $base = 0;           # start of the current CHECK-LABEL region
    my $i = 0;
    my $j = 0;
    my $n = scalar @$checks;
    my $ok = 1;

    while (1) {
        my $region_end;
        if ($j == $n) {
            $region_end = $len;
            $j = $n;
        } else {
            # advance j to the next CHECK-LABEL
            my $found = -1;
            for (my $k = $j; $k < $n; $k++) {
                if ($checks->[$k]->type eq 'LABEL') { $found = $k; last }
            }
            if ($found < 0) { $region_end = $len; $j = $n }
            else {
                my $lab = $checks->[$found];
                my ($ms, $me, $ops, $s, $e) = _try_match($st, $lab, $base);
                unless (defined $ms) {
                    _report_no_match($st, $lab, $base);
                    return 0;
                }
                $region_end = $me;
                $j = $found + 1;
            }
        }

        my $sub_ok = _check_region($st, $checks, $i, $j, $base, $region_end);
        $ok = 0 unless $sub_ok;
        return 0 unless $sub_ok;

        $i = $j;
        $base = $region_end;
        last if $j == $n;

        if ($st->{opt}{var_scope}) {
            foreach my $k (keys %{ $st->{vars}{str} }) {
                delete $st->{vars}{str}{$k} unless $k =~ /^\$/;
            }
            foreach my $k (keys %{ $st->{vars}{num} }) {
                delete $st->{vars}{num}{$k} unless $k =~ /^\$/;
            }
        }
    }

    return $ok;
}

sub _check_region {
    my ($st, $checks, $from_idx, $to_idx, $rstart, $rend) = @_;

    my $pos      = $rstart;
    my $last_end = $rstart;
    my @pending_not;
    my $k = $from_idx;

    while ($k < $to_idx) {
        my $c = $checks->[$k];
        my $t = $c->type;

        if ($t eq 'NOT') { push @pending_not, $c; $k++; next }

        if ($t eq 'DAG') {
            my $g_end = $k;
            $g_end++ while $g_end < $to_idx && $checks->[$g_end]->type eq 'DAG';
            my ($nstart, $nend, $ok) =
                _do_dag($st, $checks, $k, $g_end, $pos, $rend, \@pending_not);
            return 0 unless $ok;
            @pending_not = ();
            $pos = $nend;
            $last_end = $nend;
            $k = $g_end;
            next;
        }

        # Positive directive.
        my $not_start = $pos;
        my $reps = ($t eq 'COUNT') ? $c->count : 1;
        my $first_start;
        for (my $r = 0; $r < $reps; $r++) {
            my ($ms, $me, $ops, $s, $e) = _try_match($st, $c, $pos);
            return 0 if !defined($ms) && !defined($ops);   # compile error, reported
            unless (defined $ms) {
                _report_no_match($st, $c, $pos, ($reps > 1 ? $r + 1 : undef));
                return 0;
            }
            if ($ms >= $rend && $rend < length ${ $st->{buf} }) {
                _report_no_match($st, $c, $pos, ($reps > 1 ? $r + 1 : undef));
                return 0;
            }

            $first_start = $ms if $r == 0;

            # NEXT / SAME / EMPTY adjacency rules
            if ($r == 0 && ($t eq 'NEXT' || $t eq 'SAME' || $t eq 'EMPTY')) {
                my $between = substr(${ $st->{buf} }, $last_end, $ms - $last_end);
                my $nl = ($between =~ tr/\n//);
                if ($t eq 'SAME' && $nl != 0) {
                    _report_adjacency($st, $c, $last_end, $ms,
                        "is not on the same line as the previous match");
                    return 0;
                }
                if (($t eq 'NEXT' || $t eq 'EMPTY') && $nl == 0) {
                    _report_adjacency($st, $c, $last_end, $ms,
                        "is on the same line as the previous match");
                    return 0;
                }
                if (($t eq 'NEXT' || $t eq 'EMPTY') && $nl > 1) {
                    _report_adjacency($st, $c, $last_end, $ms,
                        "is not on the line after the previous match");
                    return 0;
                }
            }

            my $verr = _apply_ops($st, $c, $ops, $s, $e);
            if (defined $verr) {
                _report_pattern_error($st, $c, $verr);
                return 0;
            }

            $pos = ($me > $ms) ? $me : $ms + 1;
            $last_end = $me;
        }

        # Pending CHECK-NOTs must not match between the previous cursor and
        # the start of this directive.s match.
        if (@pending_not || @{ $st->{implicit} }) {
            return 0 unless _check_nots($st, \@pending_not, $not_start, $first_start);
        }
        @pending_not = ();
        $k++;
    }

    # Trailing CHECK-NOTs run to the end of the region.
    if (@pending_not || @{ $st->{implicit} }) {
        return 0 unless _check_nots($st, \@pending_not, $pos, $rend);
    }

    return 1;
}


sub _check_nots {
    my ($st, $nots, $start, $end) = @_;
    my @all = (@$nots, @{ $st->{implicit} });
    return 1 unless @all;
    $end = $start if $end < $start;

    foreach my $c (@all) {
        my ($qr, $ops, $cerr) = $c->compile($st->{vars});
        unless (defined $qr) { _report_pattern_error($st, $c, $cerr); return 0 }
        my ($s, $e) = _search($st, $qr, $start);
        next unless defined $s;
        next if $s->[0] >= $end;
        _report_not_matched($st, $c, $s->[0], $e->[0]);
        return 0;
    }
    return 1;
}

sub _do_dag {
    my ($st, $checks, $from, $to, $pos, $rend, $pending_not) = @_;

    my @ranges;
    my $maxend = $pos;

    for (my $k = $from; $k < $to; $k++) {
        my $c = $checks->[$k];
        my ($qr, $ops, $cerr) = $c->compile($st->{vars});
        unless (defined $qr) { _report_pattern_error($st, $c, $cerr); return (0,0,0) }

        my $search = $pos;
        my ($ms, $me, $sg, $eg);
        while (1) {
            my ($s, $e) = _search($st, $qr, $search);
            unless (defined $s) { ($ms, $me) = (undef, undef); last }
            my ($a, $b) = ($s->[0], $e->[0]);
            my $clash = 0;
            foreach my $r (@ranges) {
                if ($a < $r->[1] && $b > $r->[0]) { $clash = 1; last }
            }
            if ($clash) { $search = $a + 1; next }
            ($ms, $me, $sg, $eg) = ($a, $b, $s, $e);
            last;
        }

        unless (defined $ms) {
            _report_no_match($st, $c, $pos);
            return (0, 0, 0);
        }

        my $verr = _apply_ops($st, $c, $ops, $sg, $eg);
        if (defined $verr) { _report_pattern_error($st, $c, $verr); return (0,0,0) }

        push @ranges, [$ms, $me];
        $maxend = $me if $me > $maxend;
    }

    if (@$pending_not || @{ $st->{implicit} }) {
        my $minstart = $maxend;
        foreach my $r (@ranges) { $minstart = $r->[0] if $r->[0] < $minstart }
        return (0, 0, 0) unless _check_nots($st, $pending_not, $pos, $minstart);
    }

    return ($pos, $maxend, 1);
}

# ---------------------------------------------------------------- diagnostics

sub _dir_name {
    my ($c) = @_;
    my $t = $c->type;
    return $c->prefix if $t eq 'PLAIN';
    return $c->prefix . '-COUNT-' . $c->count if $t eq 'COUNT';
    return $c->prefix . '-' . $t;
}

sub _caret {
    my ($col) = @_;
    return (' ' x ($col - 1)) . '^';
}

sub _report_pattern_error {
    my ($st, $c, $msg) = @_;
    my $err = $st->{err};
    print $err $c->{file} . ':' . $c->line . ': error: ' . _dir_name($c)
        . ': ' . $msg . "\n";
    print $err _dir_name($c) . ': ' . $c->text . "\n";
    $st->{failed} = 1;
}

sub _report_no_match {
    my ($st, $c, $from, $rep) = @_;
    my $err = $st->{err};
    my $what = _dir_name($c);
    my $extra = defined $rep ? " (repetition $rep)" : '';
    print $err $c->{file} . ':' . $c->line . ': error: ' . $what
        . ': expected string not found in input' . $extra . "\n";
    print $err $what . ': ' . $c->text . "\n";

    my ($l, $col) = _line_col($st, $from >= length(${ $st->{buf} })
                                   ? (length(${ $st->{buf} }) ? length(${ $st->{buf} }) - 1 : 0)
                                   : $from);
    print $err $st->{input_name} . ":$l:$col: note: scanning from here\n";
    print $err _line_text($st, $l) . "\n";
    print $err _caret($col) . "\n";
    $st->{failed} = 1;
    $st->{fail_pos} = $from;
    $st->{fail_check} = $c;
}

sub _report_adjacency {
    my ($st, $c, $prev_end, $match_start, $why) = @_;
    my $err = $st->{err};
    my ($pl) = _line_col($st, $prev_end ? $prev_end - 1 : 0);
    my ($ml, $mc) = _line_col($st, $match_start);
    print $err $c->{file} . ':' . $c->line . ': error: ' . _dir_name($c)
        . ": $why\n";
    print $err _dir_name($c) . ': ' . $c->text . "\n";
    print $err $st->{input_name} . ":$ml:$mc: note: match was here\n";
    print $err _line_text($st, $ml) . "\n";
    print $err _caret($mc) . "\n";
    print $err $st->{input_name} . ":$pl:1: note: previous match ended here\n";
    print $err _line_text($st, $pl) . "\n";
    $st->{failed} = 1;
    $st->{fail_pos} = $match_start;
    $st->{fail_check} = $c;
}

sub _report_not_matched {
    my ($st, $c, $s, $e) = @_;
    my $err = $st->{err};
    my ($l, $col) = _line_col($st, $s);
    print $err $c->{file} . ':' . $c->line . ': error: ' . _dir_name($c)
        . ': excluded string found in input' . "\n";
    print $err _dir_name($c) . ': ' . $c->text . "\n";
    print $err $st->{input_name} . ":$l:$col: note: found here\n";
    print $err _line_text($st, $l) . "\n";
    print $err _caret($col) . "\n";
    $st->{failed} = 1;
    $st->{fail_pos} = $s;
    $st->{fail_check} = $c;
}

sub _dump_input {
    my ($st) = @_;
    my $err = $st->{err};
    my $nlines = scalar @{ $st->{lines} };
    my ($fl) = defined $st->{fail_pos} ? _line_col($st, $st->{fail_pos}) : (1);
    my $ctx = $st->{opt}{dump_context};
    my ($lo, $hi) = (1, $nlines);
    if ($ctx > 0 && defined $st->{fail_pos}) {
        $lo = $fl - $ctx; $lo = 1 if $lo < 1;
        $hi = $fl + $ctx; $hi = $nlines if $hi > $nlines;
    }
    print $err "\nInput was:\n";
    print $err "<<<<<<\n";
    for (my $l = $lo; $l <= $hi; $l++) {
        my $mark = ($l == $fl) ? '>' : ' ';
        printf $err "%s%6d: %s\n", $mark, $l, _line_text($st, $l);
    }
    print $err ">>>>>>\n";
}

1;

__END__

=head1 NAME

Lit::FileCheck - FileCheck directives and matching semantics

=head1 SYNOPSIS

    my $rc = Lit::FileCheck::run(\@argv, {
        in => $fh, out => $fh, err => $fh, cwd => $dir, env => \%env,
    });

=head1 DESCRIPTION

A reimplementation of LLVM's C<FileCheck>.  Keeping the engine callable
in-process matters on OpenVMS, where creating a subprocess for every CHECK
step would dominate the run time; the internal shell dispatches the
C<FileCheck> command straight here.

Input is canonicalised before matching: C<CRLF> becomes C<LF>, and unless
C<--strict-whitespace> is given, every run of spaces and tabs collapses to
a single space.  The same collapsing is applied to the literal parts of a
pattern, so a pattern written with aligned columns still matches.

=head1 DIRECTIVES

=over 4

=item CHECK:

Match anywhere at or after the current position.

=item CHECK-NEXT:

Match on the line immediately after the previous match.

=item CHECK-SAME:

Match on the same line as the previous match.

=item CHECK-NOT:

The pattern must B<not> appear between the previous match and the next
positive one.

=item CHECK-DAG:

Consecutive C<CHECK-DAG:> directives form a group that may match in any
order, but whose matches may not overlap.

=item CHECK-LABEL:

Split the input into blocks.  Labels are matched first, and the other
directives in each block are then confined to it - which stops a failure
in one function's output from being satisfied by another's.

=item CHECK-EMPTY:

The next line must be blank.

=item CHECK-COUNT-I<n>:

Equivalent to I<n> consecutive C<CHECK:> directives.

=back

A C<-NEXT>, C<-SAME> or C<-EMPTY> directive cannot be the first for its
prefix, and an empty pattern is an error; both are diagnosed rather than
quietly ignored.

=head1 OPTIONS

=over 4

=item --check-prefix=I<PREFIX>, --check-prefixes=I<A,B>

Directive prefixes to honour; the default is C<CHECK>.

=item --comment-prefixes=I<A,B>

Prefixes that hide the rest of the line; the default is C<COM,RUN>.  This
is why a test file can hold its own C<RUN:> lines and still be its own
check file.

=item --input-file=I<FILE>

Read the input from I<FILE> rather than standard input.

=item --strict-whitespace, --match-full-lines, --ignore-case

=item --implicit-check-not=I<PATTERN>

Apply I<PATTERN> as a C<CHECK-NOT> across the whole input.

=item --allow-empty

Permit empty input, which is otherwise an error.

=item --enable-var-scope

Clear variables not named with a leading C<$> at each C<CHECK-LABEL>.

=item --allow-unused-prefixes

Do not warn when a prefix matches nothing.

=item -DI<NAME>=I<VALUE>, -D#I<NAME>=I<VALUE>

Predefine a string or numeric variable.

=item --dump-input=I<never>|I<fail>|I<always>, --dump-input-context=I<N>

Control the annotated input dump printed on failure.

=back

=head1 EXIT STATUS

0 when every directive matched, 1 when one did not, and 2 for a usage error
or an unreadable file.

=head1 SEE ALSO

L<Lit>, L<Lit::Pattern>, L<filecheck.pl>,
L<https://llvm.org/docs/CommandGuide/FileCheck.html>

=cut
