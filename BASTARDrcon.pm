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
use Sys::Hostname;
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
    $self->{server_host}   = $server_object->{address};
    $self->{server_port}   = int($server_object->{port}) or die("BASTARDrcon: invalid Port \"" . $server_object->{port} . "\"\n");

    $self->{socket} = undef;
    $self->{error} = "";

    # Set up socket parameters
    $self->{_ipaddr} = gethostbyname($self->{server_host}) or die("BASTARDrcon: could not resolve Host \"" . $self->{server_host} . "\"\n");

    return $self;
}

#
#  Socket management with healthcheck
#
sub _open_socket
{
    my ($self) = @_;
    my $server_object = $self->{"server_object"};

    if (defined $self->{rcon_socket}) {
        close($self->{rcon_socket});
        delete $self->{rcon_socket};
        ::printEvent("RCON", "Closing UDP socket on $server_object->{address}:$server_object->{port}: $!",1);
    }

    delete $self->{_rcon_challenge};

    my $proto = $self->{_proto};
    socket($self->{rcon_socket}, PF_INET, SOCK_DGRAM, $proto);
    unless ($self->{"rcon_socket"}) {
        ::printEvent("RCON", "Cannot setup UDP socket on $server_object->{address}:$server_object->{port}: $!",1);
        return 0;
    } else {
        ::printEvent("RCON", " UDP socket is now open on $server_object->{address}:$server_object->{port}",1);
    }

    my $bindaddr = sockaddr_in(0, INADDR_ANY);
    if (!bind($self->{rcon_socket}, $bindaddr)) {
        ::printEvent("RCON", " BASTARDrcon: rebuild bind: $!", 1);
        return 0;
    }
}

sub _get_rcon_challenge
{
    my ($self) = @_;

    return $self->{_rcon_challenge} if defined $self->{_rcon_challenge};

    my $sock   = $self->{rcon_socket};
    my $ipaddr = $self->{_ipaddr};
    my $port   = $self->{server_port};
    my $hisp   = sockaddr_in($port, $ipaddr);

    my $challenge_req = "\xFF\xFF\xFF\xFFchallenge rcon\n";

    send($sock, $challenge_req, 0, $hisp)
        or return undef;

    my $ans = $self->_read_multi_packets($TIMEOUT);

    return undef if $ans eq "";

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
        return $self->_open_socket();
    }

    my $rin = "";
    vec($rin, fileno($sock), 1) = 1;

    # Self ping
    my $ready = select(my $rout = $rin, undef, undef, 0.05);
    if ($ready) {
        my $buf = "";
        recv($sock, $buf, 8192, 0);
        if ($buf eq $echo) {
            return 1;   # loopback OK
        }
    }

    # HLDS simple ping
    my $ipaddr = $self->{_ipaddr};
    my $port   = $self->{server_port};
    my $hisp   = sockaddr_in($port, $ipaddr);

    my $ping = "\xFF\xFF\xFF\xFFping\n";
    $sent = send($sock, $ping, 0, $hisp);

    if (!defined $sent) {
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
    ::printEvent("RCON", " UDP socket can't read: stalled or crashed",1);
    return $self->_open_socket();
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
    my $ipaddr = $self->{_ipaddr};
    my $port   = $self->{server_port};
    my $pass   = $self->{rcon_password};
    my $hisp   = sockaddr_in($port, $ipaddr);

    my $challenge = $self->_get_rcon_challenge();
    return $self->_healthcheck_socket() unless defined $challenge;

    my $payload = "rcon $challenge \"$pass\" $cmd\n";
    my $msg     = "\xFF\xFF\xFF\xFF" . $payload;

    send($sock, $msg, 0, $hisp)
        or return $self->_healthcheck_socket();

    my $ans = $self->_read_multi_packets($TIMEOUT);

    # Empty reply → stale challenge → retry once
    if ($ans eq "" && $attempt == 0) {
        delete $self->{_rcon_challenge};
        return $self->_sendrecv($cmd, 1);
    }

    return $ans;
}

#
# Send a package
#
sub send_rcon
{
    my ($self, $id, $command, $string1, $string2) = @_;
    my $tmp = pack("VVZ*Z*",$id,$command,$string1,$string2);
    my $size = length($tmp);
    if($size > 4096)
    {
        $self->{error} = "Command too long to send!";
        return 1;
    }
    $tmp = pack("V", $size) .$tmp;

    unless(defined(send($self->{"socket"},$tmp,0)))
    {
        die("BASTARDrcon: send $!");
    }
    return 0;
}

