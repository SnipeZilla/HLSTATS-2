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

use Sys::Hostname;
use IO::Socket::INET;
use IO::Select;
use bytes;
use Scalar::Util;
use Time::HiRes qw(time);
use Mojo::IOLoop;
use Mojo::IOLoop::Client;

do "$::opt_libdir/HLstats_GameConstants.plib";

my $VERSION = "2.00";
my $TIMEOUT = 2.0;
my $RETRY_EVERY = 1;      # seconds between attempts while the server cannot be reached
my $QUEUE_MAX   = 100;    # messages kept while a connection is being opened ...
my $QUEUE_TTL   = 10;     # ... for this many seconds at most

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
  $self->{addr}                     = "$server_object->{address}:$server_object->{port}";
  $self->{"auth"}                   = 0;
  $self->{"packet_id"}              = 10;
  $self->{rcon_err}                 = 0;
  $self->{inbox}                    = {};   # replies that arrived for another request id
  $self->{rbuf}                     = '';   # bytes read from the socket, not yet a whole packet
  $self->{broken}                   = 0;    # this connection is closed or out of sync: reconnect
  $self->{nowait}                   = {};   # request ids sent by execute_nowait: their replies are dropped
  $self->{gc_at}                    = 0;    # next clean-up of nowait and inbox
  $self->{tried}                    = 0;    # the first connection is opened at once, every later one in the background
  $self->{connecting}               = 0;    # a connection is being opened in the background
  $self->{retry_at}                 = 0;    # no new attempt before this time (a second after a failure)
  $self->{retry_wait}               = 0;    # after a refused password: seconds between attempts, doubled each time
  $self->{queue}                    = [];   # [time, command] given to execute_nowait while not connected
  $self->{down_since}               = 0;    # the connection has not worked since then
  $self->{down_logged}              = 0;
  $self->{destroyed}                = 0;
  return $self;
}

sub execute
{
  my ($self, $command, $splitted_answer) = @_;
  if ($::g_stdin == 0) {
      
    my $answer = $self->sendrecv($command, $splitted_answer);
    if (defined $answer && $answer =~ /bad rcon_password/i) {
      ::printEvent("RCON", "Bad Password",1,"$self->{server_object}->{address}:$self->{server_object}->{port}");
    }
    return $answer;
  }  
}

#
# Send a command without waiting for its reply (chat messages, kicks, bans: nothing reads the answer).
# The reply is read and dropped by the event loop. Returns 1 when sent.
# While a connection is being opened, the command waits for it ($QUEUE_TTL seconds at most).
#
sub execute_nowait
{
  my ($self, $command) = @_;
  return 0 if $::g_stdin;

  if ($self->_ready()) {
      $self->_drain_nowait();
      return 1 if !$self->{broken} && $self->_send_nowait($command);
      # A server that stopped reading (its buffer is full): the message is dropped
      return 0 unless $self->{broken};
      # Closed by the server: a new connection is opened in the background, and the message waits for it
      $self->_lost("Connection closed by the server");
  }
  my $queue = $self->{queue};
  push @$queue, [time(), $command];
  shift @$queue while @$queue > $QUEUE_MAX;
  return 0;
}

sub _send_nowait
{
  my ($self, $command) = @_;
  # A server that stopped reading would block the daemon once the send buffer is full: the message is dropped
  return 0 unless IO::Select->new($self->{"rcon_socket"})->can_write(0);

  my $req_id = _next_req_id($self);
  return 0 if $self->send_rcon($req_id, $SERVERDATA_EXECCOMMAND, $command);
  $self->{nowait}{$req_id} = time();
  return 1;
}

sub get_auth_code
{
  my ($self, $id) = @_;
  my $auth = 0;
  
  if ($id == $AUTH_PACKET_ID) {
    ::printEvent("RCON", "Rcon password accepted",1,"$self->{server_object}->{address}:$self->{server_object}->{port}");
    $auth = 1;
    $self->{"auth"} = 1;
  } elsif( $id == -1) {
    ::printEvent("RCON", "Rcon password refused",1,"$self->{server_object}->{address}:$self->{server_object}->{port}");
    $self->{"auth"} = 0;
    $auth           = 0;
  } else {
    ::printEvent("RCON", "Bad password response id=$id",1,"$self->{server_object}->{address}:$self->{server_object}->{port}");
    $self->{"auth"} = 0;
    $auth           = 0;
  }
  return $auth;

}

