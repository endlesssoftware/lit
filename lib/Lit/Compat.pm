package Lit::Compat;

# Portability layer for lit.pl / filecheck.pl.
#
# Deliberately written to Perl 5.6 rules: no //, no say, no state, no named
# captures, no post-5.8 core modules.  OpenVMS VAX is a supported host and its
# newest Perl is 5.8.x.
#
# Paths are held in Unix syntax everywhere inside the tools.  Perl's CRTL on
# VMS accepts Unix paths in open()/opendir()/stat(), so the only place a
# conversion is needed is when a filename is handed to a foreign command.

use strict;
use warnings;

require 5.006;

use Config ();
use File::Path ();
use Cwd ();

use vars qw($VERSION);
$VERSION = '0.01';

use constant IS_VMS => ($^O eq 'VMS');
use constant IS_WIN => ($^O eq 'MSWin32' || $^O eq 'os2' || $^O eq 'dos');

# ---------------------------------------------------------------- capabilities

my $HAVE_FILESPEC = 0;
if (IS_VMS) {
    eval { require VMS::Filespec; $HAVE_FILESPEC = 1; 1 };
}

my $HAVE_HIRES = 0;
eval { require Time::HiRes; $HAVE_HIRES = 1; 1 };

my $HAVE_FORK = 0;
if (!IS_VMS && $Config::Config{d_fork}) {
    $HAVE_FORK = 1;
}

sub have_fork  { return $HAVE_FORK }
sub have_hires { return $HAVE_HIRES }

sub now {
    return $HAVE_HIRES ? Time::HiRes::time() : time();
}

# --------------------------------------------------------------------- paths

# Convert a possibly-native path into the Unix syntax used internally.
sub to_unix {
    my ($p) = @_;
    return $p if !defined $p || $p eq '';
    if (IS_VMS && $HAVE_FILESPEC) {
        my $u;
        eval { $u = VMS::Filespec::unixify($p); 1 };
        return defined($u) && length($u) ? $u : $p;
    }
    if (IS_WIN) { $p =~ s{\\}{/}g }
    return $p;
}

# Convert an internal Unix path into what the host's command interpreter wants.
sub to_native {
    my ($p) = @_;
    return $p if !defined $p || $p eq '';
    if (IS_VMS && $HAVE_FILESPEC) {
        my $v;
        eval { $v = VMS::Filespec::vmsify($p); 1 };
        return defined($v) && length($v) ? $v : $p;
    }
    return $p;
}

sub to_native_dir {
    my ($p) = @_;
    return $p if !defined $p || $p eq '';
    if (IS_VMS && $HAVE_FILESPEC) {
        my $v;
        eval { $v = VMS::Filespec::vmspath($p); 1 };
        return defined($v) && length($v) ? $v : $p;
    }
    return $p;
}

# Join path components in Unix syntax, collapsing redundant separators.
sub joinp {
    my @parts = grep { defined && length } @_;
    return '' unless @parts;
    my $head = shift @parts;
    $head =~ s{/+$}{} unless $head eq '/';
    my $out = $head;
    foreach my $p (@parts) {
        my $q = $p;
        $q =~ s{^/+}{};
        $q =~ s{/+$}{};
        next unless length $q;
        $out .= ($out =~ m{/$} ? '' : '/') . $q;
    }
    return $out;
}

