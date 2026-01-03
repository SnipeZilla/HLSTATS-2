package TRcon;
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
no strict 'vars';

use Sys::Hostname;
use IO::Socket::INET;
use IO::Select;
use bytes;
use Scalar::Util;

do "$::opt_libdir/HLstats_GameConstants.plib";

my $VERSION = "2.00";
my $TIMEOUT = 2.0;

my $SERVERDATA_EXECCOMMAND        = 2;
my $SERVERDATA_AUTH               = 3;
my $SERVERDATA_RESPONSE_VALUE     = 0;
my $SERVERDATA_AUTH_RESPONSE      = 2;
my $AUTH_PACKET_ID                = 1;
$SIG{PIPE} = 'IGNORE';
#
# Constructor
#

sub new
{
  my ($class_name, $server_object) = @_;
  my ($self) = {};
  bless($self, $class_name);
  
  $self->{"rcon_socket"}            = 0;
  $self->{"server_object"}          = $server_object;
  Scalar::Util::weaken($self->{"server_object"});
  $self->{"auth"}                   = 0;
  $self->{"packet_id"}              = 10;
  $self->{rcon_err}                 = 0;
  $self->{inbox} = {};
  return $self;
}

sub execute
{
  my ($self, $command, $splitted_answer) = @_;
  if ($::g_stdin == 0) {
      
    my $answer = $self->sendrecv($command, $splitted_answer);
    if (defined $answer && $answer =~ /bad rcon_password/i) {
      ::printEvent("RCON", "Bad Password",1);
    }
    return $answer;
  }  
}

sub get_auth_code
{
  my ($self, $id) = @_;
  my $auth = 0;
  
  if ($id == $AUTH_PACKET_ID) {
    ::printEvent("RCON", "Rcon password accepted",1);
    $auth = 1;
    $self->{"auth"} = 1;
  } elsif( $id == -1) {
    ::printEvent("RCON", "Rcon password refused",1);
    $self->{"auth"} = 0;
    $auth           = 0;
  } else {
    ::printEvent("RCON", "Bad password response id=$id",1);
    $self->{"auth"} = 0;
    $auth           = 0;
  }
  return $auth;

}

sub sendrecv
{
  my ($self, $msg, $splitted_answer) = @_;

  my $server_object = $self->{"server_object"};

  if (!$self->{"rcon_socket"} || $self->{rcon_err} )  {

      if ($self->{"rcon_socket"}) {
          shutdown($self->{"rcon_socket"}, 2);
          $self->{"rcon_socket"}->close();
          $self->{"rcon_socket"} = undef;
          ::printEvent("RCON", "Closing TCP socket on $server_object->{address}:$server_object->{port}: $!",1);
      }

      ::printEvent("RCON", "Attempting TCP socket on $server_object->{address}:$server_object->{port}: $!",1);

      $self->{"rcon_socket"} = IO::Socket::INET->new(
          Proto    => "tcp",
          PeerAddr => $server_object->{address},
          PeerPort => $server_object->{port},
          Timeout  => $TIMEOUT,
      );

      unless ($self->{"rcon_socket"}) {
          ::printEvent("RCON", "Cannot setup TCP socket on $server_object->{address}:$server_object->{port}: $!",1);
      } else {
          ::printEvent("RCON", " TCP socket is now open on $server_object->{address}:$server_object->{port}",1);
          binmode($self->{"rcon_socket"}, ':raw');
          $self->{"rcon_socket"}->autoflush(1);
      }

      $self->{"auth"} = 0;
  }

  my $r_socket  = $self->{"rcon_socket"};
  my $server    = $self->{"server_object"};
  my $auth      = $self->{"auth"};
  my $response  = "";

  if (($r_socket) && ($r_socket->connected() )) {

    if ($auth == 0)  {
      ::printEvent("RCON", "Trying to get rcon access (auth)",1);
      if ($self->send_rcon($AUTH_PACKET_ID, $SERVERDATA_AUTH, $server->{rcon}, 1)) {
        ::printEvent("RCON", "Couldn't send password", 1);
        return;
      }
      my ($id, $command, $response) = $self->recieve_rcon($AUTH_PACKET_ID);
      if($command == $SERVERDATA_AUTH_RESPONSE) {
        $auth = $self->get_auth_code($id);
      } elsif (($command == $SERVERDATA_RESPONSE_VALUE) && ($id == $AUTH_PACKET_ID)) {  
         #Source servers sends one junk packet during the authentication step, before it responds 
         # with the correct authentication response.  
         ::printEvent("RCON", "Junk packet from Source Engine",3);
         my ($id, $command, $response) = $self->recieve_rcon($AUTH_PACKET_ID);
         $auth = $self->get_auth_code($id);
      }

    }

    if ($auth == 1)  {

        my $req_id;
        $self->{rcon_err} = 0;

        if ($splitted_answer // 0) {
            $req_id = $self->send_command_with_sentinel($msg);
            return unless $req_id && $req_id !~ /^(?:0|1)$/;
        } else {
            $req_id = _next_req_id($self);
            return if $self->send_rcon($req_id, $SERVERDATA_EXECCOMMAND, $msg);
        }

        my ($id, $command, $response) = $self->recieve_rcon($req_id, $splitted_answer);
        return $response;

    }

  } else {
     $self->{rcon_err}++;
  } 
  return;
  
}

