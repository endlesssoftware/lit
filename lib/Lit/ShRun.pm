package Lit::ShRun;

# Executes the command lists produced by Lit::ShLex.
#
# Pipelines are staged through temporary files rather than real pipes.  That
# costs a little I/O, but it works identically on hosts with no usable
# fork() (OpenVMS) and it cannot deadlock, which matters because a test
# script is always a finite, non-interactive computation.

use strict;
use warnings;

require 5.006;

use Lit::Compat ();
use Lit::ShLex ();
use Lit::Builtins ();

use vars qw($VERSION);
$VERSION = '0.01';

# ---------------------------------------------------------------------------
# run_list(\@list, \%shell, \%opt) -> \%result
#
#   %shell   { cwd => $dir, env => \%env }         mutated by cd/export
#   %opt     out_file      path collecting unredirected stdout (appended)
#            err_file      path collecting unredirected stderr (appended)
#            pipefail      pipeline fails if any stage fails (default on)
#            deadline      absolute time after which we give up
#
#   %result  { code, timedout, error }
# ---------------------------------------------------------------------------

sub run_list {
    my ($list, $shell, $opt) = @_;
    my $code = 0;

    foreach my $item (@$list) {
        my $sep = $item->{sep};
        if (defined $sep) {
            next if $sep eq '&&' && $code != 0;
            next if $sep eq '||' && $code == 0;
        }
        my $r = run_pipeline($item->{pipeline}, $shell, $opt);
        return $r if $r->{timedout} || defined $r->{error};
        $code = $r->{code};
    }
    return { code => $code, timedout => 0, error => undef };
}

sub run_pipeline {
    my ($pipeline, $shell, $opt) = @_;

    my $n = scalar @$pipeline;
    my @pipe_files;
    for (my $i = 0; $i < $n - 1; $i++) {
        push @pipe_files, Lit::Compat::temp_file_auto('litpipe');
    }

    my $last_code = 0;
    my $fail_code = 0;

    for (my $i = 0; $i < $n; $i++) {
        my $cmd = $pipeline->[$i];

        my ($argv, $gerr) = _expand_argv($cmd, $shell);
        return { code => 127, timedout => 0, error => $gerr } if defined $gerr;
        next unless @$argv;

        my ($fd, $rerr) = _resolve_redirs($cmd, $shell, $opt,
                                          ($i > 0 ? $pipe_files[$i - 1] : undef),
                                          ($i < $n - 1 ? $pipe_files[$i] : undef));
        return { code => 127, timedout => 0, error => $rerr } if defined $rerr;

        my $r = _dispatch($argv, $fd, $shell, $opt);
        return $r if $r->{timedout} || defined $r->{error};

        my $code = $r->{code};
        $code = ($code == 0) ? 1 : 0 if $cmd->{negate};

        $last_code = $code;
        $fail_code = $code if $code != 0;
    }

    my $pipefail = exists $opt->{pipefail} ? $opt->{pipefail} : 1;
    my $code = $pipefail ? ($fail_code ? $fail_code : $last_code) : $last_code;
    unlink @pipe_files;
    return { code => $code, timedout => 0, error => undef };
}

# --------------------------------------------------------------- word expansion

sub _expand_argv {
    my ($cmd, $shell) = @_;
    my @out;
    foreach my $w (@{ $cmd->{argv} }) {
        my ($text, $quoted) = @$w;
        if (!$quoted && Lit::Compat::is_glob($text)) {
            my @g = Lit::Compat::glob_expand($text, $shell->{cwd});
            push @out, @g;
        } else {
            push @out, $text;
        }
    }
    return (\@out, undef);
}

# ---------------------------------------------------------------- redirection
#
# Redirections are applied left to right, exactly as a shell does, so that
# "> out 2>&1" and "2>&1 > out" differ in the usual way.  Each descriptor is
# modelled as a file plus an append flag; "2>&1" copies fd 1's *current*
# descriptor into fd 2.

