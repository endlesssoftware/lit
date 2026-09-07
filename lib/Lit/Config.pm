package Lit::Config;

# The per-suite / per-directory configuration object.
#
# lit's own config files are Python, which is exactly the dependency this
# distribution exists to avoid, so here they are Perl.  A config file is
# evaluated as the body of a sub receiving ($config, $lit_config):
#
#     lit.cfg
#     ------------------------------------------------------------------
#     $config->name('brcob');
#     $config->suffixes('.cob', '.pli');
#     $config->test_source_root($config->dir);
#     $config->test_exec_root($lit_config->param('build', '/build') . '/test');
#
#     $config->add_feature('vms') if $lit_config->is_vms;
#     $config->add_substitution('%brcob', '/sys$system/brcob.exe');
#     ------------------------------------------------------------------
#
# Config file names are chosen to be legal on ODS-2, which allows only one
# dot: prefer lit.cfg / litlocal.cfg / litsite.cfg.  The Unix spellings
# lit.local.cfg and lit.site.cfg are also accepted where the filesystem
# permits them.

use strict;
use warnings;

require 5.006;

use Lit::Compat ();

use vars qw($VERSION @SUITE_NAMES @LOCAL_NAMES @SITE_NAMES);
$VERSION = '0.01';

@SITE_NAMES  = ('litsite.cfg',  'lit.site.cfg');
@SUITE_NAMES = ('lit.cfg',      'litcfg.pl');
@LOCAL_NAMES = ('litlocal.cfg', 'lit.local.cfg');

sub new {
    my ($class, %args) = @_;
    my $self = {
        parent           => $args{parent},
        dir              => $args{dir},
        name             => defined $args{name} ? $args{name} : 'tests',
        suffixes         => [],
        excludes         => { 'Output' => 1, '.git' => 1, '.svn' => 1, 'CVS' => 1 },
        substitutions    => [],
        features         => {},
        environment      => { %ENV },
        test_source_root => undef,
        test_exec_root   => undef,
        unsupported      => 0,
        pipefail         => 1,
        timeout          => 0,
        recursive        => 1,
    };
    return bless $self, $class;
}

sub clone {
    my ($self, $dir) = @_;
    my $c = { %$self };
    $c->{parent}        = $self;
    $c->{dir}           = defined $dir ? $dir : $self->{dir};
    $c->{suffixes}      = [ @{ $self->{suffixes} } ];
    $c->{excludes}      = { %{ $self->{excludes} } };
    $c->{substitutions} = [ map { [ @$_ ] } @{ $self->{substitutions} } ];
    $c->{features}      = { %{ $self->{features} } };
    $c->{environment}   = { %{ $self->{environment} } };
    return bless $c, ref $self;
}

# ------------------------------------------------------------- simple slots

sub _slot {
    my $self = shift;
    my $key  = shift;
    $self->{$key} = shift if @_;
    return $self->{$key};
}

sub name             { my $s = shift; return $s->_slot('name', @_) }
sub dir              { my $s = shift; return $s->_slot('dir', @_) }
sub test_source_root { my $s = shift; return $s->_slot('test_source_root', @_) }
sub test_exec_root   { my $s = shift; return $s->_slot('test_exec_root', @_) }
sub unsupported      { my $s = shift; return $s->_slot('unsupported', @_) }
sub pipefail         { my $s = shift; return $s->_slot('pipefail', @_) }
sub timeout          { my $s = shift; return $s->_slot('timeout', @_) }
sub recursive        { my $s = shift; return $s->_slot('recursive', @_) }

# ---------------------------------------------------------------- suffixes

sub suffixes {
    my $self = shift;
    if (@_) {
        my @s = (ref $_[0] eq 'ARRAY') ? @{ $_[0] } : @_;
        $self->{suffixes} = [ map { _norm_suffix($_) } @s ];
    }
    return $self->{suffixes};
}

sub add_suffix {
    my $self = shift;
    push @{ $self->{suffixes} }, map { _norm_suffix($_) } @_;
    return $self->{suffixes};
}

sub _norm_suffix {
    my ($s) = @_;
    return $s if $s =~ /^\./;
    return '.' . $s;
}

