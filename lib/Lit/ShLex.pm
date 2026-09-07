package Lit::ShLex;

# Lexer and parser for the subset of POSIX shell syntax that appears in
# RUN: lines.  We never hand a command line to a real shell, because on
# OpenVMS there isn't one -- DCL has neither these operators nor the same
# quoting rules.  Parsing here means RUN lines behave identically on every
# supported host.
#
# Supported:  words with '...', "..." and backslash quoting; the control
# operators | || && ; ! ; and the redirections < > >> N> N>> N>&M &> &>>.
#
# Deliberately unsupported (diagnosed rather than silently mis-run):
# subshells, background &, here-documents, variable expansion, backquotes.

use strict;
use warnings;

require 5.006;

use vars qw($VERSION);
$VERSION = '0.01';

# ------------------------------------------------------------------ tokenize
#
# Returns (\@tokens, undef) or (undef, $error).  Token shapes:
#   ['op',        '|' | '||' | '&&' | ';' | '&' | '(' | ')']
#   ['word',      $text, $was_quoted]
#   ['redir',     $fd, '<' | '>' | '>>']        target is the next word
#   ['redirboth', '>' | '>>']                   target is the next word
#   ['dup',       $fd, $target_fd_or_dash]

sub tokenize {
    my ($line) = @_;
    my @toks;
    my $len = length $line;
    pos($line) = 0;

    while (pos($line) < $len) {
        next if $line =~ /\G[ \t]+/gc;

        if ($line =~ /\G(&&|\|\|)/gc)          { push @toks, ['op', $1]; next }
        if ($line =~ /\G&>>/gc)                { push @toks, ['redirboth', '>>']; next }
        if ($line =~ /\G&>/gc)                 { push @toks, ['redirboth', '>'];  next }
        if ($line =~ /\G([|;()&])/gc)          { push @toks, ['op', $1]; next }

        if ($line =~ /\G([0-9]*)>&[ \t]*([0-9]+|-)(?![0-9])/gc) {
            push @toks, ['dup', (length $1 ? 0 + $1 : 1), $2]; next;
        }
        if ($line =~ /\G([0-9]*)<&[ \t]*([0-9]+|-)(?![0-9])/gc) {
            push @toks, ['dup', (length $1 ? 0 + $1 : 0), $2]; next;
        }
        if ($line =~ /\G([0-9]*)>&/gc)         { push @toks, ['redirboth', '>']; next }
        if ($line =~ /\G([0-9]*)>>/gc)         { push @toks, ['redir', (length $1 ? 0+$1 : 1), '>>']; next }
        if ($line =~ /\G([0-9]*)>/gc)          { push @toks, ['redir', (length $1 ? 0+$1 : 1), '>'];  next }
        if ($line =~ /\G([0-9]*)</gc)          { push @toks, ['redir', (length $1 ? 0+$1 : 0), '<'];  next }

        my ($word, $quoted, $err) = _word(\$line, $len);
        return (undef, $err) if defined $err;
        push @toks, ['word', $word, $quoted];
    }

    return (\@toks, undef);
}

