# HLstatsZ - Real-time player and clan rankings and statistics
# This file is part of HLstatsZ, released under the GNU General Public License v2 or later.
#
# For current support and updates:
#    https://snipezilla.com
#    https://github.com/SnipeZilla
#
# hlstatsz_profile.pl - performance profiler for the HLstatsZ daemon
#
# Turn it on:  set "Profile 1" in hlstats.conf and restart HLstatsZ. Set it back to 0 when you are done.
#
# While it is on, the daemon times its own work and adds a line every 5 seconds to hlstatsz_profile.log, in the
# profile folder next to hlstats.pl. Open that log with hlstatsz_profile_viewer.html, in the same folder (any
# browser, no internet needed), to see how the daemon copes with the load, and what it is waiting for when it does not.
#
# The log never takes more than about 10 MB: at 5 MB hlstatsz_profile.log is renamed hlstatsz_profile.old.log
# (replacing the previous one) and a new log is started. While the daemon has nothing to do, it writes a short
# "idle" line once a minute instead of a line every 5 seconds.
#
# A line of the log:
#   2026-11-09 08:20:07 dt=5.00s lines=507 (101/s) total=1112 servers=3 players=57 slots=96 top=212 busy=2388ms
#       cpu=310ms stall=2012ms handle=375ms db=20ms (29 calls) rcon=2012ms (2 calls) rcon_sent=26ms (664 calls)
#       lookup=0ms (0 calls) out=0ms (0 calls) timer=2013ms :: INSERT hlstats_Events_Frags n=11 15ms | ...
#
#   dt         length of the interval
#   lines      log lines handled in the interval (total: since the daemon started)
#   servers    game servers that sent lines in the interval; players: the players on them; slots: the players they
#              have room for (0 when the daemon does not know it for one of them); top: the lines of the busiest one
#   busy       time spent in all the work timed here (the daemon does one thing at a time)
#   cpu        processor time used by the whole daemon
#   stall      the longest time the daemon went without coming back to its event loop
#   handle     handling the log lines (handleIncoming), with the database and rcon calls made from there
#   timer      the periodic work (handleData) and what the daemon does with a game server's answer it did not wait
#              for, with the database and rcon calls made from there
#   db         database statements
#   rcon       rcon commands that wait for the game server's answer
#   rcon_sent  rcon messages, and questions, sent without waiting for the answer
#   lookup     GeoIP lookups, DNS, and the query of a new game server
#   out        writing the daemon's own output (DebugLevel)
#   ::         the 8 statements that took the most time: name, number of calls, time
#
# db, rcon, rcon_sent, lookup and out do not overlap: the time spent in one is not counted in another.

package HLstatsZ::Profile;

use strict;
use warnings;
use Time::HiRes ();
use Mojo::IOLoop;

# Once only (everything below is kept in variables, so loading this file a second time changes nothing)
our $loaded;
return 1 if $loaded++;

my $INTERVAL  = 5;                  # seconds between two lines
my $MAX_BYTES = 5 * 1024 * 1024;    # size of a log file: the log and one old log are kept
my $IDLE_LINE = 60;                 # seconds between two "idle" lines while nothing happens
my $TOP       = 8;                  # statements listed on a line
my $PROBE     = 0.1;                # seconds between two checks that the event loop answers (stall)

# The log goes in the profile folder, with the viewer that reads it
my $base = defined $main::opt_libdir && length $main::opt_libdir ? $main::opt_libdir : '.';
$base =~ s{(?<=.)[\\/]+\z}{};
my $dir  = "$base/profile";
my $path = "$dir/hlstatsz_profile.log";
my $old  = "$dir/hlstatsz_profile.old.log";

# Seconds on a clock that never goes back (the system clock where the machine has no such clock)
my $now = eval { require Mojo::Util; Mojo::Util->can('steady_time') } || \&Time::HiRes::time;

##
## The log
##

my ($log, $size) = (undef, 0);
my $eol = $^O eq 'MSWin32' ? 2 : 1;    # bytes of a line end in the file

my $open = sub {
    my ($mode) = @_;
    mkdir $dir unless -d $dir;          # the profile folder, made again if it was removed
    open(my $fh, $mode, $path) or return 0;
    my $was = select($fh); $| = 1; select($was);
    ($log, $size) = ($fh, $mode eq '>' ? 0 : (-s $fh) || 0);
    return 1;
};

