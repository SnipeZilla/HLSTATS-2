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
use Mojo::Promise;

do "$::opt_libdir/HLstats_GameConstants.plib";

my $VERSION = "2.00";
my $TIMEOUT = 2.0;
my $RETRY_EVERY = 1;      # seconds between attempts while the server cannot be reached
my $QUEUE_MAX   = 100;    # messages kept while a connection is being opened ...
my $QUEUE_TTL   = 10;     # ... for this many seconds at most
my $WIRE_MAX    = 200;    # commands that wait for the answer to a question before they are sent
my $SETTLE      = 0.3;    # seconds a question waits, at most, for the replies to the messages sent before it ...
my $SETTLE_MAX  = 1.5;    # ... three times what the game server takes to answer, when that is more, up to this

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
  $self->{connecting}               = 0;    # a connection is being opened in the background
  $self->{retry_at}                 = 0;    # no new attempt before this time (a second after a failure)
  $self->{retry_wait}               = 0;    # after a refused password: seconds between attempts, doubled each time
  $self->{queue}                    = [];   # [time, command] given to execute_nowait while not connected
  $self->{down_since}               = 0;    # the connection has not worked since then
  $self->{down_logged}              = 0;
  $self->{destroyed}                = 0;
  $self->{later}                    = {};   # request id => [callback, timer, command]: questions asked by execute_later
  $self->{sends}                    = 0;    # messages sent by execute_nowait
  # A game server answers the commands it reads in one frame with the request id of the last of them (CS2: sent
  # together, "users" and "status" are both answered under the id of "status"). So a question of execute_later is
  # alone on the wire: nothing is sent between the reply to what was sent before it and its own answer.
  $self->{wire}                     = [];   # [command, callback]: commands not sent yet, in order (no callback: a message)
  $self->{flying}                   = 0;    # request id of the question that waits for its answer
  $self->{hold}                     = 0;    # a command the daemon waits for is on the wire: nothing else is sent
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
      # The event loop reads the replies as they come. Here at every 32nd message only: for a burst of messages
      # whose replies would fill the socket's buffer before the loop runs again
      $self->_drain_nowait() unless ++$self->{sends} & 31;
      # A question waits for its answer, or to be sent: the message is sent after it
      if (!$self->{broken} && ($self->{flying} || @{ $self->{wire} })) {
          return 0 if @{ $self->{wire} } >= $WIRE_MAX;
          push @{ $self->{wire} }, [$command];
          return 1;
      }
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

# The IO::Select of the connection, made once for it and not for every message
sub _sel
{
  my ($self) = @_;
  my $sock = $self->{"rcon_socket"};
  unless ($self->{sel} && $self->{sel_of} == $sock) {
      $self->{sel}    = IO::Select->new($sock);
      $self->{sel_of} = $sock;
  }
  return $self->{sel};
}

sub _send_nowait
{
  my ($self, $command) = @_;
  # A server that stopped reading would block the daemon once the send buffer is full: the message is dropped
  return 0 unless $self->_sel->can_write(0);

  my $req_id = _next_req_id($self);
  return 0 if $self->send_rcon($req_id, $SERVERDATA_EXECCOMMAND, $command);
  $self->{nowait}{$req_id} = time();
  return 1;
}

#
# Ask the game server something without waiting for its answer.
#
sub execute_later
{
  my ($self, $command, $cb, $on_send) = @_;
  return 0 if $::g_stdin;

  unless ($self->_ready()) {
      # The connection is being opened in the background: the question waits for it, and gets no answer if it fails
      return 0 unless $self->{connecting} && @{ $self->{wire} } < $WIRE_MAX;
      push @{ $self->{wire} }, [$command, $cb, $on_send];
      return 1;
  }

  $self->_drain_nowait();
  if ($self->{broken}) {
      $self->_lost("Connection closed by the server");
      return 0;
  }
  # A server that stopped reading would block the daemon in the write
  return 0 unless $self->_sel->can_write(0);
  return 0 if @{ $self->{wire} } >= $WIRE_MAX;

  push @{ $self->{wire} }, [$command, $cb, $on_send];
  $self->_wire_pump();
  return 1;
}

