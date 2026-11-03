package HLstats_Game;
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

sub new
{
    my $class_name = shift;
    my $game = shift;
    
    my $self = {};
    bless($self, $class_name);
    
    # Initialise Properties
    $self->{game}           = $game;
    $self->{weapons}        = ();
    $self->{actions}        = ();
    
    # Set Property Values
    
    die("HLstats_Game->new(): must specify game's game code\n")    if ($game eq "");
    my $weaponlist = ::query_now("SELECT code, name, modifier FROM hlstats_Weapons WHERE game=?", $game);
    while ( my($code,$name,$modifier) = $weaponlist->fetchrow_array) {
        $self->{weapons}{$code}{name} = $name;
        $self->{weapons}{$code}{modifier} = $modifier;
    }
    
    my $actionlist = ::query_now("SELECT id, code, reward_player, reward_team, team, description, for_PlayerActions, for_PlayerPlayerActions, for_TeamActions, for_WorldActions FROM hlstats_Actions WHERE game=?", $game);
    while ( my($id, $code, $reward_player,$reward_team,$team, $descr, $paction, $ppaction, $taction, $waction) = $actionlist->fetchrow_array) {
        $self->{actions}{$code}{id} = $id;
        $self->{actions}{$code}{descr} = $descr;
        $self->{actions}{$code}{reward_player} = $reward_player;
        $self->{actions}{$code}{reward_team} = $reward_team;
        $self->{actions}{$code}{team} = $team;
        $self->{actions}{$code}{paction} = $paction;
        $self->{actions}{$code}{ppaction} = $ppaction;
        $self->{actions}{$code}{taction} = $taction;
        $self->{actions}{$code}{waction} = $waction;
    }
    $actionlist->finish;

    ::printEvent("GAME", "Created new game object for $game ",1);
    return $self;
}

#
# Players of this game, counted once a minute at most. Each server of the game asks at each of its flushes (every
# 20 s), each !rank asks too, and each count reads every player of the game: counted every time, it was the daemon's
# biggest cost with many servers (100 busy servers and 240,000 players: close to 40% of its time).
#
sub getTotalPlayers
{
    my ($self) = @_;
    return $self->countPlayers("ranked", "hideranking = 0");
}

# The players the servers track (all but the hidden ones): hlstats_Servers.players
sub getTrackedPlayers
{
    my ($self) = @_;
    return $self->countPlayers("tracked", "hideranking <> 1");
}

sub countPlayers
{
    my ($self, $kind, $where) = @_;
    my $counted = $self->{player_count}{$kind};
    return $counted->[1] if $counted && time() - $counted->[0] < 60;

    # The database does not answer: the last count, until it does
    my $result = ::exec_cache("game_players_$kind",
        "SELECT count(*) as players FROM hlstats_Players WHERE game=? AND $where AND lastAddress <> ''", $self->{game})
        or return $counted ? $counted->[1] : 0;
    my ($players) = $result->fetchrow_array;
    $result->finish;

    $self->{player_count}{$kind} = [time(), $players // 0];
    return $players // 0;
}

1;
