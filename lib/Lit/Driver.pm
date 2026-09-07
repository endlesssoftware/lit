package Lit::Driver;

# Command line driver: argument parsing, discovery, execution and reporting.
# bin/lit.pl is a thin wrapper around run().

use strict;
use warnings;

require 5.006;

use Lit::Compat ();
use Lit::LitConfig ();
use Lit::Discovery ();
use Lit::TestRunner ();
use Lit::Test ();

use vars qw($VERSION);
$VERSION = '0.01';

sub _usage {
    return <<'USAGE';
usage: lit.pl [options] <test paths>

Selection and discovery
  --filter=REGEX          Only run tests whose name matches REGEX
  --filter-out=REGEX      Skip tests whose name matches REGEX
  --max-failures=N        Stop after N failures
  --order=found|lexical|random
  --show-suites           List discovered suites and exit
  --show-tests            List discovered tests and exit

Execution
  -j N, --threads=N       Run N tests in parallel (1 where fork is absent)
  --timeout=N             Per-test time limit in seconds
  --param NAME=VAL, -D NAME=VAL
                          Set a parameter visible to config files
  --path=DIR              Prepend DIR to PATH for tests
  --no-execute            Discover and report, but do not run anything

Output
  -q, --quiet             Only print failures
  -s, --succinct          Less output; no per-test PASS lines
  -v, --verbose           Show the output of failing tests
  -a, --show-all          Show the output of every test
  --time-tests            Print each test's elapsed time
  --xunit-xml-output=FILE Write JUnit XML results to FILE
  --version               Print version and exit
  -h, --help              This message
USAGE
}

sub _parse_args {
    my ($argv, $o, $err) = @_;
    my @paths;
    my @args = @$argv;

    while (@args) {
        my $a = shift @args;
        if ($a eq '--') { push @paths, @args; last }

        if ($a =~ /^--?([A-Za-z][-A-Za-z0-9_]*)(?:=(.*))?$/s) {
            my ($name, $val) = ($1, $2);
            my $has = defined $val;
            my $need = sub {
                return $val if $has;
                return shift @args if @args;
                print $err "lit: option --$name requires a value\n";
                return undef;
            };

            # Attached forms: -j4 and -DNAME=VALUE.
            if ($name =~ /^j([0-9]+)$/) { $o->{jobs} = 0 + $1; next }
            if ($name =~ /^D(.+)$/) {
                my $d = $1;
                $d .= '=' . $val if $has;
                if ($d =~ /^([^=]+)=(.*)$/s) { $o->{params}{$1} = $2 }
                else                         { $o->{params}{$d} = '' }
                next;
            }
            if ($name eq 'filter')      { my $v=$need->(); return -1 unless defined $v; $o->{filter}=$v; next }
            if ($name eq 'filter-out')  { my $v=$need->(); return -1 unless defined $v; $o->{filter_out}=$v; next }
            if ($name eq 'max-failures'){ my $v=$need->(); return -1 unless defined $v; $o->{max_failures}=0+$v; next }
            if ($name eq 'order')       { my $v=$need->(); return -1 unless defined $v; $o->{order}=$v; next }
            if ($name eq 'threads' || $name eq 'j' || $name eq 'workers') {
                my $v=$need->(); return -1 unless defined $v; $o->{jobs}=0+$v; next }
            if ($name eq 'timeout' || $name eq 'max-time') {
                my $v=$need->(); return -1 unless defined $v; $o->{timeout}=0+$v; next }
            if ($name eq 'param' || $name eq 'D') {
                my $v=$need->(); return -1 unless defined $v;
                if ($v =~ /^([^=]+)=(.*)$/s) { $o->{params}{$1} = $2 }
                else                         { $o->{params}{$v} = '' }
                next;
            }
            if ($name eq 'path')        { my $v=$need->(); return -1 unless defined $v; push @{$o->{path}}, $v; next }
            if ($name eq 'xunit-xml-output') {
                my $v=$need->(); return -1 unless defined $v; $o->{xunit}=$v; next }

            if ($name eq 'quiet'   || $name eq 'q') { $o->{quiet}    = 1; next }
            if ($name eq 'succinct'|| $name eq 's') { $o->{succinct} = 1; next }
            if ($name eq 'verbose' || $name eq 'v') { $o->{verbose}++;    next }
            if ($name eq 'vv')                      { $o->{verbose} += 2; next }
            if ($name eq 'show-all'|| $name eq 'a') { $o->{show_all} = 1; $o->{verbose}++; next }
            if ($name eq 'time-tests')              { $o->{time_tests} = 1; next }
            if ($name eq 'no-execute')              { $o->{no_execute} = 1; next }
            if ($name eq 'show-suites')             { $o->{show_suites} = 1; next }
            if ($name eq 'show-tests')              { $o->{show_tests} = 1; next }
            if ($name eq 'version')                 { $o->{version} = 1; next }
            if ($name eq 'help' || $name eq 'h')    { $o->{help} = 1; next }

            print $err "lit: unknown option '$a'\n";
            return -1;
        }
        push @paths, $a;
    }
    return \@paths;
}

