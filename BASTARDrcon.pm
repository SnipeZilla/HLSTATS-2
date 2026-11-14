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
use Mojo::Promise;
use bytes;

##
## Main
##

my $TIMEOUT     = 2.0;
my $RETRY_EVERY = 1;      # seconds between attempts while the server does not answer
my $QUEUE_MAX   = 100;    # messages kept while a challenge is being asked for ...
my $QUEUE_TTL   = 10;     # ... for this many seconds at most
my $STATUS_END  = qr/^\s*\d+ users?\s*$/m;    # the last line of "status": its answer is complete
my $NEXT_PACKET = 0.2;    # seconds between the packets of one answer, at most
my $WIRE_MAX    = 200;    # commands that wait for the answer to a question before they are sent
my $SETTLE      = 0.3;    # seconds a question waits after a message: the answer to it would be taken for its own ...
my $SETTLE_MAX  = 1.5;    # ... three times what the game server takes to answer, when that is more, up to this

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
    # HL1 answers carry no id: a question of execute_later is alone on the wire, nothing is sent until its answer
    $self->{wire}          = [];    # [command, callback, $done, on_send]: commands not sent yet, in order (no callback: a message)
    $self->{asking}        = undef; # the question that waits for its answer
    $self->{hold}          = 0;     # a command the daemon waits for is on the wire: nothing else is sent
    $self->{sent_at}       = 0;     # when the last message was sent
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
        # A question waits for its answer, or to be sent: the message is sent after it
        if ($self->{asking} || @{ $self->{wire} }) {
            return 0 if @{ $self->{wire} } >= $WIRE_MAX;
            push @{ $self->{wire} }, [$command];
            return 1;
        }
        if ($self->_send_rcon($command)) {
            $self->{sent_at} = time();
            return 1;
        }
        $self->_lost("Cannot send to the server: $!");
    }
    my $queue = $self->{queue};
    push @$queue, [time(), $command];
    shift @$queue while @$queue > $QUEUE_MAX;
    return 0;
}

#
# Ask the game server something without waiting for its answer: $cb->($answer) is called when it comes, $cb->(undef)
# when it gives none within $TIMEOUT seconds. Returns 0 when the question cannot be asked now (no challenge and none
# being asked for): the caller asks with execute(). A command with arguments is a message, as in execute(): it is
# sent, and the answer is "". $done: the answer is complete once it matches.
#
sub execute_later
{
    my ($self, $command, $cb, $done, $on_send) = @_;
    return 0 if $::g_stdin;

    if ($command !~ /^\S+$/) {
        $self->execute_nowait($command);
        my $addr = $self->{addr};
        Mojo::IOLoop->next_tick(sub { _later_call($addr, $cb, "") });
        return 1;
    }
    $done //= $STATUS_END if $command eq 'status';

    unless ($self->_ready()) {
        # A challenge is being asked for: the question waits for it, and gets no answer if there is none
        return 0 unless $self->{opening} && @{ $self->{wire} } < $WIRE_MAX;
        push @{ $self->{wire} }, [$command, $cb, $done, $on_send];
        return 1;
    }
    return 0 if @{ $self->{wire} } >= $WIRE_MAX;
    push @{ $self->{wire} }, [$command, $cb, $done, $on_send];
    $self->_wire_pump();
    return 1;
}

# The game server can be asked without waiting: its challenge is known, or being asked for
sub can_ask
{
    my ($self) = @_;
    return 0 if $::g_stdin;
    return 1 if $self->_ready() || $self->{opening};
    return 0;
}

#
# Ask the game server something without waiting: a promise of its answer (undef when it gives none). Never rejected.
#
sub ask
{
    my ($self, $command) = @_;
    my $promise = Mojo::Promise->new;
    $promise->resolve(undef) unless $self->execute_later($command, sub { $promise->resolve($_[0]) });
    return $promise;
}

