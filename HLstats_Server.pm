package HLstats_Server;
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

use POSIX;
use IO::Socket;
use Socket;
use Encode qw(decode);
use Scalar::Util ();
use Mojo::IOLoop;
use Mojo::Promise;

do "$::opt_libdir/HLstats_GameConstants.plib";

sub new
{
    my ($class_name, $serverId, $address, $port, $server_name, $rcon_pass, $game, $publicaddress, $gameengine, $realgame, $maxplayers) = @_;
    
    my ($self) = {};
    
    bless($self, $class_name);
    
    $self->{id}             = $serverId;
    $self->{address}        = $address;
    $self->{port}           = $port;
    $self->{game}           = $game;
    $self->{rcon}           = $rcon_pass;
    $self->{srv_players}    = {};

    # Game Engine
    # HL1 - 1
    # HL2 (original) - 2
    # HL2ep2 ("OrangeBox") - 3
    $self->{game_engine}    = $gameengine;

    $self->{rcon_obj}       = undef;
    $self->{name}           = ::utf8_text($server_name);
    $self->{auto_ban}       = 0;
    $self->{contact}        = "";
    $self->{hlstats_url}    = "";
    $self->{publicaddress}  = $publicaddress;
    $self->{play_game}      = -1;

    $self->{last_event}     = 0;
    $self->{last_check}     = 0;

    $self->{lines}         = 0;
    $self->{map}           = "";
    $self->{server_map}    = "";
    $self->{numplayers}    = 0;
    $self->{num_trackable_players} = 0;
    $self->{num_players_load} = 0;
    $self->{minplayers}    = 6;
    $self->{maxplayers}    = $maxplayers;
    $self->{difficulty}    = 0;

    $self->{players}       = 0;
    $self->{rounds}        = 0;
    $self->{kills}         = 0;
    $self->{suicides}      = 0;
    $self->{headshots}     = 0;
    $self->{ct_shots}      = 0;
    $self->{ct_hits}       = 0;
    $self->{ts_shots}      = 0;
    $self->{ts_hits}       = 0;
    $self->{bombs_planted} = 0;
    $self->{bombs_defused} = 0;
    $self->{ct_wins}       = 0;
    $self->{ts_wins}       = 0; 
    $self->{map_started}   = time();
    $self->{map_changes}   = 0;
    $self->{map_rounds}    = 0;
    $self->{map_ct_wins}   = 0;
    $self->{map_ts_wins}   = 0; 
    $self->{map_ct_shots}  = 0;
    $self->{map_ct_hits}   = 0;
    $self->{map_ts_shots}  = 0; 
    $self->{map_ts_hits}   = 0;

    # team balancer
    $self->{ba_enabled}       = 0;
    $self->{ba_ct_wins}       = 0;
    $self->{ba_ts_win}        = 0;
    $self->{ba_ct_frags}      = 0;
    $self->{ba_ts_frags}      = 0;
    $self->{ba_winner}        = ();
    $self->{ba_map_rounds}    = 0;
    $self->{ba_last_swap}     = 0;
    $self->{ba_player_switch} = 0;  # player switched on his own

    # Messaging commands
    $self->{show_stats}                      = 0;
    $self->{broadcasting_events}             = 0;
    $self->{broadcasting_player_actions}     = 0;
    $self->{broadcasting_command}            = "";
    $self->{broadcasting_command_announce}   = "say";
    $self->{player_events}                   = 1; 
    $self->{player_command}                  = "say";
    $self->{player_command_osd}              = "";
    $self->{player_command_hint}             = "";
    $self->{player_admin_command}            = 0;
    $self->{default_display_events}          = 1;
    $self->{browse_command}                  = "";
    $self->{swap_command}                    = "";
    $self->{exec_command}                    = "";
    $self->{global_chat_command}             = "say";

    # Message format operators
    $self->{format_color}        = "";
    $self->{format_action}       = "";
    $self->{format_actionend}    = "";
    $self->{format_A}            = "";
    $self->{format_B}            = "";
    
    $self->{total_kills}                   = 0;
    $self->{total_headshots}               = 0;
    $self->{total_suicides}                = 0;
    $self->{total_rounds}                  = 0;
    $self->{total_shots}                   = 0;
    $self->{total_hits}                    = 0;

    $self->{track_server_load}             = 0;
    $self->{track_server_timestamp}        = 0;
    
    $self->{ignore_nextban}                = ();
    $self->{use_browser}                   = 0;
    $self->{round_status}                  = 0;
    $self->{min_players_rank}              = 1;
    $self->{admins}                        = ();
    $self->{ignore_bots}                   = 1;
    $self->{tk_penalty}                    = 0;
    $self->{suicide_penalty}               = 0;
    $self->{skill_mode}                    = 0;
    $self->{game_type}                     = 0;
    $self->{bonusroundignore}              = 0;
    $self->{bonusroundtime}                = 0;
    $self->{bonusroundtime_ts}             = 0;
    $self->{bonusroundtime_state}          = 0;
    $self->{lastdisabledbonus}             = $::ev_unixtime;
    $self->{mod}                           = "";
    $self->{switch_admins}                 = 0;
    $self->{public_commands}               = 1;
    $self->{connect_announce}              = 0;
    $self->{update_hostname}               = 0;
    
    $self->{lastblueflagdefend}            = 0;
    $self->{lastredflagdefend}             = 0;

    # location hax
    $self->{nextkillx}                     = "";
    $self->{nextkilly}                     = "";
    $self->{nextkillz}                     = "";
    $self->{nextkillvicx}                  = "";
    $self->{nextkillvicy}                  = "";
    $self->{nextkillvicz}                  = "";

    $self->{nextkillheadshot}              = 0;

    $self->{next_timeout}                  = 0;
    $self->{next_flush}                    = 0;
    $self->{next_plyr_flush}               = 0;
    $self->{needsupdate}                   = 0;
    $self->{do_stats}                      = 0;

    $self->{visible_max}                   = undef;    # sv_visiblemaxplayers of the game server, when it was asked
    $self->{visible_max_at}                = 0;
    $self->{act_players_db}                = undef;    # the number of players last written by flush_player_count
    $self->{holding}                       = 0;        # the first log lines wait for the map (hold_lines)
    $self->{held}                          = [];

    $self->set_play_game($realgame);

    $self->init_rcon() if ($self->{rcon}); 

    $self->updateDB();
    $self->update_server_loc();

    return $self;
}

sub set_play_game
{
    my ($self, $realgame) = @_;
    
    if (exists($gamecode_to_game{$realgame}))
    {
        $self->{play_game} = $gamecode_to_game{$realgame};
    }
}

sub is_admin
{
    my($self, $steam_id) = @_;
    for (@{$self->{admins}}) {
        if ($_ eq $steam_id) {
            return 1;
        }
    }
    return 0;
}

