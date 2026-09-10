package Lit::TestRunner;

# The ShTest format: read a test file's RUN:/REQUIRES:/XFAIL: directives,
# apply substitutions, and execute the resulting script with the internal
# shell.

use strict;
use warnings;

require 5.006;

use Lit::Compat ();
use Lit::ShRun ();
use Lit::BoolExpr ();
use Lit::Test ();

use vars qw($VERSION);
$VERSION = '0.01';

my $KEYWORDS = 'RUN|XFAIL|REQUIRES-ANY|REQUIRES|UNSUPPORTED|ALLOW_RETRIES|REDEFINE|DEFINE';

# ---------------------------------------------------------------- parsing

# Returns a hashref:
#   runs          [ { line => N, text => $cmd, subs => \@subs }, ... ]
#   requires      [ $expr, ... ]
#   unsupported   [ $expr, ... ]
#   xfails        [ $expr, ... ]
#   retries       N
#   error         message, if the file could not be parsed
sub parse_script {
    my ($test) = @_;

    my $text = Lit::Compat::read_file($test->path);
    return { error => "cannot read test file" } unless defined $text;

    my %p = (runs => [], requires => [], unsupported => [], xfails => [],
             retries => 0, error => undef);

    my @local_subs;
    my $lineno = 0;
    my $pending;                 # a RUN entry awaiting a continuation

    foreach my $raw (split(/\n/, $text, -1)) {
        $lineno++;
        my $line = $raw;
        $line =~ s/\r$//;

        last if $line =~ /(?:^|[^\w.-])END\.\s*$/;
        next unless $line =~ /(?:^|[^\w.-])($KEYWORDS)\s*:(.*)$/;

        my ($kw, $body) = ($1, $2);
        $body =~ s/^\s+//;
        $body =~ s/\s+$//;

        if ($kw eq 'RUN') {
            if ($pending) {
                $pending->{text} .= ' ' . $body;
            } else {
                $pending = { line => $lineno, text => $body,
                             subs => [ @local_subs ] };
            }
            if ($pending->{text} =~ s/\\$//) {
                $pending->{text} =~ s/\s+$//;
                next;                      # continued on the next RUN line
            }
            push @{ $p{runs} }, $pending;
            $pending = undef;
            next;
        }

        if ($kw eq 'REQUIRES' || $kw eq 'REQUIRES-ANY') {
            push @{ $p{requires} }, $body;
            next;
        }
        if ($kw eq 'UNSUPPORTED') { push @{ $p{unsupported} }, $body; next }
        if ($kw eq 'XFAIL')       { push @{ $p{xfails} },      $body; next }
        if ($kw eq 'ALLOW_RETRIES') {
            if ($body =~ /^([0-9]+)$/) { $p{retries} = 0 + $1 }
            else { $p{error} = "line $lineno: ALLOW_RETRIES: expects a number" }
            next;
        }
        if ($kw eq 'DEFINE' || $kw eq 'REDEFINE') {
            unless ($body =~ /^(%\{[^}]+\}|%[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/s) {
                $p{error} = "line $lineno: $kw: expects '%{name} = value'";
                next;
            }
            my ($name, $value) = ($1, $2);
            if ($kw eq 'REDEFINE') {
                @local_subs = grep { $_->[0] ne $name } @local_subs;
            }
            unshift @local_subs, [ $name, $value ];
            next;
        }
    }

    push @{ $p{runs} }, $pending if $pending;
    return \%p;
}

# ---------------------------------------------------------- substitutions

# Built-in substitutions.  As with lit on Windows, %s and friends give the
# host's native path syntax while %/s gives the forward-slash form; on
# OpenVMS that is the difference between DISK:[DIR]FILE.EXT and
# /disk/dir/file.ext.
sub default_substitutions {
    my ($test) = @_;

    my $src      = $test->path;
    my $src_dir  = Lit::Compat::dirname_of($src);
    my $tmp      = $test->temp_base;
    my $tmp_dir  = $test->exec_dir;

    my @subs = (
        [ '%{pathsep}',  Lit::Compat::path_sep() ],
        [ '%basename_t', Lit::Compat::basename_of($tmp) ],
        [ '%basename_s', Lit::Compat::basename_of($src) ],
        [ '%/s', $src ],
        [ '%/S', $src_dir ],
        [ '%/p', $src_dir ],
        [ '%/t', $tmp ],
        [ '%/T', $tmp_dir ],
        [ '%s',  Lit::Compat::to_native($src) ],
        [ '%S',  Lit::Compat::to_native_dir($src_dir) ],
        [ '%p',  Lit::Compat::to_native_dir($src_dir) ],
        [ '%t',  Lit::Compat::to_native($tmp) ],
        [ '%T',  Lit::Compat::to_native_dir($tmp_dir) ],
    );

    # Longest pattern first, so %basename_t wins over %b and %/s over %s.
    @subs = sort { length($b->[0]) <=> length($a->[0]) } @subs;
    return \@subs;
}

sub apply_substitutions {
    my ($text, $subs) = @_;
    my $mark = "\001LITPCT\001";
    $text =~ s/%%/$mark/g;

    for (my $pass = 0; $pass < 10; $pass++) {
        my $before = $text;
        foreach my $s (@$subs) {
            my ($pat, $rep) = @$s;
            $rep = '' unless defined $rep;
            if (ref($pat) eq 'Regexp') { $text =~ s/$pat/$rep/g }
            else {
                my $q = quotemeta $pat;
                $text =~ s/$q/$rep/g;
            }
        }
        last if $text eq $before;
    }

    $text =~ s/\Q$mark\E/%/g;
    return $text;
}

# ------------------------------------------------------------------ execute

sub execute {
    my ($test, $lit, $opt) = @_;
    $opt = {} unless defined $opt;

    my $started = Lit::Compat::now();
    my $config  = $test->config;
    my $parsed  = parse_script($test);

    if (defined $parsed->{error}) {
        return $test->set_result('UNRESOLVED', $parsed->{error},
                                 Lit::Compat::now() - $started);
    }

    my @features = @{ $config->features };

    # ---- UNSUPPORTED / REQUIRES
    foreach my $e (@{ $parsed->{unsupported} }) {
        my ($v, $err) = Lit::BoolExpr::evaluate($e, \@features);
        return $test->set_result('UNRESOLVED', "bad UNSUPPORTED expression: $err")
            if defined $err;
        return $test->set_result('UNSUPPORTED', "unsupported: $e",
                                 Lit::Compat::now() - $started) if $v;
    }
    foreach my $e (@{ $parsed->{requires} }) {
        my ($v, $err) = Lit::BoolExpr::evaluate($e, \@features);
        return $test->set_result('UNRESOLVED', "bad REQUIRES expression: $err")
            if defined $err;
        unless ($v) {
            return $test->set_result('UNSUPPORTED', "missing required feature: $e",
                                     Lit::Compat::now() - $started);
        }
    }

    unless (@{ $parsed->{runs} }) {
        return $test->set_result('UNRESOLVED', "test has no 'RUN:' line",
                                 Lit::Compat::now() - $started);
    }

    # ---- XFAIL
    my $xfail = 0;
    foreach my $e (@{ $parsed->{xfails} }) {
        my ($v, $err) = Lit::BoolExpr::evaluate($e, \@features);
        return $test->set_result('UNRESOLVED', "bad XFAIL expression: $err")
            if defined $err;
        $xfail = 1 if $v;
    }

    # ---- scratch area
    my $execdir = $test->exec_dir;
    unless (Lit::Compat::mkpath($execdir)) {
        return $test->set_result('UNRESOLVED',
            "cannot create output directory '$execdir'",
            Lit::Compat::now() - $started);
    }
    _clean_temps($test);

    my $retries = $parsed->{retries};
    my $attempt = 0;
    my ($code, $report, $timedout);

    while (1) {
        $attempt++;
        ($code, $report, $timedout) = _run_script($test, $parsed, $lit, $opt);
        last if $code == 0;
        last if $attempt > $retries;
        _clean_temps($test);
    }

    my $elapsed = Lit::Compat::now() - $started;
    $test->set_metrics(read_metrics($test));

    if ($timedout) {
        return $test->set_result('TIMEOUT', $report, $elapsed);
    }
    if ($code == 0) {
        return $test->set_result('XPASS', $report, $elapsed) if $xfail;
        return $test->set_result(($attempt > 1 ? 'FLAKYPASS' : 'PASS'),
                                 $report, $elapsed);
    }
    return $test->set_result(($xfail ? 'XFAIL' : 'FAIL'), $report, $elapsed);
}

# Where the metrics builtin accumulates this test's measurements.  It sits
# under %t, so _clean_temps removes any stale copy before each attempt.
sub metrics_file {
    my ($test) = @_;
    return $test->temp_base . '.metrics';
}

# Read them back.  A repeated name takes its last value, which is what an
# append-as-you-go file should mean.
sub read_metrics {
    my ($test) = @_;
    my $text = Lit::Compat::read_file(metrics_file($test));
    return {} unless defined $text;
    my %m;
    foreach my $line (split(/\n/, $text)) {
        next unless $line =~ /^([A-Za-z_][A-Za-z0-9_.\-]*)=(.*)$/;
        $m{$1} = $2;
    }
    return \%m;
}

sub _clean_temps {
    my ($test) = @_;
    my $base = $test->temp_base;
    my $dir  = Lit::Compat::dirname_of($base);
    my $stem = Lit::Compat::basename_of($base);
    local *DH;
    return unless opendir(DH, $dir);
    my @e = grep { index($_, $stem) == 0 } readdir(DH);
    closedir(DH);
    foreach my $f (@e) {
        my $p = Lit::Compat::joinp($dir, $f);
        if (-d $p) { Lit::Compat::rmtree($p) } else { unlink $p }
    }
}

sub _run_script {
    my ($test, $parsed, $lit, $opt) = @_;

    my $config   = $test->config;
    my $execdir  = $test->exec_dir;
    my $defaults = default_substitutions($test);

    my %shell = (
        cwd => $execdir,
        env => { %{ $config->environment } },
    );

    # Named in the environment rather than passed as an argument, so that an
    # external tool can append to it as easily as the metrics builtin can.
    # Native syntax for the same reason.
    $shell{env}{LIT_METRICS_FILE} =
        Lit::Compat::to_native(metrics_file($test));

    my $timeout = $config->timeout;
    $timeout = $lit->{timeout} if !$timeout && $lit->{timeout};
    my $deadline = $timeout ? Lit::Compat::now() + $timeout : undef;

    my $out_file = Lit::Compat::joinp($execdir, 'lit.out');
    my $err_file = Lit::Compat::joinp($execdir, 'lit.err');

    my @script;          # for the failure report
    my $report = '';
    my $code   = 0;
    my $timedout = 0;

    foreach my $run (@{ $parsed->{runs} }) {
        my @subs = (@{ $run->{subs} }, @{ $config->substitutions }, @$defaults);
        my $cmd = apply_substitutions($run->{text}, \@subs);
        push @script, { line => $run->{line}, text => $cmd };

        Lit::Compat::write_file($out_file, '');
        Lit::Compat::write_file($err_file, '');

        my $r = Lit::ShRun::run_line($cmd, \%shell, {
            out_file => $out_file,
            err_file => $err_file,
            pipefail => $config->pipefail,
            deadline => $deadline,
        });

        my $out = Lit::Compat::read_file($out_file);
        my $err = Lit::Compat::read_file($err_file);
        $out = '' unless defined $out;
        $err = '' unless defined $err;

        $script[-1]{code} = $r->{code};
        $script[-1]{out}  = $out;
        $script[-1]{err}  = $err;
        $script[-1]{fail} = defined $r->{error} ? $r->{error} : undef;

        if (defined $r->{error}) {
            $code = 127;
            $report = _format_report($test, \@script, "shell error: $r->{error}");
            unlink $out_file, $err_file;
            return ($code, $report, 0);
        }
        if ($r->{timedout}) {
            $timedout = 1;
            $code = 1;
            $report = _format_report($test, \@script,
                "timed out after $timeout seconds");
            unlink $out_file, $err_file;
            return ($code, $report, 1);
        }
        if ($r->{code} != 0) {
            $code = $r->{code};
            $report = _format_report($test, \@script, undef);
            unlink $out_file, $err_file;
            return ($code, $report, 0);
        }
    }

    unlink $out_file, $err_file;
    $report = _format_report($test, \@script, undef) if $opt->{show_all};
    return (0, $report, 0);
}

sub _format_report {
    my ($test, $script, $note) = @_;

    my $r = '';
    $r .= "Script:\n--\n";
    foreach my $s (@$script) {
        $r .= sprintf("# RUN: at line %d\n%s\n", $s->{line}, $s->{text});
    }
    $r .= "--\n";

    my $last = $script->[-1];
    if (defined $note) { $r .= "\n$note\n" }
    if (defined $last->{code}) {
        $r .= "\nExit Code: " . $last->{code} . "\n";
    }
    if (defined $last->{out} && length $last->{out}) {
        $r .= "\nCommand Output (stdout):\n--\n" . $last->{out};
        $r .= "\n" unless $last->{out} =~ /\n$/;
        $r .= "--\n";
    }
    if (defined $last->{err} && length $last->{err}) {
        $r .= "\nCommand Output (stderr):\n--\n" . $last->{err};
        $r .= "\n" unless $last->{err} =~ /\n$/;
        $r .= "--\n";
    }
    return $r;
}

1;

__END__

=head1 NAME

Lit::TestRunner - test file directives and RUN: line substitutions

=head1 DESCRIPTION

Implements the ShTest format: read a test file's directives, apply
substitutions, and execute the result with the internal shell.

Directives are recognised anywhere in a line, so they sit inside whatever
comment syntax the file already uses - C<; RUN:>, C<// RUN:>, C<! RUN:>
and C<* RUN:> all work.

=head1 DIRECTIVES

=over 4

=item RUN: I<command>

A command to run.  The test fails at the first C<RUN:> line that exits
non-zero.  A line ending in a backslash continues onto the next C<RUN:>
line:

    ; RUN: prog --a-long-option \
    ; RUN:      --another | FileCheck %s

State set by one C<RUN:> line persists into the next, so C<cd> and
C<export> behave as they would in a script.  Each test runs with its
working directory set to its own F<Output> directory.

=item REQUIRES: I<expr>

Skip the test unless the expression is true.

=item UNSUPPORTED: I<expr>

Skip the test if the expression is true.

=item XFAIL: I<expr>

The test is expected to fail.  C<XFAIL: *> always applies.  A test marked
C<XFAIL> that passes anyway is reported as C<XPASS>, so the marker cannot
rot unnoticed.

=item ALLOW_RETRIES: I<n>

Retry a failing test up to I<n> times before believing it.  A test that
only passes on a retry is reported as C<FLAKYPASS>.

=item DEFINE: %{name} = I<value>

=item REDEFINE: %{name} = I<value>

Define a substitution for the C<RUN:> lines that follow.  C<REDEFINE>
replaces an existing definition rather than shadowing it.

=item END.

Stop scanning the file here.

See L<Lit::BoolExpr> for the expression language.

=back

=head1 SUBSTITUTIONS

=over 4

=item %s, %S, %p

The test file, its directory, and its directory again (C<%p> is an alias
for C<%S>).

=item %t, %T

A scratch file base unique to this test, and the scratch directory.  Files
matching C<%t*> are removed before each run, so a test cannot be fooled by
its own leftovers.

=item %basename_s, %basename_t

=item %{pathsep}

C<:> or C<;>.

=item %%

A literal percent sign.

=back

As with lit on Windows, C<%s> and friends give the host's B<native> path
syntax while C<%/s> gives the forward-slash form.  On OpenVMS that is the
difference between F<DISK:[DIR]FILE.EXT> and F</disk/dir/file.ext> - use
C<%s> when handing a path to a native tool, and C<%/s> inside a builtin.

Substitutions from the config file are applied before the built-in set,
and the whole list runs to a fixed point, so a C<DEFINE:> may refer to
C<%t> and a config substitution may refer to another.

=head1 SEE ALSO

L<Lit>, L<Lit::Config>, L<Lit::BoolExpr>, L<Lit::ShLex>

=cut