#
# Send what waits on the wire, in order: the messages one after the other, a question $SETTLE seconds after the last
# message (its answer has no id: the answer to a message would be taken for it), and nothing after it until its answer.
#
sub _wire_pump
{
    my ($self) = @_;
    my $wire = $self->{wire};
    my $reactor = Mojo::IOLoop->singleton->reactor;
    Scalar::Util::weaken(my $weak = $self);

    while (@$wire && !$self->{asking} && !$self->{hold} && $self->{ready} && $self->{rcon_socket}) {
        my ($command, $cb, $done, $on_send) = @{ $wire->[0] };

        unless ($cb) {
            shift @$wire;
            unless ($self->_send_rcon($command)) {
                $self->_lost("Cannot send to the server: $!");
                return;
            }
            $self->{sent_at} = time();
            next;
        }

        my $settle = 3 * ($self->{rtt} // 0);
        $settle = $SETTLE     if $settle < $SETTLE;
        $settle = $SETTLE_MAX if $settle > $SETTLE_MAX;
        my $wait = $self->{sent_at} + $settle - time();
        if ($wait > 0) {
            $self->{settle_timer} ||= $reactor->timer($wait => sub {
                return unless $weak;
                delete $weak->{settle_timer};
                $weak->_wire_pump();
            });
            return;
        }

        shift @$wire;
        unless ($self->_send_rcon($command)) {
            my $addr = $self->{addr};
            Mojo::IOLoop->next_tick(sub { _later_call($addr, $cb, undef) });
            $self->_lost("Cannot send to the server: $!");
            return;
        }
        my $now = time();
        $self->{asking} = {
            cmd => $command, cb => $cb, done => $done, ans => '', at => $now, rx => $now,
            timer => $reactor->timer($TIMEOUT => sub { $weak->_ask_end() if $weak }),
        };
        $on_send->() if $on_send;
    }
}

# A packet of the answer to the question on the wire
sub _ask_packet
{
    my ($self, $buf) = @_;
    my $ask = $self->{asking};
    # What the game server takes to answer: the first packet of an answer (a moving average)
    unless (length $ask->{ans}) {
        my $rtt = time() - $ask->{at};
        $self->{rtt} = defined $self->{rtt} ? 0.7 * $self->{rtt} + 0.3 * $rtt : $rtt;
    }
    $ask->{ans} .= $buf;
    $ask->{rx}   = time();
    return $self->_ask_end() if $ask->{done} && $ask->{ans} =~ $ask->{done};

    # The next packet comes within $NEXT_PACKET seconds, or the answer is complete
    my $reactor = Mojo::IOLoop->singleton->reactor;
    $reactor->remove($ask->{timer});
    Scalar::Util::weaken(my $weak = $self);
    $ask->{timer} = $reactor->timer($NEXT_PACKET => sub { $weak->_ask_end() if $weak });
}

# The answer to the question on the wire is complete, or there is none: its callback is called at the next turn of
# the event loop. Without an answer the server is down or loading a map: a new challenge is asked for.
sub _ask_end
{
    my ($self) = @_;
    my $ask = delete $self->{asking} or return;
    Mojo::IOLoop->singleton->reactor->remove($ask->{timer});
    my $ans  = length($ask->{ans}) ? $ask->{ans} : undef;
    my $addr = $self->{addr};
    my $cb   = $ask->{cb};
    Mojo::IOLoop->next_tick(sub { _later_call($addr, $cb, $ans) });

    unless (defined $ans) {
        ::printEvent("RCON", "$ask->{cmd} :: Failed to read packet", 1, $addr);
        $self->_lost("No answer");
        return;
    }
    $self->{rcon_err} = 0;
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

# Before a command the daemon waits for: the answer to the question that is on the wire is read first
sub _ask_wait
{
    my ($self) = @_;
    while (my $ask = $self->{asking}) {
        my $now = time();
        if (length $ask->{ans}) {
            $self->_ask_end(), next if $now - $ask->{rx} >= $NEXT_PACKET;
        } elsif ($now - $ask->{at} >= $TIMEOUT) {
            $self->_ask_end();
            next;
        }
        $self->_read_packets(0.05);
    }
}

#
# A command whose answer is wanted
#
sub _sendrecv
{
    my ($self, $cmd, $done, $retried) = @_;
    return "" unless $self->_ready();
    # Alone on the wire, as a question of execute_later
    $self->{hold} = 1;
    $self->_ask_wait();
    my $ans = $self->_sendrecv_now($cmd, $done, $retried);
    $self->{hold} = 0;
    $self->_wire_pump();
    return $ans;
}

sub _sendrecv_now
{
    my ($self, $cmd, $done, $retried) = @_;
    return "" unless $self->{ready};
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
        return $self->_sendrecv_now($cmd, $done, 1);
    }
    $self->{rcon_err} = 0;
    return $ans;
}

#
# Challenge known and password checked. Otherwise a challenge is asked for in the background (not before retry_at
# after a failure) and the caller goes on without it: a server that is down never makes the daemon wait.
#
sub _ready
{
    my ($self) = @_;
    # Answers to earlier messages: an expired challenge shows there
    $self->_read_packets(0) if $self->{ready};
    return 1 if $self->{ready};
    return 0 if $self->{opening} || $self->{retry_at} > time() || $self->{destroyed};
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
    # The answer to the question on the wire. Otherwise the answer to a message: nothing reads it
    return $self->_ask_packet($buf) if $self->{asking};
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
        $self->{sent_at} = $now;
    }
    # The questions asked while the challenge was asked for
    $self->_wire_pump();
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

    # The question on the wire and those not sent yet get no answer (in the order they were asked); the messages
    # wait for the next challenge
    $reactor->remove(delete $self->{settle_timer}) if $self->{settle_timer};
    my @questions;
    if (my $ask = delete $self->{asking}) {
        $reactor->remove($ask->{timer});
        push @questions, $ask->{cb};
    }
    my $wire = $self->{wire} || [];
    $self->{wire} = [];
    for my $w (@$wire) {
        my ($command, $cb) = @$w;
        if ($cb) {
            push @questions, $cb;
        } elsif (!$self->{destroyed}) {
            push @{ $self->{queue} }, [time(), $command];
        }
    }
    shift @{ $self->{queue} } while @{ $self->{queue} } > $QUEUE_MAX;
    return if $self->{destroyed};
    my $addr = $self->{addr};
    for my $cb (@questions) {
        Mojo::IOLoop->next_tick(sub { _later_call($addr, $cb, undef) });
    }
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
    $self->{hold} = 0;
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
    return $self->_players_of($self->execute("status") // '');
}

#
# getPlayers without waiting for the game server: $cb->(%players) is called when it has answered
#
sub getPlayers_later
{
    my ($self, $cb) = @_;
    Scalar::Util::weaken(my $weak = $self);
    return $self->execute_later("status", sub {
        return unless $weak && $weak->{server_object};
        $cb->($weak->_players_of($_[0] // ''));
    });
}

#
# getPlayer without waiting for the game server: $cb->($player) is called with the player of that unique id in its
# answer to "status" (undef when he is not in it, or when there is no answer). Players asked for before the question
# is sent share its answer.
#
sub getPlayer_later
{
    my ($self, $uniqueid, $slot_name, $cb) = @_;

    my $round = $self->{player_round};
    unless ($round && !$round->{sent}) {
        $round = { sent => 0, waiters => [] };
        Scalar::Util::weaken(my $weak = $self);
        my $asked = $self->execute_later("status", sub {
            my $status = $_[0];
            $round->{sent} = 1;
            my %players = ($weak && $weak->{server_object} && $status) ? $weak->_players_of($status) : ();
            my @waiters = @{ $round->{waiters} };
            $round->{waiters} = [];
            for my $w (@waiters) {
                my ($id, $wcb) = @$w;
                _later_call($weak ? $weak->{addr} : '', $wcb, ref($players{$id}) eq 'HASH' ? $players{$id} : undef);
            }
        }, undef, sub { $round->{sent} = 1 });
        return 0 unless $asked;
        $self->{player_round} = $round;
    }
    push @{ $round->{waiters} }, [$uniqueid, $cb];
    return 1;
}

# The players and the host in the answer to "status"
sub _players_of
{
    my ($self, $status) = @_;
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
  return ($self->server_data_of($self->execute("status") // ''), 0);
}

# The host name, the map and the player slots in the answer to "status"
sub server_data_of
{
  my ($self, $status) = @_;
  my @lines = split(/[\r\n]+/, $status // '');

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
  return ($servhostname, $map, $max_players);
}


sub getVisiblePlayers
{
  my ($self) = @_;
  return $self->visible_of($self->execute("sv_visiblemaxplayers") // '');
}

# sv_visiblemaxplayers in the game server's answer, -1 when it is not there
sub visible_of
{
  my ($self, $status) = @_;
  my @lines = split(/[\r\n]+/, $status // '');
  

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


# No difficulty for HL1 (Left 4 Dead, on Source servers)
sub difficulty_of { return 0 }

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