sub get_game_mod_opts
{
    # Runs immediately after server object is created and options are loaded.
    my($self) = @_;

    if ($self->{mod} ne "") {
        my $mod = $self->{mod};
            
        if ($mod eq "SOURCEMOD") {
            $self->{browse_command} = "hlx_sm_browse";
            $self->{swap_command} = "hlx_sm_swap";
            $self->{global_chat_command} = "hlx_sm_psay";
            $self->setHlxCvars();
        } elsif ($mod eq "MANI") {
            $self->{browse_command} = "ma_hlx_browse";
            $self->{swap_command} = "ma_swapteam";
            $self->{exec_command} = "ma_cexec";
            $self->{global_chat_command} = "ma_psay";
        } elsif ($mod eq "AMXX") {
            $self->{browse_command} = "hlx_amx_browse";
            $self->{swap_command} = "hlx_amx_swap";
            $self->{global_chat_command} = "hlx_amx_psay";
            $self->setHlxCvars();
        } elsif ($mod eq "BEETLE") {
            $self->{browse_command} = "hlx_browse";
            $self->{swap_command} = "hlx_swap";
            $self->{exec_command} = "hlx_exec";
            $self->{global_chat_command} = "admin_psay";
        } elsif ($mod eq "MINISTATS") {
            $self->{browse_command} = "ms_browse";
            $self->{swap_command} = "ms_swap";
            $self->{global_chat_command} = "ms_psay";
        }
        
        # Turn on color and add game-specific color modifiers for when using hlx:ce sourcemod plugin
        if (($self->{mod} eq "SOURCEMOD" &&
                (
                   $self->{play_game} == CSS()
                || $self->{play_game} == CS2()
                || $self->{play_game} == TF()
                || $self->{play_game} == L4D()
                || $self->{play_game} == DODS()
                || $self->{play_game} == HL2MP()
                || $self->{play_game} == AOC()
                || $self->{play_game} == ZPS()
                || $self->{play_game} == FF()
                || $self->{play_game} == GES()
                || $self->{play_game} == FOF()
                || $self->{play_game} == PVKII()
                || $self->{play_game} == CSP()
                || $self->{play_game} == NUCLEARDAWN()
                || $self->{play_game} == DDD()
                )
            )
            || ($self->{mod} eq "AMXX"
                && $self->{play_game} == CSTRIKE())
        ) {
    
            $self->{format_color} = " 1";
            if ($self->{play_game} == ZPS() || $self->{play_game} == GES()) {
                $self->{format_action} = "\x05";
            } elsif ($self->{play_game} == FF()) {
                $self->{format_action} = "^4";
            } else {
                $self->{format_action} = "\x04";
            }
            
            if ($self->{play_game} == FF()) {
                $self->{format_actionend} = "^0";
            } else {
                $self->{format_actionend} = "\x01";
            }
            if ($self->{play_game} == CS2()){
                $self->{format_A} = " \x0B";
                $self->{format_B} = " \x10";
                # default \x01   white       \x01 darkred",  \x02   purple    \x03
                # green   \x04   lightgreen  \x05 slimegreen \x06   red       \x07
                # grey    \x08   yellow      \x09 invisible  \x0A   lightblue \x0B
                # blue    \x0C   lightpurple \x0D pink       \x0E   fadedred  \x0F
                # gold    \x10
            } 
        }
        # Insurgency can only do one solid color afaik. The rest is handled in the plugin
        if ($self->{mod} eq "SOURCEMOD" && $self->{play_game} == INSMOD()) {
            $self->{format_color} = " 1";
        }
    }
}

sub format_userid {
    my($self, $userid) = @_;
    if ($self->{mod} eq "AMXX") {
        return "#".$userid;
    }
    return "\"".$userid."\"";
}

sub quoteparam {
    my($self, $message) = @_;
    $message =~ s/'/ ' /g;
    $message =~ s/"/ '' /g;
    if (($self->{game_engine} != 2 || $self->{mod} eq "SOURCEMOD") && $self->{mod} ne "MANI") {
        return "\"".$message."\"";
    }
    return $message;
}

#
# Set property 'key' to 'value'
#

sub set
{
    my ($self, $key, $value) = @_;
    
    if (defined($self->{$key}))
    {
        if ($self->{$key} eq $value)
        {
            return 0;
        }
        
        $self->{$key} = $value;
        
        if ($key eq "hlstats_url")  {
            # so ingame browsing will work correctly
            $self->{ingame_url}  = $value;
            $self->{ingame_url}  =~ s/\/hlstats.php//i;
            $self->{ingame_url}  =~ s/\/$//;
            ::printEvent("SERVER", "Ingame-URL: ".$self->{ingame_url}, 1,"$self->{address}:$self->{port}");
        }
        return 1;
    }
    else
    {
        warn("HLstats_Server->set: \"$key\" is not a valid property name\n");
        return 0;
    }
}


#
# Increment (or decrement) the value of 'key' by 'amount' (or 1 by default)
#

sub increment
{
    my ($self, $key, $amount) = @_;
    if ($amount) {
        $amount = int($amount);
    } else {
        $amount = 1
    }
    
    my $value = $self->{$key};
    $self->set($key, $value + $amount);
}


sub init_rcon
{
    my ($self)      = @_;
    my $server_ip   = $self->{address};
    my $server_port = $self->{port};
    my $rcon_pass   = $self->{rcon};
    my $game        = $self->{game};

    if ($::g_rcon && $rcon_pass) {
        if ($self->{game_engine} == 1) {
            $self->{rcon_obj} = new BASTARDrcon($self);
        } else {
            $self->{rcon_obj} = new TRcon($self);
        }
    }

       if ($self->{rcon_obj}) {
        ::printEvent ("HLSATSZ", "Connecting to rcon on $server_ip:$server_port ... ok",1,"$self->{address}:$self->{port}");
        if ($::g_mode eq "LAN") {
            $self->get_lan_players();
        }
    }
}

#
# Run an rcon command. Called in void context (the answer is not used: messages, kicks, bans), the command is
# sent without waiting for the game server's reply, so the daemon goes on with the next log line.
#
sub dorcon
{
    my ($self, $command)      = @_;
    my $result;
    my $wants_answer = defined wantarray;
    my $rcon_obj = $self->{rcon_obj};
    if (($rcon_obj) && ($::g_rcon == 1) && ($self->{rcon} ne "")) {

        # replace ; to avoid executing multiple rcon commands.
        $command  =~ s/;//g ;

        ::printEvent("RCON", $command, 3,"$self->{address}:$self->{port}");
        if (!$wants_answer && $rcon_obj->can('execute_nowait')) {
            $rcon_obj->execute_nowait($command);
            return;
        }
        $result = $rcon_obj->execute($command);

    } else {
        ::printEvent("RCON", "error: No Object available",3,"$self->{address}:$self->{port}");
    }
    return $result;
}