# One line to the log. The profiler never stops the daemon: a log that cannot be written is tried again at the
# next line.
my $write = sub {
    my ($line) = @_;
    return unless $log || $open->('>>');

    if ($size + length($line) > $MAX_BYTES) {
        close($log);
        undef $log;
        unlink($old);
        # The old log cannot be replaced (open in another program): this log is emptied instead, the limit holds
        my $kept = rename($path, $old);
        return unless $open->($kept ? '>>' : '>');
    }

    if (print {$log} $line) {
        $size += length($line) - 1 + $eol;
    } else {
        close($log);
        undef $log;
    }
};

my $stamp = sub {
    my ($s, $m, $h, $d, $mo, $y) = localtime;
    return sprintf('%04d-%02d-%02d %02d:%02d:%02d', $y + 1900, $mo + 1, $d, $h, $m, $s);
};

# Nothing is changed in the daemon when the log cannot be written
$open->('>>') or die "cannot write $path: $!\n";

##
## The timers
##

my %acc = map { $_ => [0, 0] } qw(handle timer db rcon sent lookup out);    # what => [ms, calls]
my (%stmt, %label);                 # statement => [calls, ms]; exec_cache id => its name on the line
my ($lines, $total, $busy) = (0, 0, 0);
our $inside;                        # while a timed call runs: where the timed calls it makes add their time