#
# Connected and authenticated. Otherwise a connection is opened in the background (not before retry_at after a
# failure) and the caller goes on without it: a server that is down or frozen never makes the daemon wait.
# The very first connection is opened at once: the server just sent its first log line, and the daemon needs its map.
#
sub _ready
{
  my ($self) = @_;
  return 1 if $self->{"rcon_socket"} && $self->{"auth"} && !$self->{rcon_err} && !$self->{broken};
  return 0 if $self->{connecting} || $self->{retry_at} > time() || $self->{destroyed};
  return $self->_open_now() unless $self->{tried}++;
  $self->_open_async();
  return 0;
}

#
# The first connection, opened while the caller waits (2 s at most, once)
#
sub _open_now
{
  my ($self) = @_;
  my $server_object = $self->{"server_object"} or return 0;
  $self->_close_socket();
  $self->{attempt_at} = time();

  my $sock = IO::Socket::INET->new(
      Proto    => "tcp",
      PeerAddr => $server_object->{address},
      PeerPort => $server_object->{port},
      Timeout  => $TIMEOUT,
  );
  return $self->_failed("Cannot connect: " . ($! || "timeout")) unless $sock;
  binmode($sock, ':raw');
  $sock->autoflush(1);
  $self->{"rcon_socket"} = $sock;
  return $self->_failed("Couldn't send the rcon password")
      if $self->send_rcon($AUTH_PACKET_ID, $SERVERDATA_AUTH, $server_object->{rcon}, 1);

  # Source sends an empty reply before the answer to the password
  my $deadline = time() + $TIMEOUT;
  while ((my $remain = $deadline - time()) > 0) {
      my ($id, $type) = $self->_next_packet($remain);
      last unless defined $id;
      next unless $type == $SERVERDATA_AUTH_RESPONSE;
      return $self->get_auth_code($id) ? $self->_authenticated() : $self->_refused();
  }
  return $self->_failed($self->{broken} ? "Connection closed by the server" : "No answer to the rcon password");
}

#
# Open a connection in the background: the event loop connects, sends the password and reads the answer
#
sub _open_async
{
  my ($self) = @_;
  my $server_object = $self->{"server_object"} or return;
  $self->_close_socket();
  $self->{connecting} = 1;
  $self->{attempt_at} = time();

  Scalar::Util::weaken(my $weak = $self);
  my $client = $self->{connector} = Mojo::IOLoop::Client->new;
  $client->on(connect => sub { $weak->_connected($_[1]) if $weak });
  $client->on(error   => sub { $weak->_failed("Cannot connect: $_[1]") if $weak });
  $client->connect(address => $server_object->{address}, port => $server_object->{port}, timeout => $TIMEOUT);
}

sub _connected
{
  my ($self, $handle) = @_;
  my $server_object = $self->{"server_object"} or return $self->_close_socket();
  delete $self->{connector};
  binmode($handle, ':raw');
  $self->{"rcon_socket"} = $handle;

  Scalar::Util::weaken(my $weak = $self);
  my $reactor = Mojo::IOLoop->singleton->reactor;
  $self->{auth_timer} = $reactor->timer($TIMEOUT => sub { $weak->_failed("No answer to the rcon password") if $weak });
  $reactor->io($handle => sub { $weak->_auth_read() if $weak })->watch($handle, 1, 0);
  $self->_failed("Couldn't send the rcon password")
      if $self->send_rcon($AUTH_PACKET_ID, $SERVERDATA_AUTH, $server_object->{rcon}, 1);
}

