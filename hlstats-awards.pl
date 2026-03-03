#!/usr/bin/perl
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

##
## Settings
##

# $opt_configfile - Absolute path and filename of configuration file.
my $opt_configfile = "./hlstats.conf";

# $opt_libdir - Directory to look in for local required files
#               (our *.plib, *.pm files).
my $opt_libdir = "./";

##
##
################################################################################
## No need to edit below this line
##
use Getopt::Long;
use DBI;
use Encode;

require "$opt_libdir/ConfigReaderSimple.pm";
do "$opt_libdir/HLstats.plib";

$|=1;
Getopt::Long::Configure ("bundling");


binmode STDIN, ":utf8";
binmode STDOUT, ":utf8";

##
## MAIN
##

# Options
my $opt_help = 0;
my $opt_version = 0;
my $opt_numdays = 1;
my $g_deletedays = 28;
my $opt_player_activity = 0;
my $opt_awards = 0;
my $opt_ribbons = 0;
my $opt_geoip = 0;
my $opt_prune = 0;
my $opt_optimize = 0;
my $opt_verbose = 0;
our $opt_cpanelhack = 0;

our $db_host = "localhost";
our $db_user = "";
our $db_pass = "";
our $db_name = "hlstats";

my $date_ubase="";
my $date_base="CURRENT_DATE()";

my %player_tables = map { $_ => 1 } qw(
    ChangeName ChangeRole ChangeTeam Chat Connects Disconnects Entries
    Latency PlayerActions PlayerPlayerActions Statsme Statsme2
    StatsmeLatency StatsmeTime Suicides TeamBonuses
);
my %frag_tables = map { $_ => 1 } qw(
    Frags Teamkills
);
my %global_tables = map { $_ => 1 } qw(
    Admin Rcon
);


my $usage = <<EOT
Usage: hlstats-awards.pl [OPTION]...
Generate awards from Half-Life server statistics.
    
 Actions (specify none or more, default -iarp):
  -i, --inactive                  Calculate player activity
                                    and deactivate inactive players
  -a, --awards                    Process daily awards (see --date descr for more info)
  -r, --ribbons                   Process ribbons
  -g, --geoip                     Attempt to lookup and store locations for players with
                                    unknown/no location. (run after updating geoip data)
  -p, --prune                     Prune old events and sessions
  -o, --optimize                  Optimize all db tables

 Other options:
  -h, --help                      display this help and exit
  -v, --version                   output version information and exit
      --numdays                   number of days in period for awards
      --date=YYYY-MM-DD           day after date to calculate awards for (defaults to today) 
                                    If you specify a date like 2008-01-04 it will do awards
                                    based on 2008-01-03 stats
      --db-host=HOST              database ip:port
      --db-name=DATABASE          database name
      --db-password=PASSWORD      database password (WARNING: specifying the
                                    password on the command line is insecure.
                                    Use the configuration file instead.)
      --db-username=USERNAME      database username
  -c, --configfile                Specific configfile to use, settings in this file can't
                                  be overided with commandline settings.

Long options can be abbreviated, where such abbreviation is not ambiguous.

Most options can be specified in the configuration file:
  $opt_configfile
Note: Options set on the command line take precedence over options set in the
configuration file.

EOT
;

# Read Config File

my %conf_directives = (
    "DBHost",            "db_host",
    "DBUsername",        "db_user",
    "DBPassword",        "db_pass",
    "DBName",            "db_name",
    "DBDriver",          "db_driver",
    "CpanelHack",        "opt_cpanelhack"
);

if (-r $opt_configfile)
{
    $conf = ConfigReaderSimple->new($opt_configfile);
    $conf->parse();
    &doConf($conf, %conf_directives);
}
else
{
    print "-- Warning: unable to open configuration file $opt_configfile\n";
}

# Read Command Line Arguments

GetOptions(
    "help|h"            => \$opt_help,
    "version|v"         => \$opt_version,
    "numdays=i"         => \$opt_numdays,
    "date=s"            => \$date_ubase,
    "inactive|i"        => \$opt_player_activity,
    "awards|a"          => \$opt_awards,
    "ribbons|r"         => \$opt_ribbons,
    "geoip|g"           => \$opt_geoip,
    "clans|t"           => \$opt_clans,
    "prune|p"           => \$opt_prune,
    "optimize|o"        => \$opt_optimize,
    "db-host=s"         => \$db_host,
    "db-name=s"         => \$db_name,
    "dv-driver=s"       => \$db_driver,
    "db-password=s"     => \$db_pass,
    "db-username=s"     => \$db_user,
    "configfile|c=s"    => \$configfile,
    "verbose"           => \$opt_verbose
) or die($usage);

if ($opt_help)
{
    print $usage;
    exit(0);
}

if ($configfile && -r $configfile) {
    $conf = '';
    $conf = ConfigReaderSimple->new($configfile);
    $conf->parse();
    doConf($conf, %conf_directives);
}

print "-- Connecting to MySQL database '$db_name' on '$db_host' as user '$db_user' with $db_driver... ";

DB_connect();

print "connected OK\n";

my $g_version = $::g_version;


