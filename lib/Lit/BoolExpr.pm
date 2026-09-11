package Lit::BoolExpr;

# Evaluates the boolean expressions used by REQUIRES:, UNSUPPORTED: and
# XFAIL: lines.
#
#   expr    := or
#   or      := and ('||' and)*
#   and     := not ('&&' not)*
#   not     := '!' not | primary
#   primary := '(' expr ')' | identifier | '{{' regex '}}'
#
# An identifier is true when it names an available feature.  A {{regex}}
# match is true when it matches any available feature.  '*' is always true,
# which is how XFAIL: * is spelled.
#
# A bare comma-separated list is also accepted, as lit allows, and means the
# same as ||.

use strict;
use warnings;

require 5.006;

use vars qw($VERSION);
$VERSION = '1.00';

sub evaluate {
    my ($text, $features) = @_;
    my %have = map { $_ => 1 } @$features;

    my ($toks, $err) = _lex($text);
    return (undef, $err) if defined $err;
    return (0, undef) unless @$toks;

    my $pos = 0;
    my ($v, $e) = _or(\%have, $features, $toks, \$pos);
    return (undef, $e) if defined $e;
    if ($pos < @$toks) {
        return (undef, "unexpected '" . $toks->[$pos][1] . "' in expression");
    }
    return ($v, undef);
}

sub _lex {
    my ($text) = @_;
    my @toks;
    my $len = length $text;
    pos($text) = 0;
    while (pos($text) < $len) {
        next if $text =~ /\G\s+/gc;
        if ($text =~ /\G\{\{/gc) {
            my $start = pos($text);
            my $end = index($text, '}}', $start);
            return (undef, "unterminated '{{' in expression") if $end < 0;
            push @toks, ['regex', substr($text, $start, $end - $start)];
            pos($text) = $end + 2;
            next;
        }
        if ($text =~ /\G(&&|\|\||[!(),])/gc) { push @toks, ['op', $1]; next }
        if ($text =~ /\G([-+=.\w*]+)/gc)     { push @toks, ['id', $1]; next }
        return (undef, "unexpected character '" . substr($text, pos($text), 1)
                     . "' in expression");
    }
    return (\@toks, undef);
}

sub _peek {
    my ($toks, $pos) = @_;
    return undef if $$pos >= @$toks;
    return $toks->[$$pos];
}

sub _or {
    my ($have, $list, $toks, $pos) = @_;
    my ($v, $e) = _and($have, $list, $toks, $pos);
    return (undef, $e) if defined $e;
    while (1) {
        my $t = _peek($toks, $pos);
        last unless $t && $t->[0] eq 'op' && ($t->[1] eq '||' || $t->[1] eq ',');
        $$pos++;
        my ($r, $e2) = _and($have, $list, $toks, $pos);
        return (undef, $e2) if defined $e2;
        $v = ($v || $r) ? 1 : 0;
    }
    return ($v, undef);
}

sub _and {
    my ($have, $list, $toks, $pos) = @_;
    my ($v, $e) = _not($have, $list, $toks, $pos);
    return (undef, $e) if defined $e;
    while (1) {
        my $t = _peek($toks, $pos);
        last unless $t && $t->[0] eq 'op' && $t->[1] eq '&&';
        $$pos++;
        my ($r, $e2) = _not($have, $list, $toks, $pos);
        return (undef, $e2) if defined $e2;
        $v = ($v && $r) ? 1 : 0;
    }
    return ($v, undef);
}

sub _not {
    my ($have, $list, $toks, $pos) = @_;
    my $t = _peek($toks, $pos);
    if ($t && $t->[0] eq 'op' && $t->[1] eq '!') {
        $$pos++;
        my ($v, $e) = _not($have, $list, $toks, $pos);
        return (undef, $e) if defined $e;
        return ($v ? 0 : 1, undef);
    }
    return _primary($have, $list, $toks, $pos);
}

sub _primary {
    my ($have, $list, $toks, $pos) = @_;
    my $t = _peek($toks, $pos);
    return (undef, "unexpected end of expression") unless $t;

    if ($t->[0] eq 'op' && $t->[1] eq '(') {
        $$pos++;
        my ($v, $e) = _or($have, $list, $toks, $pos);
        return (undef, $e) if defined $e;
        my $c = _peek($toks, $pos);
        return (undef, "missing ')' in expression")
            unless $c && $c->[0] eq 'op' && $c->[1] eq ')';
        $$pos++;
        return ($v, undef);
    }

    if ($t->[0] eq 'regex') {
        $$pos++;
        my $re = eval { qr/^$t->[1]$/ };
        return (undef, "invalid regex '{{$t->[1]}}' in expression") unless $re;
        foreach my $f (@$list) { return (1, undef) if $f =~ $re }
        return (0, undef);
    }

    if ($t->[0] eq 'id') {
        $$pos++;
        my $name = $t->[1];
        return (1, undef) if $name eq '*' || $name eq 'true';
        return (0, undef) if $name eq 'false';
        return ($have->{$name} ? 1 : 0, undef);
    }

    return (undef, "unexpected '" . $t->[1] . "' in expression");
}

1;

__END__

=head1 NAME

Lit::BoolExpr - the REQUIRES:/UNSUPPORTED:/XFAIL: expression language

=head1 DESCRIPTION

Evaluates a boolean expression over the suite's feature set.

    expr    := or
    or      := and ('||' and)*
    and     := not ('&&' not)*
    not     := '!' not | primary
    primary := '(' expr ')' | identifier | '{{' regex '}}'

An identifier is true when it names an available feature.  C<{{regex}}> is
true when the regex matches any available feature.  C<*> and C<true> are
always true, C<false> never is.  A comma-separated list means the same as
C<||>, which is how lit's older syntax is spelled.

=head1 EXAMPLES

    REQUIRES: vms && !vax
    UNSUPPORTED: {{system-(linux|darwin)}}
    XFAIL: *
    XFAIL: mms, mmk

Features come from three places: the host set added automatically (see
L<Lit::LitConfig/host_features>), anything the config adds with
C<< $config->add_feature >>, and - a useful idiom - a C<--param> turned
into a feature so that existing directives keep working:

    my $tool = lc($lit_config->param('tool', 'mms'));
    $config->add_feature($tool);

With that, C<XFAIL: mms> means "expected to fail under C<--param tool=mms>,
and expected to B<pass> under any other tool", which is usually what a
divergence between two implementations should assert.

=head1 SEE ALSO

L<Lit>, L<Lit::TestRunner>, L<Lit::Config>

=cut