sub dorcon_multi
{
    my ($self, @commands)      = @_;
    my $result;
    my $wants_answer = defined wantarray;
    my $rcon_obj = $self->{rcon_obj};

    if (($rcon_obj) && ($::g_rcon == 1) && ($self->{rcon} ne "")) {
        if ($self->{game_engine} > 1)
        {
            my $fullcmd = "";
            foreach (@commands)
            {
                my $cmd = $_;
                # replace ; to avoid executing multiple rcon commands.
                $cmd =~ s/;//g;
                $fullcmd .="$cmd;";
            }
            ::printEvent("RCON", $fullcmd, 3,"$self->{address}:$self->{port}");
            if (!$wants_answer && $rcon_obj->can('execute_nowait')) {
                $rcon_obj->execute_nowait($fullcmd);
                return;
            }
            $result = $rcon_obj->execute($fullcmd);
        }
        else
        {
            foreach (@commands)
            {
                ::printEvent("RCON", $_, 3,"$self->{address}:$self->{port}");
                $result = $rcon_obj->execute($_);
            }
        }
    } else {
      ::printEvent("RCON", "error: No Object available",3,"$self->{address}:$self->{port}");
    }
    return $result;
}    

sub rcon_getaddress
{
    my ($self, $uniqueid, $slot_name) = @_;
    my $result;
    my $rcon_obj = $self->{rcon_obj};
    if (($rcon_obj) && ($::g_rcon == 1) && ($self->{rcon} ne ""))
    {
        $result = $rcon_obj->getPlayer($uniqueid, $slot_name);
    }
    else
    {
        ::printEvent("Rcon", "error: No Object available",3,"$self->{address}:$self->{port}");
    }
    # getPlayer gives 0 for a player who is not in the status answer (gone already, or no answer): no address then
    return ref($result) eq 'HASH' ? $result : undef;
}

#
# rcon_getaddress without waiting for the answer: $cb->($player) is called with the player in the game server's
# answer to "status" (undef: not in it, or no answer). Returns 0 when the game server cannot be asked that way: the
# caller asks with rcon_getaddress().
#
sub rcon_getaddress_later
{
    my ($self, $uniqueid, $slot_name, $cb) = @_;
    my $rcon_obj = $self->{rcon_obj};
    return 0 unless Scalar::Util::blessed($rcon_obj) && $::g_rcon == 1 && $self->{rcon} ne "" && $rcon_obj->can('getPlayer_later');
    return $rcon_obj->getPlayer_later($uniqueid, $slot_name, $cb);
}

sub rcon_getStatus
{
    my ($self) = @_;
    my $rcon_obj = $self->{rcon_obj};
    my $map_result = "";
    my $max_player_result = -1;
    my $servhostname = "";
    my $difficulty = 0;
    
    if (($rcon_obj) && ($::g_rcon == 1) && ($self->{rcon})) {
        ($servhostname, $map_result, $max_player_result, $difficulty) = $rcon_obj->getServerData();
        $max_player_result = visible_max($max_player_result, $self->visible_maxplayers());
    } else {
        ::printEvent("Rcon", "error: No Object available",3,"$self->{address}:$self->{port}");
    }
    return ($map_result, $max_player_result, $servhostname, $difficulty);
}

# The player slots to show: sv_visiblemaxplayers when it is set, and lower than the maximum of the game server
sub visible_max
{
    my ($max_players, $visible) = @_;
    return $visible if ($visible != -1) && (($visible < $max_players) || $max_players == 0);
    return $max_players;
}

#
# sv_visiblemaxplayers of the game server (-1: not set, or not known). It hardly ever changes: the game server is
# asked every 10 minutes at most, not with every status.
#
sub visible_maxplayers
{
    my ($self) = @_;
    my $now = time();
    my $age = $now - $self->{visible_max_at};
    if (!defined $self->{visible_max} || $age >= 600 || $age < 0) {
        my ($visible, $answered) = $self->{rcon_obj}->getVisiblePlayers();
        return $visible unless $answered;    # no answer (or HL1): asked again the next time
        $self->{visible_max}    = $visible;
        $self->{visible_max_at} = $now;
    }
    return $self->{visible_max};
}