# ---------------------------------------------------------------------- run

sub run {
    my ($argv, $ctx) = @_;
    $ctx = {} unless defined $ctx;
    my $out = defined $ctx->{out} ? $ctx->{out} : \*STDOUT;
    my $err = defined $ctx->{err} ? $ctx->{err} : \*STDERR;

    my %o = (
        params => {}, path => [], jobs => 0, timeout => 0,
        verbose => 0, quiet => 0, succinct => 0,
        order => 'lexical', max_failures => 0,
    );

    my $paths = _parse_args($argv, \%o, $err);
    return 2 if !ref $paths;

    if ($o{version}) { print $out "lit.pl (perl) $VERSION\n"; return 0 }
    if ($o{help})    { print $out _usage(); return 0 }

    @$paths = ('.') unless @$paths;

    my $lit = Lit::LitConfig->new(
        params  => $o{params},
        quiet   => $o{quiet},
        verbose => $o{verbose},
        timeout => $o{timeout},
        err     => $err,
    );

    if (@{ $o{path} }) {
        my $sep = Lit::Compat::path_sep();
        my $cur = defined $ENV{PATH} ? $ENV{PATH} : '';
        $ENV{PATH} = join($sep, @{ $o{path} }, $cur);
    }

    my ($tests, $errors) = Lit::Discovery::find_tests($paths, $lit);
    foreach my $e (@$errors) { print $err "lit: error: $e\n" }
    if (!@$tests) {
        print $err "lit: error: no tests discovered\n" unless @$errors;
        return 2;
    }

    if ($o{show_suites}) {
        my %seen;
        foreach my $t (@$tests) {
            my $s = $t->suite;
            next if $seen{ $s->name }++;
            print $out "  " . $s->name . " - " . $s->test_source_root . "\n";
        }
        return 0;
    }

    @$tests = _select(\@$tests, \%o);
    unless (@$tests) {
        print $err "lit: error: filter excluded every discovered test\n";
        return 2;
    }
    @$tests = _order(\@$tests, $o{order});

    if ($o{show_tests}) {
        print $out "  " . $_->name . "\n" foreach @$tests;
        return 0;
    }
    if ($o{no_execute}) {
        print $out "Discovered " . scalar(@$tests) . " tests (not executed)\n";
        return 0;
    }

    my $jobs = $o{jobs};
    if ($jobs <= 0) { $jobs = Lit::Compat::have_fork() ? _cpu_count() : 1 }
    $jobs = 1 unless Lit::Compat::have_fork();

    my $t0 = Lit::Compat::now();
    my $state = { done => 0, total => scalar(@$tests), failures => 0,
                  out => $out, o => \%o, stopped => 0 };

    if ($jobs > 1) { _run_parallel($tests, $lit, $state, $jobs) }
    else           { _run_serial($tests, $lit, $state) }

    my $elapsed = Lit::Compat::now() - $t0;
    _summary($tests, $state, $elapsed, $out);
    _write_xunit($tests, $o{xunit}, $err) if defined $o{xunit};

    my $bad = 0;
    foreach my $t (@$tests) {
        next unless defined $t->result;
        $bad++ if Lit::Test::is_failure($t->result);
    }
    return $bad ? 1 : 0;
}

# ------------------------------------------------------------------ selection