# The answer to the password, read by the event loop (Source sends an empty reply first)
sub _auth_read
{
  my ($self) = @_;
  my $sock = $self->{"rcon_socket"} or return;

  my $n = sysread($sock, my $chunk, 65536);
  unless (defined $n) {
      return if $!{EAGAIN} || $!{EWOULDBLOCK};
      return $self->_failed("Socket read error $!");
  }
  return $self->_failed("Connection closed by the server") unless $n;

  $self->{rbuf} .= $chunk;
  while (my ($id, $type, $body) = $self->_take_packet()) {
      next unless $type == $SERVERDATA_AUTH_RESPONSE;
      return $self->get_auth_code($id) ? $self->_authenticated() : $self->_refused();
  }
  $self->_failed("Invalid answer to the rcon password") if $self->{broken};
}

sub _authenticated
{
  my ($self) = @_;
  my $sock = $self->{"rcon_socket"};
  my $reactor = Mojo::IOLoop->singleton->reactor;
  $reactor->remove(delete $self->{auth_timer}) if $self->{auth_timer};
  $reactor->remove($sock);
  $sock->blocking(1);
  $sock->autoflush(1);

  # From now on the event loop reads the replies to messages, and sees at once a connection closed by the server
  Scalar::Util::weaken(my $weak = $self);
  $reactor->io($sock => sub { $weak->_on_readable() if $weak })->watch($sock, 1, 0);

  if ($self->{down_logged}) {
      ::printEvent("RCON", sprintf("Connected again after %.0f s", time() - $self->{down_since}), 1, $self->{addr});
  }
  $self->{connecting}  = 0;
  $self->{rcon_err}    = 0;
  $self->{retry_at}    = 0;
  $self->{retry_wait}  = 0;
  $self->{down_since}  = 0;
  $self->{down_logged} = 0;

  # What was given to execute_nowait while the connection was being opened
  my @queue = @{ $self->{queue} };
  $self->{queue} = [];
  my $now = time();
  for my $q (@queue) {
      next if $now - $q->[0] > $QUEUE_TTL;
      last unless $self->_send_nowait($q->[1]);
  }
  return 1;
}

# Replies to messages, read by the event loop as they come
sub _on_readable
{
  my ($self) = @_;
  $self->_drain_nowait();
  $self->_lost("Connection closed by the server") if $self->{broken};
}

#
# No connection: tried again a second after the start of this attempt (at once after a time-out). The error count
# grows with the time the server has been down (1, then 2 after 15 s, 3 after 30 s: hlstats.pl takes the players off
# a server that has been down for 30 s).
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
# A connection that worked stopped answering, or was closed: a new one is opened at once, in the background
#
sub _lost
{
  my ($self, $why) = @_;
  $self->_close_socket();
  $self->{down_since} ||= time();
  $self->{rcon_err} ||= 1;
  ::printEvent("RCON", "$why: reconnecting", 3, $self->{addr});
  $self->{retry_at} = 0;
  $self->_open_async() unless $self->{destroyed};
  return 0;
}