sub is_absolute {
    my ($p) = @_;
    return 0 unless defined $p && length $p;
    return 1 if $p =~ m{^/};
    return 1 if IS_WIN && $p =~ m{^[A-Za-z]:};
    return 1 if IS_VMS && $p =~ m{[:\[]};
    return 0;
}

sub abs_path {
    my ($p, $base) = @_;
    return $p if is_absolute($p);
    $base = getcwd() unless defined $base;
    return joinp($base, $p);
}

sub getcwd {
    my $d = Cwd::getcwd();
    $d = Cwd::cwd() unless defined $d;
    return to_unix($d);
}

sub dirname_of {
    my ($p) = @_;
    $p =~ s{/+$}{};
    return '.' unless $p =~ m{/};
    $p =~ s{/[^/]*$}{};
    return length($p) ? $p : '/';
}

sub basename_of {
    my ($p) = @_;
    $p =~ s{/+$}{};
    $p =~ s{^.*/}{};
    return $p;
}

# Normalise "a/./b", "a/b/../c" without touching the filesystem.
sub clean_path {
    my ($p) = @_;
    return $p unless defined $p;
    my $lead = ($p =~ m{^/}) ? '/' : '';
    my @out;
    foreach my $seg (split m{/+}, $p) {
        next if $seg eq '' || $seg eq '.';
        if ($seg eq '..' && @out && $out[-1] ne '..') { pop @out; next }
        push @out, $seg;
    }
    my $r = $lead . join('/', @out);
    return length($r) ? $r : ($lead ? '/' : '.');
}

sub mkpath  { my ($d) = @_; File::Path::mkpath($d); return -d $d }
sub rmtree  { my ($d) = @_; return unless -e $d; eval { File::Path::rmtree($d); 1 } }

# ------------------------------------------------------------------- file I/O

sub read_file {
    my ($path) = @_;
    local *FH;
    open(FH, '<', $path) or return undef;
    binmode(FH) unless IS_VMS;
    local $/ = undef;
    my $data = <FH>;
    close(FH);
    $data = '' unless defined $data;
    return $data;
}

sub write_file {
    my ($path, $data) = @_;
    local *FH;
    open(FH, '>', $path) or return 0;
    binmode(FH) unless IS_VMS;
    print FH $data;
    close(FH) or return 0;
    return 1;
}

# --------------------------------------------------------------- temp files

my $TMP_SEQ = 0;
my $TMP_ROOT;

sub temp_root {
    return $TMP_ROOT if defined $TMP_ROOT;
    my $d;
    if (IS_VMS) {
        $d = defined $ENV{'SYS$SCRATCH'} ? to_unix($ENV{'SYS$SCRATCH'}) : undef;
        $d = to_unix('SYS$SCRATCH:') unless defined $d && length $d;
    } else {
        foreach my $k (qw(TMPDIR TEMP TMP)) {
            if (defined $ENV{$k} && length $ENV{$k} && -d $ENV{$k}) { $d = $ENV{$k}; last }
        }
        $d = '/tmp' unless defined $d;
    }
    $d =~ s{/+$}{};
    $TMP_ROOT = $d;
    return $TMP_ROOT;
}

# Short, ODS-2 legal temp names: at most one dot, <= 39 characters.
sub temp_file {
    my ($tag, $dir) = @_;
    $tag = 'lit' unless defined $tag && length $tag;
    $tag =~ s/[^A-Za-z0-9_]/_/g;
    $tag = substr($tag, 0, 12);
    $dir = temp_root() unless defined $dir && length $dir;
    $TMP_SEQ++;
    return joinp($dir, sprintf('%s_%d_%d.tmp', $tag, $$ % 100000, $TMP_SEQ));
}

my @CLEANUP;
sub temp_file_auto {
    my $f = temp_file(@_);
    push @CLEANUP, $f;
    return $f;
}
sub cleanup_temps {
    foreach my $f (@CLEANUP) { unlink $f if defined $f && -e $f }
    @CLEANUP = ();
}
END { cleanup_temps() }

# --------------------------------------------------------------- exit status

# Turn Perl's $? into a plain small integer exit code.
#
# On VMS a child's exit status is a VMS condition value.  When the child is
# itself a Perl (or any CRTL) program built with POSIX exit enabled, the
# POSIX code is encoded in bits <3:10> of a 0x35A000-based status.  Decode
# that when we recognise it; otherwise fall back to severity: even severity
# (WARNING/ERROR/FATAL) means failure, odd (SUCCESS/INFO) means success.
sub exit_code_from_status {
    my ($status) = @_;
    return 0 unless defined $status;
    if ($status == -1) { return 127 }

    if (IS_VMS) {
        my $native = $status;
        # ${^CHILD_ERROR_NATIVE} is more faithful when available.
        {
            no strict 'refs';
            my $n = eval { ${^CHILD_ERROR_NATIVE} };
            $native = $n if defined $n && $n != 0;
        }
        if (($native & 0xFFF0000) == 0x35A0000) {
            my $code = ($native & 0x7F8) >> 3;
            return $code;
        }
        my $severity = $native & 7;
        return 0 if ($severity == 1 || $severity == 3);   # SUCCESS / INFO
        my $code = ($status >> 8) & 0xFF;
        return $code ? $code : 1;
    }

    if ($status & 127) {                   # died on a signal
        return 128 + ($status & 127);
    }
    return ($status >> 8) & 0xFF;
}

# Encode our own exit code so the host shell sees the right thing.
sub exit_with {
    my ($code) = @_;
    cleanup_temps();
    $code = 0 unless defined $code;
    $code = 0 + $code;
    $code = 255 if $code > 255;
    $code = 1   if $code < 0;
    exit($code);
}

# ----------------------------------------------------------------- searching

sub path_sep { return IS_WIN ? ';' : ':' }

sub which {
    my ($prog, $env) = @_;
    return undef unless defined $prog && length $prog;
    $env = \%ENV unless defined $env;
    if ($prog =~ m{[/\\]} || (IS_VMS && $prog =~ m{[:\[]})) {
        return (-f $prog || -x $prog) ? $prog : undef;
    }
    my $path = defined $env->{PATH} ? $env->{PATH} : '';
    my @dirs = split(/\Q${\ path_sep() }\E/, $path);
    my @exts = ('');
    if (IS_WIN) { @exts = ('', '.exe', '.com', '.bat', '.cmd') }
    if (IS_VMS) { @exts = ('', '.exe', '.com') }
    foreach my $d (@dirs) {
        next unless length $d;
        foreach my $e (@exts) {
            my $cand = joinp(to_unix($d), $prog . $e);
            return $cand if -f $cand;
        }
    }
    return undef;
}

# ------------------------------------------------------------------ globbing

# Does this word need globbing at all?
#
# The Unix set cannot be used on OpenVMS: '[' and ']' delimit the directory
# of every absolute VMS path, so treating them as the start of a character
# class turns $5$DKA0:[SYS0.SYSCOMMON.perl-5_34]perl.exe into a regex with
# an invalid "l-5" range.  On VMS only '*' marks a pattern here.  VMS also
# has '%' as a single-character wildcard, but a bare '%' is common enough in
# ordinary text that treating it as one causes more surprises than it cures.
sub is_glob {
    my ($w) = @_;
    return 0 unless defined $w && length $w;
    return (index($w, '*') >= 0) ? 1 : 0 if IS_VMS;
    return ($w =~ /[*?\[]/) ? 1 : 0;
}

# Portable glob.  Perl's built-in glob() shells out or behaves differently
# per platform, so walk the directories ourselves.
sub glob_expand {
    my ($pattern, $cwd) = @_;
    return ($pattern) unless is_glob($pattern);

    # On OpenVMS, match in Unix syntax.  The walker below splits on '/',
    # which a VMS file spec has none of, and would read its brackets as a
    # character class.  Perl's CRTL is happy to opendir() a Unix path there.
    if (IS_VMS) {
        my @hits = eval {
            my $upat = to_unix($pattern);
            my $ucwd = defined $cwd ? to_unix($cwd) : undef;
            my @u = _glob_unix($upat, $ucwd);
            return ($pattern) if @u == 1 && $u[0] eq $upat;   # no match
            map { to_native($_) } @u;
        };
        return ($pattern) if $@ || !@hits;
        return @hits;
    }

    return _glob_unix($pattern, $cwd);
}

sub _glob_unix {
    my ($pattern, $cwd) = @_;
    my $abs = is_absolute($pattern);
    my $work = $abs ? $pattern : joinp((defined $cwd ? $cwd : '.'), $pattern);

    my @segs = split m{/+}, $work;
    my $lead = ($work =~ m{^/}) ? '/' : '';
    shift @segs while @segs && $segs[0] eq '';

    my @cur = ($lead eq '/' ? '/' : '.');
    my $first = 1;
    foreach my $seg (@segs) {
        my @next;
        if ($seg !~ /[*?\[]/) {
            foreach my $d (@cur) { push @next, joinp($d, $seg) }
            @cur = @next;
            $first = 0;
            next;
        }
        my $re = _glob_to_re($seg);
        foreach my $d (@cur) {
            local *DH;
            opendir(DH, $d) or next;
            my @ents = sort grep { $_ ne '.' && $_ ne '..' } readdir(DH);
            closedir(DH);
            foreach my $e (@ents) {
                next if $e =~ /^\./ && $seg !~ /^\./;
                push @next, joinp($d, $e) if $e =~ $re;
            }
        }
        @cur = @next;
        $first = 0;
    }

    my @hits = grep { -e $_ } @cur;
    return ($pattern) unless @hits;

    unless ($abs) {
        my $base = defined $cwd ? $cwd : '.';
        $base =~ s{/+$}{};
        foreach my $h (@hits) { $h =~ s{^\Q$base\E/}{} }
    }
    return sort @hits;
}

sub _glob_to_re {
    my ($g) = @_;
    my $re = '';
    my @c = split //, $g;
    my $i = 0;
    while ($i < @c) {
        my $ch = $c[$i];
        if ($ch eq '*')    { $re .= '[^/]*' }
        elsif ($ch eq '?') { $re .= '[^/]' }
        elsif ($ch eq '[') {
            my $j = $i + 1;
            my $cls = '';
            $cls .= '^' , $j++ if $j < @c && ($c[$j] eq '!' || $c[$j] eq '^');
            while ($j < @c && $c[$j] ne ']') { $cls .= $c[$j]; $j++ }
            if ($j < @c) { $re .= '[' . $cls . ']'; $i = $j }
            else         { $re .= '\[' }
        }
        else { $re .= quotemeta($ch) }
        $i++;
    }
    my $ci = (IS_VMS || IS_WIN) ? '(?i)' : '';

    # A bracket run that is not a valid character class - "[SYS0.PERL-5_34]"
    # and its "l-5" range, say - must not take the process down.  Fall back
    # to matching the segment literally, which simply means it expands to
    # itself.
    my $qr = eval { qr/^$ci$re$/ };
    return $qr if $qr;
    $qr = eval { qr/^$ci\Q$g\E$/ };
    return $qr if $qr;
    return qr/(?!)/;
}

# ------------------------------------------------------------------ spawning
#
# spawn(\%job) -> ($exit_code, $timed_out, $error)
#
#   argv        arrayref, already word-split (no shell involved)
#   stdin       path, or undef for the null device
#   stdout      path, or undef for the null device
#   stderr      path, or the string '&1' to merge into stdout, or undef
#   append_out  append rather than truncate stdout
#   append_err  likewise for stderr
#   cwd         working directory (Unix syntax)
#   env         hashref replacing the environment
#   timeout     seconds; 0/undef for none (not honoured on VMS)
#
# There is no shell anywhere in this path: redirection is set up by us, so
# the same RUN lines behave identically under sh, DCL and cmd.exe.

sub null_device {
    return 'NLA0:' if IS_VMS;
    return 'NUL'   if IS_WIN;
    return '/dev/null';
}

sub spawn {
    my ($job) = @_;

    # A 'dcl' job carries raw DCL lines rather than an argv, and only the
    # OpenVMS backend can run one.
    if ($job->{dcl}) {
        return (127, 0, 'no DCL command given') unless @{ $job->{dcl} };
        return (127, 0, "DCL commands need OpenVMS; this host is $^O")
            unless IS_VMS;
        return _spawn_dcl($job);
    }

    return (127, 0, 'no command given') unless $job->{argv} && @{ $job->{argv} };
    return _spawn_fork($job) if $HAVE_FORK;
    return _spawn_dcl($job)  if IS_VMS;
    return _spawn_system($job);
}

# ---- POSIX backend -------------------------------------------------------

sub _spawn_fork {
    my ($job) = @_;
    my @argv = @{ $job->{argv} };

    my $pid = fork();
    return (127, 0, "fork failed: $!") unless defined $pid;

    if ($pid == 0) {
        # ---- child
        eval { setpgrp(0, 0); 1 };
        if (defined $job->{cwd} && !chdir($job->{cwd})) {
            print STDERR "cannot chdir to $job->{cwd}: $!\n";
            _child_exit(127);
        }
        if ($job->{env}) { %ENV = %{ $job->{env} } }

        my $in = defined $job->{stdin} ? $job->{stdin} : null_device();
        unless (open(STDIN, '<', $in)) {
            print STDERR "cannot open $in for reading: $!\n";
            _child_exit(127);
        }
        my $out = defined $job->{stdout} ? $job->{stdout} : null_device();
        my $omode = $job->{append_out} ? '>>' : '>';
        unless (open(STDOUT, $omode, $out)) {
            print STDERR "cannot open $out for writing: $!\n";
            _child_exit(127);
        }
        if (defined $job->{stderr} && $job->{stderr} eq '&1') {
            open(STDERR, '>&', \*STDOUT);
        } else {
            my $e = defined $job->{stderr} ? $job->{stderr} : null_device();
            my $emode = $job->{append_err} ? '>>' : '>';
            unless (open(STDERR, $emode, $e)) { _child_exit(127) }
        }
        select(STDOUT); $| = 1;

        { exec { $argv[0] } @argv; }
        print STDERR "cannot execute '$argv[0]': $!\n";
        _child_exit(127);
    }

    # ---- parent
    my $timeout  = $job->{timeout};
    my $timedout = 0;
    my $status;

    if ($timeout && $timeout > 0) {
        eval {
            local $SIG{ALRM} = sub { die "lit-timeout\n" };
            alarm($timeout);
            waitpid($pid, 0);
            $status = $?;
            alarm(0);
            1;
        };
        if ($@) {
            alarm(0);
            $timedout = 1;
            kill('TERM', -$pid) or kill('TERM', $pid);
            my $waited = 0;
            while ($waited < 20) {
                last if waitpid($pid, 1) == $pid;    # WNOHANG
                select(undef, undef, undef, 0.1);
                $waited++;
            }
            kill('KILL', -$pid) or kill('KILL', $pid);
            waitpid($pid, 0);
            $status = $?;
        }
    } else {
        waitpid($pid, 0);
        $status = $?;
    }

    return (exit_code_from_status($status), $timedout, undef);
}

sub _child_exit {
    my ($code) = @_;
    eval { require POSIX; POSIX::_exit($code); 1 } or CORE::exit($code);
}

# ---- OpenVMS backend -----------------------------------------------------
#
# VMS has no usable fork() and DCL has no redirection operators, so build a
# throw-away command procedure that uses DEFINE/USER to point SYS$INPUT,
# SYS$OUTPUT and SYS$ERROR at the right files, then @-invoke it.
#
# Output always goes to a scratch file which we then copy or append into
# place: DCL creates a new file version rather than truncating, and there is
# no append mode for SYS$OUTPUT at all.

# Build the text of the throw-away command procedure the DCL backend runs.
#
# Factored out of _spawn_dcl so it can be unit tested anywhere: this is the
# one part of the OpenVMS path that does not itself need OpenVMS to check.
#
# Redirection differs between the two job shapes, and the difference
# matters.  DEFINE/USER lasts only until the next image exits, which is
# exactly right for a single command; a multi-line DCL fragment would lose
# the redirection after its first image, so those get a process-level
# DEFINE and an explicit DEASSIGN before the exit.
sub build_dcl_procedure {
    my ($job, $out_tmp, $err_tmp) = @_;

    my $merge   = (defined $job->{stderr} && $job->{stderr} eq '&1') ? 1 : 0;
    my $verbatim = $job->{dcl} ? 1 : 0;
    my $qual    = $verbatim ? '/NOLOG' : '/USER/NOLOG';

    my @dcl;
    push @dcl, '$ __lit_def = F$ENVIRONMENT("DEFAULT")';

    # Stop at the first failure and report it, rather than letting SET NOON
    # swallow it while later commands run against a broken state - a failed
    # SET DEFAULT followed by a build that then "succeeds" in the wrong
    # directory is the case that matters.
    #
    # The threshold is WARNING, not ERROR, because that is exactly what
    # exit_code_from_status() treats as failure: odd VMS severities
    # (SUCCESS, INFO) succeed, even ones (WARNING, ERROR, FATAL) do not.
    # Anything we would report as a non-zero exit therefore also ends the
    # sequence.
    #
    # A fragment that wants the older behaviour can say so in its own DCL,
    # since these lines are passed through verbatim:
    #     dcl 'ON WARNING THEN CONTINUE' '...'
    push @dcl, '$ ON WARNING THEN GOTO __lit_done';

    if (defined $job->{cwd}) {
        push @dcl, '$ SET DEFAULT ' . to_native_dir($job->{cwd});
    }

    my $in = defined $job->{stdin} ? to_native($job->{stdin}) : 'NLA0:';
    push @dcl, '$ DEFINE' . $qual . ' SYS$INPUT ' . $in;
    push @dcl, '$ DEFINE' . $qual . ' SYS$OUTPUT ' . to_native($out_tmp);
    if ($merge) {
        push @dcl, '$ DEFINE' . $qual . ' SYS$ERROR SYS$OUTPUT';
    } else {
        push @dcl, '$ DEFINE' . $qual . ' SYS$ERROR ' . to_native($err_tmp);
    }

    if ($verbatim) {
        push @dcl, @{ _dcl_verbatim($job->{dcl}) };
    } else {
        my ($verb, @rest) = _dcl_verb($job->{argv}, $job->{env});
        push @dcl, @{ _dcl_command($verb, \@rest) };
    }

    # Cleanup runs whether we fell through or jumped here.  $STATUS must be
    # captured before anything else: SET NOON would overwrite it.
    push @dcl, '$ __lit_done:';
    push @dcl, '$ __lit_sts = $STATUS';
    # Once an ON action fires, DCL reverts to the default (exit on error),
    # so cleanup could otherwise be cut short by a tidy-up command that
    # fails - a DEASSIGN of something we never got as far as defining.
    push @dcl, '$ SET NOON';
    if ($verbatim) {
        push @dcl, '$ DEASSIGN SYS$INPUT';
        push @dcl, '$ DEASSIGN SYS$OUTPUT';
        push @dcl, '$ DEASSIGN SYS$ERROR' unless $merge;
    }
    push @dcl, '$ SET DEFAULT \'__lit_def\'';
    push @dcl, '$ EXIT __lit_sts';

    return join("\n", @dcl) . "\n";
}

# Turn user-written DCL text into procedure records.  Each argument may
# itself hold newlines.  A leading '$' is supplied where DCL needs one, but
# never on a continuation record - one following a line ending in '-' -
# because DCL concatenates those raw.
#
# Long lines are left exactly as written: wrapping them at a guessed space
# could split a quoted string, and the author of a DCL fragment is better
# placed than we are to say where it may break.
sub _dcl_verbatim {
    my ($lines) = @_;
    my @out;
    my $continued = 0;
    foreach my $chunk (@$lines) {
        next unless defined $chunk;
        foreach my $raw (split(/\r?\n/, $chunk, -1)) {
            if (!$continued && $raw !~ /\S/) { next }
            if ($continued) {
                push @out, $raw;
            } else {
                my $l = $raw;
                $l =~ s/^\s+//;
                $l = '$ ' . $l unless $l =~ /^\$/;
                push @out, $l;
            }
            $continued = ($raw =~ /-[ \t]*$/) ? 1 : 0;
        }
    }
    return \@out;
}

# A Unix-looking path reaching DCL is a bug, not a curiosity: "SET DEFAULT
# /work" and "DEFINE SYS$OUTPUT /tmp/x" are not DCL commands.  It means the
# conversion to VMS syntax did not happen - VMS::Filespec unavailable, or a
# path vmspath() could not express - so report that rather than writing a
# procedure which cannot possibly run.
#
# Only the paths that are actually interpolated into the procedure are
# checked.  A job's stdout and stderr are not among them: those are written
# by Perl afterwards, and Perl's CRTL is happy with Unix syntax.
sub dcl_path_problem {
    my ($job, $out_tmp, $err_tmp) = @_;

    my @check;
    push @check, [ 'working directory', $job->{cwd}, to_native_dir($job->{cwd}) ]
        if defined $job->{cwd};
    push @check, [ 'standard input', $job->{stdin}, to_native($job->{stdin}) ]
        if defined $job->{stdin};
    push @check, [ 'scratch file', $out_tmp, to_native($out_tmp) ]
        if defined $out_tmp;
    push @check, [ 'scratch file', $err_tmp, to_native($err_tmp) ]
        if defined $err_tmp;

    foreach my $c (@check) {
        my ($what, $orig, $native) = @$c;
        next unless defined $native && $native =~ m{^/};
        return "cannot express the $what '$orig' in VMS syntax"
             . ($HAVE_FILESPEC ? '' : '; VMS::Filespec is not available');
    }
    return undef;
}

sub _spawn_dcl {
    my ($job) = @_;

    my $com     = temp_file('litcmd');
    my $out_tmp = temp_file('litout');
    my $err_tmp = temp_file('literr');

    my $bad = dcl_path_problem($job, $out_tmp, $err_tmp);
    return (127, 0, $bad) if defined $bad;

    my $merge = (defined $job->{stderr} && $job->{stderr} eq '&1') ? 1 : 0;

    write_file($com, build_dcl_procedure($job, $out_tmp, $err_tmp))
        or return (127, 0, "cannot write command procedure $com");

    my %saved;
    if ($job->{env}) {
        %saved = %ENV;
        %ENV = %{ $job->{env} };
    }
    my $rc = system('@' . to_native($com));
    my $status = $?;
    %ENV = %saved if $job->{env};

    _place_output($out_tmp, $job->{stdout}, $job->{append_out});
    _place_output($err_tmp, ($merge ? undef : $job->{stderr}), $job->{append_err})
        unless $merge;
    unlink $com, $out_tmp, $err_tmp;

    return (exit_code_from_status($status), 0, undef);
}

# Work out how DCL should be told to run argv[0].
sub _dcl_verb {
    my ($argv, $env) = @_;
    my @a = @$argv;
    my $prog = shift @a;
    my $low = lc $prog;

    if ($low =~ /\.com$/) { return ('@' . to_native($prog), @a) }
    if ($low =~ /\.exe$/ || $prog =~ m{[/\[:]}) {
        return ('$' . to_native($prog), @a);
    }
    my $found = which($prog, $env);
    if (defined $found) {
        return ('@' . to_native($found), @a) if $found =~ /\.com$/i;
        return ('$' . to_native($found), @a);
    }
    # Not a file: assume a DCL verb or an already-defined foreign command.
    return ($prog, @a);
}

# Emit the DCL lines that invoke the command, honouring the line-length limit
# by continuing with a trailing hyphen.
sub _dcl_command {
    my ($verb, $args) = @_;
    my @lines;
    my $head;
    my $foreign = ($verb =~ /^[\$\@]/) ? 1 : 0;

    if ($foreign) {
        push @lines, '$ __lit_cmd := ' . $verb;
        $head = '$ __lit_cmd';
    } else {
        $head = '$ ' . $verb;
    }

    my $cur = $head;
    my @out;
    foreach my $a (@$args) {
        # Everything is quoted, because DCL upcases unquoted parameters and
        # test suites depend on case-sensitive file names.  The exception is
        # a qualifier passed to a real DCL verb, which must stay bare.
        my $q = (!$foreign && $a =~ m{^/}) ? $a : _dcl_quote($a);
        if (length($cur) + 1 + length($q) > 200) {
            push @out, $cur . ' -';
            # A continuation record must NOT begin with '$': DCL concatenates
            # the raw next record onto the line ending in '-'.
            $cur = '  ' . $q;
        } else {
            $cur .= ' ' . $q;
        }
    }
    push @out, $cur;
    push @lines, @out;
    return \@lines;
}

# DCL upcases unquoted parameters, so every argument is quoted; embedded
# quotes are doubled.
sub _dcl_quote {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/"/""/g;
    return '"' . $s . '"';
}

sub _place_output {
    my ($tmp, $dest, $append) = @_;
    return unless defined $dest;
    return if $dest eq '&1';
    my $data = read_file($tmp);
    $data = '' unless defined $data;
    if ($append) {
        local *FH;
        if (open(FH, '>>', $dest)) { print FH $data; close(FH) }
    } else {
        write_file($dest, $data);
    }
}

# ---- last-resort backend -------------------------------------------------

sub _spawn_system {
    my ($job) = @_;
    my @argv = @{ $job->{argv} };

    my $out_tmp = temp_file('litout');
    my $err_tmp = temp_file('literr');
    my $merge = (defined $job->{stderr} && $job->{stderr} eq '&1') ? 1 : 0;

    my $cmd = join(' ', map { _sh_quote($_) } @argv);
    $cmd .= ' < ' . _sh_quote(defined $job->{stdin} ? $job->{stdin} : null_device());
    $cmd .= ' > ' . _sh_quote($out_tmp);
    $cmd .= $merge ? ' 2>&1' : ' 2> ' . _sh_quote($err_tmp);

    my %saved;
    my $olddir;
    if ($job->{env}) { %saved = %ENV; %ENV = %{ $job->{env} } }
    if (defined $job->{cwd}) { $olddir = getcwd(); chdir($job->{cwd}) }

    system($cmd);
    my $status = $?;

    chdir($olddir) if defined $olddir;
    %ENV = %saved if $job->{env};

    _place_output($out_tmp, $job->{stdout}, $job->{append_out});
    _place_output($err_tmp, ($merge ? undef : $job->{stderr}), $job->{append_err})
        unless $merge;
    unlink $out_tmp, $err_tmp;

    return (exit_code_from_status($status), 0, undef);
}

sub _sh_quote {
    my ($s) = @_;
    return "''" unless defined $s && length $s;
    return $s if $s =~ m{^[A-Za-z0-9_./:=+-]+$};
    $s =~ s/'/'\\''/g;
    return "'" . $s . "'";
}

1;

__END__

=head1 NAME

Lit::Compat - host portability layer

=head1 DESCRIPTION

Paths, temporary files, exit-status decoding, globbing and process
spawning.  Mostly of interest when changing the code rather than when
using it.

Written to Perl 5.6 rules - no C<//>, C<say>, C<state>, named captures or
post-5.8 core modules - because OpenVMS VAX is a supported host and its
newest Perl is 5.8.

=head1 PATHS

Paths are held in Unix syntax everywhere inside the tools.  Perl's CRTL on
OpenVMS accepts Unix paths in C<open>, C<opendir> and C<stat>, so the only
place a conversion is needed is when a filename is handed to a foreign
command - which is what C<to_native> and C<to_native_dir> are for.

    to_unix($p)        native syntax -> the internal Unix form
    to_native($p)      a file, in whatever the host's interpreter wants
    to_native_dir($p)  likewise for a directory
    joinp(@parts)      join, collapsing redundant separators
    clean_path($p)     resolve . and .. textually
    is_absolute($p)    understands /path, C:\path and DISK:[DIR]

Temporary file names are kept legal on ODS-2: at most one dot, at most 39
characters.

C<to_native> and C<to_native_dir> are identity functions off OpenVMS,
which is worth remembering when reading generated DCL on another host: a
procedure printed on Linux shows F</disk/dir> where OpenVMS would show
F<DISK:[DIR]>.

Because that conversion is the only thing standing between an internal
path and a command procedure, C<dcl_path_problem> checks the paths that
are interpolated into one and refuses a job whose paths did not convert.
C<SET DEFAULT /work> is not a DCL command, and failing with that said
plainly beats writing a procedure that cannot run.

=head1 SPAWNING

C<spawn(\%job)> runs an external command with no shell involved.  A job
carries either an C<argv> to run directly, or - OpenVMS only - a C<dcl>
arrayref of raw DCL lines to place in one command procedure; see
L<Lit::Builtins/THE dcl BUILTIN>.

C<build_dcl_procedure> returns the text of that procedure and is
deliberately separate from running it, so the generated DCL can be checked
on any host.

There are three backends, chosen by the host:

=over 4

=item C<fork>/C<exec>, where a real C<fork()> exists

The child sets its process group so a timeout can kill the whole group,
applies the redirections with C<open> onto the standard handles, and
C<exec>s.

=item DCL, on OpenVMS

There is no usable C<fork()>, and DCL has no redirection operators, so the
backend writes a throw-away command procedure that uses C<DEFINE/USER> to
point C<SYS$INPUT>, C<SYS$OUTPUT> and C<SYS$ERROR> at the right files, then
invokes it.

Output always goes to a scratch file that is then copied or appended into
place, because DCL creates a new file version rather than truncating and
has no append mode for C<SYS$OUTPUT> at all.

Every argument is quoted, since DCL upcases unquoted parameters and test
suites depend on case-sensitive file names; the exception is a qualifier
passed to a real DCL verb, which must stay bare.  Long argument lists are
continued with a trailing hyphen, and the continuation record carries no
C<$> - DCL concatenates the raw next record.

=item C<system()>, as a fallback

=back

All three return a plain small integer exit code.  On OpenVMS that means
decoding a VMS condition value: the POSIX exit code is recovered from a
C<0x35A000>-based status when one is recognised, and otherwise the
severity decides - odd (SUCCESS, INFO) is success, even (WARNING, ERROR,
FATAL) is failure.

=head1 SEE ALSO

L<Lit>, L<Lit::ShRun>

=cut
