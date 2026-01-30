package HLstats_Player;
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

#
# Constructor
#
use Encode qw(decode);

do "$::opt_libdir/HLstats_GameConstants.plib";

sub new
{
    my $class_name = shift;
    my %params = @_;

    my $self = {};
    bless($self, $class_name);

    # Initialise Properties
    $self->{userid}              = 0;
    $self->{realuserid}          = '';
    $self->{slot}                = 0;
    $self->{server}              = "";
    $self->{server_id}           = 1;
    $self->{name}                = "";
    $self->{uniqueid}            = "";
    $self->{plain_uniqueid}      = "";
    $self->{address}             = "";
    $self->{cli_port}            = "";
    $self->{ping}                = 0;
    $self->{connect_time}        = time();
    $self->{last_update}         = 0;
    $self->{last_update_skill}   = 0;
    $self->{day_skill_change}    = 0;

    $self->{city}                = "";
    $self->{state}               = "";
    $self->{country}             = "";
    $self->{flag}                = "";
    $self->{lat}                 = undef;
    $self->{lng}                 = undef;

    $self->{playerid}            = 0;
    $self->{clan}                = 0;
    $self->{kills}               = 0;
    $self->{total_kills}         = 0;
    $self->{deaths}              = 0;
    $self->{suicides}            = 0;
    $self->{skill}               = 1000;
    $self->{game}                = "";
    $self->{team}                = "";
    $self->{role}                = "";
    $self->{timestamp}           = 0;
    $self->{headshots}           = 0;
    $self->{shots}               = 0;
    $self->{hits}                = 0;
    $self->{teamkills}           = 0;
    $self->{kill_streak}         = 0;
    $self->{death_streak}        = 0;

    $self->{auto_command}        = "";
    $self->{auto_type}           = "";
    $self->{auto_time}           = 0;
    $self->{auto_time_count}     = 0;

    $self->{session_skill}       = 0;
    $self->{session_kills}       = 0;
    $self->{session_deaths}      = 0;
    $self->{session_suicides}    = 0;
    $self->{session_headshots}   = 0;
    $self->{session_shots}       = 0;
    $self->{session_hits}        = 0;
    $self->{session_start_pos}   = -1;

    $self->{map_kills}           = 0;
    $self->{map_deaths}          = 0;
    $self->{map_suicides}        = 0;
    $self->{map_headshots}       = 0;
    $self->{map_shots}           = 0;
    $self->{map_hits}            = 0;
    $self->{is_dead}             = 0;
    $self->{has_bomb}            = 0;

    $self->{is_banned}           = 0;
    $self->{is_bot}              = 0;

    $self->{display_events}      = 1;
    $self->{display_chat}        = 1;
    $self->{kills_per_life}      = 0;
    $self->{last_history_day}    = "";
    $self->{last_death_weapon}   = 0;
    $self->{last_sg_build}       = 0;
    $self->{last_disp_build}     = 0;
    $self->{last_entrance_build} = 0;
    $self->{last_exit_build}     = 0;
    $self->{last_team_change}    = "";
    $self->{deaths_in_a_row}     = 0;
    $self->{trackable}           = 0;
    $self->{needsupdate}         = 0;


    # Set Property Values
    unless (defined $params{uniqueid}) {
        ::printEvent("HLSTATSZ", "HLstats_Player->new(): missing uniqueid", 1);
        return undef;
    }


    while (my ($k, $v) = each %params) {
        next if $k eq 'name' || $k eq 'uniqueid';
        $self->set($k, $v);
    }


    $self->updateTrackable();
    $self->{plain_uniqueid} = $params{plain_uniqueid};
    $self->setUniqueId($params{uniqueid});
    if ($::g_stdin == 0 && ( ($self->{userid} > 0 || $::g_servers{$self->{server}}->{play_game} == CS2())) ) {
        $self->insertPlayerLivestats();
    }
    $self->setName($params{name});
    $self->getAddress();
    $self->flushDB();

    ::printEvent("MYSQL", "Created new player object " . $self->getInfoString(),4);
    return $self;
}

sub playerCleanup
{
    my ($self) = @_;
    $self->flushDB();
    $self->deleteLivestats();
    ::printEvent("MYSQL", "Flush DB and delete player from Live stats",4);
}