sub _word {
    my ($lref, $len) = @_;
    my $w      = '';
    my $quoted = 0;

    while (pos($$lref) < $len) {
        if ($$lref =~ /\G\\(.)/gcs)          { $w .= $1; $quoted = 1; next }
        if ($$lref =~ /\G\\\z/gc)            { $w .= '\\'; next }

        if ($$lref =~ /\G'/gc) {
            if ($$lref =~ /\G([^']*)'/gcs)   { $w .= $1; $quoted = 1; next }
            return (undef, undef, "unterminated single quote");
        }

        if ($$lref =~ /\G"/gc) {
            my $inner = '';
            my $closed = 0;
            while (pos($$lref) < $len) {
                if ($$lref =~ /\G\\(["\\\$`])/gcs) { $inner .= $1; next }
                if ($$lref =~ /\G"/gc)             { $closed = 1; last }
                if ($$lref =~ /\G([^"\\]+)/gcs)    { $inner .= $1; next }
                if ($$lref =~ /\G(\\)/gc)          { $inner .= $1; next }
                last;
            }
            return (undef, undef, "unterminated double quote") unless $closed;
            $w .= $inner;
            $quoted = 1;
            next;
        }

        last if $$lref =~ /\G(?=[ \t|&;()<>])/gc;
        if ($$lref =~ /\G([^ \t|&;()<>'"\\]+)/gcs) { $w .= $1; next }
        last;
    }

    return (undef, undef, "cannot lex command line near position " . pos($$lref))
        unless length($w) || $quoted;
    return ($w, $quoted, undef);
}

# --------------------------------------------------------------------- parse
#
# Returns (\@list, undef) or (undef, $error), where each list element is
#
#   { sep      => undef | '&&' | '||' | ';',   # separator *before* it
#     pipeline => [ $cmd, ... ] }
#
# and each $cmd is
#
#   { argv   => [ [$word, $quoted], ... ],
#     redirs => [ { fd => N, mode => '<'|'>'|'>>'|'dup'|'both', target => ... } ],
#     negate => 0 | 1 }

sub parse {
    my ($line) = @_;

    my ($toks, $err) = tokenize($line);
    return (undef, $err) if defined $err;
    return ([], undef) unless @$toks;

    my @list;
    my @pipeline;
    my $cmd = _new_cmd();
    my $sep = undef;
    my $i   = 0;

    my $finish_cmd = sub {
        if (@{ $cmd->{argv} } || @{ $cmd->{redirs} }) {
            push @pipeline, $cmd;
        }
        $cmd = _new_cmd();
    };
    my $finish_pipeline = sub {
        $finish_cmd->();
        if (@pipeline) {
            push @list, { sep => $sep, pipeline => [@pipeline] };
            @pipeline = ();
        }
    };

    while ($i < @$toks) {
        my $t = $toks->[$i];

        if ($t->[0] eq 'op') {
            my $o = $t->[1];
            if ($o eq '(' || $o eq ')') {
                return (undef, "subshells are not supported in RUN lines");
            }
            if ($o eq '&') {
                return (undef, "background commands are not supported in RUN lines");
            }
            if ($o eq '|') {
                return (undef, "syntax error near '|'")
                    unless @{ $cmd->{argv} } || @{ $cmd->{redirs} };
                $finish_cmd->();
                $i++;
                next;
            }
            # && || ;
            return (undef, "syntax error near '$o'")
                unless @pipeline || @{ $cmd->{argv} } || @{ $cmd->{redirs} };
            $finish_pipeline->();
            $sep = $o;
            $i++;
            next;
        }

        if ($t->[0] eq 'word') {
            if ($t->[1] eq '!' && !$t->[2] && !@{ $cmd->{argv} }) {
                $cmd->{negate} = $cmd->{negate} ? 0 : 1;
                $i++;
                next;
            }
            push @{ $cmd->{argv} }, [ $t->[1], $t->[2] ];
            $i++;
            next;
        }

        if ($t->[0] eq 'dup') {
            push @{ $cmd->{redirs} },
                { fd => $t->[1], mode => 'dup', target => $t->[2] };
            $i++;
            next;
        }

        if ($t->[0] eq 'redir' || $t->[0] eq 'redirboth') {
            my $nxt = $toks->[$i + 1];
            unless (defined $nxt && $nxt->[0] eq 'word') {
                return (undef, "missing filename after redirection");
            }
            if ($t->[0] eq 'redirboth') {
                push @{ $cmd->{redirs} },
                    { fd => 1, mode => $t->[1], target => $nxt->[1] };
                push @{ $cmd->{redirs} },
                    { fd => 2, mode => 'dup', target => 1 };
            } else {
                push @{ $cmd->{redirs} },
                    { fd => $t->[1], mode => $t->[2], target => $nxt->[1] };
            }
            $i += 2;
            next;
        }

        return (undef, "internal error: unexpected token '$t->[0]'");
    }

    $finish_pipeline->();
    return (\@list, undef);
}

sub _new_cmd {
    return { argv => [], redirs => [], negate => 0 };
}

1;