#
# The game server can be asked without waiting: connected, or being connected to (the question waits for it)
#
sub can_ask
{
  my ($self) = @_;
  return 0 if $::g_stdin;
  return 1 if $self->_ready() || $self->{connecting};
  return 0;
}

#
# Ask the game server something without waiting: a promise of its answer (undef when it gives none: no connection,
# no reply within $TIMEOUT seconds). It is never rejected.
#
#   $rcon->ask("status")->then(sub { my ($answer) = @_; ... });
#
sub ask
{
  my ($self, $command) = @_;
  my $promise = Mojo::Promise->new;
  $promise->resolve(undef) unless $self->execute_later($command, sub { $promise->resolve($_[0]) });
  return $promise;
}

#
# Send what waits on the wire, in order: the messages one after the other, a question only when it is alone, that is
# when the replies to the messages sent before it have come ($SETTLE seconds at most: some commands get no reply),
# and nothing after it until its answer (or $TIMEOUT).
#
sub _wire_pump
{
  my ($self) = @_;
  my $wire = $self->{wire};
  my $reactor = Mojo::IOLoop->singleton->reactor;

  while (@$wire && !$self->{flying} && !$self->{hold}) {
      return unless $self->{"rcon_socket"} && $self->{"auth"} && !$self->{broken};
      my ($command, $cb, $on_send) = @{ $wire->[0] };

      unless ($cb) {
          shift @$wire;
          $self->_send_nowait($command);    # dropped when the server stopped reading, as in execute_nowait
          next;
      }

      my $wait = $self->_settle_wait();
      if ($wait > 0) {
          Scalar::Util::weaken(my $weak = $self);
          $self->{settle_timer} ||= $reactor->timer($wait => sub {
              return unless $weak;
              delete $weak->{settle_timer};
              $weak->_wire_pump();
          });
          return;
      }

      shift @$wire;
      my $req_id = _next_req_id($self);
      if (!$self->_sel->can_write(0) || $self->send_rcon($req_id, $SERVERDATA_EXECCOMMAND, $command)) {
          my $addr = $self->{addr};
          Mojo::IOLoop->next_tick(sub { _later_call($addr, $cb, undef) });
          if ($self->{broken}) {
              $self->_lost("Cannot send to the server");
              return;
          }
          next;
      }
      Scalar::Util::weaken(my $weak = $self);
      my $timer = $reactor->timer($TIMEOUT => sub { $weak->_later_timeout($req_id) if $weak });
      $self->{later}{$req_id} = [$cb, $timer, $command, time()];
      $self->{flying} = $req_id;
      $on_send->() if $on_send;
  }
}

# A reply to a message of execute_nowait. A game server answers in the order it was asked, and CS2 answers the
# commands it read together under the id of the last of them: the messages sent before this one are answered too.
sub _nowait_done
{
  my ($self, $id) = @_;
  my $nowait = $self->{nowait};
  my $sent = delete $nowait->{$id} or return 0;
  $self->_note_rtt($sent);
  for my $older (keys %$nowait) {
      delete $nowait->{$older} if $older < $id;
  }
  return 1;
}