#
# Send a package
#
sub _next_req_id
{
    my ($self) = @_;
    my $rid = ($self->{"packet_id"} // 10);
    $rid = ($rid + 1) & 0x7fffffff;
    $rid = 10 if $rid == 0;
    $self->{"packet_id"} = $rid;
    return $rid;
}

sub _rcon_pack
{
    my ($id, $type, $body) = @_;
    my $payload = pack('V V a* x x', $id, $type, $body // '');
    return pack('V a*', length($payload), $payload);
}

sub send_rcon
{
    my ($self, $id, $command, $string1, $string2) = @_;
    my $sock = $self->{"rcon_socket"};
    return 1 unless $sock && $sock->connected() && $sock->peeraddr();

    my $data = _rcon_pack($id, $command, $string1 // '');
    return 1 unless defined $data;

    if (length($data) > 4096) {
        ::printEvent("RCON", "Command too long to send!",1);
        return 1;
    }

    my $n = syswrite($sock, $data);
    if ($!) {
        $self->{rcon_err}++;
        ::printEvent("RCON", "$!",1);
    }

    return ($n // 0) == length($data) ? 0 : 1;
}

sub send_command_with_sentinel
{
    my ($self, $cmd) = @_;
    my $id = _next_req_id($self);

    return 1 if $self->send_rcon($id, $SERVERDATA_EXECCOMMAND, $cmd);
    return 1 if $self->send_rcon($id, $SERVERDATA_EXECCOMMAND, '');

    return $id;
}
#
#  Recieve a package
#
sub _read_exact {
    my ($sock, $len) = @_;
    my $buf = '';

    while (length($buf) < $len) {
        my $n = sysread($sock, my $chunk, $len - length($buf));

        if (defined $n) {
            return undef if $n == 0;  # EOF
            $buf .= $chunk;
        } else {
            ::printEvent("RCON", "Socket read error: $!", 1);
            return undef;
        }
    }

    return $buf;
}

sub _recv_one_packet {
    my ($sock, $timeout) = @_;

    my $sel = IO::Select->new($sock);
    unless ($sel->can_read($timeout)) {
        ::printEvent("RCON", "Socket can't read: stalled or crashed", 1);
        $self->{rcon_err}++;
        return;
    }

    my $hdr = _read_exact($sock, 4);
    unless ($hdr) {
        ::printEvent("RCON", "Failed to read packet header", 1);
        return;
    }

    my $len = unpack('V', $hdr);
    if ($len < 10 || $len > 65536) {
        ::printEvent("RCON", "Invalid packet length: $len", 1);
        return;
    }

    my $payload = _read_exact($sock, $len);
    unless ($payload) {
        ::printEvent("RCON", "Failed to read packet payload (len=$len)", 1);
        return;
    }

    my ($id, $type, $rest) = unpack('V V a*', $payload);
    $rest =~ s/\x00{2}\z//;

    return ($id, $type, $rest);
}

sub recieve_rcon
{
    my ($self, $packet_id, $splitted_answer) = @_;

    my $sock = $self->{"rcon_socket"};
    unless($sock && $sock->connected()) {
        $self->{rcon_err}++;
        return (-1, -1, undef);
    }

    # done
    my ($buf, $done) = _inbox_take($self, $packet_id);
    if (length($buf)) {
        return ($packet_id, $SERVERDATA_RESPONSE_VALUE, $buf) if !$splitted_answer;
        return ($packet_id, $SERVERDATA_RESPONSE_VALUE, $buf) if $done;
    }

    my $deadline = time() + $TIMEOUT;
    my $msg = $buf;  # continue any partial we had

    while (1) {
        my $remain = $deadline - time();
        last if $remain <= 0;

        my ($id, $type, $body) = _recv_one_packet($sock, $remain);
        last unless defined $id;  # EOF/timeout at socket level

        # Auth path: allow Source junk packet then real auth response
        if ($packet_id == $AUTH_PACKET_ID) {
            if ($type == $SERVERDATA_RESPONSE_VALUE && $id == $AUTH_PACKET_ID) {
                ($id, $type, $body) = _recv_one_packet($sock, $remain);
                return (-1, -1, undef) unless defined $id;
            }
            return ($id, $type, $body // '');
        }

        if ($id == $packet_id) {
            $msg .= ($body // '');
            if ($splitted_answer) {
                return ($id, $type, $msg) if defined($body) && $body eq '';
                next;
            } else {
                return ($id, $type, $msg);
            }
        }

        # Wrong id:
        _inbox_push($self, $id, $type, $body);
        _inbox_gc($self, 5);
    }

    # Deadline reached.
    ::printEvent("RCON", "Timeout: Socket stalled", 1);
    $self->{rcon_err}++ unless $msg;
    return ( ($msg ne '') ? ($packet_id, $SERVERDATA_RESPONSE_VALUE, $msg) : (-1, -1, undef) );
}

# Queue non-matching packets by id
sub _inbox_push
{
    my ($self, $id, $type, $body) = @_;
    my $ent = ($self->{inbox}{$id} ||= { buf => '', done => 0 });
    $ent->{buf}  .= ($body // '');
    $ent->{done}  = 1 if defined($body) && $body eq '';  # empty-body sentinel
    $ent->{t}     = time;
}

# Take and clear buffered data for id
sub _inbox_take
{
    my ($self, $id) = @_;
    my $ent = delete $self->{inbox}{$id} or return ('', 0);
    return ($ent->{buf} // '', $ent->{done} // 0);
}

# prune old ids
sub _inbox_gc
{
    my ($self, $max_age) = @_;
    my $now = time;
    for my $id (keys %{ $self->{inbox} || {} }) {
        my $ent = $self->{inbox}{$id} or next;
        next if $ent->{done};
        delete $self->{inbox}{$id} if ($now - ($ent->{t} || $now)) > $max_age;
    }
}
#
# Get error message
#

sub error
{
  my ($self) = @_;
  return $self->{"rcon_error"};
}

#
# Parse "status" command output into player information
#
# CS2 RCON doesn't send the steamid
sub find_steamid
{
    my ($self, $userid, $slot) = @_;
    my $server = $self->{server_object}{srv_players} or return;
    for my $player ( values %$server ) {
        next unless (defined $player->{userid});
        if ($player->{userid} == $userid ) {
            return $player->{uniqueid};
        } elsif (defined $slot && $player->{userid} == $slot) {
            return $player->{uniqueid};
        }
    }
    return undef;
}

# CS2 log is userid or slot
sub updateSlot
{
    my ($self, %players) = @_;
    my $server = "$self->{server_object}->{address}:$self->{server_object}->{port}";
    foreach my $key (keys %players)
    {
        my $p=$players{$key};
        last unless (defined $p->{slot}); 
        my $uniqueid = $p->{UniqueID};
        my $old_key = "$p->{slot}/$uniqueid";
        my $new_key = "$p->{UserID}/$uniqueid";
        # transfer old profile to new one:
        if ( exists $::g_servers{$server}->{srv_players}->{$old_key} && $old_key ne $new_key) {
            $::g_servers{$server}->{srv_players}->{$new_key} = delete $::g_servers{$server}->{srv_players}->{$old_key};
            $::g_servers{$server}->{srv_players}->{$new_key}->{userid} = $p->{UserID};
            $::g_servers{$server}->{srv_players}->{$new_key}->{realuserid} = $p->{realuserid};
        }
    }
}

sub getPlayers
{
    my ($self,$steamid,$slot_name) = @_;
   my $game = $self->{server_object}->{play_game} ;
    my $command = ($game == CS2()) ? "users;status" : ($game == L4D()) ? "z_difficulty;status" : "status";
    my $server = "$self->{server_object}->{address}:$self->{server_object}->{port}";
    my $status = $self->execute($command, 1);
    return ("", -1, "", 0) unless $status;

    my @lines = split(/[\r\n]+/, $status);
    my %players;
    my %userid_to_slot;

    # HL2 standard
    # userid name uniqueid connected ping loss state adr
    ##187 ".:[SoV]:.Evil Shadow" STEAM_0:1:6200412 13:48 97 0 active 213.10.196.229:24085

    # L4D
    # userid name uniqueid connected ping loss state rate adr
    ##2 1 "psychonic" STEAM_1:1:4153990 00:45 68 1 active 20000 192.168.5.115:27006

    #cs2
    # userid connected ping loss state rate adr name
    # 7    04:32   24    0     active 786432 64.74.97.164:53449 'snipezilla'
    # slot id name
    # 0:321:"snipezilla"

   foreach my $line (@lines) {

        # 'users' save list for later
        if ($line =~ /^(\d+):(\d+):"([^"]+)"$/) {
            $userid_to_slot{$2} = $1; 
            next;
        }
        # L4D difficulty
        elsif ($line =~ /^\s*"z_difficulty"\s*=\s*"([A-Za-z]+)".*$/x)  {
            $players{"host"}{"difficulty"} = exists($l4d_difficulties{$1}) ? $l4d_difficulties{$1} : 0;
        }
        # 'status'
        elsif ($line =~ /^\s*hostname\s*:\s*([\S].*)$/) {
            $players{"host"}{"name"} = $1; # host
        } 
        elsif ($line =~ /\s*map\s*:\s*([\S]+).*$/) {
            $players{"host"}{"map"} = $1; # map
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
        elsif ($line =~ /
                        ^(?:\#\s*)?     # not for cs2
                        (\d+)\s+        # userid
                        (?:\d+\s+|)     # extra number in L4D, not sure what this is??
                        "(.+)"\s+       # name
                        (\S+)\s+        # uniqueid
                        ([\d:]+)\s+     # time
                        (\d+)\s+        # ping
                        (\d+)\s+        # loss
                        ([A-Za-z]+)\s+  # state
                        (?:\d+\s+|)     # rate (L4D only)
                        ([^:]+):        # addr
                        (\S+)           # port
                        $/x)
        {

            my ($userid, $name, $uniqueid, $time, $ping, $loss, $state, $address, $port) = ($1, $2, $3, $4, $5, $6, $7, $8, $9);
            $uniqueid =~ s!\[U:1:(\d+)\]!($1 % 2).':'.int($1 / 2)!eg;
            $uniqueid =~ s/^STEAM_[0-9]+?\://i;
            if ($time eq 'BOT') {
                $md5 = Digest::MD5->new;
                $md5->add($time);
                $md5->add($server);
                $uniqueid = "BOT:" . $md5->hexdigest;
            }
            my $key = ($::g_mode eq "NameTrack") ? $name : ($::g_mode eq "LAN") ? $address : $uniqueid;
            next unless $key;
            $players{$key} = {
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

        } elsif ($line =~ /
                          (\d+)\s+            # $1 userid
                          ([\d:]+?|BOT)\s+    # $2 connected 
                          (\d+)\s+            # $3 ping
                          (\d+)\s+            # $4 loss
                          ([A-Za-z]+)\s+      # $5 state
                          (\d+)\s+            # $6 extra
                          (?:                 
                              ([^:]+):        # $7 addr
                              (\d+)\s+        # $8 port
                          )?                  
                          '(.*?)'             # $9 name
                          $/x)
        {
  
            my ($userid, $time, $ping, $loss, $state, $address, $port, $name) = ($1, $2, $3, $4, $5, ($7 // ""), ($8 // ""), $9);
            if ($time eq 'BOT') {
                $md5 = Digest::MD5->new;
                $md5->add($time);
                $md5->add($server);
                $uniqueid = "BOT:" . $md5->hexdigest;
            }
            my $slot = defined($userid_to_slot{$userid}) ? $userid_to_slot{$userid} : $userid;
            my $uniqueid = $self->find_steamid($userid, $slot);
            if (!defined $uniqueid && defined $steamid && defined $slot_name && $slot_name eq $slot."/".$name) {
                $uniqueid = $steamid; # new player cs2
            }
            my $key = ($::g_mode eq "NameTrack") ? $name : ($::g_mode eq "LAN") ? $address : $uniqueid;
            next unless $key;
            $players{$key} = {
                "slot"       => $slot,
                "Name"       => $name,
                "UserID"     => $userid,
                "realuserid" => ($slot ne $userid ? $userid: ''),
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

    $self->updateSlot(%players);
    return %players;

}

sub getServerData
{
  my ($self) = @_;

  my $status = $self->execute("status", 1);
  return ("", "", 0, 0) unless $status;
  my $server_object = $self->{server_object};
  my $game = $server_object->{play_game};  

  my @lines = split(/[\r\n]+/, $status);

  my $servhostname         = "";
  my $map         = "";
  my $max_players = 0;
  my $difficulty = 0;

  foreach my $line (@lines)
  {
    if ($line =~ /^\s*hostname\s*:\s*([\S].*)$/)
    {
      $servhostname   = $1;
    }
    elsif ($line =~ /\s*map\s*:\s*([\S]+).*$/)
    {
      $map   = $1;
    }
    elsif ($line =~ /^Game Time\s*(\d*?:?\d+:\d+),\s*Mod\s*"([^"]+)",\s*Map\s*"([^"]+)"\s*$/)
    {
        # srcds/cs2
        $map   = $3;
    }
    elsif ($line =~ /loaded spawngroup.*?\[1:\s*([^\s]+)\s*/) {
        # srcds/cs2 non-workshop map
        $map   = $1;
    }
    elsif ($line =~ /^\s*players\s*:\s*\d+[^(]+\((\d+)\/?\d?\smax.*$/)
    {
      $max_players = $1;
    }
  }
  if ($game == L4D()) {
      $difficulty = $self->getDifficulty();
  }
  return ($servhostname, $map, $max_players, $difficulty);
}


sub getVisiblePlayers
{
  my ($self) = @_;
  my $status = $self->execute("sv_visiblemaxplayers");
  
  my @lines = split(/[\r\n]+/, $status);
  

  my $max_players = -1;
  foreach my $line (@lines) {

      # "sv_visiblemaxplayers" = "-1"
      # - Overrides the max players reported to prospective clients
      if ($line =~ /"?sv_visiblemaxplayers"?\s*=\s*"?([-0-9]+)"?.*$/x) {
          $max_players   = $1;
      }
  }
  return ($max_players);
}

my %l4d_difficulties = (
    'Easy'       => 1,
    'Normal'     => 2,
    'Hard'       => 3,
    'Impossible' => 4
);

sub getDifficulty
{
    #z_difficulty
    #"z_difficulty" = "Normal"
    # game replicated
    # - Difficulty of the current game (Easy, Normal, Hard, Impossible)
    
  my ($self) = @_;
  my $zdifficulty = $self->execute("z_difficulty");
    
  my @lines = split(/[\r\n]+/, $zdifficulty);
  
  foreach my $line (@lines)
  {
    if ($line =~ /^\s*"z_difficulty"\s*=\s*"([A-Za-z]+)".*$/x)
    {
        if (exists($l4d_difficulties{$1}))
        {
            return $l4d_difficulties{$1};
        }
    }
  }
  return 0;
}


#
# Get information about a player by userID
#

sub getPlayer
{
  my ($self, $uniqueid,$slot_name) = @_;
  my %players = $self->getPlayers($uniqueid,$slot_name);
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
