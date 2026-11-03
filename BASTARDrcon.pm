package BASTARDrcon;
# HLstatsZ - Real-time player and clan rankings and statistics
# Originally HLstatsX Community Edition by Nicholas Hastings (2008–20XX)
# Based on ELstatsNEO by Malte Bayer, HLstatsX by Tobias Oetzel, and HLstats by Simon Garner
#
# HLstats > HLstatsX > HLstatsX:CE > HLStatsZ
# HLstatsZ continues a long lineage of open-source server stats tools for Half-Life and Source games.
# This version is released under the GNU General Public License v2 or later.
# 
# For current support and updates:
#    https://snipezilla.com
#    https://github.com/SnipeZilla
#    https://forums.alliedmods.net/forumdisplay.php?f=156

use strict;

use sigtrap;
use Socket qw(PF_INET SOCK_DGRAM INADDR_ANY sockaddr_in inet_aton);
use IO::Select;
use Scalar::Util;
use Time::HiRes qw(time);
use Mojo::IOLoop;
use bytes;

##
## Main
##

my $TIMEOUT     = 2.0;
my $RETRY_EVERY = 1;      # seconds between attempts while the server does not answer
my $QUEUE_MAX   = 100;    # messages kept while a challenge is being asked for ...
my $QUEUE_TTL   = 10;     # ... for this many seconds at most
my $STATUS_END  = qr/^\s*\d+ users?\s*$/m;    # the last line of "status": its answer is complete

#
# Constructor
#
sub new
{
    my ($class_name, $server_object) = @_;
    my ($self) = {};
    bless($self, $class_name);

    # Initialise properties
    $self->{server_object} = $server_object;
    Scalar::Util::weaken($self->{server_object});
    $self->{rcon_password} = $server_object->{rcon}  or die("BASTARDrcon: a Password is required\n");
    $self->{address}       = $server_object->{address};
    $self->{ipAddr}        = inet_aton($server_object->{address});
    $self->{server_port}   = int($server_object->{port}) or die("BASTARDrcon: invalid Port \"" . $server_object->{port} . "\"\n");
    $self->{addr}          = "$self->{address}:$self->{server_port}";

    $self->{rcon_socket}   = undef;
    $self->{rcon_err}      = 0;
    $self->{ready}         = 0;     # challenge known and password checked: commands go out
    $self->{opening}       = '';    # 'challenge', then 'probe' (the password checked), while a challenge is asked for
    $self->{tried}         = 0;     # the first challenge is asked at once, every later one in the background
    $self->{retry_at}      = 0;     # no new attempt before this time (a second after a failure)
    $self->{retry_wait}    = 0;     # after a refused password: seconds between attempts, doubled each time
    $self->{queue}         = [];    # [time, command] of the messages given while a challenge was asked for
    $self->{down_since}    = 0;     # the server has not answered since then
    $self->{down_logged}   = 0;
    $self->{destroyed}     = 0;

    return $self;
}

#
# Execute an Rcon command and return the response. A command with arguments (a message, a kick, a ban) is sent
# without waiting for its answer. $done: the answer is complete once it matches (no wait for more packets).
#
sub execute
{
    my ($self, $command, $done) = @_;
    $done //= $STATUS_END if $command eq 'status';
    return $self->_sendrecv($command, $done) if $command =~ /^\S+$/;
    $self->execute_nowait($command);
    return "";
}

#
# Send a command without waiting for its answer (dorcon in void context). Returns 1 when sent.
# While a challenge is being asked for, the command waits for it ($QUEUE_TTL seconds at most).
#
sub execute_nowait
{
    my ($self, $command) = @_;
    if ($self->_ready()) {
        return 1 if $self->_send_rcon($command);
        $self->_lost("Cannot send to the server: $!");
    }
    my $queue = $self->{queue};
    push @$queue, [time(), $command];
    shift @$queue while @$queue > $QUEUE_MAX;
    return 0;
}

