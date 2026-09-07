package Lit::LitConfig;

# The global driver configuration -- the object a config file sees as
# $lit_config.  Holds command line parameters, verbosity, and the host
# facts that REQUIRES:/UNSUPPORTED: lines are usually written against.

use strict;
use warnings;

require 5.006;

use Config ();
use Lit::Compat ();

use vars qw($VERSION);
$VERSION = '0.01';

sub new {
    my ($class, %args) = @_;
    my $self = {
        params      => defined $args{params} ? $args{params} : {},
        quiet       => $args{quiet}   ? 1 : 0,
        verbose     => defined $args{verbose} ? $args{verbose} : 0,
        timeout     => defined $args{timeout} ? $args{timeout} : 0,
        num_errors  => 0,
        num_warns   => 0,
        err         => defined $args{err} ? $args{err} : \*STDERR,
    };
    bless $self, $class;
    return $self;
}

# ------------------------------------------------------------------- params

sub params { return $_[0]->{params} }

sub param {
    my ($self, $name, $default) = @_;
    return $self->{params}{$name} if exists $self->{params}{$name};
    return $default;
}

sub set_param { my ($self, $k, $v) = @_; $self->{params}{$k} = $v; return $v }

# --------------------------------------------------------------------- host

sub is_vms     { return Lit::Compat::IS_VMS ? 1 : 0 }
sub is_windows { return Lit::Compat::IS_WIN ? 1 : 0 }
sub is_unix    { return (Lit::Compat::IS_VMS || Lit::Compat::IS_WIN) ? 0 : 1 }
sub host_os    { return $^O }
sub host_arch  { return $Config::Config{archname} }

# Features every suite gets for free, so that a test can say
#   REQUIRES: system-openvms
#   UNSUPPORTED: vax
# without the suite having to detect anything itself.
sub host_features {
    my ($self) = @_;
    my @f;

    my $os = lc $^O;
    if    ($os eq 'vms')      { push @f, 'system-openvms', 'openvms', 'vms' }
    elsif ($os eq 'dec_osf')  { push @f, 'system-tru64', 'tru64', 'osf1' }
    elsif ($os eq 'linux')    { push @f, 'system-linux', 'linux' }
    elsif ($os eq 'darwin')   { push @f, 'system-darwin', 'darwin' }
    elsif ($os eq 'mswin32')  { push @f, 'system-windows', 'windows' }
    else                      { push @f, 'system-' . $os, $os }

    my $arch = lc(join(' ', grep { defined && length }
                            $Config::Config{archname},
                            $Config::Config{myarchname}));
    if    ($arch =~ /vax/)                 { push @f, 'vax' }
    elsif ($arch =~ /(?:axp|alpha)/)       { push @f, 'alpha' }
    elsif ($arch =~ /(?:ia64|itanium)/)    { push @f, 'ia64' }
    elsif ($arch =~ /(?:x86_64|amd64)/)    { push @f, 'x86_64' }
    elsif ($arch =~ /(?:i[3-6]86|x86)/)    { push @f, 'x86' }
    elsif ($arch =~ /(?:aarch64|arm64)/)   { push @f, 'aarch64' }

    push @f, 'host-endian-little' if $Config::Config{byteorder} =~ /^1234/;
    push @f, 'host-endian-big'    if $Config::Config{byteorder} =~ /^(?:4321|87654321)$/;

    # 64-bit-capable Perl means the host can express 64-bit test values.
    push @f, 'int64' if ($Config::Config{ivsize} || 4) >= 8;

    return \@f;
}

# ------------------------------------------------------------------ messages

sub note {
    my ($self, $msg) = @_;
    return if $self->{quiet};
    print { $self->{err} } "lit: note: $msg\n";
}

sub warning {
    my ($self, $msg) = @_;
    $self->{num_warns}++;
    return if $self->{quiet};
    print { $self->{err} } "lit: warning: $msg\n";
}

sub error {
    my ($self, $msg) = @_;
    $self->{num_errors}++;
    print { $self->{err} } "lit: error: $msg\n";
}

sub fatal {
    my ($self, $msg) = @_;
    print { $self->{err} } "lit: fatal: $msg\n";
    Lit::Compat::exit_with(2);
}

sub num_errors { return $_[0]->{num_errors} }
sub num_warns  { return $_[0]->{num_warns} }

# Load another config file into $config; called from a site config to pull
# in the suite's lit.cfg after it has set the roots.
sub load_config {
    my ($self, $config, $path) = @_;
    require Lit::Config;
    my $err = Lit::Config::load_into($config, $path, $self);
    $self->fatal($err) if defined $err;
    return $config;
}

1;