#
# A refused password is not tried again for 10 s, then 20 s, 40 s, then once a minute: game servers ban an address
# after a few refused passwords (sv_rcon_minfailures within sv_rcon_minfailuretime). The server is up: its players stay.
#
sub _refused
{
  my ($self) = @_;
  $self->_close_socket();
  $self->{rcon_err} = 1;
  my $wait = ($self->{retry_wait} || 5) * 2;
  $self->{retry_wait} = $wait > 60 ? 60 : $wait;
  ::printEvent("RCON", "Next attempt in $self->{retry_wait} s", 1, $self->{addr});
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

# Close the connection, or the attempt to open one; everything buffered for it is dropped
sub _close_socket
{
  my ($self) = @_;
  my $reactor = Mojo::IOLoop->singleton->reactor;
  $reactor->remove(delete $self->{auth_timer}) if $self->{auth_timer};
  delete $self->{connector};
  if (my $sock = $self->{"rcon_socket"}) {
      $reactor->remove($sock) if defined fileno($sock);
      eval { shutdown($sock, 2); };
      eval { $sock->close(); };
  }
  $self->{"rcon_socket"} = undef;
  $self->{connecting} = 0;
  $self->{rbuf}   = '';
  $self->{broken} = 0;
  $self->{inbox}  = {};
  $self->{nowait} = {};
  $self->{"auth"} = 0;
}

sub sendrecv
{
  my ($self, $msg, $splitted_answer) = @_;

  return unless $self->_ready();
  $self->_drain_nowait();
  if ($self->{broken}) {
      $self->_lost("Connection closed by the server");
      return;
  }
  # A server that stopped reading would block the daemon in the write
  unless (IO::Select->new($self->{"rcon_socket"})->can_write(0)) {
      $self->_lost("The server stopped reading");
      return;
  }

  my $req_id;
  if ($splitted_answer // 0) {
      $req_id = $self->send_command_with_sentinel($msg);
      $req_id = undef if $req_id && $req_id =~ /^(?:0|1)$/;
  } else {
      $req_id = _next_req_id($self);
      $req_id = undef if $self->send_rcon($req_id, $SERVERDATA_EXECCOMMAND, $msg);
  }
  unless ($req_id) {
      $self->_lost("Cannot send to the server") if $self->{broken};
      return;
  }

  my ($id, $command, $response) = $self->recieve_rcon($req_id, $splitted_answer);
  # No answer: the server is frozen, loading a map or gone. Another connection is opened in the background
  $self->_lost("No answer to $msg") if $self->{rcon_err} || $self->{broken};
  return $response;
}

sub destroy {
    my ($self) = @_;
    $self->{destroyed} = 1;
    $self->_close_socket();
    my $reactor = Mojo::IOLoop->singleton->reactor;
    $reactor->remove(delete $self->{retry_timer}) if $self->{retry_timer};
    $self->{queue} = [];
    return 1;
}

# Also when the server object is deleted: no watcher may stay on a closed socket
sub DESTROY
{
    my ($self) = @_;
    $self->destroy() unless ${^GLOBAL_PHASE} eq 'DESTRUCT';
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
    unless ($sock && $sock->connected()) {
        if ($sock) { $self->{rcon_err}++; $self->{broken} = 1; }    # reset by the server: reconnect
        return 1;
    }

    my $data = _rcon_pack($id, $command, $string1 // '');
    return 1 unless defined $data;

    if (length($data) > 4096) {
        ::printEvent("RCON", "Command too long to send!",1,"$self->{server_object}->{address}:$self->{server_object}->{port}");
        return 1;
    }

    # $! is only meaningful when syswrite failed (it can hold an old error after a good write)
    my $n = syswrite($sock, $data);
    unless (defined $n && $n == length($data)) {
        $self->{rcon_err}++;
        $self->{broken} = 1;
        ::printEvent("RCON", defined $n ? "Short write ($n of ".length($data)." bytes)" : "Socket write error $!",1,
            "$self->{server_object}->{address}:$self->{server_object}->{port}");
        return 1;
    }
    return 0;
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
#
# Read what the socket has within $timeout seconds into the buffer.
# Returns the byte count, 0 on timeout, undef when the connection is closed or broken.
#
sub _fill
{
    my ($self, $timeout) = @_;
    my $sock = $self->{"rcon_socket"} or return undef;

    my $sel = IO::Select->new($sock);
    return 0 unless $sel->can_read($timeout > 0 ? $timeout : 0);

    my $n = sysread($sock, my $chunk, 65536);
    unless ($n) {
        ::printEvent("RCON", defined $n ? "Connection closed by the server" : "Socket read error $!", 1,
            "$self->{server_object}->{address}:$self->{server_object}->{port}");
        $self->{rcon_err}++;
        $self->{broken} = 1;
        return undef;
    }
    $self->{rbuf} .= $chunk;
    return $n;
}

#
# One whole packet off the buffer: (id, type, body), or () when it is not all there yet
#
sub _take_packet
{
    my ($self) = @_;
    return () if length($self->{rbuf}) < 4;

    my $len = unpack('V', $self->{rbuf});
    if ($len < 10 || $len > 65536) {
        ::printEvent("RCON", "Invalid packet length: $len", 1, "$self->{server_object}->{address}:$self->{server_object}->{port}");
        $self->{rbuf} = '';
        $self->{rcon_err}++;
        $self->{broken} = 1;    # framing lost: reconnect
        return ();
    }
    return () if length($self->{rbuf}) < 4 + $len;

    my $payload = substr($self->{rbuf}, 4, $len);
    substr($self->{rbuf}, 0, 4 + $len, '');
    my ($id, $type, $rest) = unpack('l< l< a*', $payload);
    $rest =~ s/\x00{1,2}\z//;
    return ($id, $type, $rest);
}

#
# Next whole packet, waiting at most $timeout seconds: (id, type, body) or () on timeout or error
#
sub _next_packet
{
    my ($self, $timeout) = @_;
    my $deadline = time() + $timeout;

    while (1) {
        my @packet = $self->_take_packet();
        return @packet if @packet;
        return () if $self->{broken};

        my $remain = $deadline - time();
        return () if $remain <= 0;
        my $got = $self->_fill($remain);
        return () unless defined $got;
    }
}

#
# Read and drop the replies to commands sent by execute_nowait, without waiting.
# Any other packet is kept in the inbox for the request that asked for it.
#
sub _drain_nowait
{
    my ($self) = @_;
    return unless $self->{"rcon_socket"};

    for (1 .. 16) {
        last unless $self->_fill(0);
    }
    while (my ($id, $type, $body) = $self->_take_packet()) {
        next if delete $self->{nowait}{$id};
        _inbox_push($self, $id, $type, $body);
    }

    # Every 10 s: forget the ids whose reply never came, and old packets nobody asked for
    my $now = time();
    return if $now < ($self->{gc_at} // 0);
    $self->{gc_at} = $now + 10;
    for my $id (keys %{ $self->{nowait} }) {
        delete $self->{nowait}{$id} if $now - $self->{nowait}{$id} > 30;
    }
    _inbox_gc($self, 5);
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

        my ($id, $type, $body) = $self->_next_packet($remain);
        last unless defined $id;  # EOF/timeout at socket level

        # A reply to a message sent without waiting
        next if delete $self->{nowait}{$id};

        # Auth path: allow Source junk packet then real auth response
        if ($packet_id == $AUTH_PACKET_ID) {
            if ($type == $SERVERDATA_RESPONSE_VALUE && $id == $AUTH_PACKET_ID) {
                ($id, $type, $body) = $self->_next_packet($deadline - time());
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
    ::printEvent("RCON", "Timeout: Socket stalled", 1,"$self->{server_object}->{address}:$self->{server_object}->{port}");
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
        delete $self->{inbox}{$id} if ($now - ($ent->{t} || $now)) > $max_age;
    }
}

#
# Parse "status" command output into player information
#
# CS2 RCON doesn't send the steamid
sub find_steamid
{
    my ($self, $userid, $slot) = @_;
    my $server = $self->{server_object}->{srv_players} or return;
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

my %l4d_difficulties = (
    'Easy'       => 1,
    'Normal'     => 2,
    'Hard'       => 3,
    'Impossible' => 4
);

sub getPlayers
{
    my ($self,$steamid,$slot_name) = @_;
    my $game = $self->{server_object}->{play_game};
    my $server = "$self->{server_object}->{address}:$self->{server_object}->{port}";
    my $status;

    if ($game == CS2()) {
        my $users = $self->execute("users") // '';
        my $stat  = $self->execute("status") // '';
        $status = length($users) ? "$users\n$stat" : $stat;
    } else {
        $status = $self->execute("status");
    }
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
            ^\#\s*                # not for cs2
            (\d+)\s+              # $1 userid
            (?:\d+\s+)?           # optional L4D extra number
            "(.+?)"\s+            # $2 name
            BOT\b                 # uniqueid = BOT
            /x)
        {
            my ($userid, $name) = ($1, $2);
            my $md5 = Digest::MD5->new;
            $md5->add($name);
            $md5->add($server);
            my $uniqueid = "BOT:" . $md5->hexdigest;
            my $key = $uniqueid;
            next unless $key;

            $players{$key} = {
                "Name"       => $name,
                "UserID"     => $userid,
                "UniqueID"   => $uniqueid,
                "Ping"       => 0,
                "Address"    => ""
            };
        }
        elsif ($line =~ /
            ^\#\s*                # not for cs2
            (\d+)\s+              # $1 userid
            (?:\d+\s+)?           # optional L4D extra number
            "(.+?)"\s+            # $2 name
            (\S+)\s+              # $3 uniqueid (STEAM_x or other)
            [\d:]+\s+             # time
            (\d+)\s+              # $4 ping
            \d+\s+                # loss
            [A-Za-z]+\s+          # state
            (?:\d+\s+)?           # optional L4D rate
            (?:([^:]+):(\d+))?    # $5 addr
            \s*$
            /x)
        {
            my ($userid, $name, $uniqueid, $ping, $address) = ($1, $2, $3, $4, $5 // "");
            $uniqueid =~ s!\[U:1:(\d+)\]!($1 % 2).':'.int($1 / 2)!eg;
            $uniqueid =~ s/^STEAM_[0-9]+?\://i;
            my $key = ($::g_mode eq "NameTrack") ? $name : ($::g_mode eq "LAN" && $address) ? "$address/$userid/$name" : $uniqueid;
            next unless $key;
            $players{$key} = {
                "Name"       => $name,
                "UserID"     => $userid,
                "UniqueID"   => $uniqueid,
                "Ping"       => $ping,
                "Address"    => $address,
            };

        } elsif ($line =~ /
                          (\d+)\s+              # $1 userid
                          ([\d:]+?|BOT)\s+      # $2 connected 
                          (\d+)\s+              # $3 ping
                          \d+\s+                # loss
                          [A-Za-z]+\s+          # state
                          \d+\s+                # extra
                          (?:([^:]+):(\d+)\s+)? # $4 addr
                          '(.*?)'               # $6 name
                          $/x)
        {
  
            my ($userid, $time, $ping, $address, $name) = ($1, $2, $3, $4 // "", $6);
            my $uniqueid;
            if ($time =~ /^BOT/) {
                my $md5 = Digest::MD5->new;
                $md5->add($name);
                $md5->add($server);
                $uniqueid = "BOT:" . $md5->hexdigest;
            }
            my $slot = defined($userid_to_slot{$userid}) ? $userid_to_slot{$userid} : $userid;
            if (!defined $uniqueid) {
                $uniqueid = $self->find_steamid($userid, $slot);
            }
            if (!defined $uniqueid && defined $steamid && defined $slot_name && $slot_name eq $slot."/".$name) {
                $uniqueid = $steamid;
            }
            my $key = ($::g_mode eq "NameTrack") ? $name : ($::g_mode eq "LAN" && $address) ? "$address/$userid/$name" : $uniqueid;
            next unless $key;
            $players{$key} = {
                "slot"       => $slot,
                "Name"       => $name,
                "UserID"     => $userid,
                "realuserid" => ($slot ne $userid ? $userid: ''),
                "UniqueID"   => $uniqueid,
                "Ping"       => $ping,
                "Address"    => $address
            };

        }

    }

    $self->updateSlot(%players);
    return %players;

}

sub getServerData
{
  my ($self) = @_;
  my $server_object = $self->{server_object};
  my $game = $server_object->{play_game};

  ::printEvent("RCON", "status",3,"$server_object->{address}:$server_object->{port}");
  my $status = $self->execute("status");
  return ("", "", 0, 0) unless $status;

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
        ::printEvent("RCON", "z_difficulty",3,"$server_object->{address}:$server_object->{port}");
        $difficulty = $self->getDifficulty();
  }

  return ($servhostname, $map, $max_players, $difficulty);
}


sub getVisiblePlayers
{
  my ($self) = @_;
  ::printEvent("RCON", "sv_visiblemaxplayers",3,"$self->{server_object}->{address}:$self->{server_object}->{port}");
  my $status = $self->execute("sv_visiblemaxplayers") // '';
  
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

sub getDifficulty
{
    #z_difficulty
    #"z_difficulty" = "Normal"
    # game replicated
    # - Difficulty of the current game (Easy, Normal, Hard, Impossible)
    
  my ($self) = @_;
  my $zdifficulty = $self->execute("z_difficulty") // '';
    
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
    ::printEvent("RCON", "getPlayer No such player: $uniqueid", 3);
    return 0;
  }
}

1;
# end