sub _resolve_redirs {
    my ($cmd, $shell, $opt, $pipe_in, $pipe_out) = @_;

    my %fd = (
        0 => { file => $pipe_in, append => 0 },
        1 => { file => (defined $pipe_out ? $pipe_out : $opt->{out_file}),
               append => (defined $pipe_out ? 0 : 1) },
        2 => { file => $opt->{err_file}, append => 1 },
    );

    foreach my $r (@{ $cmd->{redirs} }) {
        my $fd = $r->{fd};
        if ($r->{mode} eq 'dup') {
            my $t = $r->{target};
            if ($t eq '-') { $fd{$fd} = { file => undef, append => 0 }; next }
            return (undef, "cannot duplicate fd $t") unless exists $fd{ 0 + $t };
            $fd{$fd} = { %{ $fd{ 0 + $t } } };
            next;
        }
        my $path = $r->{target};
        $path = Lit::Compat::clean_path(Lit::Compat::joinp($shell->{cwd}, $path))
            unless Lit::Compat::is_absolute($path) || _is_device($path);
        if ($r->{mode} eq '<') {
            return (undef, "cannot open '$r->{target}' for reading: no such file")
                unless -e $path || _is_device($path);
            $fd{$fd} = { file => $path, append => 0, read => 1 };
        } else {
            $fd{$fd} = { file => $path, append => ($r->{mode} eq '>>' ? 1 : 0) };
            # A fresh '>' truncates once, here, so that repeated writes by a
            # pipeline stage do not clobber each other.
            if ($r->{mode} eq '>' && !_is_device($path)) {
                Lit::Compat::write_file($path, '');
                $fd{$fd}{append} = 1;
            }
        }
    }

    return (\%fd, undef);
}

sub _is_device {
    my ($p) = @_;
    return 1 if $p eq '/dev/null' || uc($p) eq 'NUL';
    return 1 if $p =~ /^NLA0:/i;
    return 0;
}

# ------------------------------------------------------------------ dispatch

sub _dispatch {
    my ($argv, $fd, $shell, $opt) = @_;

    my $name = $argv->[0];
    my $builtin = Lit::Builtins::lookup($name);

    if ($builtin) { return _run_builtin($builtin, $argv, $fd, $shell, $opt) }
    return _run_external($argv, $fd, $shell, $opt);
}

sub _run_builtin {
    my ($builtin, $argv, $fd, $shell, $opt) = @_;

    my ($in, $out, $err);
    my @close;
    my $merged = 0;

    if (defined $fd->{0}{file}) {
        unless (open($in, '<', $fd->{0}{file})) {
            return { code => 1, timedout => 0,
                     error => "cannot open $fd->{0}{file}: $!" };
        }
    } else {
        open($in, '<', Lit::Compat::null_device()) or $in = undef;
    }
    push @close, $in if $in;

    ($out, my $e1) = _open_sink($fd->{1});
    return { code => 1, timedout => 0, error => $e1 } if defined $e1;
    push @close, $out;

    if (defined $fd->{2}{file} && defined $fd->{1}{file}
        && $fd->{2}{file} eq $fd->{1}{file}) {
        $err = $out;
        $merged = 1;
    } else {
        ($err, my $e2) = _open_sink($fd->{2});
        return { code => 1, timedout => 0, error => $e2 } if defined $e2;
        push @close, $err;
    }

    my $old = select($out); $| = 1; select($err); $| = 1; select($old);

    my $ctx;
    $ctx = {
        in    => $in,
        out   => $out,
        err   => $err,
        fd    => $fd,
        shell => $shell,
        exec  => sub {
            my ($nested_argv, $nested_ctx) = @_;

            # Release our own handles on the redirection targets first.  The
            # nested command opens the same files, and OpenVMS RMS will not
            # grant a second write accessor by default: the nested open
            # simply fails, and a wrapper like "not" then inverts an error
            # rather than the command's real status.
            foreach my $h (@close) { close($h) if $h }
            @close = ();

            my $nshell = $nested_ctx->{shell};
            my $r = _dispatch($nested_argv, $nested_ctx->{fd}, $nshell, $opt);
            return $r->{code};
        },
    };

    my $code = eval { $builtin->($argv, $ctx) };
    if ($@) {
        my $msg = $@;
        $msg =~ s/\s+$//;
        print { $err } "$argv->[0]: internal error: $msg\n";
        $code = 1;
    }
    $code = 0 unless defined $code;

    foreach my $h (@close) { close($h) if $h }
    return { code => $code, timedout => 0, error => undef };
}