#
# rcon_getStatus without waiting for the answer: set_status() gets it when it comes. The questions are promises
# (TRcon::ask): "status", with "sv_visiblemaxplayers" when it was asked more than 10 minutes ago, or never, and
# "z_difficulty" for Left 4 Dead. Returns 0 when the game server cannot be asked that way (no connection and none
# being opened): the caller asks with rcon_getStatus().
#
sub rcon_getStatus_later
{
    my ($self) = @_;
    my $rcon_obj = $self->{rcon_obj};
    return 0 unless Scalar::Util::blessed($rcon_obj) && $::g_rcon == 1 && $self->{rcon} && $rcon_obj->can('ask');
    return 0 unless $rcon_obj->can_ask();

    Scalar::Util::weaken(my $weak = $self);
    my @asked = ($self->{last_check}, $self->{map});
    my $addr  = "$self->{address}:$self->{port}";

    ::printEvent("RCON", "status", 3, $addr);
    my @questions = ($rcon_obj->ask("status"));

    # sv_visiblemaxplayers hardly ever changes: asked every 10 minutes at most
    my $age = time() - $self->{visible_max_at};
    my $ask_visible = !defined $self->{visible_max} || $age >= 600 || $age < 0;
    $self->{visible_max_at} = time() if $ask_visible;
    push @questions, $ask_visible ? $rcon_obj->ask("sv_visiblemaxplayers") : Mojo::Promise->resolve(undef);

    my $l4d = $self->{play_game} == L4D();
    push @questions, $l4d ? $rcon_obj->ask("z_difficulty") : Mojo::Promise->resolve(undef);

    Mojo::Promise->all(@questions)->then(sub {
        my ($status, $visible, $zdifficulty) = map { $_->[0] } @_;
        my $rcon = $weak && $weak->{rcon_obj} or return;
        $weak->{visible_max} = $rcon->visible_of($visible) if defined $visible;

        # Not when the log told of a map change meanwhile: it is newer than this answer
        if ($status && $weak->{last_check} == $asked[0] && $weak->{map} eq $asked[1]) {
            my ($servhostname, $map, $max_players) = $rcon->server_data_of($status);
            my $difficulty = defined $zdifficulty ? $rcon->difficulty_of($zdifficulty) : 0;
            $weak->set_status($map, visible_max($max_players, $weak->{visible_max} // -1), $servhostname, $difficulty);
        }
    })->catch(sub {
        my $why = $_[0] // '';
        $why =~ s/\s+\z//;
        ::printEvent("RCON", "Error while handling the status: $why", 1, $addr);
    })->finally(sub {
        # The first log lines of the server waited for this (hold_lines)
        $weak->release_lines() if $weak;
    });
    return 1;
}

#
# The first log lines of a game server wait for its map: it is asked without waiting (rcon_getStatus_later), and the
# lines given to hold_line() meanwhile are handled when the answer comes, in the order they came. 5 s at most (the
# connection, then the answer); nothing waits when the map is known, or when the server cannot be asked.
#
sub hold_lines
{
    my ($self) = @_;
    return 0 if $::g_stdin || $self->{holding} || $self->{map} ne "";

    $self->{last_check} = time();
    $self->{holding}    = 1;
    $self->{held}       = [];
    unless ($self->rcon_getStatus_later()) {
        $self->{holding} = 0;
        return 0;
    }
    Scalar::Util::weaken(my $weak = $self);
    $self->{hold_timer} = Mojo::IOLoop->timer(5 => sub { $weak->release_lines() if $weak });
    return 1;
}

# A log line that came while the map is waited for: [source, address, line]
sub hold_line
{
    my ($self, @line) = @_;
    push @{ $self->{held} }, [@line] if @{ $self->{held} } < 20000;
}

sub release_lines
{
    my ($self) = @_;
    return unless $self->{holding};
    $self->{holding} = 0;
    Mojo::IOLoop->remove(delete $self->{hold_timer}) if $self->{hold_timer};
    my $held = $self->{held};
    $self->{held} = [];
    ::replayLine(@$_) for @$held;
}

#
# rcon_getplayers without waiting for the answer: $cb->(%players) is called when it comes. Returns 0 when the game
# server cannot be asked that way (HL1, no connection yet): the caller asks with rcon_getplayers().
#
sub rcon_getplayers_later
{
    my ($self, $cb) = @_;
    my $rcon_obj = $self->{rcon_obj};
    return 0 unless Scalar::Util::blessed($rcon_obj) && $::g_rcon == 1 && $self->{rcon} ne "" && $rcon_obj->can('getPlayers_later');
    return $rcon_obj->getPlayers_later($cb);
}

#
# Run an rcon command without waiting for its answer: $cb->($answer) is called when it comes ($cb->(undef) when the
# game server gives none). Returns 0 when the command cannot be sent that way: the caller runs it with dorcon().
#
sub dorcon_later
{
    my ($self, $command, $cb) = @_;
    my $rcon_obj = $self->{rcon_obj};
    return 0 unless Scalar::Util::blessed($rcon_obj) && $::g_rcon == 1 && $self->{rcon} ne "" && $rcon_obj->can('execute_later');

    # replace ; to avoid executing multiple rcon commands.
    $command =~ s/;//g;
    return 0 unless $rcon_obj->execute_later($command, $cb);
    ::printEvent("RCON", $command, 3,"$self->{address}:$self->{port}");
    return 1;
}

sub rcon_getplayers
{
    my ($self) = @_;
    my %result;
    my $rcon_obj = $self->{rcon_obj};
    if (($rcon_obj) && ($::g_rcon == 1) && ($self->{rcon} ne ""))
    {
        %result = $rcon_obj->getPlayers();
    } else {
        ::printEvent("Rcon", "error: No Object available",3,"$self->{address}:$self->{port}");
    }
    return %result;
}

sub track_server_load {
    my ($self) = @_;

    return unless $self->{track_server_load};   # the server's TrackServerLoad (a property of the same name)

    my $command = $self->{play_game} == CS2() ? "status_json" : "stats";
    # What is saved with the answer, as it is now: the answer may come later
    my @now = (time(), $self->{num_players_load}, $self->{minplayers}, $self->{maxplayers}, $self->{map});

    # Without waiting for the answer where that can be done
    Scalar::Util::weaken(my $weak = $self);
    return if $self->dorcon_later($command, sub { $weak->save_server_load($_[0], @now) if $weak && defined $_[0] });

    my $string = eval { $self->dorcon($command); };
    return if !defined $string || $@;
    $self->save_server_load($string, @now);
}

# The load of the game server, from its answer to "stats" ("status_json" for CS2)
sub save_server_load {
    my ($self, $string, $new_timestamp, $act_players, $min_players, $max_players, $map_then) = @_;

    my ($fps, $uptime, $map);
    if ( $self->{play_game} == CS2() ) {

       $fps      = ($string =~ /"frametime_ms": ([\d.]+)/) ? sprintf("%.2f", 1000 / $1) : '0.00';
       ($uptime) = $string =~ /"process_uptime": ([\d]+)/;
       $map      = $map_then;

    } else {

        $string =~ /CPU.*\n(.*)\n*L{0,1}.*\Z/;
        $string = $1 // '';
        $string =~ /([^ ]+)\s+([^ ]+)\s+([^ ]+)\s+([^ ]+)\s+([^ ]+)\s+([^ ]+)\s+([^ ]+)\s*([^ ]*)/;
        $uptime = $4;
        $fps = $6;
        $map = $map_then;

    }
    ::exec_cache("flush_server_load",
        "INSERT IGNORE INTO hlstats_server_load
            SET
                server_id=?,
                timestamp=?,
                act_players=?,
                min_players=?,
                max_players=?,
                map=?,
                uptime=?,
                fps=?",
        $self->{id},
        $new_timestamp,
        $act_players,
        $min_players,
        $max_players,
        $map_then,
        ($uptime?$uptime:0),
        ($fps?$fps:0)
    );

}

sub dostats 
{
    my ($self) = @_;
    my $rcon_obj = $self->{rcon_obj};
    $rcmd = $self->{broadcasting_command_announce};

    # ShowStats, with or without BroadCastEvents (messageAll forced: it sends nothing without it)
    if (($::g_stdin == 0) && ($rcon_obj) && ($self->{rcon} ne ""))  
    {
        my $hpk = sprintf("%.0f", 0);

        if ($self->{total_kills} > 0) {
            $hpk = sprintf("%.2f", (100/$self->{total_kills})*$self->{total_headshots});
        }  
        if ($rcmd ne "") {
            $self->dorcon("$rcmd ".$self->quoteparam("HLstatsZ - Tracking ".::number_format($self->{players})." players with ".::number_format($self->{total_kills})." kills and ".::number_format($self->{total_headshots})." headshots ($hpk%)"));
        } else {
            $self->messageAll("HLstatsZ - Tracking ".::number_format($self->{players})." players with ".::number_format($self->{total_kills})." kills and ".::number_format($self->{total_headshots})." headshots ($hpk%)", 0, 1);
        }
    }  
}      

sub get_map
{
    my ($self, $host) = @_;

    if (!$::g_stdin) {
        # After a map change, map and server_map (the map saved in the database) differ until the next server
        # flush, up to 20 s later: one status query every 5 s then, not one for every event
        my $since = time() - $self->{last_check};
        if ( ( $since > 120 ) || ( $self->{map} ne $self->{server_map} && $since >= 5 ) || ( defined $host->{map} ) ) {

            $self->{last_check} = time();

            if ($self->{rcon_obj}) {

                if (defined $host && ($self->{play_game} != L4D() || $self->{"difficulty"} > 0)) {
                    $self->set_status($host->{"map"}, $host->{"max_players"}, $host->{"name"}, 0);
                # The game server is asked without waiting, set_status() gets its answer when it comes (the first
                # lines of a server are held until then: hold_lines). No connection and none being opened: as before.
                } elsif (!$self->rcon_getStatus_later()) {
                    $self->set_status($self->rcon_getStatus());
                }

            }

        }
    }

    return $self->{map};

}

#
# What the game server says of itself (rcon status): its map, its player slots, its name, its difficulty (L4D)
#
sub set_status
{
    my ($self, $temp_map, $temp_maxplayers, $servhostname, $difficulty) = @_;
    my $update = 0;

    if ($temp_map) {

        if ($self->{map} ne $temp_map) {
            $self->{map} = $temp_map;
            $update++;
        }

        if (($temp_maxplayers != -1) && ($temp_maxplayers > 0) && ($temp_maxplayers)) {
            if ($self->{maxplayers} != $temp_maxplayers) {
                $self->{maxplayers} = $temp_maxplayers;
                ::printEvent("RCON", " Max players: $temp_maxplayers",1,"$self->{address}:$self->{port}");
                $update++;
            }
        }
        if (($difficulty > 0) && ($self->{play_game} == L4D()) && ($self->{difficulty} != $difficulty) ) {
            $self->{difficulty} = $difficulty;
            ::printEvent("RCON", "Set difficulty ".$self->{difficulty}." successfully",3,"$self->{address}:$self->{port}");
        }

        $servhostname = ::utf8_text($servhostname);
        if (($self->{update_hostname} > 0) && ($self->{name} ne $servhostname) && ($servhostname)) {
            $self->{name} = $servhostname;
            $update++;
        }

    }

    if ($update > 0) {
        ::printEvent("RCON", "Got new map ".$self->{map}." successfully",3,"$self->{address}:$self->{port}");
        $self->updateDB();
    }
}

sub get_lan_players
{
    my ($self) = @_;

    if ($::g_mode eq "LAN")  {
        # Without waiting for the game server where that can be done
        Scalar::Util::weaken(my $weak = $self);
        return if $self->rcon_getplayers_later(sub { $weak->set_lan_players(@_) if $weak });
        $self->set_lan_players($self->rcon_getplayers());
    }
}

# The players of the game server's answer to "status", for the LAN mode
sub set_lan_players
{
    my ($self, %players) = @_;
    while ( my($p_uid, $p_obj) = each(%players) )
    {
        next unless ref($p_obj) eq 'HASH' && defined $p_obj->{"UserID"};    # the host, no answer
        my $srv_addr = $self->{address}.":".$self->{port};
        my $userid   = $p_obj->{"UserID"};
        my $name     = $p_obj->{"Name"};
        my $address  = $p_obj->{"Address"};
        ::g_lan_noplayerinfo->{"$srv_addr/$userid/$name"} = {
            ipaddress => $address,
            userid => $userid,
            name => $name,
            server => $srv_addr
        };
    }
    ::printEvent("RCON", "get_lan_players successfully",3,"$self->{address}:$self->{port}");
}

sub clear_winner
{
  my ($self) = @_;
  ::printEvent("SERVER", 'Clear Winner',3,"$self->{address}:$self->{port}");
  @{$self->{winner}} = ();
}

sub add_round_winner
{
    my ($self, $team) = @_;
  
    ::printEvent("add_round_winner", '',3,"$self->{address}:$self->{port}");
    $self->{winner}[($self->{map_rounds} % 7)] = $team;
    $self->increment("ba_map_rounds");
    $self->increment("map_rounds");
    $self->increment("rounds");
    $self->increment("total_rounds");
  
    $self->{ba_ct_wins} = 0;
    $self->{ba_ts_wins} = 0;
  
    for (@{$self->{winner}}) 
    {
        if ($_ eq "ct") {
            $self->increment("ba_ct_wins");
        } elsif ($_ eq "ts") {
            $self->increment("ba_ts_wins");
        }
    }
}

sub switch_player
{
    my ($self, $playerid, $name) = @_;
    my $rcmd = $self->{player_command_hint};
    
    $self->dorcon($self->{swap_command}." ".$self->format_userid($playerid));
    if ($self->{player_command_hint} eq "") {
        $rcmd = $self->{player_command};
    }
    $self->dorcon(sprintf("%s %s %s", $rcmd, $self->format_userid($playerid), $self->quoteparam("HLstatsZ - You were switched to balance teams")));
    if ($self->{player_admin_command} ne "") {
        $self->dorcon(sprintf("%s %s",$self->{player_admin_command}, $self->quoteparam("HLstatsZ - $name was switched to balance teams")));
    }
}


sub analyze_teams
{
    my ($self) = @_;
  
    if (($::g_stdin == 0) && ($self->{num_trackable_players} < $self->{minplayers})) 
    {
        ::printEvent("TEAMS", "(IGNORED) NOTMINPLAYERS: analyze_teams",3,"$self->{address}:$self->{port}");
    }
    elsif (($::g_stdin == 0) && ($self->{ba_enabled} > 0))
    {
        ::printEvent("TEAMS", "analyze_teams",3,"$self->{address}:$self->{port}");
        my $ts_skill     = 0;
        my $ts_avg_skill = 0;
        my $ts_count     = 0;
        my $ts_wins      = $self->{ba_ts_wins};
        my $ts_kills     = 0;
        my $ts_deaths    = 0;
        my $ts_diff      = 0;
        my @ts_players   = ();

        my $ct_skill     = 0;
        my $ct_avg_skill = 0;
        my $ct_count     = 0;
        my $ct_wins      = $self->{ba_ct_wins};
        my $ct_kills     = 0;
        my $ct_deaths    = 0;
        my $ct_diff      = 0;
        my @ct_players   = ();
        
        my $server_id   = $self->{id};
        while ( my($pl, $player) = each(%{$self->{srv_players}}) )
        {    
            my @Player      = ( $player->{name},            #0
                                $player->{uniqueid},        #1
                                $player->{skill},           #2
                                $player->{team},            #3
                                $player->{map_kills},        #4
                                $player->{map_deaths},        #5
                                ($player->{map_kills}-$player->{map_deaths}), #6
                                $player->{is_dead},            #7
                                $player->{userid},            #8
                                );
    
            if ($Player[3] eq "TERRORIST")
            {
                push(@{$ts_players[$ts_count]}, @Player);
                $ts_skill   += $Player[2]; 
                $ts_count   += 1;
                $ts_kills   += $Player[4];
                $ts_deaths  += $Player[5];
            }
            elsif ($Player[3] eq "CT")
            {
                push(@{$ct_players[$ct_count]}, @Player);
                $ct_skill   += $Player[2]; 
                $ct_count   += 1;
                $ct_kills   += $Player[4]; 
                $ct_deaths  += $Player[5]; 
            }
        }
        @ct_players = sort { $b->[6] <=> $a->[6]} @ct_players;
        @ts_players = sort { $b->[6] <=> $a->[6]} @ts_players;
    
        ::printEvent("TEAM", "Checking Teams", 3,"$self->{address}:$self->{port}");
        $admin_msg = "AUTO-TEAM BALANCER: CT ($ct_count) $ct_kills:$ct_deaths  [$ct_wins - $ts_wins] $ts_kills:$ts_deaths ($ts_count) TS";
        if ($self->{player_events} == 1)  
        {
            if ($self->{player_admin_command} ne "") {
                $cmd_str = $self->{player_admin_command}." $admin_msg";
                $self->dorcon($cmd_str);
            }  
        }
    
        $self->messageAll("HLstatsZ - ATB - Checking Teams", 0, 1);

        if ($self->{ba_map_rounds} >= 2)    # need all players for numerical balacing, at least 2 for getting all players
        {
            my $action_done = 0;
            if ($self->{ba_last_swap} > 0)
            {
                $self->{ba_last_swap}--;
            }
      
            if ($ct_count + 1 < $ts_count)         # ct need players
            {
                $needed_players = floor( ($ts_count - $ct_count) / 2);
                if ($ct_wins < 2)
                {
                    @ts_players = sort { $b->[7] <=> $a->[7]} @ts_players;
                }
                else
                {
                    @ts_players = sort { $a->[7] <=> $b->[7]} @ts_players;
                }
                foreach my $entry (@ts_players) 
                {
                    if ($needed_players > 0) # how many we need to make teams even (only numerical)
                    {
                        if (@{$entry}[7] == 1)  # only dead players!!
                        {
                            if (($self->{switch_admins} == 1) || (($self->{switch_admins} == 0) && ($self->is_admin(@{$entry}[1]) == 0)))  {
                                $self->switch_player(@{$entry}[8], @{$entry}[0]); 
                                $action_done++;
                                $needed_players--;
                            }
                        }
                    }
                }
            }
            elsif  ($ts_count + 1 < $ct_count)  # ts need players
            {
                $needed_players = floor( ($ct_count - $ts_count) / 2);
                if ($ts_wins < 2)
                {
                    @ct_players = sort { $b->[6] <=> $a->[6]} @ct_players;  # best player
                }
                else
                {
                    @ct_players = sort { $a->[6] <=> $b->[6]} @ct_players;  # worst player
                }
                foreach my $entry (@ct_players) 
                {
                    if ($needed_players > 0) # how many we need to make teams even (only numerical)
                    {
                        if (@{$entry}[7] == 1)  # only dead players!!
                        {
                            if (($self->{switch_admins} == 1) || (($self->{switch_admins} == 0) && ($self->is_admin(@{$entry}[1]) == 0)))  {
                                $self->switch_player(@{$entry}[8], @{$entry}[0]); 
                                $action_done++;
                                $needed_players--;
                            }
                        }
                    }
                }
            }
      
            if (($action_done == 0) && ($self->{ba_last_swap} == 0) && ($self->{ba_map_rounds} >= 7) && ($self->{ba_player_switch} == 0)) # frags balancing (last swap 3 rounds before)
            {
                if ($ct_wins < 2)
                {
                    if ($ct_count < $ts_count)     # one player less we dont need swap just bring one over
                    {
                        my $ts_found = 0;
                        @ts_players = sort { $b->[6] <=> $a->[6]} @ts_players;  # best player
                        foreach my $entry (@ts_players) 
                        {
                            if ($ts_found == 0)
                            {
                                if (@{$entry}[7] == 1)  # only dead players!!
                                {
                                    if (($self->{switch_admins} == 1) || (($self->{switch_admins} == 0) && ($self->is_admin(@{$entry}[1]) == 0)))  {
                                        $self->{ba_last_swap} = 3;
                                        $self->switch_player(@{$entry}[9], @{$entry}[0]); 
                                        $ts_found++;
                                    }
                                }
                            }
                        }
                    }
                    else                  # need to swap to players
                    {
                        my $ts_playerid = 0;
                        my $ts_name     = "";
                        my $ts_kills    = 0;
                        my $ts_deaths   = 0;
                        my $ct_playerid = 0;
                        my $ct_name     = "";
                        my $ct_kills    = 0;
                        my $ct_deaths   = 0;
                        my $ts_found = 0;
                        @ts_players = sort { $b->[6] <=> $a->[6]} @ts_players;  # best player
                        foreach my $entry (@ts_players) 
                        {
                            if ($ts_found == 0)
                            {
                                if (@{$entry}[7] == 1)  # only dead players!!
                                {
                                    if (($self->{switch_admins} == 1) || (($self->{switch_admins} == 0) && ($self->is_admin(@{$entry}[1]) == 0)))  {
                                        $ts_playerid = @{$entry}[8];
                                        $ts_name     = @{$entry}[0];
                                        $ts_found++;
                                    }
                                }
                            }
                        }

                        my $ct_found = 0;
                        @ct_players = sort { $a->[6] <=> $b->[6]} @ct_players;  # worst player
                        foreach my $entry (@ct_players) 
                        {
                            if ($ct_found == 0)
                            {
                                if (@{$entry}[7] == 1)  # only dead players!!
                                {
                                    if (($self->{switch_admins} == 1) || (($self->{switch_admins} == 0) && ($self->is_admin(@{$entry}[1]) == 0)))  {
                                        $ct_playerid = @{$entry}[8];
                                        $ct_name     = @{$entry}[0];
                                        $ct_found++;
                                    }
                                }
                            }
                        }
                        if (($ts_found>0) && ($ct_found>0))
                        {
                            $self->{ba_last_swap} = 3;
                            $self->switch_player($ts_playerid, $ts_name); 
                            $self->switch_player($ct_playerid, $ct_name); 
                        }
                    }
                }
                elsif ($ts_wins < 2)
                {
                    if ($ts_count < $ct_count)     # one player less we dont need swap just bring one over
                    {
                        my $ct_found = 0;
                        @ct_players = sort { $b->[6] <=> $a->[6]} @ct_players;  # best player
                        foreach my $entry (@ct_players) 
                        {
                            if ($ct_found == 0)
                            {
                                if (@{$entry}[7] == 1)  # only dead players!!
                                {
                                    if (($self->{switch_admins} == 1) || (($self->{switch_admins} == 0) && ($self->is_admin(@{$entry}[1]) == 0)))  {
                                        $self->{ba_last_swap} = 3;
                                        $self->switch_player(@{$entry}[8], @{$entry}[0]); 
                                        $ct_found++;
                                    }
                                }
                            }
                        }
                    }
                    else                  # need to swap to players
                    {
                        my $ts_playerid  = 0;
                        my $ts_name      = "";
                        my $ct_playerid  = 0;
                        my $ct_name      = "";             
                        my $ct_found = 0;
                        @ct_players = sort { $b->[6] <=> $a->[6]} @ct_players;  # best player
                        foreach my $entry (@ct_players) 
                        {
                            if ($ct_found == 0)
                            {
                                if (@{$entry}[7] == 1)  # only dead players!!
                                {
                                    if (($self->{switch_admins} == 1) || (($self->{switch_admins} == 0) && ($self->is_admin(@{$entry}[1]) == 0)))  {
                                        $ct_playerid = @{$entry}[8];
                                        $ct_name     = @{$entry}[0];
                                        $ct_found++;
                                    }
                                }
                            }
                        }

                        my $ts_found = 0;
                        @ts_players = sort { $a->[6] <=> $b->[6]} @ts_players;  # worst player
                        foreach my $entry (@ts_players) 
                        {
                            if ($ts_found == 0)
                            {
                                if (@{$entry}[7] == 1)  # only dead players!!
                                {
                                    if (($self->{switch_admins} == 1) || (($self->{switch_admins} == 0) && ($self->is_admin(@{$entry}[1]) == 0)))  {
                                        $ts_playerid = @{$entry}[8];
                                        $ts_name     = @{$entry}[0];
                                        $ts_found++;
                                    }
                                }
                            }
                        }
                        if (($ts_found > 0) && ($ct_found > 0))
                        {
                            $self->{ba_last_swap} = 3;
                            $self->switch_player($ts_playerid, $ts_name); 
                            $self->switch_player($ct_playerid, $ct_name); 
                        }
                    }
                }
            }
        } # end if rounds > 1  
    }
}

#
# Marks server as needing flush
#

sub updateDB
{
    my ($self) = @_;
    $self->{needsupdate} = 1;
}

#
# Flushes server information in database
#

sub flushDB
{
    my ($self) = @_;

    my $serverid      = $self->{id};

    my $result = ::exec_cache(
        "get_server_player_info",
        "SELECT
            kills,
            headshots,
            suicides,
            rounds,
            ct_shots+ts_shots as shots,
            ct_hits+ts_hits as hits,
            act_map
        FROM
            hlstats_Servers
        WHERE
            serverId=?",
        $self->{id}
        );
    ($self->{total_kills}, $self->{total_headshots}, $self->{total_suicides},$self->{total_rounds},$self->{total_shots},$self->{total_hits},$self->{server_map}) = $result->fetchrow_array();
    $result->finish;

    # The same for every server of the game: counted once a minute for all of them (HLstats_Game.pm)
    if (my $game = $::g_games{$self->{game}}) {
        $self->{players} = $game->getTrackedPlayers();
    }

    # Update player details
    my $query = "
        UPDATE
            hlstats_Servers
        SET  
            name=?,
            rounds=rounds + ?,
            kills=kills + ?,
            suicides=suicides + ?,
            headshots=headshots + ?,
            bombs_planted=bombs_planted + ?,
            bombs_defused=bombs_defused + ?,
            players=?,
            ct_wins=ct_wins + ?,
            ts_wins=ts_wins + ?,
            act_players=?,
            max_players=?,
            act_map=COALESCE(NULLIF(?, ''), act_map),
            map_rounds=?,
            map_ct_wins=?,
            map_ts_wins=?,
            map_started=?,
            map_changes=map_changes + ?,
            ct_shots=ct_shots + ?,
            ct_hits=ct_hits + ?,
            ts_shots=ts_shots + ?,
            ts_hits=ts_hits + ?,
            map_ct_shots=?,
            map_ct_hits=?,
            map_ts_shots=?,
            map_ts_hits=?,
            last_event=?
        WHERE
            serverId=?
    ";
    my @vals = (
        $self->{name},
        $self->{rounds},
        $self->{kills},
        $self->{suicides},
        $self->{headshots},
        $self->{bombs_planted},
        $self->{bombs_defused},
        $self->{players},
        $self->{ct_wins},
        $self->{ts_wins},
        $self->{numplayers},
        $self->{maxplayers},
        $self->{map},
        $self->{map_rounds},
        $self->{map_ct_wins},
        $self->{map_ts_wins},
        $self->{map_started},
        $self->{map_changes},
        $self->{ct_shots},
        $self->{ct_hits},
        $self->{ts_shots},
        $self->{ts_hits},
        $self->{map_ct_shots},
        $self->{map_ct_hits},
        $self->{map_ts_shots},
        $self->{map_ts_hits},
        $::ev_unixtime,
        $serverid
    );
    ::exec_cache("update_server_stats", $query, @vals);

    $self->set("server_map", $self->{map});
    $self->set("rounds", 0);
    $self->set("kills", 0);
    $self->set("suicides", 0);
    $self->set("headshots", 0);
    $self->set("bombs_planted", 0);
    $self->set("bombs_defused", 0);
    $self->set("ct_wins", 0);
    $self->set("ts_wins", 0);
    $self->set("ct_shots", 0);
    $self->set("ct_hits", 0);
    $self->set("ts_shots", 0);
    $self->set("ts_hits", 0);
    $self->set("map_changes", 0);
    $self->{needsupdate} = 0;
}

sub flush_player_count
{
    my ($self) = @_;

    # updatePlayerCount() also runs at every change of team: written when it is not the number last written
    return if defined $self->{act_players_db} && $self->{act_players_db} == $self->{numplayers};
    $self->{act_players_db} = $self->{numplayers}
        if ::exec_cache("flush_plyr_cnt", "UPDATE hlstats_Servers SET act_players=? WHERE serverId=?", $self->{numplayers}, $self->{id});
}

# The IP to geolocate the server
# The address of the logs may be private, behind NAT, Pterodactyl, LinuxGSM...), else the address.
#
sub geo_ip {
    my ($self) = @_;

    my $public = $self->{publicaddress} // '';
    $public =~ s/^\s+|\s+$//g;
    if ($public ne '') {
        my $host = $public;
        $host =~ s/:\d*$//;                  # ip:port, host:port
        my $is_ip   = $host =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
        my $is_host = $host =~ /^(?:[A-Za-z0-9-]+\.)+[A-Za-z][A-Za-z0-9-]*$/;   # cs2.myserver.com
        # A name or a single word ("SnipeZilla", "localhost"): no lookup, it can take seconds
        return $self->{address} unless $is_ip || $is_host;
        my $ip = $host;
        if ($is_host) {
            my $packed = inet_aton($host);    # host name: DNS
            $ip = $packed ? inet_ntoa($packed) : '';
            ::printEvent("SERVER", "Public address \"$public\" does not resolve, geolocating by $self->{address}", 1, "$self->{address}:$self->{port}")
                unless $packed;
        }
        return $ip if ($ip ne '' && !is_private_ip($ip));
    }
    return $self->{address};
}

sub is_private_ip {
    my ($ip) = @_;
    return 1 if $ip =~ /^(?:10|127|0)\./;
    return 1 if $ip =~ /^192\.168\./;
    return 1 if $ip =~ /^169\.254\./;
    return 1 if $ip =~ /^172\.(?:1[6-9]|2\d|3[01])\./;
    return 1 if $ip =~ /^100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./;   # CGNAT
    return 0;
}

sub update_server_loc {
    my ($self)      = @_;
    my $serverid    = $self->{id};
    my $server_ip   = $self->geo_ip();

    my ($servcity, $servcountry, $servlat, $servlng);

    # GeoLite2-City.mmdb is open
    if ($::g_gi) {
        my $geoCity;
        eval { $geoCity = $::g_gi->city( ip => $server_ip ); };
        $geoCity = undef if $@;

        if ($geoCity) {
            my $geoCityRec = $geoCity->city();
            my $geoCountry   = $geoCity->country();
            my $geoLocation  = $geoCity->location();
            my $geoSubdivision = $geoCity->most_specific_subdivision();

            my $city_name    = $geoCityRec     ? $geoCityRec->name()        : undef;
            my $country_name = $geoCountry     ? $geoCountry->name()        : undef;
            my $latitude     = $geoLocation    ? $geoLocation->latitude()   : undef;
            my $longitude    = $geoLocation    ? $geoLocation->longitude()  : undef;

            if (defined $longitude && defined $latitude) {
                $servcity    = $city_name // 'Datacenter';
                $servcountry = $country_name // 'Unknown';
                $servlat = $latitude;
                $servlng = $longitude;

                ::exec_now(
                    "UPDATE hlstats_Servers SET city=?, country=?, lat=?, lng=? WHERE serverId=?",
                    $servcity, $servcountry, $servlat, $servlng, $serverid
                );
            }
        }
        return 1;
    }
    return 0;
}

sub messageAll
{
    my($self, $msg, $noshow, $force) = @_;
    $noshow //= '';
    $force //= '';
    if ($self->{broadcasting_events} == 1 || $force == 1)
    {
        if ($self->{mod} eq "SOURCEMOD" || $self->{mod} eq "AMXX")
        {
            my @userlist;

            foreach $player (values(%{$self->{srv_players}}))
            {
                if (($player->{is_bot} == 0) && ($player->{userid} >= 0) && ($player->{playerid} != $noshow) && ($player->{display_events} == 1 || $force == 1))
                {
                    push(@userlist, $player->{userid});
                }
            }

            $self->messageMany($msg, 1, @userlist);
        }         
        else
        {
            $self->dorcon("say ".$msg);
        }
    }
}

sub messageMany
{
    my($self, $msg, $toall, @userlist) = @_;
    if (@userlist && scalar(@userlist) > 0)
    {
        if ($self->{mod} eq "SOURCEMOD")
        {
            my $usersendlist = "";
            foreach (@userlist)
            {
                $usersendlist .= $_.",";
            }
            $usersendlist =~ s/,$//;
            my $color = $self->{format_color};
            if ($toall > 0 && $color eq " 1")
            {
                $color = " 2";
            }
            
            $self->dorcon($self->{player_command}." \"$usersendlist\"$color ".$self->quoteparam($msg));
        }
        elsif ($self->{mod} eq "AMXX")
        {
            while (@userlist)
            {
                # hlx_amx_bulkpsay takes 8 userids at a time: the last batch is padded with empty ones
                my @chunk = splice(@userlist, 0, 8);
                my $usersendlist = join(",", @chunk, ('') x (8 - @chunk));
                $self->dorcon("hlx_amx_bulkpsay \"$usersendlist\"".$self->{format_color}." ".$self->quoteparam($msg));
            }
        }
        else
        {
            $rcmd = $self->{broadcasting_command};
            foreach (@userlist)
            {
                $self->dorcon(sprintf("%s %s%s %s",$rcmd, $self->format_userid($_), $self->{format_color}, $self->quoteparam($msg)));
            }
        }
    }
}


sub setHlxCvars
{
    my ($self) = @_;

    if ($self->{hlstats_url} ne "")
    {
        $self->dorcon("hlxce_webpage \"".$self->{hlstats_url}."\"");
    }
    $self->dorcon("hlxce_version \"".$::g_version."\"");
    
    if ($self->{mod} eq "MANI")
    {
        # Without waiting for the answer where that can be done
        Scalar::Util::weaken(my $weak = $self);
        my $set_prefix = sub {
            $weak->dorcon("mani_hlx_prefix \"HLstatsZ\"") if $weak && ($_[0] // '') =~ /gameme/i;
        };
        $set_prefix->(scalar $self->dorcon("mani_hlx_prefix")) unless $self->dorcon_later("mani_hlx_prefix", $set_prefix);
    }
}

sub updatePlayerCount
{
    my ($self) = @_;
    
    if ($::g_debug > 1) {
        ::printEvent("SERVER", "Updating Player Count",3,"$self->{address}:$self->{port}");
    }
    
    my $trackable = 0;

    if ($self->{play_game} == L4D()) {
        my $num = 0;
        while (my($pl, $player) = each(%{$self->{srv_players}})) {
            if ($player->{trackable} == 1 && $player->{is_bot} == 0) {
                $trackable++;
            }
            if ($player->{userid} > 0) {
                $num++;
            }
        }
        $self->{numplayers} = $num;
        $self->{num_trackable_players} = $trackable;
        $self->{num_players_load} = $self->{num_players_load} > $trackable ? $self->{num_players_load} : $trackable;
    } else {
        $self->{numplayers} = scalar keys %{$self->{srv_players}};
        while (my($pl, $player) = each(%{$self->{srv_players}})) {
            if ($player->{trackable} == 1) {
                $trackable++;
            }
        }
        $self->{num_trackable_players} = $trackable;
        $self->{num_players_load} = $self->{num_players_load} > $trackable ? $self->{num_players_load} : $trackable;
    }

    $self->flush_player_count();
}

1;
