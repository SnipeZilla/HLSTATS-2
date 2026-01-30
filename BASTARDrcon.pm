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
use bytes;

##
## Main
##

my $TIMEOUT = 2.0;

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
    $self->{rcon_password} = $server_object->{rcon}  or die("BASTARDrcon: a Password is required\n");
    $self->{address}       = $server_object->{address};
    $self->{ipAddr}        = inet_aton($server_object->{address});
    $self->{server_port}   = int($server_object->{port}) or die("BASTARDrcon: invalid Port \"" . $server_object->{port} . "\"\n");

    $self->{socket} = undef;

    return $self;
}

#
# Execute an Rcon command and return the response
#
sub execute
{
    my ($self, $command) = @_;
    return $self->_sendrecv($command);
}

#
# Send and receive a package
#
sub _sendrecv
{
    my ($self, $cmd, $attempt) = @_;
    $attempt //= 0;

    if (!$self->{rcon_socket} || !defined fileno($self->{rcon_socket})) {
        return "" unless $self->_open_socket();
    }

    my $sock   = $self->{rcon_socket};
    my $ipaddr = $self->{ipAddr};
    my $port   = $self->{server_port};
    my $pass   = $self->{rcon_password};
    
    my $hisp   = sockaddr_in($port, $ipaddr);

    my $challenge = $self->_get_rcon_challenge();
    return $self->_healthcheck_socket() unless defined $challenge;

    my $payload = "rcon $challenge \"$pass\" $cmd\n";
    my $msg     = "\xFF\xFF\xFF\xFF" . $payload;

    my $sent = send($sock, $msg, 0, $hisp);
    return $self->_healthcheck_socket() unless defined $sent;

    my $ans = $self->_read_multi_packets($TIMEOUT);
    return $self->_healthcheck_socket() unless defined $ans;


    # Empty reply → stale challenge → retry once
    if ($ans =~ /No challenge/i && $attempt == 0) {
        ::printEvent("RCON", "Challenge expired for $self->{address}:$self->{server_port}",1);
        delete $self->{_rcon_challenge};
        return $self->_sendrecv($cmd, 1);
    }

    return $ans;
}

#
#  Socket management with healthcheck
#
sub _open_socket
{
    my ($self) = @_;

    if (defined $self->{rcon_socket}) {
        close($self->{rcon_socket});
        delete $self->{rcon_socket};
        ::printEvent("RCON", "Closing UDP socket on $self->{address}:$self->{server_port}: $!",1);
    }

    delete $self->{_rcon_challenge};

    my $proto = $self->{_proto};
    socket($self->{rcon_socket}, PF_INET, SOCK_DGRAM, $proto);
    unless ($self->{"rcon_socket"}) {
        ::printEvent("RCON", "Cannot setup UDP socket on $self->{address}:$self->{server_port}: $!",1);
        return 0;
    } else {
        ::printEvent("RCON", " UDP socket is now open on $self->{address}:$self->{server_port}",1);
    }

    my $bindaddr = sockaddr_in(0, INADDR_ANY);
    if (!bind($self->{rcon_socket}, $bindaddr)) {
        ::printEvent("RCON", " Error BASTARDrcon: rebuild bind: $!", 1);
        return 0;
    }
}

sub _get_rcon_challenge
{
    my ($self) = @_;

    return $self->{_rcon_challenge} if defined $self->{_rcon_challenge};

    my $sock   = $self->{rcon_socket};
    my $ipaddr = $self->{ipAddr};
    my $port   = $self->{server_port};
    my $hisp   = sockaddr_in($port, $ipaddr);

    my $challenge_req = "\xFF\xFF\xFF\xFFchallenge rcon\n";

    send($sock, $challenge_req, 0, $hisp)
        or return undef;

    my $ans = $self->_read_multi_packets($TIMEOUT);

    return undef if !$ans;

    my $challenge;
    if ($ans =~ /challenge\s+rcon\s+("?)(-?\d+)\1/i) {
        $challenge = $2;
    } else {
        return undef;
    }

    $self->{_rcon_challenge} = $challenge;
    return $challenge;
}

sub _read_multi_packets
{
    my ($self, $timeout_first) = @_;

    my $sock = $self->{rcon_socket} or return "";

    my $rin = "";
    vec($rin, fileno($sock), 1) = 1;

    my $timeout = $timeout_first;
    my $ans     = "";
    my $buf;

    while (1) {
        my $ready = select(my $rout = $rin, undef, undef, $timeout);
        last unless $ready;

        $buf = "";
        recv($sock, $buf, 8192, 0);
        $ans .= $buf;

        $timeout = 0.20; # Next packet
    }

    return undef unless $ans;

    # Strip HL headers
    $ans =~ s/\x00+$//g;                 # trailing crap
    $ans =~ s/^\xFF\xFF\xFF\xFFl//g;     # HL response
    $ans =~ s/^\xFF\xFF\xFF\xFFn//g;     # QW response
    $ans =~ s/^\xFF\xFF\xFF\xFF//g;      # Q2/Q3 response
    $ans =~ s/^\xFE\xFF\xFF\xFF.....//g; # old HL bug/feature

    return $ans;
}

sub _healthcheck_socket
{
    my ($self) = @_;

    my $sock         = $self->{rcon_socket};
    my ($local_port) = sockaddr_in(getsockname($sock));
    my $loop_addr    = sockaddr_in($local_port, inet_aton("127.0.0.1"));

    my $echo = "hlstatsz-echo";
    my $sent = send($sock, $echo, 0, $loop_addr);

    if (!defined $sent) {
        ::printEvent("RCON", " UDP socket can't send: stalled or crashed",1);
        return $self->_open_socket();
    }

    my $rin = "";
    vec($rin, fileno($sock), 1) = 1;

    # loopback address
    my $ready = select(my $rout = $rin, undef, undef, 0.05);
    if ($ready) {
        my $buf = "";
        recv($sock, $buf, 8192, 0);
        if ($buf eq $echo) {
            return 1;   # loopback OK
        }
        ::printEvent("RCON", " UDP socket sent to self failed: stalled or crashed",1);
    }

    # HLDS simple ping
    my $ipaddr = $self->{ipAddr};
    my $port   = $self->{server_port};
    my $hisp   = sockaddr_in($port, $ipaddr);

    my $ping = "\xFF\xFF\xFF\xFFping\n";
    $sent = send($sock, $ping, 0, $hisp);
    if (!defined $sent) {
        ::printEvent("RCON", " UDP socket can't read: stalled or crashed",1);
        return $self->_open_socket();
    }

    $rin = "";
    vec($rin, fileno($sock), 1) = 1;

    $ready = select(my $rout2 = $rin, undef, undef, 0.25);
    if ($ready) {
        my $buf = "";
        recv($sock, $buf, 8192, 0);
        return 1 if $buf ne "";
    }

    # No reply → socket or path is stale
    ::printEvent("RCON", " UDP socket can't read: crashed",1);
    return $self->_open_socket();
}

#
# Parse "status" command output into player information
#
sub getPlayers
{
    my ($self) = @_;
    my $status = $self->execute("status");
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
  my $status = $self->execute("status");

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
  my $status = $self->execute("sv_visiblemaxplayers");
  
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