# "UPDATE hlstats_Weapons", "SELECT hlstats_Players": the verb and the table of a statement
my $statement = sub {
    my $head = substr($_[0] // '', 0, 1000);
    my ($verb)  = $head =~ /^\s*(\w+)/;
    my ($table) = $head =~ /\b(?:FROM|INTO|UPDATE|TABLE)\s+`?(\w+)/i;
    return uc($verb // '?') . ' ' . ($table // '?');
};

# Time every call of $sub into $what. The time a timed call spends in other timed calls is taken off its own,
# except for handle and timer: these two count all they do.
my $time = sub {
    my ($sub, $what, $name) = @_;
    no strict 'refs';
    no warnings 'redefine';
    return unless defined &$sub;
    my $orig  = \&$sub;
    my $slot  = $acc{$what};
    my $whole = $what eq 'handle' || $what eq 'timer';
    my $line  = $what eq 'handle';
    my $apart = $what eq 'timer' && $sub ne 'main::handleData';

    *$sub = sub {
        goto &$orig if $apart && $inside;    # part of the work that is being timed already
        my $nested = 0;
        my $t0     = $now->();
        my (@r, $r);
        {
            local $inside = \$nested;
            if    (wantarray)         { @r = $orig->(@_) }
            elsif (defined wantarray) { $r = $orig->(@_) }
            else                      { $orig->(@_) }
        }
        my $ms = ($now->() - $t0) * 1000;
        if ($inside) { $$inside += $ms } else { $busy += $ms }
        $ms -= $nested unless $whole;
        $ms = 0 if $ms < 0;
        $slot->[0] += $ms;
        $slot->[1]++;
        if ($name) {
            my $s = $stmt{ $name->(@_) } ||= [0, 0];
            $s->[0]++;
            $s->[1] += $ms;
        }
        if ($line) { $lines++; $total++ }
        return wantarray ? @r : $r;
    };
    return 1;
};

$time->('main::handleIncoming', 'handle');
$time->('main::handleData',     'timer');
$time->('main::query_now',  'db', sub { $statement->($_[0]) });
$time->('main::exec_now',   'db', sub { $statement->($_[0]) });
$time->('main::exec_cache', 'db', sub { $label{ $_[0] } //= "$_[0] [" . $statement->($_[1]) . ']' });
$time->("${_}::execute",        'rcon') for qw(TRcon BASTARDrcon);
$time->("${_}::execute_nowait", 'sent') for qw(TRcon BASTARDrcon);
$time->("${_}::execute_later",  'sent') for qw(TRcon BASTARDrcon);
# What the daemon does when a game server answers a question it did not wait for: periodic work, timed here when
# it is not part of handleIncoming or handleData (where the daemon asked and waited)
$time->($_, 'timer') for qw(main::cleanupPlayers HLstats_Server::set_status HLstats_Server::save_server_load);
$time->($_, 'lookup') for qw(HLstats_Player::geoLookup HLstats_Server::update_server_loc main::queryServer);
$time->('main::_dbg_flush', 'out');

##
## A line every $INTERVAL seconds
##

my $cpu = sub { my ($user, $system) = times; return $user + $system };

my ($tick_at, $probe_at, $cpu_at, $stall) = ($now->(), $now->(), $cpu->(), 0);
my ($idle, $idle_end) = (0, '');

# The game servers that sent lines since the last line of the log: how many, their players, the players they have
# room for, the lines of the busiest
my %counted;                        # server => its line counter the last time
my $servers = sub {
    my ($n, $players, $slots, $unknown, $top, %now) = (0, 0, 0, 0, 0);
    for my $addr (keys %main::g_servers) {
        my $server = $main::g_servers{$addr};
        next unless ref $server && UNIVERSAL::isa($server, 'HASH');
        my $count = $server->{lines} // 0;
        my $new   = $count - ($counted{$addr} // 0);
        $new = $count if $new < 0;      # its counter starts again at 0 (after 500,000 lines, or a reload)
        $now{$addr} = $count;
        next unless $new > 0;
        $n++;
        $players += $server->{numplayers} // 0;
        my $room = $server->{maxplayers} // 0;
        if ($room =~ /^\d+$/ && $room > 0) { $slots += $room } else { $unknown = 1 }
        $top = $new if $new > $top;
    }
    %counted = %now;
    return ($n, $players, $unknown ? 0 : $slots, $top);
};

my $idle_line = sub {
    $write->(sprintf("%s idle %.0fs\n", $idle_end, $idle));
    $idle = 0;
};

my $tick = sub {
    my $t      = $now->();
    my $dt     = $t - $tick_at;
    my $cpu_s  = $cpu->();
    my $cpu_ms = ($cpu_s - $cpu_at) * 1000;
    ($tick_at, $cpu_at) = ($t, $cpu_s);

    # A stall that has just ended, before the probe below has seen it
    my $late = ($t - $probe_at - $PROBE) * 1000;
    if ($late > 0) {
        $stall    = $late if $late > $stall;
        $probe_at = $t - $PROBE;
    }

    my $calls = 0;
    $calls += $acc{$_}[1] for qw(db rcon sent lookup out);

    if (!$lines && !$calls && $busy < 1 && $stall < 250 && $dt < $INTERVAL + 1) {
        # Nothing to say: one line a minute
        $idle    += $dt;
        $idle_end = $stamp->();
        $idle_line->() if $idle >= $IDLE_LINE;
    } else {
        $idle_line->() if $idle;
        my @top = sort { $stmt{$b}[1] <=> $stmt{$a}[1] || $a cmp $b } keys %stmt;
        splice(@top, $TOP) if @top > $TOP;
        $write->(sprintf(
            "%s dt=%.2fs lines=%d (%.0f/s) total=%d servers=%d players=%d slots=%d top=%d"
          . " busy=%.0fms cpu=%.0fms stall=%.0fms"
          . " handle=%.0fms db=%.0fms (%d calls) rcon=%.0fms (%d calls) rcon_sent=%.0fms (%d calls)"
          . " lookup=%.0fms (%d calls) out=%.0fms (%d calls) timer=%.0fms :: %s\n",
            $stamp->(), $dt, $lines, $dt > 0 ? $lines / $dt : 0, $total, $servers->(), $busy, $cpu_ms, $stall,
            $acc{handle}[0], @{ $acc{db} }, @{ $acc{rcon} }, @{ $acc{sent} }, @{ $acc{lookup} }, @{ $acc{out} },
            $acc{timer}[0], join(' | ', map { sprintf('%s n=%d %.0fms', $_, @{ $stmt{$_} }) } @top)
        ));
    }

    @$_ = (0, 0) for values %acc;
    %stmt = ();
    $lines = $busy = $stall = 0;
};

$write->(sprintf("%s start HLstatsZ %s interval=%ds debug=%d os=%s perl=%vd pid=%d\n",
    $stamp->(), $main::g_version // '?', $INTERVAL, $main::g_debug // 0, $^O, $^V, $$));

# The probe: a timer that should run every $PROBE seconds. How late it runs is how long the loop was held up
Mojo::IOLoop->next_tick(sub { $probe_at = $now->() });
Mojo::IOLoop->recurring($PROBE => sub {
    my $t    = $now->();
    my $late = ($t - $probe_at - $PROBE) * 1000;
    $stall    = $late if $late > $stall;
    $probe_at = $t;
});

Mojo::IOLoop->recurring($INTERVAL => sub { eval { $tick->(); 1 } or warn "hlstatsz_profile: $@" });

# The daemon stops: the last interval, and a "stop" line (a daemon that was killed leaves none)
my $pid = $$;
END {
    if ($log && $pid && $pid == $$) {
        eval {
            $tick->();
            $idle_line->() if $idle;
            $write->($stamp->() . " stop\n");
        };
    }
}

1;