#
# A command whose answer is wanted
#
sub _sendrecv
{
    my ($self, $cmd, $done, $retried) = @_;
    return "" unless $self->_ready();
    unless ($self->_send_rcon($cmd)) {
        $self->_lost("Cannot send to the server: $!");
        return "";
    }

    my $ans = $self->_read_multi_packets($TIMEOUT, $done);
    unless (defined $ans) {
        ::printEvent("RCON", "$cmd :: Failed to read packet", 1, $self->{addr});
        # Down, or loading a map: a new challenge is asked for in the background
        $self->_lost("No answer");
        return "";
    }

    # The server was restarted (its challenges are new), or changed its password: asked again at once, as it answers,
    # and the command sent again once (the new challenge tells which, a bad password is not tried again for a while)
    if ($ans =~ /^(?:Bad challenge|No challenge|Bad rcon_password)/m) {
        if ($retried) {
            $self->_lost("Challenge refused");
            return "";
        }
        ::printEvent("RCON", "Challenge expired", 1, $self->{addr});
        return "" unless $self->_open_now();
        return $self->_sendrecv($cmd, $done, 1);
    }
    $self->{rcon_err} = 0;
    return $ans;
}

#
# Challenge known and password checked. Otherwise a challenge is asked for in the background (not before retry_at
# after a failure) and the caller goes on without it: a server that is down never makes the daemon wait.
# The very first one is asked at once: the server just sent its first log line, and the daemon needs its map.
#
sub _ready
{
    my ($self) = @_;
    # Answers to earlier messages: an expired challenge shows there
    $self->_read_packets(0) if $self->{ready};
    return 1 if $self->{ready};
    return 0 if $self->{opening} || $self->{retry_at} > time() || $self->{destroyed};
    return $self->_open_now() unless $self->{tried}++;
    $self->_open();
    return 0;
}

#
# A challenge asked for while the caller waits (2 s at most)
#
sub _open_now
{
    my ($self) = @_;
    return 0 unless $self->_open($TIMEOUT);
    my $deadline = time() + $TIMEOUT;
    while ($self->{opening}) {
        my $remain = $deadline - time();
        return $self->_failed("No answer to the rcon challenge") if $remain <= 0;
        $self->_read_packets($remain);
    }
    return $self->{ready};
}

#
# Ask for a challenge on a new socket, without waiting: the event loop reads the answer, then checks the password
# with a harmless command. The answers still on their way to the old socket are dropped with it.
# A server that is up answers within its next frame: one attempt a second while it does not.
#
sub _open
{
    my ($self, $wait) = @_;
    return 0 if $self->{destroyed};
    $self->_close_socket();
    $self->{attempt_at} = time();

    my $proto = getprotobyname('udp') // 0;
    my $sock;
    unless (socket($sock, PF_INET, SOCK_DGRAM, $proto) && bind($sock, sockaddr_in(0, INADDR_ANY))) {
        return $self->_failed("Cannot setup UDP socket: $!");
    }
    $self->{rcon_socket} = $sock;
    $self->{opening}     = 'challenge';

    # The socket is read by the event loop from now on: answers to messages, an expired challenge
    Scalar::Util::weaken(my $weak = $self);
    my $reactor = Mojo::IOLoop->singleton->reactor;
    $reactor->io($sock => sub { $weak->_read_packets(0) if $weak })->watch($sock, 1, 0);
    $self->{open_timer} = $reactor->timer($wait || $RETRY_EVERY => sub { $weak->_failed("No answer to the rcon challenge") if $weak && $weak->{opening} });

    return 1 if $self->_send_raw("challenge rcon\n");
    return $self->_failed("Cannot send to the server: $!");
}

#
# Every packet the server sent (the first one waited for $timeout seconds at most), to _handle_packet
#
sub _read_packets
{
    my ($self, $timeout) = @_;
    my $sock = $self->{rcon_socket} or return;
    my $sel  = IO::Select->new($sock);
    for (my $n = 0; $n < 64 && $sel->can_read($n ? 0 : $timeout); $n++) {
        my $buf = '';
        unless (defined recv($sock, $buf, 8192, 0)) {
            # Windows reports a closed port this way ("port unreachable" for an earlier packet)
            $self->_lost("The server port is closed") if $self->{ready} && ($!{ECONNRESET} || $!{ECONNREFUSED});
            last;
        }
        $self->_handle_packet(_strip($buf));
        # Closed, or replaced by a new one, by _handle_packet
        last unless $self->{rcon_socket} && $self->{rcon_socket} == $sock;
    }
}