if ($opt_version)
{
    print "\nhlstats-awards.pl (HLX:CE Awards Script) Version $g_version\n"
        . "Real-time player and clan rankings and statistics for Half-Life\n\n"
        . "Copyright (C) 2001  Simon Garner\n"
        . "Modified & Enhanced in 2005 by Tobias Oetzel (Tobi@gameme.de)\n\n";

    print "\nThis is free software; see the source for copying conditions.  There is NO\n"
        . "warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.\n\n";

    exit(0);
}

if ($date_ubase)
{
    $date_base = "'" . $date_ubase . "'";
}

if (0 == ($opt_player_activity + $opt_awards + $opt_ribbons + $opt_geoip + $opt_clans + $opt_prune + $opt_optimize))
{
    $opt_player_activity = 1;
    $opt_awards = 1;
    $opt_ribbons = 1;
    $opt_prune = 1;
}

# Startup

print "++ HLstatsZ Awards & Maintenance script version $g_version starting...\n\n";
exec_now("UPDATE hlstats_Options
              SET value=?
              WHERE keyname='version';",$g_version);
DoPruning() if ($opt_prune);
DoOptimize() if ($opt_optimize);
DoInactive() if ($opt_player_activity);
DoAwards() if ($opt_awards);
DoRibbons() if ($opt_ribbons);
DoGeoIP() if ($opt_geoip);
DoClans() if ($opt_clans);
print "\n++ HLstatsZ Awards & Maintenance script finished.\n\n";
exit(0);

sub DoInactive
{
    print "++ Updating player activity... ";
    $g_minactivity = 2419200;
    # Inactive Players
    my $result = query_now("
        SELECT
            value
        FROM
            hlstats_Options
        WHERE
            keyname = 'MinActivity'
    ");

    if ($result->rows > 0) {
        my ($tempminact) = $result->fetchrow_array;
        $g_minactivity = $tempminact * 86400;
    }
    
    if ($g_minactivity > 0)
    {
        $g_timestamp = 0;
    
        $result = query_now("
            SELECT
                value
            FROM
                hlstats_Options
            WHERE
                keyname = 'UseTimestamp'
        ");
        
        
        if ($result->rows > 0) {
            ($g_timestamp) = $result->fetchrow_array;
        }
        
        %last_events = ();
        
        if ($g_timestamp > 0)
        {
            $result = query_now("
                SELECT
                    game,
                    MAX(last_event)
                FROM
                    hlstats_Servers
                GROUP BY
                    game
            ");
            my %last_events = ();
    
    
            while ( my($game, $last) = $result->fetchrow_array) {
                $last_events{$game} = $last
            }
            while ( my($game, $last) = each(%last_events))
            {
                exec_now("
                    UPDATE
                        hlstats_Players
                    SET
                        hlstats_Players.activity = IF(($g_minactivity > $last - hlstats_Players.last_event), ((100 / $g_minactivity) * ($g_minactivity - ($last - hlstats_Players.last_event))), -1)
                    WHERE
                        hlstats_Players.game =?",$game);
            }
        }
        else
        {
            exec_now("
                UPDATE
                    hlstats_Players
                SET
                    hlstats_Players.activity = IF(($g_minactivity > UNIX_TIMESTAMP() - hlstats_Players.last_event), ((100 / $g_minactivity) * ($g_minactivity - (UNIX_TIMESTAMP() - hlstats_Players.last_event))), -1)
            ");
        }
    
        exec_now("
            UPDATE
                hlstats_Players
            SET
                hideranking = 0
            WHERE
                hideranking <> 2
                AND lastAddress <> ''
        ");
    }
    
    print "done\n";
}

sub DoAwards
{
    print "++ Processing awards... ";
    
    my $resultAwards = query_now("
        SELECT
            hlstats_Awards.awardId,
            hlstats_Awards.game,
            hlstats_Awards.awardType,
            hlstats_Awards.code
        FROM
            hlstats_Awards
        LEFT JOIN hlstats_Games ON
            hlstats_Games.code = hlstats_Awards.game
        WHERE
            hlstats_Games.hidden='0'
        ORDER BY
            hlstats_Awards.game,
            hlstats_Awards.awardType
    ");

    my $result = query_now("
        SELECT
            value,
            DATE_SUB($date_base, INTERVAL 1 DAY)
        FROM
            hlstats_Options
        WHERE
            keyname = 'awards_d_date'
    ");

    if ($result->rows > 0)
    {
        ($awards_d_date, $awards_d_date_new) = $result->fetchrow_array;
        
        exec_now("
            UPDATE
                hlstats_Options
            SET
                value='$awards_d_date_new'
            WHERE
                keyname='awards_d_date'
        ");
        
        print "(generating awards for $awards_d_date_new (previous: $awards_d_date))... ";
    }
    else
    {
        exec_now("
            INSERT INTO
                hlstats_Options
                (
                    keyname,
                    value,
                    opttype
                )
            VALUES
            (
                'awards_d_date',
                DATE_SUB($date_base, INTERVAL 1 DAY),
                2
            )
        ");
    }

    exec_now("
        REPLACE INTO
            hlstats_Options
            (
                keyname,
                value,
                opttype
            )
        VALUES
        (
            'awards_numdays',
            $opt_numdays,
            2
        )
    ");

    while( ($awardId, $game, $awardType, $code) = $resultAwards->fetchrow_array )
    {

        if ($awardType eq "O")
        {
            $table = "hlstats_Events_PlayerActions";
            $join  = "LEFT JOIN hlstats_Actions ON hlstats_Actions.id = $table.actionId";
            $matchfield = "hlstats_Actions.code";
            $playerfield = "$table.playerId";
        }
        elsif ($awardType eq "W")
        {
            $table = "hlstats_Events_Frags";
            $playerfield = "$table.killerId";
            if ($code eq "headshot") {
                $join  = "";
                $matchfield = "$table.headshot";
                $code = 1;
            } else {
                $join  = "";
                $matchfield = "$table.weapon";
            }
        }
        elsif ($awardType eq "P")
        {
            $table = "hlstats_Events_PlayerPlayerActions";
            $join  = "LEFT JOIN hlstats_Actions ON hlstats_Actions.id = $table.actionId";
            $matchfield = "hlstats_Actions.code";
            $playerfield = "$table.playerId";
        }
        elsif ($awardType eq "V")
        {
            $table = "hlstats_Events_PlayerPlayerActions";
            $join  = "LEFT JOIN hlstats_Actions ON hlstats_Actions.id = $table.actionId";
            $matchfield = "hlstats_Actions.code";
            $playerfield = "$table.victimId";
        }
        
        if ($code eq "latency") {
            $resultDaily = query_now("
                 SELECT
                     p.playerId,
                     ROUND(p.lastPing / 2, 0) AS latency
                 FROM
                     hlstats_Players p
                 INNER JOIN
                     hlstats_Players_History h 
                         ON h.playerId = p.playerId
                        AND h.game = p.game
                 WHERE
                     p.game = ?
                     AND p.hideranking = 0
                     AND p.lastAddress <> ''
                     AND p.last_event > UNIX_TIMESTAMP(UTC_TIMESTAMP() - INTERVAL $opt_numdays DAY)
                     AND h.eventTime >= UNIX_TIMESTAMP(DATE_SUB(FROM_UNIXTIME($date_base), INTERVAL $opt_numdays DAY))
                     AND h.eventTime <  UNIX_TIMESTAMP(DATE_SUB(FROM_UNIXTIME($date_base), INTERVAL ($opt_numdays - 1) DAY))
                     AND h.connection_time >= 300
                     AND h.kills > 0
                     AND p.lastPing IS NOT NULL
                     AND p.lastPing > 0
                 ORDER BY
                     p.lastPing ASC
                 LIMIT 1;
            ", $game);
            $resultGlobal = query_now("
                SELECT
                    p.playerId,
                    ROUND(p.lastPing / 2, 0) AS latency
                FROM
                    hlstats_Players p
                WHERE
                    p.game = ?
                    AND p.hideranking = 0
                    AND p.lastAddress <> ''
                    AND p.kills > 1000
                    AND p.last_event > UNIX_TIMESTAMP(UTC_TIMESTAMP() - INTERVAL $g_deletedays DAY)
                    AND p.lastPing IS NOT NULL
                    AND p.lastPing > 0
                ORDER BY
                    p.lastPing ASC
                LIMIT 1;
            ", $game);
        } elsif ($code eq "mostkills") {
            $resultDaily = query_now("
                SELECT
                    hlstats_Players_History.playerId,
                    hlstats_Players_History.kills
                FROM
                    hlstats_Players_History,
                    hlstats_Players
                WHERE
                    hlstats_Players_History.game=?
                    AND hlstats_Players.playerId = hlstats_Players_History.playerId
                    AND hlstats_Players.hideranking=0
                    AND hlstats_Players.lastAddress <> ''
                    AND eventTime = DATE_SUB($date_base, INTERVAL $opt_numdays DAY)
                ORDER BY
                    kills DESC
                LIMIT 1
            ",$game);
            $resultGlobal = query_now("
                SELECT
                    playerId,
                    kills
                FROM
                    hlstats_Players
                WHERE
                    hlstats_Players.game=?
                    AND hlstats_Players.hideranking=0
                    AND hlstats_Players.lastAddress <> ''
                ORDER BY
                    kills DESC
                LIMIT 1
            ",$game);
        }
        elsif ($code eq "suicide") {
            $resultDaily = query_now("
                SELECT
                    hlstats_Players_History.playerId,
                    hlstats_Players_History.suicides
                FROM
                    hlstats_Players_History,
                    hlstats_Players
                WHERE
                    hlstats_Players_History.game=?
                    AND hlstats_Players.playerId = hlstats_Players_History.playerId
                    AND hlstats_Players.hideranking=0
                    AND hlstats_Players.lastAddress <> ''
                    AND eventTime = DATE_SUB($date_base, INTERVAL $opt_numdays DAY)
                ORDER BY
                    suicides DESC
                LIMIT 1
            ",$game);
            $resultGlobal = query_now("
                SELECT
                    playerId,
                    suicides
                FROM
                    hlstats_Players
                WHERE
                    hlstats_Players.game=?
                    AND hlstats_Players.hideranking=0
                    AND hlstats_Players.lastAddress <> ''
                ORDER BY
                    suicides DESC
                LIMIT 1
            ",$game);
        } elsif ($code eq "teamkills") {
            $resultDaily = query_now("
                SELECT
                    hlstats_Players_History.playerId,
                    hlstats_Players_History.teamkills
                FROM
                    hlstats_Players_History,
                    hlstats_Players
                WHERE
                    hlstats_Players_History.game=?
                    AND hlstats_Players.playerId = hlstats_Players_History.playerId
                    AND hlstats_Players.hideranking=0
                    AND hlstats_Players.lastAddress <> ''
                    AND eventTime = DATE_SUB($date_base, INTERVAL $opt_numdays DAY)
                ORDER BY
                    teamkills DESC
                LIMIT 1
            ",$game);
            $resultGlobal = query_now("
                SELECT
                    playerId,
                    teamkills
                FROM
                    hlstats_Players
                WHERE
                    hlstats_Players.game=?
                    AND hlstats_Players.hideranking=0
                    AND hlstats_Players.lastAddress <> ''
                ORDER BY
                    teamkills DESC
                LIMIT 1
            ",$game);
        } elsif ($code eq "bonuspoints") {
            $resultDaily = query_now("
                SELECT
                    actions.playerId,
                    SUM(actions.bonus) AS av_bonuspoints
                FROM
                    (SELECT
                        playerId, bonus, serverId, eventTime 
                    FROM
                        hlstats_Events_PlayerActions 
                    WHERE
                        eventTime < $date_base AND eventTime > DATE_SUB($date_base, INTERVAL $opt_numdays DAY)
                    UNION ALL
                    SELECT
                        playerId, bonus, serverId, eventTime
                    FROM
                        hlstats_Events_PlayerPlayerActions
                    WHERE
                        eventTime < $date_base AND eventTime > DATE_SUB($date_base, INTERVAL $opt_numdays DAY)
                    ) actions
                INNER JOIN
                    hlstats_Servers    ON
                    hlstats_Servers.serverId=actions.serverId
                    AND hlstats_Servers.game=?
                INNER JOIN
                    hlstats_Players    ON
                    hlstats_Players.playerId = actions.playerId
                    AND hlstats_Players.hideranking=0
                    AND hlstats_Players.lastAddress <> ''
                GROUP BY
                    playerId
                ORDER BY
                    av_bonuspoints DESC
                LIMIT 1       
            ",$game);
            $resultGlobal = query_now("
                SELECT
                    actions.playerId,
                    SUM(actions.bonus) AS av_bonuspoints
                FROM
                    (SELECT
                        playerId, bonus, serverId, eventTime 
                    FROM
                        hlstats_Events_PlayerActions 
                    UNION ALL
                    SELECT
                        playerId, bonus, serverId, eventTime
                    FROM
                        hlstats_Events_PlayerPlayerActions
                    ) actions
                INNER JOIN
                    hlstats_Servers ON
                    hlstats_Servers.serverId=actions.serverId
                    AND hlstats_Servers.game=?
                INNER JOIN
                    hlstats_Players    ON
                    hlstats_Players.playerId = actions.playerId
                    AND hlstats_Players.hideranking=0
                    AND hlstats_Players.lastAddress <> ''
                GROUP BY
                    playerId
                ORDER BY
                    av_bonuspoints DESC
                LIMIT 1       
            ",$game);
        } elsif ($code eq "allsentrykills") {
            $resultDaily = query_now("
                SELECT
                    hlstats_Events_Frags.killerId,
                    COUNT(hlstats_Events_Frags.weapon) AS awardcount
                FROM
                    hlstats_Events_Frags
                INNER JOIN hlstats_Players ON
                    hlstats_Players.playerId = hlstats_Events_Frags.killerId
                    AND hlstats_Players.hideranking=0
                    AND hlstats_Players.lastAddress <> ''
                WHERE
                    hlstats_Events_Frags.eventTime < $date_base
                    AND hlstats_Events_Frags.eventTime > DATE_SUB($date_base, INTERVAL $opt_numdays DAY)
                    AND hlstats_Players.game=?
                    AND hlstats_Events_Frags.weapon LIKE 'obj_sentrygun%'
                GROUP BY
                    hlstats_Events_Frags.killerId
                ORDER BY
                    awardcount DESC,
                    hlstats_Players.skill DESC
                LIMIT 1
            ",$game);
            $resultGlobal = query_now("
                SELECT
                    hlstats_Events_Frags.killerId,
                    COUNT(hlstats_Events_Frags.weapon) AS awardcount
                FROM
                    hlstats_Events_Frags
                INNER JOIN hlstats_Players ON
                    hlstats_Players.playerId = hlstats_Events_Frags.killerId
                    AND hlstats_Players.hideranking=0
                    AND hlstats_Players.lastAddress <> ''
                WHERE
                    hlstats_Players.game=?
                    AND hlstats_Events_Frags.weapon LIKE 'obj_sentrygun%'
                GROUP BY
                    hlstats_Events_Frags.killerId
                ORDER BY
                    awardcount DESC,
                    hlstats_Players.skill DESC
                LIMIT 1
            ",$game);
        } elsif ($code eq "connectiontime") {
            $resultDaily = query_now("
                SELECT
                    hlstats_Players_History.playerId,
                    hlstats_Players_History.connection_time
                FROM
                    hlstats_Players_History,
                    hlstats_Players
                WHERE
                    hlstats_Players_History.game=?
                    AND hlstats_Players.playerId = hlstats_Players_History.playerId
                    AND hlstats_Players.hideranking=0
                    AND hlstats_Players.lastAddress <> ''
                    AND eventTime = DATE_SUB($date_base, INTERVAL $opt_numdays DAY)
                ORDER BY
                    connection_time DESC
                LIMIT 1
            ",$game);
            $resultGlobal = query_now("
                SELECT
                    playerId,
                    connection_time
                FROM
                    hlstats_Players
                WHERE
                    hlstats_Players.game=?
                    AND hlstats_Players.hideranking=0
                    AND hlstats_Players.lastAddress <> ''
                ORDER BY
                    connection_time DESC
                LIMIT 1
            ",$game);
        } elsif ($code eq "killstreak") {
            $resultDaily = query_now("
                SELECT
                    hlstats_Players_History.playerId,
                    hlstats_Players_History.kill_streak
                FROM
                    hlstats_Players_History,
                    hlstats_Players
                WHERE
                    hlstats_Players_History.game=?
                    AND hlstats_Players.playerId = hlstats_Players_History.playerId
                    AND hlstats_Players.hideranking=0
                    AND hlstats_Players.lastAddress <> ''
                    AND eventTime = DATE_SUB($date_base, INTERVAL $opt_numdays DAY)
                ORDER BY
                    kill_streak DESC
                LIMIT 1
            ",$game);
            $resultGlobal = query_now("
                SELECT
                    playerId,
                    kill_streak
                FROM
                    hlstats_Players
                WHERE
                    hlstats_Players.game=?
                    AND hlstats_Players.hideranking=0
                    AND hlstats_Players.lastAddress <> ''
                ORDER BY
                    kill_streak DESC
                LIMIT 1
            ",$game);
        } elsif ($code eq "deathstreak") {
        print "in deathstreak";
            $resultDaily = query_now("
                SELECT
                    hlstats_Players_History.playerId,
                    hlstats_Players_History.death_streak
                FROM
                    hlstats_Players_History,
                    hlstats_Players
                WHERE
                    hlstats_Players_History.game=?
                    AND hlstats_Players.playerId = hlstats_Players_History.playerId
                    AND hlstats_Players.hideranking=0
                    AND hlstats_Players.lastAddress <> ''
                    AND eventTime = DATE_SUB($date_base, INTERVAL $opt_numdays DAY)
                ORDER BY
                    death_streak DESC
                LIMIT 1
            ",$game);
            $resultGlobal = query_now("
                SELECT
                    playerId,
                    death_streak
                FROM
                    hlstats_Players
                WHERE
                    hlstats_Players.game=?
                    AND hlstats_Players.hideranking=0
                    AND hlstats_Players.lastAddress <> ''
                ORDER BY
                    death_streak DESC
                LIMIT 1
            ",$game);
        } else {
            $resultDaily = query_now("
                SELECT
                    $playerfield,
                    COUNT($matchfield) AS awardcount
                FROM
                    $table
                INNER JOIN hlstats_Players ON
                    hlstats_Players.playerId = $playerfield
                    AND hlstats_Players.hideranking=0
                    AND hlstats_Players.lastAddress <> ''
                $join
                WHERE
                    $table.eventTime < $date_base
                    AND $table.eventTime > DATE_SUB($date_base, INTERVAL $opt_numdays DAY)
                    AND hlstats_Players.game=?
                    AND $matchfield='$code'
                GROUP BY
                    $playerfield
                ORDER BY
                    awardcount DESC,
                    hlstats_Players.skill DESC
                LIMIT 1
            ",$game);
            $resultGlobal = query_now("
                SELECT
                    $playerfield,
                    COUNT($matchfield) AS awardcount
                FROM
                    $table
                INNER JOIN hlstats_Players ON
                    hlstats_Players.playerId = $playerfield
                    AND hlstats_Players.hideranking=0
                    AND hlstats_Players.lastAddress <> ''
                $join
                WHERE
                    hlstats_Players.game=?
                    AND $matchfield='$code'
                GROUP BY
                    $playerfield
                ORDER BY
                    awardcount DESC,
                    hlstats_Players.skill DESC
                LIMIT 1
            ",$game);
        }
        
        ($d_winner_id, $d_winner_count) = $resultDaily->fetchrow_array;
        ($g_winner_id, $g_winner_count) = $resultGlobal->fetchrow_array;
        
        if (!$d_winner_id || $d_winner_count < 1)
        {
            $d_winner_id = "NULL";
            $d_winner_count = "NULL";
        }
        if (!$g_winner_id || $g_winner_count < 1)
        {
            $g_winner_id = "NULL";
            $g_winner_count = "NULL";
        }
        
        if ($opt_verbose)
        {
            print "  - $d_winner_id ($d_winner_count)\n";
            print "  - $g_winner_id ($g_winner_count)\n";
        }
        
        exec_now("
            UPDATE
                hlstats_Awards
            SET
                d_winner_id=$d_winner_id,
                d_winner_count=$d_winner_count,
                g_winner_id=$g_winner_id,
                g_winner_count=$g_winner_count
            WHERE
                awardId=$awardId
        ");
    }


    exec_now("
        INSERT IGNORE INTO 
            hlstats_Players_Awards 
        SELECT 
            value, awardId, d_winner_id, d_winner_count, game 
        FROM 
            hlstats_Options INNER JOIN hlstats_Awards 
        WHERE 
            keyname='awards_d_date' AND NOT ISNULL(d_winner_id);
        ");

    print "done\n";
}

sub DoRibbons {
    print "++ Processing ribbons... ";

    my %ribbons_by_game;
    my $ribbon_rs = query_now("
        SELECT ribbonId, awardCode, awardCount, special, game
        FROM hlstats_Ribbons
        WHERE special IN (0,2)
    ");
    while ( my ($rid, $code, $count, $special, $game) = $ribbon_rs->fetchrow_array ) {
        push @{ $ribbons_by_game{$game} }, {
            ribbonId => $rid,
            code     => $code,
            count    => $count,
            special  => $special
        };
    }

    my $games_rs = query_now("SELECT code FROM hlstats_Games;");
    while ( my ($game) = $games_rs->fetchrow_array ) {

        exec_now("DELETE FROM hlstats_Players_Ribbons WHERE game=?",$game);

        next unless exists $ribbons_by_game{$game};

        for my $ribbon (@{ $ribbons_by_game{$game} }) {
            my $rid    = $ribbon->{ribbonId};
            my $count  = $ribbon->{count};

            my $players_rs;

            if ( $ribbon->{special} == 2 ) {

                $players_rs = query_now("
                    SELECT playerId
                    FROM hlstats_Players
                    WHERE game=?
                      AND hideranking=0
                      AND lastAddress <> ''
                      AND (connection_time/3600) >= $count
                ",$game);
            }
            else {
                # Award ribbons
                $players_rs = query_now("
                    SELECT pa.playerId
                    FROM hlstats_Players_Awards pa
                    JOIN hlstats_Awards a
                      ON a.awardId=pa.awardId
                     AND a.game=pa.game
                    JOIN hlstats_Players p
                      ON p.playerId=pa.playerId
                     AND p.hideranking=0
                     AND p.lastAddress <> ''
                    WHERE pa.game=?
                      AND a.code=?
                      AND a.awardType<>'V'
                    GROUP BY pa.playerId
                    HAVING COUNT(pa.playerId) >= $count
                ",$game,$ribbon->{code});
            }

            my @values;
            while ( my ($pid) = $players_rs->fetchrow_array ) {
                push @values, "($pid,$rid,'$game')";
            }

            if (@values) {
                exec_now("
                    INSERT INTO hlstats_Players_Ribbons (playerId, ribbonId, game)
                    VALUES ".join(',', @values)."
                    ON DUPLICATE KEY UPDATE
                    game = ? ", $game
                );
            }
        }
    }

    print "done\n";
}

sub DoGeoIP
{
    print "++ Looking up missing player locations... ";
    
    my $useGeoIPBinary = 0;
    my $gi = undef;
    my $dogeo = 0;
    my $cnt = 0;
    
    # Sanity checks to see if we can do geolocation updates
    $result = query_now("
        SELECT
            value
        FROM
            hlstats_Options
        WHERE
            keyname='UseGeoIPBinary'
            AND value > '0'
        LIMIT 1
    ");
    
    if ($result->rows > 0)
    {
        $useGeoIPBinary = 1;
        $geoipfile = "$opt_libdir/GeoLiteCity/GeoLite2-City.mmdb";
    }
    else
    {
        $useGeoIPBinary = 0;
    }
    
    if ($useGeoIPBinary == 0)
    {
        my $result = query_now("SELECT locId FROM geoLiteCity_Blocks LIMIT 1;");
        if ($result->rows > 0)
        {
            $dogeo = 1;
        }
        else
        {
            printEvent("ERROR", "GeoIP method set to database but geoLiteCity tables are empty.", 1);
        }
    }
    elsif ($useGeoIPBinary == 1 && -r $geoipfile)
    {
        if ($opt_cpanelhack) {
            my $home_dir = $ENV{ HOME };
            my $base_module_dir = (-d "$home_dir/perl" ? "$home_dir/perl" : ( getpwuid($>) )[7] . '/perl/');
            unshift @INC, map { $base_module_dir . $_ } @INC;
        }

        eval "use GeoIP2::Database::Reader";
        
        $gi = GeoIP2::Database::Reader->new(
            file    => $geoipfile,
            locales => [ 'en' ]
        );

        if ($gi) 
        {
            $dogeo = 1;
        }
        else
        {
            printEvent("ERROR", "GeoIP method set to binary file lookup but $geoipfile errored while opening.", 1);
            $gi = undef;
        }
    }
    else
    {
        printEvent("ERROR", "GeoIP method set to binary file lookup but $geoipfile NOT FOUND", 1);
    }

        
    if ($dogeo) {
        sub ip2number {
            my ($ipstr) = @_;
            my @ip = split(/\./, $ipstr);
            my $number = ($ip[0]*16777216) + ($ip[1]*65536) + ($ip[2]*256) + $ip[3];

            return $number;
        }

        sub trim {
            my $string = shift;
            $string =~ s/^\s+|\s+$//g;
            return $string;
        }
        $result = query_now("SELECT playerId, lastAddress, lastName FROM hlstats_Players WHERE flag='' AND lastAddress<>'';");
                
        while (my($pid, $address, $name) = $result->fetchrow_array) {
            $address = trim($address);
            next if ($address !~ /^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$/);
            if ($opt_verbose)
            {
                print "Attempting to find location for: ".$name." (".$address.")\n";
            }
            my $number = ip2number($address);
            my $update = 0;
            my $foundflag = "";
            my $foundcountry = "";
            my $foundcity = "";
            my $foundstate = "";
            my $foundlat = 0;
            my $foundlng = 0;
            if ($useGeoIPBinary > 0) {
                if ($opt_verbose)
                {
                    print "2 ".$pid." ".$address."\n";
                }

                my $country_code = undef;
                my $country_name = undef;
                my $region = undef;
                my $city = undef;
                my $lat = undef;
                my $lng = undef;

                my $geoCity = undef;
        
                eval { $geoCity = $gi->city( ip => $address ); };
                $geoCity = undef if $@;

                if ($geoCity) {

                    my $geoCityRec = $geoCity->city();
                    my $geoCountryRec = $geoCity->country();
                    my $geoLocationRec = $geoCity->location();
                    my $geoPostalRec = $geoCity->postal();
                    my $geoMostSpecificSubdivision = $geoCity->most_specific_subdivision();

                    $country_code = $geoCountryRec->iso_code();
                    $country_name = $geoCountryRec->name();
                    $region = $geoMostSpecificSubdivision->name();
                    $city = $geoCityRec->name();
                    $postal_code = $geoPostalRec->code();
                    $lat = $geoLocationRec->latitude();
                    $lng = $geoLocationRec->longitude();
                }    

                if ($lng) {

                    $foundflag = $country_code;
                    $foundcountry = $country_name;
                    $foundcity = $city;
                    $foundstate = $region;
                    $foundlat = $lat;
                    $foundlng = $lng;
                    $update++;
                }
            }
            else
            {
                $result2 = query_now("SELECT locId FROM geoLiteCity_Blocks WHERE startIpNum<=? AND endIpNum>=? LIMIT 1;",$number,$number);
                if ($result2->rows > 0) {
                    my ($locid) = $result2->fetchrow_array;
                    $data = query_now("SELECT city, region AS state, name AS country, country AS flag, latitude AS lat, longitude AS lng FROM geoLiteCity_Location a  inner join hlstats_Countries b ON a.country=b.flag WHERE locId=? LIMIT 1;",$locid);
                    if ($data->rows > 0) {
                        ($foundcity, $foundstate, $foundcountry, $foundflag, $foundlat, $foundlng) = $data->fetchrow_array;
                        $update++;
                    }
                }
            }
            if ($update > 0)
            {
                exec_now("
                    UPDATE
                        hlstats_Players
                    SET
                        flag=?,
                        country=?,
                        lat='".(($foundlat ne "")?$foundlat:undef)."',
                        lng='".(($foundlng ne "")?$foundlng:undef)."',
                        city=?,
                        state=?
                    WHERE
                        playerId=?",$foundflag,$foundcountry,$foundcity,$foundstate,$pid);
                $cnt++;
            }
        }
    }
    printf ("done%s\n", (($cnt>0)?" (updated $cnt players)":""));
}

sub DoClans
{
    print "++ Reparsing player names to recalculate clan affiliations... ";
    
    my @clanpatterns = ();
    my $result = query_now("
        SELECT
            pattern,
            position,
            LENGTH(pattern) AS pattern_length
        FROM
            hlstats_ClanTags
        ORDER BY
            pattern_length DESC,
            id
    ");
    
    while ( my($pattern, $position) = $result->fetchrow_array) {
        my $regpattern = quotemeta($pattern);
        $regpattern =~ s/([A-Za-z0-9]+[A-Za-z0-9_-]*)/\($1\)/; # to find clan name from tag
        $regpattern =~ s/A/./g;
        $regpattern =~ s/X/.?/g;
        if ($position eq "START") {
            push(@clanpatterns, "^($regpattern).+");
        } elsif ($position eq "END") {
            push(@clanpatterns, ".+($regpattern)\$");
        } elsif ($position eq "EITHER") {
            push(@clanpatterns, "^($regpattern).+");
            push(@clanpatterns, ".+($regpattern)\$");
        }
    }
    
    $result = query_now("
        SELECT
            playerId, lastName, game
        FROM
            hlstats_Players
    ");
    
    while ( my($playerId, $name, $game) = $result->fetchrow_array)
    {
        my $clanTag = "";
        my $clanId = 0;
        foreach (@clanpatterns)
        {
            $clanTag = "";
            if ($name =~ /$_/i)
            {
                $clanTag  = $1;
                $clanName = $2;
                last;
            }            
        }
        if (!$clanTag)
        {
            exec_cache("playerclan_clear", "UPDATE hlstats_Players SET clan=0 WHERE playerId=?", $playerId);
            next;
        }
        
        my $query = "
            SELECT
                clanId
            FROM
                hlstats_Clans
            WHERE
                tag=? AND
                game=?
        ";
        my $clanresult = exec_cache("clan_select", $query, $clanTag, $game);

        if ($clanresult->rows) {
            my ($id) = $clanresult->fetchrow_array;
            $clanresult->finish;
            $clanId = $id;
        } else {
            # The clan doesn't exist yet, so we create it.
            $query = "
                REPLACE INTO
                    hlstats_Clans
                    (
                        tag,
                        name,
                        game
                    )
                VALUES
                (
                    ?,?,?
                )
            ";
            exec_cache("clan_insertupdate", $query, $clanTag, $clanName, $game);
            
            $clanId = $dbh->last_insert_id(undef, undef, undef, undef);
        }
        exec_cache("playerclan_update", "UPDATE hlstats_Players SET clan=? WHERE playerId=?", $clanId, $playerId);
    }
    
    print "done\n";
}

sub DoPruning
{
    my $result = query_now("SELECT `value` FROM hlstats_Options WHERE keyname='DeleteDays'");
    ($g_deletedays) = $result->fetchrow_array;

    print "++ Cleaning up database using per-player sliding window ($g_deletedays days)\n";

    foreach my $eventTable (keys %g_eventTables)
    {
        print "   - Pruning hlstats_Events_$eventTable ... ";

        # -----------------------------
        # Per-player tables
        # -----------------------------
        if ($player_tables{$eventTable}) {
            exec_now("
                DELETE e
                FROM hlstats_Events_$eventTable e
                JOIN (
                    SELECT playerId, MAX(eventTime) AS last_event
                    FROM hlstats_Events_$eventTable
                    GROUP BY playerId
                ) t ON e.playerId = t.playerId
                WHERE e.eventTime < (t.last_event - INTERVAL $g_deletedays DAY)
            ");
            print "done\n";
            next;
        }

        # -----------------------------
        # Frag-like tables (killer/victim)
        # -----------------------------
        if ($frag_tables{$eventTable}) {
            exec_now("
                DELETE e
                FROM hlstats_Events_$eventTable e
                JOIN (
                    SELECT killerId AS pid, MAX(eventTime) AS last_event
                    FROM hlstats_Events_$eventTable
                    GROUP BY killerId
                    UNION
                    SELECT victimId AS pid, MAX(eventTime)
                    FROM hlstats_Events_$eventTable
                    GROUP BY victimId
                ) t ON (e.killerId = t.pid OR e.victimId = t.pid)
                WHERE e.eventTime < (t.last_event - INTERVAL $g_deletedays DAY)
            ");
            print "done\n";
            next;
        }

        # -----------------------------
        # Global prune fallback
        # -----------------------------
        if ($global_tables{$eventTable}) {
            exec_now("
                DELETE FROM hlstats_Events_$eventTable
                WHERE eventTime < DATE_SUB(UTC_TIMESTAMP(), INTERVAL 1 YEAR)
            ");
            print "done\n";
            next;
        }

        # -----------------------------
        # Unknown/new table
        # -----------------------------
        exec_now("
            DELETE FROM hlstats_Events_$eventTable
            WHERE eventTime < DATE_SUB(UTC_TIMESTAMP(), INTERVAL 1 YEAR)
        ");
        print "done (fallback)\n";
    }

    # -----------------------------------------
    # Player history
    # -----------------------------------------
    print "++ Cleaning up player history using per-player sliding window ($g_deletedays days)... ";
    exec_now("
        DELETE e
        FROM hlstats_Players_History e
        JOIN (
            SELECT playerId, MAX(eventTime) AS last_event
            FROM hlstats_Players_History
            GROUP BY playerId
        ) t ON e.playerId = t.playerId
        WHERE e.eventTime < (t.last_event - INTERVAL $g_deletedays DAY)
    ");
    print "done\n";

    # -----------------------------------------
    # Other HLstats tables (unchanged)
    # -----------------------------------------
    print "++ Cleaning up stale trend samples... ";
    exec_now("
        DELETE FROM hlstats_Trend
        WHERE timestamp < (UNIX_TIMESTAMP() - 172800)
    ");
    print "done\n";

    print "++ Cleaning up server load history older than one year... ";
    exec_now("
        DELETE FROM hlstats_server_load
        WHERE timestamp < (UNIX_TIMESTAMP(UTC_TIMESTAMP() - INTERVAL 1 YEAR))
    ");
    print "done\n";
}

sub DoOptimize
{    
    print "++ Optimizing all tables... ";

    $result = query_now("SHOW TABLES");
    while ( ($row) = $result->fetchrow_array ) {
        push(@g_allTables, $row);
    }
    foreach $table (@g_allTables) {
        exec-now("
            OPTIMIZE TABLE $table
        ");
    }
    print "done\n";
}
