#!/usr/bin/perl
#
# mkcom.PL - generate vms/lit_define_commands.com
#
# Run by make, through MakeMaker's PL_FILES, with the target file name as
# its only argument.  It exists because the procedure has to name the place
# "make install" will actually put the scripts, and the Perl image that
# will run them - neither of which is known until build time.
#
# The DCL is the template in the __DATA__ section at the bottom.  Edit it
# there: the generated .com is overwritten by every build.

use strict;
use warnings;

use Config;

my $target = shift(@ARGV);
$target = 'vms/lit_define_commands.com'
    unless defined $target && length $target;

# MakeMaker passes only the target.  The two optional arguments after it
# let a test generate the OpenVMS-shaped procedure from any host.
my ($force_root, $force_perl) = @ARGV;

# Where EXE_FILES land, and the Perl that will run them.
my $root = '';
foreach my $k (qw(installscript installsitescript installbin)) {
    if (defined $Config{$k} && length $Config{$k}) { $root = $Config{$k}; last }
}
my $perl = $^X;

if ($^O eq 'VMS') {
    eval {
        require VMS::Filespec;
        $root = VMS::Filespec::vmspath($root) if length $root;
        $perl = VMS::Filespec::vmsify($perl);
        1;
    };
}
else {
    # Built somewhere other than OpenVMS.  Generate the procedure anyway, so
    # the template is exercised, but leave the paths empty rather than bake
    # in a Unix path DCL could not use: the procedure checks for that and
    # refuses.  Emitting "SET DEFAULT /work"-style nonsense is exactly the
    # failure this project has been bitten by before.
    $root = '';
    $perl = '';
}

if (defined $force_root) { $root = $force_root }
if (defined $force_perl) { $perl = $force_perl }

my $dcl = do { local $/; <DATA> };
$dcl =~ s/\@LIT_ROOT\@/$root/g;
$dcl =~ s/\@LIT_PERL\@/$perl/g;

open(my $fh, '>', $target) or die "$0: cannot write $target: $!\n";
print $fh $dcl;
close($fh) or die "$0: cannot close $target: $!\n";

print "Generated $target\n";
exit 0;

__DATA__
$ !
$ ! LIT_DEFINE_COMMANDS.COM - define the Lit foreign commands.
$ !
$ ! GENERATED FILE - do not edit.  The template lives in the __DATA__
$ ! section of [.VMS]MKCOM.PL, and this file is rewritten by every build.
$ !
$ ! Copy it to SYS$STARTUP: and call it from SYS$MANAGER:SYLOGIN.COM, or let
$ ! users call it from their own LOGIN.COM:
$ !
$ !     $ IF F$SEARCH("SYS$STARTUP:LIT_DEFINE_COMMANDS.COM") .NES. "" THEN -
$ !         @SYS$STARTUP:LIT_DEFINE_COMMANDS.COM
$ !
$ ON WARNING THEN CONTINUE
$ !
$ LIT_ROOT = "@LIT_ROOT@"
$ LIT_PERL = "@LIT_PERL@"
$ !
$ LIT       :== $'LIT_PERL' 'LIT_ROOT'LIT.PL
$ FILECHECK :== $'LIT_PERL' 'LIT_ROOT'FILECHECK.PL
$ !
$ EXIT 1
