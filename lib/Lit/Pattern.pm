package Lit::Pattern;

# Compiles a FileCheck pattern string into a Perl regex plus a list of
# post-match operations (variable definitions and numeric assertions).
#
# Supported pattern syntax:
#   {{regex}}                 embedded regular expression
#   [[NAME:regex]]            define string variable NAME
#   [[NAME]]                  use string variable NAME
#   [[$NAME:regex]] [[$NAME]] same, but global (survives --enable-var-scope)
#   [[@LINE]] [[@LINE+n]]     line number of the directive
#   [[#NAME:]]                define numeric variable NAME
#   [[#NAME:expr]]            define NAME, asserting the match equals expr
#   [[#expr]]                 match a number equal to expr
#   [[#%<fmt>,...]]           as above with an explicit format (u d x X, .N)
#
# Expressions: literals (decimal or 0x hex), numeric variables, @LINE,
# + and -, and the functions add sub mul div min max.

use strict;
use warnings;

require 5.006;

use vars qw($VERSION);
$VERSION = '0.01';

my $NAME_RE  = qr/\$?[A-Za-z_][A-Za-z0-9_]*/;

# ---------------------------------------------------------------- new / parse

sub new {
    my ($class, %args) = @_;
    my $self = {
        prefix  => $args{prefix},
        type    => $args{type},
        count   => defined $args{count} ? $args{count} : 1,
        text    => $args{text},
        line    => $args{line},
        file    => $args{file},
        strict  => $args{strict}     ? 1 : 0,
        full    => $args{full}       ? 1 : 0,
        nocase  => $args{nocase}     ? 1 : 0,
    };
    return bless $self, $class;
}

sub type   { return $_[0]->{type} }
sub line   { return $_[0]->{line} }
sub prefix { return $_[0]->{prefix} }
sub text   { return $_[0]->{text} }
sub count  { return $_[0]->{count} }

# ------------------------------------------------------------------- compile
#
# Returns ($qr, \@ops, undef) on success or (undef, undef, $message).
# $vars is { str => {NAME=>value}, num => {NAME=>{value=>v, fmt=>f}} }.