sub _handle_packet
{
    my ($self, $buf) = @_;
    my $opening = $self->{opening};

    if ($opening eq 'challenge') {
        return unless $buf =~ /challenge\s+rcon\s+("?)(-?\d+)\1/i;
        $self->{_rcon_challenge} = $2;
        $self->{opening} = 'probe';
        # The password, checked with a harmless command before any other is sent: game servers ban an address
        # after a few bad ones (sv_rcon_minfailures within sv_rcon_minfailuretime)
        return 1 if $self->_send_rcon("echo hlstatsz");
        return $self->_failed("Cannot send to the server: $!");
    }
    if ($buf =~ /^(?:Bad challenge|No challenge)/m) {
        return $opening ? $self->_failed("Challenge refused") : $self->_lost("Challenge expired");
    }
    if ($buf =~ /^Bad rcon_password/m) {
        # Right after a new challenge, it is the password; later, it may be a server that changed its challenge
        return $opening ? $self->_refused() : $self->_lost("Bad rcon_password");
    }
    return $self->_opened() if $opening eq 'probe';
    # Otherwise the answer to a message: nothing reads it
}

sub _opened
{
    my ($self) = @_;
    my $reactor = Mojo::IOLoop->singleton->reactor;
    $reactor->remove(delete $self->{open_timer}) if $self->{open_timer};
    ::printEvent("RCON", "Rcon password accepted", 1, $self->{addr});
    if ($self->{down_logged}) {
        ::printEvent("RCON", sprintf("Answering again after %.0f s", time() - $self->{down_since}), 1, $self->{addr});
    }
    $self->{opening}     = '';
    $self->{ready}       = 1;
    $self->{rcon_err}    = 0;
    $self->{retry_at}    = 0;
    $self->{retry_wait}  = 0;
    $self->{down_since}  = 0;
    $self->{down_logged} = 0;

    # What was given while the challenge was asked for
    my @queue = @{ $self->{queue} };
    $self->{queue} = [];
    my $now = time();
    for my $q (@queue) {
        next if $now - $q->[0] > $QUEUE_TTL;
        last unless $self->_send_rcon($q->[1]);
    }
    return 1;
}

#
# No answer: tried again a second after the start of this attempt (at once after a time-out). The error count grows
# with the time the server has been down (1, then 2 after 15 s, 3 after 30 s: hlstats.pl takes the players off a server
# that has been down for 30 s).
#
sub _failed
{
    my ($self, $why) = @_;
    $self->_close_socket();
    my $now = time();
    $self->{down_since} ||= $now;
    $self->{rcon_err} = 1 + int(($now - $self->{down_since}) / 15);
    $self->_log_down($why, "trying again every second");
    my $delay = ($self->{attempt_at} // 0) + $RETRY_EVERY - $now;
    $self->_retry_in($delay > 0 ? $delay : 0);
    return 0;
}

#
# A server that answered stopped answering, or changed its challenge: a new one is asked for at once, in the background
#
sub _lost
{
    my ($self, $why) = @_;
    $self->{down_since} ||= time();
    $self->{rcon_err} ||= 1;
    ::printEvent("RCON", "$why: asking for a new challenge", 3, $self->{addr});
    $self->{retry_at} = 0;
    $self->_open();
    return 0;
}

#
# A refused password is not tried again for 10 s, then 20 s, 40 s, then once a minute. The server is up: its players stay.
#
sub _refused
{
    my ($self) = @_;
    $self->_close_socket();
    $self->{rcon_err} = 1;
    my $wait = ($self->{retry_wait} || 5) * 2;
    $self->{retry_wait} = $wait > 60 ? 60 : $wait;
    ::printEvent("RCON", "Rcon password refused: next attempt in $self->{retry_wait} s", 1, $self->{addr});
    $self->_retry_in($self->{retry_wait});
    return 0;
}

# The next attempt is made by the event loop, even when no command needs the server
sub _retry_in
{
    my ($self, $delay) = @_;
    my $reactor = Mojo::IOLoop->singleton->reactor;
    $reactor->remove(delete $self->{retry_timer}) if $self->{retry_timer};
    $self->{retry_at} = time() + $delay;
    return if $self->{destroyed};

    Scalar::Util::weaken(my $weak = $self);
    $self->{retry_timer} = $reactor->timer($delay => sub {
        return unless $weak;
        delete $weak->{retry_timer};
        $weak->{retry_at} = 0;
        $weak->_ready();
    });
}

# Once per outage
sub _log_down
{
    my ($self, $why, $next) = @_;
    return if $self->{down_logged}++;
    $why =~ s/\s+\z//;
    ::printEvent("RCON", "$why: $next", 1, $self->{addr});
}

sub _close_socket
{
    my ($self) = @_;
    my $reactor = Mojo::IOLoop->singleton->reactor;
    $reactor->remove(delete $self->{open_timer}) if $self->{open_timer};
    if (my $sock = delete $self->{rcon_socket}) {
        $reactor->remove($sock) if defined fileno($sock);
        eval { close($sock); };
    }
    delete $self->{_rcon_challenge};
    $self->{ready}   = 0;
    $self->{opening} = '';
}

sub _send_rcon
{
    my ($self, $cmd) = @_;
    my $challenge = $self->{_rcon_challenge} // return 0;
    return $self->_send_raw(qq{rcon $challenge "$self->{rcon_password}" $cmd\n});
}

sub _send_raw
{
    my ($self, $text) = @_;
    my $sock = $self->{rcon_socket} or return 0;
    return defined send($sock, "\xFF\xFF\xFF\xFF" . $text, 0, sockaddr_in($self->{server_port}, $self->{ipAddr}));
}

sub _strip
{
    my ($buf) = @_;
    $buf =~ s/\x00+$//g;                 # trailing craps/nulls
    $buf =~ s/^\xFF\xFF\xFF\xFFl//;      # HL response
    $buf =~ s/^\xFF\xFF\xFF\xFFn//;      # QW response
    $buf =~ s/^\xFF\xFF\xFF\xFF//;       # Q2/Q3 response
    $buf =~ s/^\xFE\xFF\xFF\xFF.....//;  # old HL feature
    return $buf;
}

#
# An answer, in one packet or more: the first within $timeout_first seconds, the next ones 0.2 s apart at most,
# none more once it matches $done
#
sub _read_multi_packets {
    my ($self, $timeout_first, $done) = @_;

    my $sock = $self->{rcon_socket} or return undef;
    my $sel  = IO::Select->new($sock);

    my $timeout = $timeout_first;
    my $ans     = "";

    while ($sel->can_read($timeout)) {
        my $buf = "";
        last unless defined recv($sock, $buf, 8192, 0);   # recv error
        $ans .= _strip($buf);
        last if ($done && $ans =~ $done) || $ans =~ /^(?:Bad challenge|No challenge|Bad rcon_password)/m;
        $timeout = 0.20; # next packet
    }

    return undef if $ans eq "";
    return $ans;
}

sub destroy {
    my ($self) = @_;
    $self->{destroyed} = 1;
    $self->_close_socket();
    my $reactor = Mojo::IOLoop->singleton->reactor;
    $reactor->remove(delete $self->{retry_timer}) if $self->{retry_timer};
    $self->{queue}    = [];
    $self->{rcon_err} = 0;
    return 1;
}

# Also when the server object is deleted: no watcher may stay on a closed socket
sub DESTROY
{
    my ($self) = @_;
    $self->destroy() unless ${^GLOBAL_PHASE} eq 'DESTRUCT';
}

#
# Parse "status" command output into player information
#
sub getPlayers
{
    my ($self) = @_;
    my $status = $self->execute("status") // '';
    my $server = "$self->{server_object}->{address}:$self->{server_object}->{port}";

    my @lines = split(/[\r\n]+/, $status);

    my %players;
    my $md5;

    # HL1
    #      name userid uniqueid frag time ping loss adr
    # 1 "psychonic" 1 STEAM_0:1:4153990   0 00:33   13    0 192.168.5.115:27005
    # 2 "SnipeZilla" 2 BOT  11  1:37:35    0    0
    foreach my $line (@lines)
    {
        $line =~ s/[\x00-\x1F\x80-\xFF]+//g;                    # remove binary junk
        $line =~ s/^l(?=(hostname|map|players|\#))//;           # fix lhostname, l#, etc.
        $line =~ s/(BOT\s+\d+)\s+[^\d:]+(\d+:\d+:\d+)/$1 $2/;   # fix frag→time corruption
        $line =~ s/(\d+:\d+:\d+)l/$1/;                          # fix stray 'l' after time

        if ($line =~ /^\s*hostname\s*:\s*([\S].*)$/) {
            $players{"host"}{"name"} = $1; # host
        }
        elsif ($line =~ /\s*map\s*:\s*([\S]+).*$/) {
            $players{"host"}{"map"} = $1; # map
        }
        elsif ($line =~ /^\s*players\s*:\s*\d+[^(]+\((\d+)\/?\d?\smax.*$/) {
            $players{"host"}{ "max_players"} = $1;
        }
        elsif ($line =~ /
            ^\#\s*\d+\s+          # slot
            "(.+?)"\s+            # $1 name
            (\d+)\s+              # $2 userid
            BOT\b                 # uniqueid = BOT
            /x)
        {
            my ($name, $userid) = ($1, $2);
            $md5 = Digest::MD5->new;
            $md5->add($name);
            $md5->add($server);
            my $uniqueid = "BOT:" . $md5->hexdigest;
            my $key = ($::g_mode eq "NameTrack") ? $name : $uniqueid;
            next unless $key;

            $players{$key} = {
                "Name"       => $name,
                "UserID"     => $userid,
                "UniqueID"   => $uniqueid,
                "Ping"       => 0,
                "Address"    => ""
            };
        }
        elsif ($line =~ /^\#\s*\d+\s+          # slot
                         "(.+?)"\s+            # $1 name
                         (\d+)\s+              # $2 userid
                         ([^\s]+)\s+           # $3 uniqueid (BOT or STEAM_x)
                         \d+\s+                # frag (ignored)
                         [\d:]+\s+             # time
                         (\d+)\s+              # $4 ping
                         \d+                   # loss
                         (?:\s+([^:]+):\d+)?   # $5 optional addr:port
                         \s*$/x)
        {
            my $name     = $1;
            my $userid   = $2;
            my $uniqueid = $3;
            my $ping     = $4;
            my $address  = $5 // "";

            $uniqueid =~ s/^STEAM_[0-9]+://i;

            my $key = ($::g_mode eq "NameTrack") ? $name : ($::g_mode eq "LAN" && $address) ? "$address/$userid/$name" : $uniqueid;

            $players{$key} = {
                "Name"       => $name,
                "UserID"     => $userid,
                "UniqueID"   => $uniqueid,
                "Ping"       => $ping,
                "Address"    => $address
            };
        }

    }
    return %players;
}

sub getServerData
{
  my ($self) = @_;
  my $status = $self->execute("status") // '';

  my @lines = split(/[\r\n]+/, $status);

  my $servhostname         = "";
  my $map         = "";
  my $max_players = 0;
  foreach my $line (@lines)
  {
    if ($line =~ /^\s*hostname\s*:\s*([\S].*)$/x)
    {
      $servhostname   = $1;
    }
    elsif ($line =~ /^\s*map\s*:\s*([\S]+).*$/x)
    {
      $map   = $1;
    }
    elsif ($line =~ /^\s*players\s*:\s*\d+.+\((\d+)\smax.*$/)
    {
      $max_players = $1;
    }
  }
  return ($servhostname, $map, $max_players, 0);
}


sub getVisiblePlayers
{
  my ($self) = @_;
  my $status = $self->execute("sv_visiblemaxplayers") // '';
  
  my @lines = split(/[\r\n]+/, $status);
  

  my $max_players = -1;
  foreach my $line (@lines)
  {
    # "sv_visiblemaxplayers" = "-1"
    #       - Overrides the max players reported to prospective clients
    if ($line =~ /^\s*"sv_visiblemaxplayers"\s*=\s*"([-0-9]+)".*$/x)
    {
      $max_players   = $1;
    }
  }
  return ($max_players);
}


#
# Get information about a player by userID
#

sub getPlayer
{
  my ($self, $uniqueid) = @_;
  my %players = $self->getPlayers();
  
  if (defined($players{$uniqueid}))
  {
    return $players{$uniqueid};
  }
  else
  {
    ::printEvent("RCON", "getPlayer No such player: $uniqueid", 3);
    return 0;
  }
}

1;
# end
