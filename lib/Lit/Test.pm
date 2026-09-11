package Lit::Test;

# A single test and its result.

use strict;
use warnings;

require 5.006;

use Lit::Compat ();

use vars qw($VERSION @CODES %IS_FAILURE);
$VERSION = '1.00';

# Result codes, in the order they are summarised.
@CODES = qw(PASS FLAKYPASS XFAIL UNSUPPORTED XPASS FAIL TIMEOUT UNRESOLVED);

%IS_FAILURE = (
    XPASS      => 1,
    FAIL       => 1,
    TIMEOUT    => 1,
    UNRESOLVED => 1,
);

sub is_failure { my ($code) = @_; return $IS_FAILURE{$code} ? 1 : 0 }

sub new {
    my ($class, %args) = @_;
    my $self = {
        suite    => $args{suite},        # Lit::Config of the owning suite
        config   => $args{config},       # effective config for this test
        path     => $args{path},         # absolute source path (Unix syntax)
        rel      => $args{rel},          # path relative to the suite root
        result   => undef,
        output   => '',
        elapsed  => 0,
        metrics  => {},
        xfails   => [],
    };
    return bless $self, $class;
}

sub path      { return $_[0]->{path} }
sub rel       { return $_[0]->{rel} }
sub config    { return $_[0]->{config} }
sub suite     { return $_[0]->{suite} }
sub result    { return $_[0]->{result} }
sub output    { return $_[0]->{output} }
sub elapsed   { return $_[0]->{elapsed} }

# "suite name :: relative/path", the identifier lit prints.
sub name {
    my ($self) = @_;
    my $suite = $self->{suite} ? $self->{suite}->name : 'tests';
    return $suite . ' :: ' . $self->{rel};
}

sub metrics { return $_[0]->{metrics} }

sub set_metrics {
    my ($self, $m) = @_;
    $self->{metrics} = (defined $m && ref $m eq 'HASH') ? $m : {};
    return $self;
}

sub set_result {
    my ($self, $code, $output, $elapsed) = @_;
    $self->{result}  = $code;
    $self->{output}  = defined $output ? $output : '';
    $self->{elapsed} = defined $elapsed ? $elapsed : 0;
    return $self;
}

# Where this test's scratch files live: <exec root>/<dir of rel>/Output
sub exec_dir {
    my ($self) = @_;
    my $root = $self->{config}->test_exec_root;
    $root = $self->{config}->test_source_root unless defined $root;
    my $sub = Lit::Compat::dirname_of($self->{rel});
    $sub = '' if $sub eq '.';
    return Lit::Compat::clean_path(
        Lit::Compat::joinp($root, $sub, 'Output'));
}

sub temp_base {
    my ($self) = @_;
    my $base = Lit::Compat::basename_of($self->{rel});
    return Lit::Compat::joinp($self->exec_dir, $base . '.tmp');
}

1;

__END__

=head1 NAME

Lit::Test - a single test and its result

=head1 RESULT CODES

    PASS          passed
    FLAKYPASS     passed, but only after an ALLOW_RETRIES retry
    XFAIL         failed, and was expected to (XFAIL:)
    UNSUPPORTED   skipped by REQUIRES: or UNSUPPORTED:
    XPASS         passed, but was expected to fail
    FAIL          failed
    TIMEOUT       exceeded the per-test time limit
    UNRESOLVED    could not be run: unreadable, unparsable, or no RUN: line

The last four count as failures and make C<lit.pl> exit non-zero.  C<XPASS>
is among them deliberately: an C<XFAIL:> marker that has quietly started
passing is a defect in the test suite.

=head1 METHODS

    name()        "suite name :: relative/path"
    path()        absolute source path, Unix syntax
    rel()         path relative to the suite root
    config()      the effective Lit::Config for this test
    result()      one of the codes above
    output()      the failure report
    elapsed()     seconds
    metrics()     hashref of values recorded by the metrics builtin
    exec_dir()    this test's own Output directory
    temp_base()   the value %t expands to

=head1 SEE ALSO

L<Lit>, L<Lit::TestRunner>

=cut