#
# Set property 'key' to 'value'
#

sub set
{
    my ($self, $key, $value, $no_updatetime) = @_;

    if (defined($self->{$key})) {
        if (!defined $no_updatetime || $no_updatetime == 0) {
            $self->{timestamp} = $::ev_daemontime;
        }

        return 0 if ($self->{$key} eq $value);

        if ($key eq "uniqueid") {

            return $self->setUniqueId($value);

        } elsif ($key eq "name") {

            return $self->setName($value);

        } elsif ($key eq "skill" && (( $self->{userid} < 1 && $::g_servers{$self->{server}}->{play_game} != CS2()) ||  ($self->{userid} < 0 && $::g_servers{$self->{server}}->{play_game} == CS2())) ) {

            return $self->{skill};

        } else {

            $self->{$key} = $value;
            return 1;
        }
    } else {
        warn("HLstats_Player->set: \"$key\" is not a valid property name\n");
        return 0;
    }
}


#
# Increment (or decrement) the value of 'key' by 'amount' (or 1 by default)
#
sub increment
{
    my ($self, $key, $amount, $no_updatetime) = @_;
    #not sure about this one
    if ($key eq "skill" && (( $self->{userid} < 1 && $::g_servers{$self->{server}}->{play_game} != CS2()) ||  ($self->{userid} < 0 && $::g_servers{$self->{server}}->{play_game} == CS2())) ) {
        return $self->{skill};
    }
    
    $amount = 1 if (!defined($amount));
    
    if ($amount != 0) {    
        my $value = $self->{$key};
        $self->set($key, $value + $amount, $no_updatetime);
    }
}