sub _select {
    my ($tests, $o) = @_;
    my @sel = @$tests;
    if (defined $o->{filter}) {
        my $re = eval { qr/$o->{filter}/ };
        @sel = grep { $_->name =~ $re } @sel if $re;
    }
    if (defined $o->{filter_out}) {
        my $re = eval { qr/$o->{filter_out}/ };
        @sel = grep { $_->name !~ $re } @sel if $re;
    }
    return @sel;
}

sub _order {
    my ($tests, $order) = @_;
    return @$tests if $order eq 'found';
    if ($order eq 'random') {
        my @t = @$tests;
        for (my $i = @t - 1; $i > 0; $i--) {
            my $j = int(rand($i + 1));
            @t[$i, $j] = @t[$j, $i];
        }
        return @t;
    }
    return sort { $a->name cmp $b->name } @$tests;
}

sub _cpu_count {
    return 0 + $ENV{LIT_JOBS} if $ENV{LIT_JOBS} && $ENV{LIT_JOBS} =~ /^[0-9]+$/;
    return 0 + $ENV{NUMBER_OF_PROCESSORS}
        if $ENV{NUMBER_OF_PROCESSORS} && $ENV{NUMBER_OF_PROCESSORS} =~ /^[0-9]+$/;
    if (open(my $fh, '<', '/proc/cpuinfo')) {
        my $n = 0;
        while (<$fh>) { $n++ if /^processor\s*:/ }
        close $fh;
        return $n if $n > 0;
    }
    my $n = `sysctl -n hw.ncpu 2>/dev/null`;
    return 0 + $n if defined $n && $n =~ /^\s*([0-9]+)/ && $1 > 0;
    return 1;
}

# ------------------------------------------------------------------ execution

sub _run_serial {
    my ($tests, $lit, $state) = @_;
    foreach my $t (@$tests) {
        last if _should_stop($state);
        Lit::TestRunner::execute($t, $lit, { show_all => $state->{o}{show_all} });
        _report_one($t, $state);
    }
}

sub _run_parallel {
    my ($tests, $lit, $state, $jobs) = @_;

    my @queue = @$tests;
    my %running;

    while (@queue || %running) {
        while (@queue && scalar(keys %running) < $jobs && !_should_stop($state)) {
            my $t = shift @queue;
            my $rf = Lit::Compat::temp_file_auto('litres');
            my $pid = fork();
            unless (defined $pid) {
                # Out of processes: fall back to running this one here.
                Lit::TestRunner::execute($t, $lit, { show_all => $state->{o}{show_all} });
                _report_one($t, $state);
                next;
            }
            if ($pid == 0) {
                Lit::TestRunner::execute($t, $lit, { show_all => $state->{o}{show_all} });
                my $r = $t->result . "\n" . $t->elapsed . "\n" . $t->output;
                Lit::Compat::write_file($rf, $r);
                eval { require POSIX; POSIX::_exit(0); 1 } or CORE::exit(0);
            }
            $running{$pid} = [ $t, $rf ];
        }
        last unless %running;

        my $pid = wait();
        last if $pid < 0;
        my $entry = delete $running{$pid};
        next unless $entry;
        my ($t, $rf) = @$entry;

        my $data = Lit::Compat::read_file($rf);
        unlink $rf;
        if (defined $data && $data =~ /^([A-Z]+)\n([0-9.eE+-]*)\n(.*)$/s) {
            $t->set_result($1, $3, 0 + (length $2 ? $2 : 0));
        } else {
            $t->set_result('UNRESOLVED', "worker produced no result", 0);
        }
        _report_one($t, $state);
    }

    foreach my $pid (keys %running) { waitpid($pid, 0) }
}

sub _should_stop {
    my ($state) = @_;
    return 1 if $state->{stopped};
    my $max = $state->{o}{max_failures};
    if ($max && $state->{failures} >= $max) { $state->{stopped} = 1; return 1 }
    return 0;
}

# ------------------------------------------------------------------ reporting

