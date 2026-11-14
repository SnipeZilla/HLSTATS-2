#!/usr/bin/perl
# HLstatsX Community Edition - Real-time player and clan rankings and statistics
# Copyleft (L) 2008-20XX Nicholas Hastings (nshastings@gmail.com)
# http://www.hlxcommunity.com
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
# 
# For support and installation notes visit http://www.hlxcommunity.com

####
# Script to mark banned users in HLstatsX Community Edition from a Sourcebans, AMXBans, Beetlesmod, or ES GlobalBan database (or multiple at once!)
# Last Revised: 2009-07-22 13:35 GMT
# BeetlesMod and GlobalBan support added by Bo Tribun (R3M)

#######################################################################################
#  Fill in at least one of the Bans databases below.
#  The HLstatsZ database, and the driver for all of them (DBDriver), come from hlstats.conf.
#  A port other than 3306 needs the server's IP as host (127.0.0.1), not localhost.
#######################################################################################
# Sourcebans DB Info
$sb_dbhost = "localhost";
$sb_dbport = 3306;
$sb_dbuser = "";
$sb_dbpass = "";
$sb_dbname = "";
$sb_prefix = "sb_"; # be sure to include the underscore (_)

# AMXBans DB Info
$amxb_dbhost = "localhost";
$amxb_dbport = 3306;
$amxb_dbuser = "";
$amxb_dbpass = "";
$amxb_dbname = "";

# BeetlesMod DB Info
$bm_dbhost = "localhost";
$bm_dbport = 3306;
$bm_dbuser = "";
$bm_dbpass = "";
$bm_dbname = "";

# ES GlobalBan DB Info
$gb_dbhost = "localhost";
$gb_dbport = 3306;
$gb_dbuser = "";
$gb_dbpass = "";
$gb_dbname = "";


##
##
################################################################################
## No need to edit below this line
##

use DBI;
use FindBin;
use File::Basename;
use File::Spec;

# -n, --nodebug: nothing is printed (the daemon passes it when it runs with -n itself). Errors still are, on STDERR.
open(STDOUT, '>', File::Spec->devnull()) if grep { $_ eq '-n' || $_ eq '--nodebug' } @ARGV;