sub compile {
    my ($self, $vars) = @_;

    # CHECK-EMPTY carries no pattern text; it matches a genuinely blank line.
    if (defined $self->{type} && $self->{type} eq q{EMPTY}) {
        return (qr/^$/m, [], undef);
    }

    my $s      = $self->{text};
    my $re     = '';
    my @ops    = ();
    my $ngroup = 0;

    if ($self->{full}) {
        $re .= '^';
        $re .= ' *' unless $self->{strict};
    }

    while (length $s) {
        # -------------------------------------------------- {{ regex }}
        if ($s =~ /^\{\{/) {
            my $end = index($s, '}}', 2);
            return (undef, undef, "found start of regex string with no end '}}'")
                if $end < 0;
            my $body = substr($s, 2, $end - 2);
            $s = substr($s, $end + 2);
            my $err = _validate_re($body);
            return (undef, undef, $err) if defined $err;
            $re .= '(?:' . $body . ')';
            $ngroup += _count_groups($body);
            next;
        }

        # -------------------------------------------------- [[ ... ]]
        if ($s =~ /^\[\[/) {
            my $end = index($s, ']]', 2);
            return (undef, undef, "invalid variable reference: missing ']]'")
                if $end < 0;
            my $body = substr($s, 2, $end - 2);
            $s = substr($s, $end + 2);

            my ($chunk, $err) = $self->_block($body, $vars, \$ngroup, \@ops);
            return (undef, undef, $err) if defined $err;
            $re .= $chunk;
            next;
        }

        # -------------------------------------------------- literal run
        my $lit;
        my $nb = index($s, '{{');
        my $nv = index($s, '[[');
        my $cut = -1;
        if ($nb >= 0 && $nv >= 0) { $cut = $nb < $nv ? $nb : $nv }
        elsif ($nb >= 0)          { $cut = $nb }
        elsif ($nv >= 0)          { $cut = $nv }

        if ($cut > 0)      { $lit = substr($s, 0, $cut); $s = substr($s, $cut) }
        elsif ($cut == 0)  { $lit = substr($s, 0, 1);    $s = substr($s, 1) }
        else               { $lit = $s;                  $s = '' }

        # Mirror the canonicalisation applied to the input buffer.
        $lit =~ s/[ \t]+/ /g unless $self->{strict};
        $re .= quotemeta($lit);
    }

    if ($self->{full}) {
        $re .= ' *' unless $self->{strict};
        $re .= '$';
    }

    my $flags = $self->{nocase} ? '(?i)' : '';
    my $qr;
    eval { $qr = qr/$flags$re/m; 1 }
        or return (undef, undef, "invalid pattern: $@");

    return ($qr, \@ops, undef);
}

# ---------------------------------------------------------- [[ ... ]] bodies

sub _block {
    my ($self, $body, $vars, $ngroup, $ops) = @_;

    # [[@LINE]], [[@LINE+3]], [[@LINE-2]]  (legacy, non-numeric form)
    if ($body =~ /^\s*\@LINE\s*(?:([+-])\s*([0-9]+)\s*)?$/) {
        my $v = $self->{line};
        if (defined $1) { $v = ($1 eq '+') ? $v + $2 : $v - $2 }
        return (quotemeta("$v"), undef);
    }

    # [[# ... ]] numeric block
    if ($body =~ /^#(.*)$/s) {
        return $self->_numeric_block($1, $vars, $ngroup, $ops);
    }

    # [[NAME:regex]] -- definition
    if ($body =~ /^($NAME_RE):(.*)$/s) {
        my ($name, $sub) = ($1, $2);
        return (undef, "invalid variable name '$name'") if $name =~ /^\$?[0-9]/;
        my $err = _validate_re($sub);
        return (undef, $err) if defined $err;
        $$ngroup++;
        my $g = $$ngroup;
        push @$ops, { kind => 'def_str', name => $name, group => $g };
        my $chunk = '(' . $sub . ')';
        $$ngroup += _count_groups($sub);
        return ($chunk, undef);
    }

    # [[NAME]] -- use
    if ($body =~ /^($NAME_RE)$/) {
        my $name = $1;
        return (undef, "undefined variable: $name")
            unless exists $vars->{str}{$name};
        return (quotemeta($vars->{str}{$name}), undef);
    }

    return (undef, "invalid variable reference: [[$body]]");
}

sub _numeric_block {
    my ($self, $body, $vars, $ngroup, $ops) = @_;

    my $fmt;
    if ($body =~ s/^\s*%([-.0-9]*[udxX])\s*,//) { $fmt = $1 }

    # Definition?  "NAME:" possibly followed by a constraint expression.
    if ($body =~ /^\s*($NAME_RE)\s*:(.*)$/s) {
        my ($name, $rest) = ($1, $2);
        my $want;
        if ($rest =~ /\S/) {
            $rest =~ s/^\s*==\s*//;
            my ($v, $err) = $self->_eval_expr($rest, $vars);
            return (undef, $err) if defined $err;
            $want = $v;
        }
        my $use_fmt = defined $fmt ? $fmt : 'u';
        $$ngroup++;
        my $g = $$ngroup;
        push @$ops, { kind => 'def_num', name => $name, group => $g, fmt => $use_fmt };
        push @$ops, { kind => 'check_num', group => $g, want => $want, fmt => $use_fmt,
                      text => $rest }
            if defined $want;
        return ('(' . _num_re($use_fmt) . ')', undef);
    }

    # Use: an expression whose value the matched number must equal.
    return (undef, "empty numeric expression") unless $body =~ /\S/;
    my ($v, $err) = $self->_eval_expr($body, $vars);
    return (undef, $err) if defined $err;

    my $use_fmt = $fmt;
    unless (defined $use_fmt) {
        # Inherit the format of the sole variable mentioned, else %u.
        if ($body =~ /^\s*($NAME_RE)\s*$/ && exists $vars->{num}{$1}) {
            $use_fmt = $vars->{num}{$1}{fmt};
        }
        $use_fmt = 'u' unless defined $use_fmt;
    }
    $$ngroup++;
    my $g = $$ngroup;
    push @$ops, { kind => 'check_num', group => $g, want => $v, fmt => $use_fmt,
                  text => $body };
    return ('(' . _num_re($use_fmt) . ')', undef);
}

# --------------------------------------------------------------- expressions

sub _eval_expr {
    my ($self, $expr, $vars) = @_;
    my @toks;
    my $s = $expr;
    while ($s =~ /\S/) {
        $s =~ s/^\s+//;
        last unless length $s;
        if    ($s =~ s/^(0[xX][0-9a-fA-F]+)//) { push @toks, ['num', hex($1)] }
        elsif ($s =~ s/^([0-9]+)//)            { push @toks, ['num', 0 + $1] }
        elsif ($s =~ s/^\@LINE//)              { push @toks, ['num', $self->{line}] }
        elsif ($s =~ s/^($NAME_RE)//)          { push @toks, ['name', $1] }
        elsif ($s =~ s/^([-+(),])//)           { push @toks, ['op', $1] }
        else { return (undef, "unexpected character in expression: " . substr($s, 0, 1)) }
    }
    my $pos = 0;
    my ($v, $err) = _parse_sum(\@toks, \$pos, $vars);
    return (undef, $err) if defined $err;
    return (undef, "trailing garbage in numeric expression '$expr'")
        if $pos < @toks;
    return ($v, undef);
}

sub _parse_sum {
    my ($toks, $pos, $vars) = @_;
    my ($v, $err) = _parse_atom($toks, $pos, $vars);
    return (undef, $err) if defined $err;
    while ($$pos < @$toks && $toks->[$$pos][0] eq 'op'
           && ($toks->[$$pos][1] eq '+' || $toks->[$$pos][1] eq '-')) {
        my $op = $toks->[$$pos][1];
        $$pos++;
        my ($r, $e2) = _parse_atom($toks, $pos, $vars);
        return (undef, $e2) if defined $e2;
        $v = ($op eq '+') ? $v + $r : $v - $r;
    }
    return ($v, undef);
}

my %FUNC = (
    add => sub { $_[0] + $_[1] },
    sub => sub { $_[0] - $_[1] },
    mul => sub { $_[0] * $_[1] },
    div => sub { $_[1] == 0 ? undef : int($_[0] / $_[1]) },
    min => sub { $_[0] < $_[1] ? $_[0] : $_[1] },
    max => sub { $_[0] > $_[1] ? $_[0] : $_[1] },
);

sub _parse_atom {
    my ($toks, $pos, $vars) = @_;
    return (undef, "unexpected end of numeric expression") if $$pos >= @$toks;
    my $t = $toks->[$$pos];

    if ($t->[0] eq 'op' && $t->[1] eq '-') {
        $$pos++;
        my ($v, $e) = _parse_atom($toks, $pos, $vars);
        return (undef, $e) if defined $e;
        return (-$v, undef);
    }
    if ($t->[0] eq 'op' && $t->[1] eq '(') {
        $$pos++;
        my ($v, $e) = _parse_sum($toks, $pos, $vars);
        return (undef, $e) if defined $e;
        return (undef, "missing ')' in numeric expression")
            unless $$pos < @$toks && $toks->[$$pos][0] eq 'op' && $toks->[$$pos][1] eq ')';
        $$pos++;
        return ($v, undef);
    }
    if ($t->[0] eq 'num') { $$pos++; return ($t->[1], undef) }

    if ($t->[0] eq 'name') {
        my $name = $t->[1];
        # function call?
        if ($$pos + 1 < @$toks && $toks->[$$pos+1][0] eq 'op'
            && $toks->[$$pos+1][1] eq '(') {
            return (undef, "unknown function '$name'") unless $FUNC{$name};
            $$pos += 2;
            my ($a, $e1) = _parse_sum($toks, $pos, $vars);
            return (undef, $e1) if defined $e1;
            return (undef, "'$name' expects two arguments")
                unless $$pos < @$toks && $toks->[$$pos][0] eq 'op' && $toks->[$$pos][1] eq ',';
            $$pos++;
            my ($b, $e2) = _parse_sum($toks, $pos, $vars);
            return (undef, $e2) if defined $e2;
            return (undef, "missing ')' after '$name' arguments")
                unless $$pos < @$toks && $toks->[$$pos][0] eq 'op' && $toks->[$$pos][1] eq ')';
            $$pos++;
            my $v = $FUNC{$name}->($a, $b);
            return (undef, "division by zero in numeric expression") unless defined $v;
            return ($v, undef);
        }
        $$pos++;
        return (undef, "undefined numeric variable: $name")
            unless exists $vars->{num}{$name};
        return ($vars->{num}{$name}{value}, undef);
    }
    return (undef, "unexpected token in numeric expression");
}

# ------------------------------------------------------------------ numerics

# Regex matching a number written in the given format.
sub _num_re {
    my ($fmt) = @_;
    my $prec = 1;
    $prec = $1 if $fmt =~ /\.([0-9]+)/;
    my $conv = substr($fmt, -1);
    my $body;
    if    ($conv eq 'x') { $body = '[0-9a-fA-F]' }
    elsif ($conv eq 'X') { $body = '[0-9a-fA-F]' }
    else                 { $body = '[0-9]' }
    my $core = $body . '{' . $prec . ',}';
    return ($conv eq 'd') ? '-?' . $core : $core;
}

sub parse_num {
    my ($text, $fmt) = @_;
    my $conv = substr($fmt, -1);
    if ($conv eq 'x' || $conv eq 'X') { return hex($text) }
    return 0 + $text;
}

sub format_num {
    my ($value, $fmt) = @_;
    my $conv = substr($fmt, -1);
    my $prec = ($fmt =~ /\.([0-9]+)/) ? $1 : undef;
    my $spec;
    if (defined $prec) { $spec = '%0' . $prec . $conv }
    else               { $spec = '%' . $conv }
    $spec =~ s/u$/d/;
    return sprintf($spec, $value);
}

# ------------------------------------------------------------------- helpers

# Number of capturing groups a regex fragment introduces.
sub _count_groups {
    my ($re) = @_;
    my $n     = 0;
    my $i     = 0;
    my $len   = length $re;
    my $incls = 0;
    while ($i < $len) {
        my $c = substr($re, $i, 1);
        if ($c eq '\\') { $i += 2; next }
        if ($incls) {
            $incls = 0 if $c eq ']';
            $i++;
            next;
        }
        if ($c eq '[') { $incls = 1; $i++; next }
        if ($c eq '(') {
            $n++ unless substr($re, $i + 1, 1) eq '?';
            $i++;
            next;
        }
        $i++;
    }
    return $n;
}

sub _validate_re {
    my ($body) = @_;
    my $ok = eval { my $x = qr/$body/; 1 };
    return undef if $ok;
    my $msg = $@;
    $msg =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*$//s;
    $msg =~ s/\s+$//;
    return "invalid regex: $msg";
}

1;