sub _report_one {
    my ($t, $state) = @_;
    my $o    = $state->{o};
    my $out  = $state->{out};
    my $code = $t->result;

    $state->{done}++;
    $state->{failures}++ if Lit::Test::is_failure($code);

    my $interesting = Lit::Test::is_failure($code);
    my $show_line   = $interesting;
    $show_line = 1 if !$o->{quiet} && !$o->{succinct} && !$interesting;

    if ($show_line) {
        my $line = sprintf("%s: %s (%d of %d)",
                           $code, $t->name, $state->{done}, $state->{total});
        $line .= sprintf(" [%.2fs]", $t->elapsed) if $o->{time_tests};
        print $out $line . "\n";
    }

    my $show_output = 0;
    $show_output = 1 if $interesting;
    $show_output = 1 if $o->{show_all};
    $show_output = 0 if $o->{quiet} && !$interesting;

    if ($show_output && length $t->output) {
        my $bar = '*' x 20;
        print $out "$bar TEST '" . $t->name . "' "
                 . ($interesting ? 'FAILED' : 'OUTPUT') . " $bar\n";
        print $out $t->output;
        print $out "\n" unless $t->output =~ /\n$/;
        print $out "$bar\n";
    }
}

sub _summary {
    my ($tests, $state, $elapsed, $out) = @_;

    my %count;
    foreach my $t (@$tests) {
        my $c = defined $t->result ? $t->result : 'UNRESOLVED';
        $count{$c}++;
    }

    printf $out "\nTesting Time: %.2fs\n\n", $elapsed;
    my $total = scalar @$tests;
    print $out "Total Discovered Tests: $total\n";

    my %label = (
        PASS        => 'Passed',
        FLAKYPASS   => 'Passed With Retry',
        XFAIL       => 'Expectedly Failed',
        UNSUPPORTED => 'Unsupported',
        XPASS       => 'Unexpectedly Passed',
        FAIL        => 'Failed',
        TIMEOUT     => 'Timed Out',
        UNRESOLVED  => 'Unresolved',
    );

    foreach my $c (@Lit::Test::CODES) {
        next unless $count{$c};
        printf $out "  %-20s %4d (%.2f%%)\n",
            $label{$c} . ':', $count{$c}, 100 * $count{$c} / $total;
    }

    if ($state->{stopped}) {
        print $out "\nStopped early: reached the --max-failures limit.\n";
    }
}

# --------------------------------------------------------------- JUnit XML

sub _xml_escape {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    $s =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f]//g;
    return $s;
}

sub _write_xunit {
    my ($tests, $file, $err) = @_;
    local *FH;
    unless (open(FH, '>', $file)) {
        print $err "lit: cannot write '$file': $!\n";
        return;
    }

    my %by_suite;
    foreach my $t (@$tests) {
        my $s = $t->suite ? $t->suite->name : 'tests';
        push @{ $by_suite{$s} }, $t;
    }

    print FH qq{<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n};
    foreach my $s (sort keys %by_suite) {
        my @ts = @{ $by_suite{$s} };
        my $fails = scalar grep { Lit::Test::is_failure($_->result) } @ts;
        my $skips = scalar grep { defined $_->result && $_->result eq 'UNSUPPORTED' } @ts;
        my $time  = 0; $time += $_->elapsed foreach @ts;
        printf FH qq{  <testsuite name=%s tests="%d" failures="%d" skipped="%d" time="%.2f">\n},
            '"' . _xml_escape($s) . '"', scalar(@ts), $fails, $skips, $time;
        foreach my $t (@ts) {
            my $cls = $t->rel;
            $cls =~ s{[/\\]}{.}g;
            printf FH qq{    <testcase classname="%s" name="%s" time="%.2f"},
                _xml_escape($s), _xml_escape($cls), $t->elapsed;
            my $c = defined $t->result ? $t->result : 'UNRESOLVED';
            if (Lit::Test::is_failure($c)) {
                print FH ">\n";
                printf FH qq{      <failure type="%s">%s</failure>\n},
                    _xml_escape($c), _xml_escape($t->output);
                print FH "    </testcase>\n";
            } elsif ($c eq 'UNSUPPORTED') {
                print FH ">\n      <skipped/>\n    </testcase>\n";
            } else {
                print FH "/>\n";
            }
        }
        print FH "  </testsuite>\n";
    }
    print FH "</testsuites>\n";
    close FH;
}

1;