sub matches_suffix {
    my ($self, $file) = @_;
    return 0 unless @{ $self->{suffixes} };
    foreach my $s (@{ $self->{suffixes} }) {
        # Case-insensitive on hosts with case-insensitive filesystems.
        if (Lit::Compat::IS_VMS || Lit::Compat::IS_WIN) {
            return 1 if lc(substr($file, -length($s))) eq lc($s);
        } else {
            return 1 if substr($file, -length($s)) eq $s;
        }
    }
    return 0;
}

# ---------------------------------------------------------------- excludes

sub excludes {
    my $self = shift;
    if (@_) {
        my @e = (ref $_[0] eq 'ARRAY') ? @{ $_[0] } : @_;
        $self->{excludes} = { map { $_ => 1 } @e };
    }
    return [ sort keys %{ $self->{excludes} } ];
}

sub add_exclude {
    my $self = shift;
    $self->{excludes}{$_} = 1 foreach @_;
    return 1;
}

sub is_excluded {
    my ($self, $name) = @_;
    return $self->{excludes}{$name} ? 1 : 0;
}

# ----------------------------------------------------------------- features

sub add_feature {
    my $self = shift;
    $self->{features}{$_} = 1 foreach grep { defined && length } @_;
    return 1;
}

sub remove_feature {
    my $self = shift;
    delete $self->{features}{$_} foreach @_;
    return 1;
}

sub has_feature { my ($self, $f) = @_; return $self->{features}{$f} ? 1 : 0 }
sub features    { my ($self) = @_; return [ sort keys %{ $self->{features} } ] }

# ------------------------------------------------------------ substitutions

# add_substitution('%brcob', '/path/to/brcob')
# add_substitution(qr/%foo(\d+)/, '...')     -- regex keys are allowed
#
# Later additions take precedence over earlier ones, and all user
# substitutions are applied before the built-in %s / %t family.
sub add_substitution {
    my ($self, $pattern, $replacement) = @_;
    unshift @{ $self->{substitutions} }, [ $pattern, $replacement ];
    return 1;
}

sub substitutions { return $_[0]->{substitutions} }

# ------------------------------------------------------------------- environ

sub env {
    my $self = shift;
    return $self->{environment} unless @_;
    my $key = shift;
    $self->{environment}{$key} = shift if @_;
    return $self->{environment}{$key};
}

sub environment { return $_[0]->{environment} }

# ---------------------------------------------------------------- file names

sub site_config_in  { return _first_in($_[0], \@SITE_NAMES) }
sub suite_config_in { return _first_in($_[0], \@SUITE_NAMES) }
sub local_config_in { return _first_in($_[0], \@LOCAL_NAMES) }

sub _first_in {
    my ($dir, $names) = @_;
    foreach my $n (@$names) {
        my $p = Lit::Compat::joinp($dir, $n);
        return $p if -f $p;
    }
    return undef;
}

# ------------------------------------------------------------------ loading

# Evaluate a config file with ($config, $lit_config) in scope.  The #line
# directive makes any error report the config file's own line numbers.
sub load_into {
    my ($config, $path, $lit_config) = @_;

    my $src = Lit::Compat::read_file($path);
    return "cannot read config file '$path'" unless defined $src;

    my $safe = $path;
    $safe =~ s/"/\\"/g;

    my $wrapper = join('',
        "package Lit::ConfigFile;\n",
        "use strict; use warnings;\n",
        "sub {\n",
        "my (\$config, \$lit_config) = \@_;\n",
        "#line 1 \"$safe\"\n",
        $src,
        "\n;return 1;\n}\n");

    my $sub = eval $wrapper;    ## no critic
    if ($@ || !$sub) {
        my $e = $@ ? $@ : 'unknown error';
        $e =~ s/\s+$//;
        return "error in config file '$path': $e";
    }

    my $ok = eval { $sub->($config, $lit_config); 1 };
    unless ($ok) {
        my $e = $@;
        $e =~ s/\s+$//;
        return "error running config file '$path': $e";
    }
    return undef;
}

1;
