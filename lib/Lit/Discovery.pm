package Lit::Discovery;

# Locates test suites and the tests inside them.
#
# A directory becomes a test suite root when it contains a config file
# (litsite.cfg / lit.site.cfg, or lit.cfg / litcfg.pl).  Starting from each
# path named on the command line we walk upwards to find that root, then
# downwards collecting files whose suffix the effective config accepts.
# Each directory may refine the config with a local config file.

use strict;
use warnings;

require 5.006;

use Lit::Compat ();
use Lit::Config ();
use Lit::Test ();

use vars qw($VERSION);
$VERSION = '0.01';

sub find_tests {
    my ($paths, $lit) = @_;

    my @tests;
    my @errors;
    my %suites;        # suite root -> config
    my %dir_config;    # directory   -> effective config

    foreach my $raw (@$paths) {
        my $path = Lit::Compat::clean_path(
            Lit::Compat::abs_path(Lit::Compat::to_unix($raw)));

        unless (-e $path) {
            push @errors, "no such file or directory: $raw";
            next;
        }

        my $start = -d $path ? $path : Lit::Compat::dirname_of($path);
        my ($root, $cfgfile) = _find_suite_root($start);
        unless (defined $root) {
            push @errors, "cannot find a lit.cfg at or above '$raw'";
            next;
        }

        my $suite = $suites{$root};
        unless ($suite) {
            my ($c, $err) = _load_suite($root, $cfgfile, $lit);
            if (defined $err) { push @errors, $err; next }
            $suite = $suites{$root} = $c;
        }

        if (-d $path) {
            _walk($path, $suite, $suite, \%dir_config, \@tests, \@errors, $lit);
        } else {
            my $dir = Lit::Compat::dirname_of($path);
            my $cfg = _config_for_dir($dir, $suite, \%dir_config, $lit, \@errors);
            next unless defined $cfg;
            next if $cfg->unsupported;
            push @tests, _make_test($path, $suite, $cfg);
        }
    }

    return (\@tests, \@errors);
}

# ----------------------------------------------------------------- the suite

sub _find_suite_root {
    my ($dir) = @_;
    my $d = $dir;
    while (1) {
        my $site  = Lit::Config::site_config_in($d);
        return ($d, $site) if defined $site;
        my $suite = Lit::Config::suite_config_in($d);
        return ($d, $suite) if defined $suite;
        my $up = Lit::Compat::dirname_of($d);
        last if $up eq $d || !length $up;
        $d = $up;
    }
    return (undef, undef);
}

sub _load_suite {
    my ($root, $cfgfile, $lit) = @_;

    my $c = Lit::Config->new(dir => $root);
    $c->name(Lit::Compat::basename_of($root));
    $c->add_feature(@{ $lit->host_features });

    my $err = Lit::Config::load_into($c, $cfgfile, $lit);
    return (undef, $err) if defined $err;

    # A site config that did not pull in the suite config gets it now.
    my $suite_cfg = Lit::Config::suite_config_in($root);
    if (defined $suite_cfg && $cfgfile ne $suite_cfg && !$c->{_loaded_suite}) {
        $err = Lit::Config::load_into($c, $suite_cfg, $lit);
        return (undef, $err) if defined $err;
    }

    $c->test_source_root($root) unless defined $c->test_source_root;
    $c->test_exec_root($c->test_source_root) unless defined $c->test_exec_root;
    $c->test_source_root(Lit::Compat::clean_path(
        Lit::Compat::to_unix($c->test_source_root)));
    $c->test_exec_root(Lit::Compat::clean_path(
        Lit::Compat::to_unix($c->test_exec_root)));

    unless (@{ $c->suffixes }) {
        return (undef, "config '$cfgfile' does not set any suffixes; "
                     . "add \$config->suffixes('.test') or similar");
    }
    return ($c, undef);
}

# The effective config for a directory: the suite config refined by every
# local config between the suite root and that directory.
sub _config_for_dir {
    my ($dir, $suite, $cache, $lit, $errors) = @_;
    return $cache->{$dir} if exists $cache->{$dir};

    my $root = $suite->test_source_root;
    my $cfg;

    if ($dir eq $root || !_is_under($dir, $root)) {
        $cfg = $suite;
    } else {
        my $parent = _config_for_dir(Lit::Compat::dirname_of($dir),
                                     $suite, $cache, $lit, $errors);
        $cfg = defined $parent ? $parent : $suite;
    }

    my $local = Lit::Config::local_config_in($dir);
    if (defined $local) {
        $cfg = $cfg->clone($dir);
        my $err = Lit::Config::load_into($cfg, $local, $lit);
        if (defined $err) { push @$errors, $err; $cache->{$dir} = undef; return undef }
    }

    $cache->{$dir} = $cfg;
    return $cfg;
}

sub _is_under {
    my ($path, $root) = @_;
    return 1 if $path eq $root;
    my $r = $root;
    $r =~ s{/+$}{};
    return (index($path, $r . '/') == 0) ? 1 : 0;
}

# ------------------------------------------------------------------ the walk

sub _walk {
    my ($dir, $suite, $parent_cfg, $cache, $tests, $errors, $lit) = @_;

    my $cfg = _config_for_dir($dir, $suite, $cache, $lit, $errors);
    return unless defined $cfg;
    return if $cfg->unsupported;

    local *DH;
    unless (opendir(DH, $dir)) {
        push @$errors, "cannot read directory '$dir': $!";
        return;
    }
    my @entries = sort grep { $_ ne '.' && $_ ne '..' } readdir(DH);
    closedir(DH);

    foreach my $e (@entries) {
        next if $cfg->is_excluded($e);
        my $full = Lit::Compat::joinp($dir, $e);
        if (-d $full) {
            _walk($full, $suite, $cfg, $cache, $tests, $errors, $lit)
                if $cfg->recursive;
            next;
        }
        next unless $cfg->matches_suffix($e);
        push @$tests, _make_test($full, $suite, $cfg);
    }
}

sub _make_test {
    my ($path, $suite, $cfg) = @_;
    my $root = $cfg->test_source_root;
    my $rel  = $path;
    if (_is_under($path, $root)) {
        my $r = $root;
        $r =~ s{/+$}{};
        $rel = substr($path, length($r) + 1);
    } else {
        $rel = Lit::Compat::basename_of($path);
    }
    return Lit::Test->new(
        suite  => $suite,
        config => $cfg,
        path   => $path,
        rel    => $rel,
    );
}

1;