# Seconds until a question can be sent: the replies to the messages sent before it are awaited, $SETTLE seconds at most
sub _settle_wait
{
  my ($self) = @_;
  # The newest message whose reply has not come (an older one never got any)
  my $newest = 0;
  for my $sent (values %{ $self->{nowait} }) { $newest = $sent if $sent > $newest; }
  my $settle = 3 * ($self->{rtt} // 0);
  $settle = $SETTLE     if $settle < $SETTLE;
  $settle = $SETTLE_MAX if $settle > $SETTLE_MAX;
  my $wait = $newest + $settle - time();
  return $wait > 0 ? $wait : 0;
}

# What the game server takes to answer, from what was sent at $sent and is answered now (a moving average)
sub _note_rtt
{
  my ($self, $sent) = @_;
  my $rtt = time() - ($sent || return);
  return if $rtt < 0;
  $self->{rtt} = defined $self->{rtt} ? 0.7 * $self->{rtt} + 0.3 * $rtt : $rtt;
}

# The answer to a question of execute_later: its callback is called at the next turn of the event loop
sub _later_done
{
  my ($self, $id, $body) = @_;
  my $later = delete $self->{later}{$id} or return 0;
  Mojo::IOLoop->singleton->reactor->remove($later->[1]);
  $self->_note_rtt($later->[3]);
  $body //= '';
  ::printEvent("RCON", "Bad Password", 1, $self->{addr}) if $body =~ /bad rcon_password/i;
  my ($cb, $addr) = ($later->[0], $self->{addr});
  Mojo::IOLoop->next_tick(sub { _later_call($addr, $cb, $body) });
  # The next command on the wire
  $self->{flying} = 0 if $self->{flying} == $id;
  $self->_wire_pump();
  return 1;
}

# No answer within $TIMEOUT seconds. When the game server sent something else since the question was asked, the
# connection works and is kept: the server does not answer that command, and the other questions keep their answers.
# When it sent nothing at all: as after a command the daemon waited for in vain, a new connection is opened.
sub _later_timeout
{
  my ($self, $id) = @_;
  my $later = delete $self->{later}{$id} or return;
  Mojo::IOLoop->singleton->reactor->remove($later->[1]);
  $self->{flying} = 0 if $self->{flying} == $id;
  ::printEvent("RCON", "Timeout: no answer to '$later->[2]'", 1, $self->{addr});
  if (($self->{last_rx} // 0) < $later->[3]) {
      $self->{rcon_err}++;
      $self->_lost("No answer to $later->[2]");
  }
  _later_call($self->{addr}, $later->[0], undef);
  $self->_wire_pump();
}

# A callback of execute_later: an error in it is reported, and does not stop what the event loop does next
sub _later_call
{
  my ($addr, $cb, $answer) = @_;
  return if eval { $cb->($answer); 1 };
  my $why = $@;
  $why =~ s/\s+\z//;
  ::printEvent("RCON", "Error while handling an answer: $why", 1, $addr);
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
# Connected and authenticated. Otherwise a connection is opened in the background.
#
sub _ready
{
  my ($self) = @_;
  return 1 if $self->{"rcon_socket"} && $self->{"auth"} && !$self->{rcon_err} && !$self->{broken};
  return 0 if $self->{connecting} || $self->{retry_at} > time() || $self->{destroyed};
  $self->_open_async();
  return 0;
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
  $self->{auth_at} = time();
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
  $self->{rtt} = undef;
  $self->_note_rtt(delete $self->{auth_at});    # what the server took to answer the password

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
  # The questions asked while the connection was being opened
  $self->_wire_pump();
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
  delete @$self{qw(sel sel_of)};

  # The questions of execute_later that wait for an answer get none (in the order they were asked)
  my $later = $self->{later} || {};
  $self->{later} = {};
  for my $id (sort { $a <=> $b } keys %$later) {
      my ($cb, $timer) = @{ $later->{$id} };
      $reactor->remove($timer);
      next if $self->{destroyed};
      my $addr = $self->{addr};
      Mojo::IOLoop->next_tick(sub { _later_call($addr, $cb, undef) });
  }

  # What was not sent yet: the questions get no answer either, the messages wait for the next connection
  my $wire = $self->{wire} || [];
  $self->{wire}   = [];
  $self->{flying} = 0;
  $reactor->remove(delete $self->{settle_timer}) if $self->{settle_timer};
  for my $w (@$wire) {
      next if $self->{destroyed};
      my ($command, $cb) = @$w;
      if ($cb) {
          my $addr = $self->{addr};
          Mojo::IOLoop->next_tick(sub { _later_call($addr, $cb, undef) });
      } else {
          push @{ $self->{queue} }, [time(), $command];
      }
  }
  shift @{ $self->{queue} } while @{ $self->{queue} } > $QUEUE_MAX;

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
  unless ($self->_sel->can_write(0)) {
      $self->_lost("The server stopped reading");
      return;
  }

  # Alone on the wire, as a question of execute_later: the answer to the one that is waited for is read first, and
  # the replies to the messages just sent. Nothing else is sent until the answer to this command.
  $self->{hold} = 1;
  $self->_wire_wait();
  if ($self->{broken} || !$self->{"rcon_socket"}) {
      $self->{hold} = 0;
      $self->_lost("Connection closed by the server") if $self->{broken};
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
      $self->{hold} = 0;
      $self->_lost("Cannot send to the server") if $self->{broken};
      return;
  }

  $self->{asking} = $msg;
  my ($id, $command, $response) = $self->recieve_rcon($req_id, $splitted_answer);
  $self->{hold} = 0;
  # No answer: the server is frozen, loading a map or gone. Another connection is opened in the background
  if ($self->{rcon_err} || $self->{broken}) {
      $self->_lost("No answer to $msg");
  } else {
      $self->_wire_pump();
  }
  return $response;
}

#
# Before a command the daemon waits for: read the answer to the question that is on the wire (until its time-out), then
# the replies to the messages sent just before ($SETTLE seconds at most).
#
sub _wire_wait
{
  my ($self) = @_;

  while ($self->{"rcon_socket"} && !$self->{broken}) {
      my $remain;
      if (my $later = $self->{flying} && $self->{later}{ $self->{flying} }) {
          $remain = $later->[3] + $TIMEOUT - time();
          if ($remain <= 0) {
              $self->_later_timeout($self->{flying});
              next;
          }
      } else {
          $self->{flying} = 0;
          $remain = $self->_settle_wait();
          last if $remain <= 0;
      }

      my ($id, $type, $body) = $self->_next_packet($remain);
      next unless defined $id;
      next if $self->_nowait_done($id);
      next if $self->{later}{$id} && $self->_later_done($id, $body);
      _inbox_push($self, $id, $type, $body);
  }
}

sub destroy {
    my ($self) = @_;
    $self->{destroyed} = 1;
    $self->{hold} = 0;
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

    return 0 unless $self->_sel->can_read($timeout > 0 ? $timeout : 0);

    my $n = sysread($sock, my $chunk, 65536);
    unless ($n) {
        ::printEvent("RCON", defined $n ? "Connection closed by the server" : "Socket read error $!", 1,
            "$self->{server_object}->{address}:$self->{server_object}->{port}");
        $self->{rcon_err}++;
        $self->{broken} = 1;
        return undef;
    }
    $self->{rbuf} .= $chunk;
    $self->{last_rx} = time();
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
        next if $self->_nowait_done($id);
        next if $self->{later}{$id} && $self->_later_done($id, $body);
        _inbox_push($self, $id, $type, $body);
    }
    # A question that waited for the replies to the messages sent before it
    $self->_wire_pump() if @{ $self->{wire} } && !$self->{flying};

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
        next if $self->_nowait_done($id);
        # The answer to a question asked without waiting
        next if $self->{later}{$id} && $self->_later_done($id, $body);

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
    ::printEvent("RCON", "Timeout: no answer to '" . ($self->{asking} // '') . "'", 1,"$self->{server_object}->{address}:$self->{server_object}->{port}");
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
    my $status;

    if ($game == CS2()) {
        my $users = $self->execute("users") // '';
        my $stat  = $self->execute("status") // '';
        $status = length($users) ? "$users\n$stat" : $stat;
    } else {
        $status = $self->execute("status");
    }
    return $self->_players_of($status, $steamid, $slot_name);
}

#
# getPlayers without waiting for the game server: $cb->(%players) is called when it has answered
#
sub getPlayers_later
{
    my ($self, $cb) = @_;
    my $server_object = $self->{server_object} or return 0;
    Scalar::Util::weaken(my $weak = $self);

    # CS2: two questions, answered in the order they are asked
    my $users;
    if ($server_object->{play_game} == CS2()) {
        return 0 unless $self->execute_later("users", sub { $users = $_[0] });
    }
    return $self->execute_later("status", sub {
        my $stat = $_[0] // '';
        return unless $weak && $weak->{server_object};
        $cb->($weak->_players_of(defined $users && length($users) ? "$users\n$stat" : $stat));
    });
}

#
# getPlayer without waiting for the game server: $cb->($player) is called with the player of that unique id in its
# answer to "status" (undef when he is not in it, or when there is no answer). Players asked for before the question
# is sent share its answer: at a map change or when the daemon starts, one "status" for all of them and not one each.
#
sub getPlayer_later
{
    my ($self, $uniqueid, $slot_name, $cb) = @_;
    my $server_object = $self->{server_object} or return 0;

    my $round = $self->{player_round};
    unless ($round && !$round->{sent}) {
        $round = { sent => 0, waiters => [] };
        my $sent = sub { $round->{sent} = 1 };
        Scalar::Util::weaken(my $weak = $self);

        # CS2: two questions, answered in the order they are asked
        my $users;
        my $cs2 = $server_object->{play_game} == CS2();
        if ($cs2) {
            return 0 unless $self->execute_later("users", sub { $users = $_[0] }, $sent);
        }
        my $asked = $self->execute_later("status", sub {
            my $stat = $_[0];
            $round->{sent} = 1;
            my $status = defined $stat ? (defined $users && length($users) ? "$users\n$stat" : $stat) : undef;
            my @waiters = @{ $round->{waiters} };
            $round->{waiters} = [];
            for my $w (@waiters) {
                my ($id, $slot, $wcb) = @$w;
                my %players = ($weak && $weak->{server_object} && $status) ? $weak->_players_of($status, $id, $slot) : ();
                _later_call($weak ? $weak->{addr} : '', $wcb, ref($players{$id}) eq 'HASH' ? $players{$id} : undef);
            }
        }, $cs2 ? undef : $sent);
        return 0 unless $asked;
        $self->{player_round} = $round;
    }
    push @{ $round->{waiters} }, [$uniqueid, $slot_name, $cb];
    return 1;
}

# The players and the host in the answer to "status" (after the answer to "users" for CS2)
sub _players_of
{
    my ($self, $status, $steamid, $slot_name) = @_;
    return ("", -1, "", 0) unless $status;

    my $server = "$self->{server_object}->{address}:$self->{server_object}->{port}";
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

  my ($servhostname, $map, $max_players) = _server_data_of($status);
  my $difficulty = 0;
  if ($game == L4D()) {
        ::printEvent("RCON", "z_difficulty",3,"$server_object->{address}:$server_object->{port}");
        $difficulty = $self->getDifficulty();
  }

  return ($servhostname, $map, $max_players, $difficulty);
}

# The parsers of the answers, for HLstats_Server.pm (BASTARDrcon has its own for HL1)
sub server_data_of { shift; return _server_data_of(@_) }
sub visible_of     { shift; return _visible_of(@_) }
sub difficulty_of  { shift; return _difficulty_of(@_) }

# The host name, the map and the player slots in the answer to "status"
sub _server_data_of
{
  my ($status) = @_;
  my @lines = split(/[\r\n]+/, $status);

  my $servhostname         = "";
  my $map         = "";
  my $max_players = 0;

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
  return ($servhostname, $map, $max_players);
}


sub getVisiblePlayers
{
  my ($self) = @_;
  ::printEvent("RCON", "sv_visiblemaxplayers",3,"$self->{server_object}->{address}:$self->{server_object}->{port}");
  my $answer = $self->execute("sv_visiblemaxplayers");
  # With whether the game server answered: -1 is also what it says when the variable is not set
  return (_visible_of($answer // ''), defined $answer ? 1 : 0);
}

# sv_visiblemaxplayers in the game server's answer, -1 when it is not there
sub _visible_of
{
  my ($status) = @_;
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
  return _difficulty_of($self->execute("z_difficulty") // '');
}

# The difficulty (1 to 4) in the game server's answer to "z_difficulty", 0 when it is not there
sub _difficulty_of
{
  my ($zdifficulty) = @_;
  my @lines = split(/[\r\n]+/, $zdifficulty // '');
  
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