sub _open_sink {
    my ($spec) = @_;
    my $fh;
    my $file = defined $spec->{file} ? $spec->{file} : Lit::Compat::null_device();
    my $mode = $spec->{append} ? '>>' : '>';
    unless (open($fh, $mode, $file)) {
        return (undef, "cannot open $file for writing: $!");
    }
    return ($fh, undef);
}

sub _run_external {
    my ($argv, $fd, $shell, $opt) = @_;

    my @a = @$argv;
    my $prog = $a[0];

    unless (Lit::Compat::is_absolute($prog) || $prog =~ m{[/\\]}) {
        my $found = Lit::Compat::which($prog, $shell->{env});
        $a[0] = $found if defined $found;
    }

    my $merge = (defined $fd->{2}{file} && defined $fd->{1}{file}
                 && $fd->{2}{file} eq $fd->{1}{file}) ? 1 : 0;

    my $timeout = 0;
    if (defined $opt->{deadline}) {
        $timeout = $opt->{deadline} - Lit::Compat::now();
        if ($timeout <= 0) {
            return { code => 1, timedout => 1, error => undef };
        }
        $timeout = int($timeout) + 1;
    }

    my ($code, $timedout, $error) = Lit::Compat::spawn({
        argv       => \@a,
        stdin      => $fd->{0}{file},
        stdout     => $fd->{1}{file},
        stderr     => ($merge ? '&1' : $fd->{2}{file}),
        append_out => $fd->{1}{append},
        append_err => $fd->{2}{append},
        cwd        => $shell->{cwd},
        env        => $shell->{env},
        timeout    => $timeout,
    });

    return { code => $code, timedout => $timedout, error => $error };
}

# ---------------------------------------------------------------------------
# Convenience wrapper: parse and run one command line.
# ---------------------------------------------------------------------------

sub run_line {
    my ($line, $shell, $opt) = @_;
    my ($list, $err) = Lit::ShLex::parse($line);
    return { code => 127, timedout => 0, error => $err } if defined $err;
    return { code => 0, timedout => 0, error => undef } unless @$list;
    return run_list($list, $shell, $opt);
}

1;

__END__

=head1 NAME

Lit::ShRun - how a RUN: line is executed

=head1 DESCRIPTION

Executes the command lists produced by L<Lit::ShLex>.

=head1 EXECUTION MODEL

=over 4

=item Pipelines run through temporary files

Each stage writes a scratch file that the next stage reads, rather than a
real pipe.  That costs a little I/O, but it works identically on hosts
with no usable C<fork()>, and it cannot deadlock - which is safe here
because a test script is always a finite, non-interactive computation.

=item Redirections are applied left to right

Exactly as a shell does, so C<< >out 2>&1 >> and C<< 2>&1 >out >> differ in
the usual way: the first sends both streams to F<out>, the second sends
stderr where stdout was going originally and only stdout to F<out>.

Each descriptor is modelled as a file plus an append flag, and C<< 2>&1 >>
copies fd 1's I<current> descriptor into fd 2.  When both end up on the
same file they share one handle, so the interleaving is right.

=item Pipelines fail if any stage fails

C<pipefail> semantics, on by default; C<< $config->pipefail(0) >> reports
only the last stage's status.

=item A builtin is preferred over an external program of the same name

So C<FileCheck>, C<diff> and the rest are answered in-process even when a
native executable exists.

=back

=head1 SPAWNING

External commands are run without any shell, by one of three backends
chosen by the host - see L<Lit::Compat/SPAWNING>.  Redirections are set up
by us in every case, which is what makes the same C<RUN:> line behave the
same under F</bin/sh>, DCL and C<cmd.exe>.

=head1 SEE ALSO

L<Lit>, L<Lit::ShLex>, L<Lit::Builtins>, L<Lit::Compat>

=cut