sub check_history
{
    my ($self) = @_;

    #my ($sec,$min,$hour,$mday,$mon,$year) = localtime(time());
    my ($sec,$min,$hour,$mday,$mon,$year) = localtime($::ev_unixtime);
    my $date = sprintf("%04d-%02d-%02d", $year+1900, $mon+1, $mday);
    my $srv_addr = $self->{server};
    my $game     = $::g_servers{$srv_addr}{game} // '';
    my $pid      = $self->{playerid} // 0;
    
    my $is_bot = ($self->{is_bot}
                  || (( $self->{userid} < 1 && $::g_servers{$srv_addr}{play_game} != CS2())
                      || ($self->{userid} < 0 && $::g_servers{$srv_addr}{play_game} == CS2()))) ? 1 : 0;

    return 0 unless $pid && ($::g_stdin == 0 || $::g_timestamp > 0);
    return 0 if $is_bot && ($::g_servers{$srv_addr}{ignore_bots} // 0);

     $self->{last_history_day} = sprintf("%02d", $mday);
     my $sql1  = q{
        SELECT skill_change
        FROM hlstats_Players_History
        WHERE playerId = ? AND eventTime = ? AND game = ?
        LIMIT 1
    };
    my @vals1 = ($pid, $date, $game);
    my $rows1 = ::query_now($sql1, @vals1);
   
    if ($rows1->rows < 1) {
        my $sql2  = q{
            INSERT INTO hlstats_Players_History (playerId, eventTime, game, skill_change)
            VALUES (?, ?, ?, 0)
        };
        my @vals2 = ($pid, $date, $game);

        ::exec_now($sql2,@vals2);
        $self->{day_skill_change} = 0;
    } else {
        ($self->{day_skill_change}) = $rows1->fetchrow_array;
    }
    $rows1->finish;
}


#
# Set player's uniqueid
#
sub setUniqueId
{
    my ($self, $uniqueid) = @_;
    my $pid = ::getPlayerId($uniqueid);

    my $game = $::g_servers{$self->{server}}->{game};

    if ($pid) {

        # An existing player. Get their skill rating.
        $self->{playerid} = $pid;
        my $rows = ::query_now(q{SELECT skill, kills, displayEvents, flag FROM hlstats_Players WHERE playerId=?}, $pid);
        if ($rows->rows > 0) {
            ($self->{skill}, $self->{total_kills}, $self->{display_events},$self->{flag}) = $rows->fetchrow_array;
        } else {
            # Have record in hlstats_PlayerUniqueIds but not in hlstats_Players
            $self->insertPlayer($pid);
        }
        $self->{session_start_pos} = $self->getRank();
        $rows->finish;

    } else {

        # This is a new player. Create a new record for them in the Players
        $self->insertPlayer();
        ::exec_now(q{INSERT IGNORE INTO hlstats_PlayerUniqueIds (playerId, uniqueId, game) VALUES (?, ?, ?)}, $self->{playerid}, $uniqueid, $game);

    }

    $self->{uniqueid} = $uniqueid;
    $self->check_history();

    return 1;
}


#
# Inserts new player
#
sub insertPlayer
{
    my ($self, $playerid) = @_;

    my $srv_addr = $self->{server};
    my $hideval = 0;

    if ($::g_servers{$srv_addr}->{play_game} == L4D() && $self->{userid} < 0) {
        $hideval = 1;
    }

    if ($playerid) {
        my $sql = q{
            INSERT INTO hlstats_Players
                (lastName, clan, game, displayEvents, createdate, hideranking, playerId)
            VALUES
                (?, ?, ?, ?, UNIX_TIMESTAMP(), ?, ?)
        };
        my @bind = (
            $self->{name},
            $self->{clan},
            $::g_servers{$srv_addr}->{game},
            $self->{display_events},
            $hideval,
            $playerid,
        );
       ::exec_cache($sql,@bind);
       return $playerid;
    }

    my $query = q{
        INSERT INTO
            hlstats_Players
            (
                lastName,
                clan,
                game,
                displayEvents,
                createdate,
                hideranking
            )
        VALUES
        (
            ?,
            ?,
            ?,
            ?,
            UNIX_TIMESTAMP(),
            ?
        )
    };
    my @vals = ($self->{name}, $self->{clan}, $::g_servers{$srv_addr}->{game}, $self->{display_events}, $hideval);
    my $res = ::exec_cache("player_insert", $query, @vals);
    $self->{playerid} = $res->last_insert_id(undef, undef, undef, undef);

}

#
# Insert initial live stats
#
sub insertPlayerLivestats
{
    my ($self) = @_;
    my $query = "
        REPLACE INTO
            hlstats_Livestats
            (
                player_id,
                server_id,
                cli_address,
                steam_id,
                name,
                team,
                ping,
                connected,
                skill,
                cli_flag
            )
        VALUES
        (
            ?,?,?,?,?,?,?,?,?,?
        )
    ";
    my @vals = ($self->{playerid}, $self->{server_id}, $self->{address}, $self->{plain_uniqueid},
                $self->{name}, $self->{team}, $self->{ping}, $self->{connect_time}, $self->{skill}, $self->{flag});
    ::exec_cache("player_livestats_insert", $query, @vals);
    ::printEvent("MYSQL", "Insert Player in Live Stats $self->{name} ($self->{playerid})",4);
}


#
# Set player's name
#
sub setName
{
    my ($self, $name) = @_;
    
    my $old = $self->{name};

    return 2 if $old eq $name;

    $self->updateDB() if $old;
    $self->{name} = $name;

    my $is_bot = $self->{is_bot};
    my $server_address = $self->{server};

    if (($is_bot == 1) && ($::g_servers{$server_address}->{ignore_bots} == 1)) {
        $self->{clan} = 0;
    } else {
        $self->{clan} = ::getClanId($name);
    }
    my $pid = $self->{playerid};

    
    if ($pid) {
        my $sql_p = q{
            UPDATE hlstats_Players
            SET lastName = ?, clan = ?
            WHERE playerId = ?
        };
        my $rows = ::query_now($sql_p,$self->{name}, $self->{clan}, $pid);
        my $sql_n = q{
            INSERT INTO hlstats_PlayerNames (playerId, name, lastuse, numuses)
            VALUES (?, ?, FROM_UNIXTIME(?), 1)
            ON DUPLICATE KEY UPDATE
              lastuse = VALUES(lastuse),
              numuses = numuses + 1
        };
        ::exec_now($sql_n, $pid, $self->{name}, $::ev_unixtime);
         $rows->finish;
         ::printEvent("MYSQL", "HLstats_Player->setName() to DB",4);
    } else {
        ::printEvent("HLSTATSZ", "HLstats_Player->setName(): No playerid",1);
    }
}



#
# Update player information in database
#
sub flushDB {
    my ($self, $leaveLastUse, $callref) = @_;

    my $playerid = $self->{playerid} or do {
        warn "Player->Update() with no playerid set!\n";
        return 0;
    };

    my $srv_addr       = $self->{server};
    my $serverid       = $self->{server_id};
    my $server_address = $self->{server};
    my $game           = $::g_servers{$srv_addr}->{game};
    my $ignore_bots    = $::g_servers{$server_address}->{ignore_bots} // 0;
    my $is_bot         = $self->{is_bot};

    # Snapshot frequently used fields
    my $name          = ($::db_driver eq 'mysql') ? $self->{name} : decode("UTF-8", $self->{name});
    my $clan          = $self->{clan} + 0;
    my $kills         = $self->{kills};
    my $deaths        = $self->{deaths};
    my $suicides      = $self->{suicides};
    my $skill         = $self->{skill} // 0; $skill = 0 if $skill < 0;
    my $headshots     = $self->{headshots};
    my $shots         = $self->{shots};
    my $hits          = $self->{hits};
    my $teamkills     = $self->{teamkills};

    my $team          = $self->{team};
    my $map_kills     = $self->{map_kills};
    my $map_deaths    = $self->{map_deaths};
    my $map_suicides  = $self->{map_suicides};
    my $map_headshots = $self->{map_headshots};
    my $map_shots     = $self->{map_shots};
    my $map_hits      = $self->{map_hits};
    my $steamid       = $self->{plain_uniqueid};
    my $address       = $self->{address};
    my $ping          = $self->{ping};

    my $is_dead       = $self->{is_dead};
    my $has_bomb      = $self->{has_bomb};
    my $connected     = $self->{connect_time};
    my $skill_change  = $self->{session_skill};
    
    my $death_streak  = $self->{death_streak};
    my $kill_streak   = $self->{kill_streak};

    my $is_stdin      = $::g_stdin ? 1 : 0;
    my $now           = $is_stdin ? $::ev_unixtime : time();
    my $last_upd      = $self->{last_update} // 0;
    ::printEvent("MYSQL", "Flushing player $name ($playerid) <$server_address> to database...",4);

    # Compute connect-time increment
    my $add_connect_time = 0;
    if ($last_upd > 0) {
        $add_connect_time = $now - $last_upd;
        # Avoid big jumps in stdin mode
        if ($is_stdin && $add_connect_time > 600) {
            $self->{last_update}   = $::ev_unixtime;
            $add_connect_time      = 0;
        }
    }

    # Date components from event time
    my (undef,$min,$hour,$mday,$mon,$year) = localtime($::ev_unixtime);
    my $date = sprintf("%04d-%02d-%02d", $year+1900, $mon+1, $mday);
    my $day2 = sprintf("%02d", $mday);

    # History only when not stdin or explicit timestamp mode
    my $history_on = (!$is_stdin) || ($::g_timestamp > 0);

    if ($history_on) {
        my $last_history_day = $self->{last_history_day} // '';
        if ($last_history_day ne $day2) {
            my $query = q{
                INSERT IGNORE INTO hlstats_Players_History (playerId, eventTime, game)
                VALUES (?,?,?)
            };
            ::exec_cache("player_flushdb_history_1", $query, $playerid, $date, $game);
            $self->{day_skill_change} = 0;
            $self->{last_history_day} = $day2;
        }
    }

    # Day skill delta + accumulation
    my $add_history_skill      = ($self->{last_update_skill} // 0) ? ($skill - $self->{last_update_skill}) : 0;
    $self->{day_skill_change}  = ($self->{day_skill_change} // 0) + $add_history_skill;
    my $last_skill_change      = $self->{day_skill_change};

    # --- Players update (bot vs human) ---
    my $hideranking = ($ignore_bots && $is_bot ? 1 : 0);

    my $query = q{
        UPDATE hlstats_Players
           SET connection_time  = connection_time + ?,
               lastAddress      = ?,
               lastPing         = ?,
               lastName         = ?,
               clan             = ?,
               kills            = kills + ?,
               deaths           = deaths + ?,
               suicides         = suicides + ?,
               skill            = ?,
               headshots        = headshots + ?,
               shots            = shots + ?,
               hits             = hits + ?,
               teamkills        = teamkills + ?,
               last_event       = ?,
               last_skill_change= ?,
               death_streak     = IF(?>death_streak,?,death_streak),
               kill_streak      = IF(?>kill_streak,?,kill_streak),
               hideranking      = ?,
               activity         = 100
         WHERE playerId = ?
    };
    ::exec_cache("player_flushdb_player_2", $query,
        $add_connect_time, $address, $ping, $name, $clan, $kills, $deaths, $suicides, $skill,
        $headshots, $shots, $hits, $teamkills, $::ev_unixtime, $last_skill_change,
        $death_streak, $death_streak, $kill_streak , $kill_streak, $hideranking, $playerid
    );

    if ($history_on && ((!$is_bot) || ($is_bot && !$ignore_bots))) {
        my $query = q{
            UPDATE hlstats_Players_History
               SET connection_time = connection_time + ?,
                   kills           = kills + ?,
                   deaths          = deaths + ?,
                   suicides        = suicides + ?,
                   skill           = ?,
                   headshots       = headshots + ?,
                   shots           = shots + ?,
                   hits            = hits + ?,
                   teamkills       = teamkills + ?,
                   death_streak    = IF(?>death_streak,?,death_streak),
                   kill_streak     = IF(?>kill_streak,?,kill_streak),
                   skill_change    = skill_change + ?
             WHERE playerId  = ?
               AND eventTime = ?
               AND game      = ?
        };
        ::exec_cache("player_flushdb_history_2", $query,
            $add_connect_time, $kills, $deaths, $suicides, $skill,
            $headshots, $shots, $hits, $teamkills,
            $death_streak, $death_streak, $kill_streak, $kill_streak,
            $add_history_skill, $playerid, $date, $game
        );
    }

    # --- PlayerNames alias update ---
    if ($name) {
        my $query = q{
            UPDATE hlstats_PlayerNames
               SET connection_time = connection_time + ?,
                   kills           = kills + ?,
                   deaths          = deaths + ?,
                   suicides        = suicides + ?,
                   headshots       = headshots + ?,
                   shots           = shots + ?,
                   hits            = hits + ?
        };
        my @vals = ($add_connect_time, $kills, $deaths, $suicides, $headshots, $shots, $hits);

        unless ($leaveLastUse) {
            $query .= q{, lastuse = FROM_UNIXTIME(?)};
            push @vals, $::ev_unixtime;
        }

        $query .= q{ WHERE playerId = ? AND name = ? };
        push @vals, $playerid, $name;

        ::exec_cache("player_flushdb_playernames", $query, @vals);
    }

    # --- Live stats (game server mode only) ---
    if (!$is_stdin && ($self->{userid} > 0 || $::g_servers{$server_address}->{play_game} == CS2())) {
        my $query = q{
            UPDATE hlstats_Livestats
               SET cli_address  = ?,
                   steam_id     = ?,
                   name         = ?,
                   team         = ?,
                   kills        = ?,
                   deaths       = ?,
                   suicides     = ?,
                   headshots    = ?,
                   shots        = ?,
                   hits         = ?,
                   is_dead      = ?,
                   has_bomb     = ?,
                   ping         = ?,
                   connected    = ?,
                   skill_change = ?,
                   skill        = ?
             WHERE player_id = ?
        };
        ::exec_cache("player_flushdb_livestats", $query,
            $address, $steamid, $name,
			$team, $map_kills, $map_deaths, $map_suicides, $map_headshots, $map_shots,
			$map_hits, $is_dead, $has_bomb, $ping, $connected, $skill_change, $skill, $playerid);
    }

    # --- Reset in-memory counters & timestamps ---
    for my $k (qw/kills deaths suicides headshots shots hits teamkills/) {
        $self->set($k, 0, 1);
    }

    $self->{last_update}       = $now;
    $self->{last_update_skill} = $skill;
    $self->{needsupdate}       = 0;
    return 1;
}


#
# Update player timestamp (time of last event for player - used to detect idle
# players)
#
sub updateTimestamp
{
    my ($self, $timestamp) = @_;
    $timestamp = $::ev_unixtime
        unless ($timestamp);
    $self->{timestamp} = $::ev_daemontime;
    return $timestamp;
}

sub updateDB
{
    my ($self) = @_;
    $self->{needsupdate} = 1;
    
}

sub deleteLivestats
{
    my ($self) = @_;

    # delete live stats
    ::exec_now("DELETE FROM hlstats_Livestats WHERE player_id=?", $self->{playerid});

}


#
# Returns a string of information about the player.
#
sub getInfoString
{
    my ($self) = @_;
    return sprintf("\"%s\" \<P:%d,U:%d,W:%s,T:%s\>", $self->{name}, $self->{playerid}, $self->{userid}, $self->{uniqueid}, $self->{team});
}

sub getAddress
{
    my ($self) = @_;
    my $haveAddress      = $self->{address} ? 1:0;
    my $ignore_bots      = $::g_servers{$self->{server}}->{ignore_bots} // 0;

    if ( $self->{is_bot} ) {
        if ($ignore_bots == 0) { $self->{address} = '127.0.0.1'; }
        else { $self->{address} = ""; }
    }

    if (!$haveAddress && $::g_stdin == 0 && $self->{is_bot} == 0 &&
       ( $self->{userid} > 0 || $::g_servers{$self->{server}}->{play_game} == CS2())) {

        my $slot_name = $self->{userid}."/".$self->{name};

        ::printEvent("RCON", "rcon_getaddress for $slot_name",3);
        my $result = $::g_servers{$self->{server}}->rcon_getaddress($self->{uniqueid},$slot_name);

        if (defined $result->{realuserid}) {
            $self->{realuserid} = $result->{realuserid};
            $self->{userid} =  $result->{UserID};
        }
        if (defined $result->{Address} && $result->{Address} ne "") {
            $haveAddress = 1;
            $self->{address}  = $result->{Address};
            $self->{cli_port} = $result->{ClientPort};
            $self->{ping}     = $result->{Ping};

            ::printEvent("RCON", "Got Address $self->{address} for $slot_name",3);
        } else { $haveAddress = 0; }
    }

    if ($haveAddress == 1) {
        $self->geoLookup();
    }

    return 1;
}

sub geoLookup {
    my ($self) = @_;
    my $ip = $self->{address} // '';
    return unless length $ip;

    # Normalize: strip trailing :port, handle [IPv6]:port
    if ($ip =~ /^\[(.+?)\]:(\d+)$/) { $ip = $1 }
    elsif ($ip =~ /^(.+?):(\d+)$/ && $ip !~ /:/) { $ip = $1 }

    if (($::g_geoip_binary // 0) > 0) {
        return unless defined $::g_gi;

        my ($city,$state,$country,$flag,$lat,$lng);
        my $rec; eval { $rec = $::g_gi->city(ip => $ip) }; $rec = undef if $@;

        if ($rec) {
            my $c  = $rec->city;
            my $co = $rec->country;
            my $lo = $rec->location;
            my $ss = $rec->most_specific_subdivision;

            $city    = $c  ? $c->name      : undef;
            $state   = $ss ? $ss->name     : undef;
            $country = $co ? $co->name     : undef;
            $flag    = $co ? $co->iso_code : undef;
            $lat     = $lo ? $lo->latitude : undef;
            $lng     = $lo ? $lo->longitude: undef;

            return geoUpdate($self, $city, $state, $country, $flag, $lat, $lng);
        }
        return;
    }
    # Legacy DB lookup path
    my @oct = split /\./, $ip;
    return unless @oct == 4 && !grep { $_ !~ /^\d+$/ } @oct;

    my $ipnum = $oct[0]*16777216 + $oct[1]*65536 + $oct[2]*256 + $oct[3];

    my $sql1 = q{
        SELECT locId
          FROM geoLiteCity_Blocks
         WHERE startIpNum <= ? AND endIpNum >= ?
         LIMIT 1
    };
    my $sth1 = ::exec_cache("geo_blocks_by_ip", $sql1, $ipnum, $ipnum) or return;
    my ($locid) = $sth1->fetchrow_array or return;

    my $sql2 = q{
        SELECT a.city        AS city,
               a.region      AS state,
               b.name        AS country,
               a.country     AS flag,
               a.latitude    AS lat,
               a.longitude   AS lng
          FROM geoLiteCity_Location a
          JOIN hlstats_Countries b ON a.country = b.flag
         WHERE a.locId = ?
         LIMIT 1
    };
    my $sth2 = ::exec_cache("geo_location_by_locid", $sql2, $locid) or return;
    my ($city,$state,$country,$flag,$lat,$lng) = $sth2->fetchrow_array or return;

    return geoUpdate($self, $city, $state, $country, $flag, $lat, $lng);
}

sub geoUpdate {
    my ($self, $city, $state, $country, $flag, $lat, $lng) = @_;

    # Stash on object
    $self->{city}    = $city    // '';
    $self->{state}   = $state   // '';
    $self->{country} = $country // '';
    $self->{flag}    = $flag    // '';
    $self->{lat}     = (defined $lat ? $lat : undef);
    $self->{lng}     = (defined $lng ? $lng : undef);

    my $pid = $self->{playerid} // 0;
    return unless $pid;

    # Cached updates (these are hot paths)
    my $sqlA = q{
        UPDATE hlstats_Livestats
           SET cli_city    = ?,
               cli_country = ?,
               cli_flag    = ?,
               cli_state   = ?,
               cli_lat     = ?,
               cli_lng     = ?
         WHERE player_id   = ?
    };
    ::exec_cache("geo_update_livestats", $sqlA,
        $self->{city}, $self->{country}, $self->{flag}, $self->{state},
        $self->{lat}, $self->{lng}, $pid
    );

    my $sqlB = q{
        UPDATE hlstats_Players
           SET city    = ?,
               state   = ?,
               country = ?,
               flag    = ?,
               lat     = ?,
               lng     = ?
         WHERE playerId = ?
    };
    ::exec_cache("geo_update_players", $sqlB,
        $self->{city}, $self->{state}, $self->{country}, $self->{flag},
        $self->{lat}, $self->{lng}, $pid
    );
}

sub getRank
{
    my ($self) = @_;
    
    my $srv_addr  = $self->{server};
    $query = "
        SELECT
            kills,
            deaths,
            hideranking
        FROM
            hlstats_Players
        WHERE
            playerId=?
    ";
    my $result = ::exec_cache("get_player_rank_stats", $query, $self->{playerid});
        
    my ($kills, $deaths, $hideranking) = $result->fetchrow_array;
    $result->finish;
    
    return 0 if ($hideranking > 0);
    
    $deaths = 1 if ($deaths == 0);
    my $kpd = $kills/$deaths;
    
    my $rank = 0;
    
    if ($::g_ranktype ne "kills"){

        if (!defined($self->{skill})) {
            ::printEvent("ERROR", "Attempted to get rank for uninitialized player \"".$self->{name}."\"",1);
            return 0;
        }
        
        my $query = "
            SELECT
                COUNT(*)
            FROM
                hlstats_Players
            WHERE
                game=?
                AND hideranking = 0
                AND lastAddress <> ''
                AND kills >= 1
                AND (
                        (skill > ?) OR (
                            (skill = ?) AND ((kills/IF(deaths=0,1,deaths)) > ?)
                        )
                )
        ";
        my @vals = (
            $self->{game},
            $self->{skill},
            $self->{skill},
            $kpd
        );
        my $rankresult = ::exec_cache("get_player_skill_value", $query, @vals);
        ($rank) = $rankresult->fetchrow_array;
        $rankresult->finish;
        return $rank + 1;

    } else {
        my $query ="
            SELECT
                COUNT(*)
            FROM
                hlstats_Players
            WHERE
                game=?
                AND hideranking = 0
                AND lastAddress <> ''
                AND (
                        (kills > ?) OR (
                            (kills = ?) AND ((kills/IF(deaths=0,1,deaths)) > ?)
                        )
                )
        ";
        my @vals = (
            $self->{game},
            $kills,
            $kills,
            $kpd
        );
        my $rankresult = ::exec_cache("get_player_rank_value", $query, @vals);
        ($rank) = $rankresult->fetchrow_array;
        $rankresult->finish;
        return $rank + 1;
    }
    ::printEvent("MYSQL", "Got rank for $self->{name} ($self->{playerid})",4);
    return $rank;
}

sub updateTrackable
{
    my ($self) = @_;
    
    if ( (::isTrackableTeam($self->{team}) == 0) || ($::g_servers{$self->{server}}->{ignore_bots} && $self->{is_bot} == 1) || ($self->{userid} <= 0 && $::g_servers{$self->{server}}->{play_game} != CS2()) ) {
        $self->{trackable} = 0;
        return;
    }
    $self->{trackable} = 1;
}

1;