# The HLstatsZ database: from hlstats.conf, next to this file (or in the folder above, or in the current folder)
($conffile) = grep { -r $_ } ("$FindBin::Bin/hlstats.conf", "$FindBin::Bin/../hlstats.conf", "./hlstats.conf");
die("hlstats.conf not found. Exiting\n") unless $conffile;
require(dirname($conffile) . "/ConfigReaderSimple.pm");
$conf = ConfigReaderSimple->new($conffile);
$conf->parse();
$hlx_dbhost = $conf->get("DBHost") // "";
$hlx_dbuser = $conf->get("DBUsername") // "";
$hlx_dbpass = $conf->get("DBPassword") // "";
$hlx_dbname = $conf->get("DBName") // "";
# The driver, as for the daemon: DBDriver "mysql" (DBD::mysql) or "mariadb" (DBD::MariaDB)
$dbi_driver = (($conf->get("DBDriver") // "") eq "mariadb") ? "MariaDB" : "mysql";

$havesbinfo =	($sb_dbhost eq "" || $sb_dbuser eq "" || $sb_dbpass eq "" || $sb_dbname eq "")?0:1;
$haveamxbinfo =	($amxb_dbhost eq "" || $amxb_dbuser eq "" || $amxb_dbpass eq "" || $amxb_dbname eq "")?0:1;
$havebminfo =	($bm_dbhost eq "" || $bm_dbuser eq "" || $bm_dbpass eq "" || $bm_dbname eq "")?0:1;
$havegbinfo =	($gb_dbhost eq "" || $gb_dbuser eq "" || $gb_dbpass eq "" || $gb_dbname eq "")?0:1;
$havehlxinfo =	($hlx_dbhost eq "" || $hlx_dbuser eq "" || $hlx_dbname eq "")?0:1;

die("DBHost, DBUsername and DBName must be set in $conffile. Exiting\n") if ($havehlxinfo == 0);
die("DB login info incomplete: fill in at least one of the Bans databases. Exiting\n") if ($havesbinfo == 0 && $haveamxbinfo == 0 && $havebminfo == 0 && $havegbinfo == 0);

@steamids = ();

if ($havesbinfo) {
	print "Connecting to Sourcebans database...\n";
	my $sb_dbconn = DBI->connect(
			dsn($sb_dbname, $sb_dbhost, $sb_dbport),
			$sb_dbuser, $sb_dbpass) or die ("\nCan't connect to Sourcebans database '$sb_dbname' on '$sb_dbhost'\n" .
			"Server error: $DBI::errstr\n");

	print "Successfully connected to Sourcebans database.  Retrieving banned Steam IDs now...\n";

	my $result = &doQuery($sb_dbconn, "SELECT `authid` FROM ".$sb_prefix."bans WHERE `length` = 0 AND `RemovedBy` IS NULL");
	while ( my($steamid) = $result->fetchrow_array) {
		push(@steamids, $steamid);
	}
	my $rows = $result->rows;
	if ($rows) {
		print $rows." banned users retrieved from Sourcebans.\n";
	}
	$sb_dbconn->disconnect;
}

if ($haveamxbinfo) {
	print "Connecting to AMXBans database...\n";
	my $amxb_dbconn = DBI->connect(
			dsn($amxb_dbname, $amxb_dbhost, $amxb_dbport),
			$amxb_dbuser, $amxb_dbpass) or die ("\nCan't connect to AMXBans database '$amxb_dbname' on '$amxb_dbhost'\n" .
			"Server error: $DBI::errstr\n");

	print "Successfully connected to AMXBans database.  Retrieving banned Steam IDs now...\n";

	my $result = &doQuery($amxb_dbconn, "SELECT `player_id` FROM amx_bans WHERE `ban_length` = 0");
	while ( my($steamid) = $result->fetchrow_array) {
		push(@steamids, $steamid);
	}
	my $rows = $result->rows;
	if ($rows) {
		print $rows." banned users retrieved from AMXBans.\n";
	}
	$amxb_dbconn->disconnect;
}

if ($havebminfo) {
	print "Connecting to BeetlesMod database...\n";
	my $bm_dbconn = DBI->connect(
			dsn($bm_dbname, $bm_dbhost, $bm_dbport),
			$bm_dbuser, $bm_dbpass) or die ("\nCan't connect to BeetlesMod database '$bm_dbname' on '$bm_dbhost'\n" .
			"Server error: $DBI::errstr\n");

	print "Successfully connected to BeetlesMod database.  Retrieving banned Steam IDs now...\n";

	my $result = &doQuery($bm_dbconn, "SELECT `steamid` FROM `bm_bans` WHERE `Until` IS NULL");
	while ( my($steamid) = $result->fetchrow_array) {
		push(@steamids, $steamid);
	}
	my $rows = $result->rows;
	if ($rows) {
		print $rows." banned users retrieved from BeetlesMod.\n";
	}
	$bm_dbconn->disconnect;
}

if ($havegbinfo) {
	print "Connecting to ES GlobalBan database...\n";
	my $gb_dbconn = DBI->connect(
			dsn($gb_dbname, $gb_dbhost, $gb_dbport),
			$gb_dbuser, $gb_dbpass) or die ("\nCan't connect to ES GlobalBan database '$gb_dbname' on '$gb_dbhost'\n" .
			"Server error: $DBI::errstr\n");

	print "Successfully connected to ES GlobalBan database.  Retrieving banned Steam IDs now...\n";

	my $result = &doQuery($gb_dbconn, "SELECT `steam_id` FROM `gban_ban` WHERE `active` = 1 AND `pending` = 0 AND `length` = 0");
	while ( my($steamid) = $result->fetchrow_array) {
		push(@steamids, $steamid);
	}
	my $rows = $result->rows;
	if ($rows) {
		print $rows." banned users retrieved from ES GlobalBan.\n";
	}
	$gb_dbconn->disconnect;
}

if (@steamids) {
	$steamidstring = "'";
	foreach $steamid (@steamids)
	{
		$steamid =~ s/^STEAM_[0-9]+?\://i; 
		$steamidstring .= $steamid."','";
	}
	$steamidstring =~ s/\,\'$//;

	print "Connecting to HLstatsZ database '$hlx_dbname' on '$hlx_dbhost' with DBD::$dbi_driver...\n";
	$hlx_dbconn = DBI->connect(
			dsn($hlx_dbname, $hlx_dbhost),
			$hlx_dbuser, $hlx_dbpass) or die ("\nCan't connect to HLstatsZ database '$hlx_dbname' on '$hlx_dbhost'\n" .
			"Server error: $DBI::errstr\n");
	print "Updating HLstatsZ banned players...\n";
	$result = &doQuery($hlx_dbconn, "UPDATE `hlstats_Players` SET `hideranking` = 2 WHERE `playerId` IN (SELECT `playerId` FROM hlstats_PlayerUniqueIds WHERE `uniqueId` IN ($steamidstring)) AND `hideranking` < 2");
	print $result->rows." users newly marked as banned.\n";
	$hlx_dbconn->disconnect;
} else {
	print "No banned users found in database(s). Exiting\n";
}

sub doQuery
{
	my ($dbconn, $query, $callref) = @_;
	my $result = $dbconn->prepare($query) or die("Unable to prepare query:\n$query\n$DBI::errstr\n$callref");
	$result->execute or die("Unable to execute query:\n$query\n$DBI::errstr\n$callref");
	
	return $result;
}

# The connection string for a database, with the driver from hlstats.conf. The port is only added when it isn't
# the default 3306: DBD::MariaDB refuses a port with "localhost" (a local socket).
sub dsn
{
	my ($dbname, $dbhost, $dbport) = @_;
	my $dsn = "DBI:$dbi_driver:database=$dbname;host=$dbhost";
	$dsn .= ";port=$dbport" if $dbport && $dbport != 3306;
	return $dsn;
}
