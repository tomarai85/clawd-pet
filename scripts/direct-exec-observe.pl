#!/usr/bin/perl
# direct-exec-observe.pl: the observer behind scripts/direct-exec-check.sh. It starts ONE program, a copy of the installed agent that
# the caller made outside the install, and reads the window list back to back from before the exec until the program has exited. One
# perl process keeps the clock, the child and the loop, so the time between two reads is a millisecond or two and the figures are real.
#
#   direct-exec-observe.pl SAMPLER LIMIT_MS PROGRAM OUTFILE HOME
#
# SAMPLER is the read-only window lister (`SAMPLER windows` prints "WINDOW <pid> ..." lines and a "WINDOWS <n>" footer). HOME is a
# directory the caller made for this one run: the program is started with HOME and CFFIXED_USER_HOME set to it and with it as its working
# directory, so that the data directory the agent derives from $HOME (PetHome: $HOME wins when it names an existing directory) is a new
# one, and nothing of the real install is reachable through the environment. The observer REFUSES (exit 2, the program is not started) when
# HOME is missing, is not an absolute path to an existing directory, is a symbolic link, or is not empty. The only process this script ever
# signals is the child it started itself, and only at the limit. OUTFILE receives one line per event:
#   HOME <path>                           the directory the program is started with as its HOME (written before the fork)
#   EXEC <t_ms> <pid>                     the time just before the fork, and the child's pid
#   SNAP <start_ms> <end_ms> <ok 0|1> <windows_of_the_child> <alive_after 0|1>
#                                         one read of the window list; ok = the lister exited 0 and printed its footer; alive_after = the
#                                         child had not exited when the read returned (so it was alive during the whole read)
#   LIMIT <t_ms>                          the child was still running at LIMIT_MS and was stopped
#   EXIT <t_ms> <status>                  the child's exit status (256 * code + signal, as wait gives it)
#   STOPPED <t_ms>                        this observer was told to stop (TERM, INT or HUP): the child was stopped first; exit status 3
# Times are milliseconds since the fork (EXEC is 0). Exit status 0 when the child was started, 2 when it could not be or was refused.
use strict;
use warnings;
use POSIX ":sys_wait_h";
use Time::HiRes qw(time sleep);

my ($sampler, $limit_ms, $program, $outfile, $home) = @ARGV;
unless (defined $home && @ARGV == 5) {
    print STDERR "usage: direct-exec-observe.pl SAMPLER LIMIT_MS PROGRAM OUTFILE HOME\n";
    exit 2;
}
# The program never runs with the caller's HOME: no HOME, or one that is not a new, empty, real directory, is a refusal before the fork.
my $dh;
unless ($home =~ m{^/[^\0]+$} && -d $home && !-l $home && opendir($dh, $home)) {
    print STDERR "direct-exec-observe: refused: HOME is not an absolute path to a directory (not a symbolic link): $home\n";
    exit 2;
}
my @inside = grep { $_ ne "." && $_ ne ".." } readdir($dh);
closedir($dh);
if (@inside) {
    print STDERR "direct-exec-observe: refused: HOME is not empty: $home\n";
    exit 2;
}
open(my $out, ">", $outfile) or die "cannot write $outfile: $!\n";
select((select($out), $| = 1)[0]);
print $out "HOME $home\n";

my $t0 = time;
my $pid = fork();
die "fork failed: $!\n" unless defined $pid;
if ($pid == 0) {
    open(STDIN, "<", "/dev/null");
    open(STDOUT, ">", "$outfile.child") or exit 127;
    open(STDERR, ">&", \*STDOUT);
    $ENV{HOME} = $home;
    $ENV{CFFIXED_USER_HOME} = $home;
    chdir($home) or exit 127;
    exec {$program} $program or exit 127;
}
sub ms { return int((time - $t0) * 1000 + 0.5) }
print $out "EXEC 0 $pid\n";

# When the caller stops this observer, the program it started stops with it (it is this script's own child, never anything found by name).
my $stopping = sub {
    kill "TERM", $pid;
    my $n = 0;
    while (waitpid($pid, WNOHANG) != $pid && $n < 100) { sleep(0.02); $n++ }
    if ($n >= 100) { kill "KILL", $pid; waitpid($pid, 0) }
    print $out "STOPPED ", ms(), "\n";
    exit 3;
};
$SIG{TERM} = $stopping; $SIG{INT} = $stopping; $SIG{HUP} = $stopping;

my $status;
while (1) {
    my $start = ms();
    my ($ok, $owned, $footer) = (0, 0, 0);
    if (open(my $lister, "-|", $sampler, "windows")) {
        while (my $line = <$lister>) {
            if ($line =~ /^WINDOW (\d+) /) { $owned++ if $1 == $pid }
            elsif ($line =~ /^WINDOWS \d+\s*$/) { $footer = 1 }
        }
        close($lister);
        $ok = ($? == 0 && $footer) ? 1 : 0;
    }
    my $end = ms();
    my $reaped = waitpid($pid, WNOHANG);
    my $alive = ($reaped == $pid) ? 0 : 1;
    $status = $? if !$alive;
    print $out "SNAP $start $end $ok $owned $alive\n";
    last unless $alive;
    if ($end >= $limit_ms) {
        kill "TERM", $pid;
        my $n = 0;
        while (waitpid($pid, WNOHANG) != $pid && $n < 100) { sleep(0.02); $n++ }
        if ($n >= 100) { kill "KILL", $pid; waitpid($pid, 0) }
        $status = $?;
        print $out "LIMIT ", ms(), "\n";
        last;
    }
}
print $out "EXIT ", ms(), " ", (defined $status ? $status : -1), "\n";
close($out);
exit 0;