#
#  Recieve a package
#
sub recieve_rcon
{
    my $self = shift;
    my ($size, $id, $command, $msg);
    my $rin = "";
    my $tmp = "";
    
    vec($rin, fileno($self->{"socket"}), 1) = 1;
    if(select($rin, undef, undef, 0.5))
    {
        while(length($size) < 4)
        {
            $tmp = "";
            recv($self->{"socket"}, $tmp, (4-length($size)), 0);
            $size .= $tmp;
        }
        $size = unpack("V", $size);
        if($size < 10 || $size > 8192)
        {
            close($self->{"socket"});
            $self->{error} = "illegal size $size ";
            return (-1, -1, -1);
        }
        
        while(length($id)<4)
        {
            $tmp = "";
            recv($self->{"socket"}, $tmp, (4-length($id)), 0);
            $id .= $tmp;
        }
        $id = unpack("V", $id);
        $size = $size - 4;
        while(length($command)<4)
        {
            $tmp ="";
            recv($self->{"socket"}, $tmp, (4-length($command)),0);
            $command.=$tmp;
        }
        $command = unpack("V", $command);
        $size = $size - 4;
        my $msg = "";
        while($size >= 1)
        {
            $tmp = "";
            recv($self->{"socket"}, $tmp, $size, 0);
            $size -= length($tmp);
            $msg .= $tmp;
        }
        my ($string1,$string2) = unpack("Z*Z*",$msg);
        $msg = $string1.$string2;
        return ($id, $command, $msg);
    }
    else
    {
        return (-1, -1, -1);
    }
}

#
# Get error message
#
sub error
{
    my ($self) = @_;
    return $self->{"error"};
}

#
# Parse "status" command output into player information
#
sub getPlayers
{
    my ($self) = @_;
    my $status = $self->execute("status");
    
    my @lines = split(/[\r\n]+/, $status);
  
    my %players;
  
    # HL1
    #      name userid uniqueid frag time ping loss adr
    # 1 "psychonic" 1 STEAM_0:1:4153990   0 00:33   13    0 192.168.5.115:27005
  
    foreach my $line (@lines)
    {
        if ($line =~ /^\s*hostname\s*:\s*([\S].*)$/) {
            $players{"host"}{"name"} = $1; # host
        }
        elsif ($line =~ /^Game Time\s*(\d*?:?\d+:\d+),\s*Mod\s*"([^"]+)",\s*Map\s*"([^"]+)"\s*$/) {
            $players{"host"}{"map"} = $3; # map
        }
        elsif ($line =~ /loaded spawngroup.*?\[1:\s*([^\s]+)\s*/) {
            $players{"host"}{"map"} = $1;  # workshop or map
        }
        elsif ($line =~ /^\s*players\s*:\s*\d+[^(]+\((\d+)\/?\d?\smax.*$/) {
            $players{"host"}{ "max_players"} = $1;
        }
        elsif ($line =~ /^\#\s*\d+\s+
                    "(.+)"\s+                    # name
                    (\d+)\s+                     # userid
                    ([^\s]+)\s+\d+\s+            # uniqueid
                    ([\d:]+)\s+                  # time
                    (\d+)\s+                     # ping
                    (\d+)\s+                     # loss
                    ([^:]+):                     # addr
                    (\S+)                        # port
                    $/x)
        {
            my $name     = $1;
            my $userid   = $2;
            my $uniqueid = $3;
            my $time     = $4;
            my $ping     = $5;
            my $loss     = $6;
            my $state    = "";
            my $address  = $7;
            my $port     = $8;
            
            $uniqueid =~ s/^STEAM_[0-9]+?\://i;
            
            # &::printEvent("DEBUG", "USERID: '$userid', NAME: '$name', UNIQUEID: '$uniqueid', TIME: '$time', PING: '$ping', LOSS: '$loss', ADDRESS:'$address', CLI_PORT: '$port'", 1);
            
            if ($::g_mode eq "NameTrack") {
              $players{$name}    = { 
                                   "Name"       => $name,
                                   "UserID"     => $userid,
                                   "UniqueID"   => $uniqueid,
                                   "Time"       => $time,
                                   "Ping"       => $ping,
                                   "Loss"       => $loss,
                                   "State"      => $state,
                                   "Address"    => $address,
                                   "ClientPort" => $port
                                 };
            } elsif ($::g_mode eq "LAN") {
              $players{$address} = { 
                                   "Name"       => $name,
                                   "UserID"     => $userid,
                                   "UniqueID"   => $uniqueid,
                                   "Time"       => $time,
                                   "Ping"       => $ping,
                                   "Loss"       => $loss,
                                   "State"      => $state,
                                   "Address"    => $address,
                                   "ClientPort" => $port
                                 };
            } else {
              $players{$uniqueid} = { 
                                   "Name"       => $name,
                                   "UserID"     => $userid,
                                   "UniqueID"   => $uniqueid,
                                   "Time"       => $time,
                                   "Ping"       => $ping,
                                   "Loss"       => $loss,
                                   "State"      => $state,
                                   "Address"    => $address,
                                   "ClientPort" => $port
                                  };
            }
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
    $self->{"error"} = "No such player # $uniqueid";
    return 0;
  }
}

1;
# end
