# Setting up HLstatsZ

The settings worth knowing in the website's admin panel, once HLstatsZ is installed ([INSTALL.md](INSTALL.md)).
Everything not listed here can stay as it is.

To open the admin panel: **Admin** at the bottom of the website. With Steam admins set in the website's `config.php`
(`STEAM_API` and `STEAM_ADMIN`), sign in with Steam instead.

- [HLstats Settings](#hlstats-settings)
  - [Bans: SourceBans and AMXBans](#bans-sourcebans-and-amxbans)
- [Games](#games)
- [Add a server](#add-a-server)
- [Configure a server](#configure-a-server)
- [After a change: reload the daemon](#after-a-change-reload-the-daemon)
- [Check the load: the profiler](#check-the-load-the-profiler)

---

## HLstats Settings

**General Settings > HLstats Settings.** A setting marked `*` is read by the daemon:
[reload it](#after-a-change-reload-the-daemon) after a change.

| Setting | What it does |
|---|---|
| **Show Chat nav-link** | The Chat page in the menu, and the chat of the map being played under each server's players. |
| **Map Download URL** | Your FastDL, for a download link on the map pages. `%GAME%` becomes the game code: `https://yoursite.com/fastdl/%GAME%/`. Empty: no link. |
| **Languages Selection** | The languages offered to visitors, e.g. `us;fr;es`. Empty: English only. |
| **Collapse server for each game** | A game with several servers lists them closed: a click on a server opens its players and chat. |
| **Sets the player-tracking mode** `*` | **Steam ID** on the Internet. Player Name and IP Address are for LAN parties and Internet cafés. |
| **Allow only servers set up in admin panel** `*` | **Yes** (default): HLstatsZ takes the logs only of the servers [added in the admin panel](#add-a-server). **No**: a server that sends logs adds itself, without its plugin set: [configure it](#configure-a-server) after. |
| **Allow HLstats to send Rcon commands** `*` | **Yes**: HLstatsZ talks to the game servers: messages in game, server load, kicks. Each server needs its RCON password too. |
| **HLstats automatically removes older events** `*` | Days of events kept. 365 to 730; **0** keeps everything, and the database keeps growing. |
| **Make player bans available on all participating servers** `*` | A player banned on one server is banned on all of them. |
| **Log player chat to database** `*` | Saves the chat: the Chat page and the chat under the players need it. |
| **Broadcast chat messages** `*` | Repeats the chat of each server on the others: to everyone, to admins only, or not at all. |
| **Number of kills a player must have before receiving regular points** `*` | Until then (50 kills), a kill wins or loses only the minimum points: a new player's rank doesn't jump around. |
| **Key to use when sending remote commands to Daemon** `*` | Only when the daemon runs on another machine than the website: it lets **Daemon Control** reach it. |

### Bans: SourceBans and AMXBans

The website shows the bans of SourceBans (Source and CS2 servers) and AMXBans (GoldSrc servers), read from their
own databases.

1. **The databases**, in the website's `config.php`: `DB_SBNAME` for SourceBans and `DB_AMXNAME` for AMXBans, with
   their table prefix (`DB_SBPREFIX` is `sb`, `DB_AMXPREFIX` is `amx`). They must be on the database server of
   HLstatsZ, and its `DB_USER` must have all rights on them. HLstatsZ's own database will do.
2. **Bans > Bans Settings** checks them. A database or tables that don't exist yet: create them there.
   For SourceBans, enter your Steam ID as its owner: you manage the bans on the website after **Sign in with Steam**
   (`STEAM_API` in `config.php`).
3. **The plugin on the game servers** uses the same database and prefix:
   - SourceBans++: the `sourcebans` entry of `databases.cfg`, and `DatabasePrefix` in `sourcebans.cfg`.
   - HLstatsZ Classics (CS2): `SourceBans` in `HLstatsZ.json`.
   - AMXBans: `sql.cfg`, and `amx_sql_prefix` in `amxbans.cfg`.
4. Still in **Bans Settings**: **SOURCEBANS in the menu leads to** the bans pages of HLstatsZ, or to your own
   SourceBans site. **Report a player** and **Appeal a ban**: a Discord channel or a forum thread. Empty: no link.

Banned players out of the rankings: the daemon runs `importbans.pl`, with `PathBans` in `hlstats.conf`
([INSTALL.md](INSTALL.md)) and the bans database at the top of `importbans.pl`.

---

## Games

**General Settings > Games.** Tick **Hide Game** on every game you don't run, and untick the ones you run.
A hidden game is off the website, and off **Game Settings** in the admin menu, where the servers are added.

- **Display Name**: the game's name on the website.
- A game you no longer run: hide it, don't delete it. Deleting removes its servers, players and stats.
- **One game, two rankings** (a sniper-only server next to a normal one): **Tools > Duplicate Game Settings** copies a
  game under a new code, with its own ranking. Add the server under the copy.

---

## Add a server

**Game Settings > (the game) > Add Server**, then **Apply**.

- **Server IP Address** and **Server Port**: where the logs come from: the game server's IP and its game port (27015…).
- **Rcon Password**: the server's `rcon_password`. HLstatsZ needs it for the messages in game and the server load.
- **Public Address** (optional): the address players connect to, shown on the website: an IP or a host name, with or
  without the port (`cs.example.com:27015`). It also places the server on the map. Fill it in when the server is
  behind NAT, Pterodactyl or LinuxGSM. Empty: the IP and port above.
- **Admin Mod**: the plugin that shows HLstatsZ in game. **Sourcemod** for Source games and for CS2 (HLstatsZ Classics),
  **AMX Mod X** for GoldSrc (CS 1.6, DoD, TFC…). It sets the commands HLstatsZ sends to the server.

The server's settings open next ([Configure a server](#configure-a-server)). Then
[reload the daemon](#after-a-change-reload-the-daemon): it takes the server's logs from then on.

> [!TIP]
> Not sure of the IP and port? Set `DebugLevel 1` in `hlstats.conf` and restart the daemon: a server not added yet
> shows up as `NOT ALLOWED SERVER`, after the address its logs come from
> ([how to see what the daemon says](INSTALL.md#something-doesnt-work)).

---

## Configure a server

**Game Settings > (the game) > Edit Servers > Configure.** The defaults suit most servers. What the less obvious
settings do:

| Setting | What it does |
|---|---|
| **Mod** | The plugin that shows HLstatsZ in game: `SOURCEMOD` (Source games, and CS2 with HLstatsZ Classics) or `AMXX` (GoldSrc). **Add Server** sets it, with its commands (see below). |
| **BroadCastEvents** | `1`: after a kill, the killer and the victim read their points in game: *Killer (1534) got 12 points for killing Victim (1410)*. |
| **BroadCastPlayerActions** | With BroadCastEvents: the points of the actions too (bomb planted, flag captured…), to the players who get them. |
| **ConnectAnnounce** | `1`: when a player joins, the others read his rank and country: *Player (Pos 12 with 1534 points) has connected from Canada*. |
| **DefaultDisplayEvents** | Whether a new player sees the messages of BroadCastEvents (`1`) or not (`0`). Each player can switch them with `hlx_display 0` or `hlx_display 1` in the chat. |
| **ShowStats** | `1`: now and then (every 2,500 log lines), everyone reads *HLstatsZ - Tracking N players with K kills and H headshots*. |
| **TrackServerLoad** | `1`: every 5 minutes, saves the players, FPS and uptime: the server load graphs on the website. |
| **MinPlayers** | With fewer players than this on the server, kills and actions give no points: nobody farms points on an empty server. |
| **IgnoreBots** | `1`: bots are left out, and kills on bots give no points. `0`: bots are ranked like players. `-1`: bots are ranked like players, but hidden from the stats and the website (recommended with Left 4 Dead). |
| **SkillMode** | How many points a victim loses: `0` as many as the killer wins, `1` ¾, `2` half, `3` ¼, `4` none. |
| **BonusRoundIgnore** | `1`: kills after a round is won don't count (TF2 humiliation). **BonusRoundTime**: its length in seconds (`mp_bonusroundtime`), in case the start of the next round isn't seen. |
| **UpdateHostname** | `1`: the website takes the server's name from its `hostname`. `0`: it keeps the name set in **Edit Servers**. |
| **HLStatsURL** | Your website's address, for the plugin's links in game. **Add Server** fills it in. A server that added itself has `http://yoursite.com/hlstats`: put yours. |
| **DisplayResultsInBrowser** | `1`: `rank`, `statsme` and the other commands open small pages in the in-game browser. Not in CS2. |
| **PlayerEvents** | `1`: HLstatsZ answers the players' commands in the chat (`rank`, `session`, `top10`, `statsme`…). |
| **EnablePublicCommands** | `1`: with `place`, a player shows his rank to everyone. |
| **MinimumPlayersRank** | Only the top N players can play, the others are kicked: a "Top 500" server. `0`: everyone. |
| **AutoTeamBalance** | `1`: HLstatsZ evens out the teams by skill. **SwitchAdmins** `1`: it can move admins too. |
| **AutoBanRetry** | `1`: a player who leaves is banned for 5 minutes, so nobody reconnects to land in a better team. |
| **Admins** | The Steam IDs of the server's admins, separated by commas (`STEAM_0:1:123,STEAM_0:0:456`). MinimumPlayersRank and AutoBanRetry leave them alone, and the team balancer moves them only with SwitchAdmins. |
| **GameEngine**, **GameType** | Set for the game: leave them. |

Under the list: **Set all options like existing server configuration** copies the settings of another server, handy
for a second server of the same game.

<details>
<summary>A server that added itself, or the wrong plugin: the commands of each Mod</summary>

Set **Mod** and these six settings, then [reload the daemon](#after-a-change-reload-the-daemon):

| Setting | `SOURCEMOD` | `AMXX` |
|---|---|---|
| BroadCastEventsCommand | `hlx_sm_psay` | `hlx_amx_psay` |
| BroadCastEventsCommandAnnounce | `hlx_sm_csay` | `hlx_amx_csay` |
| PlayerEventsCommand | `hlx_sm_psay` | `hlx_amx_psay` |
| PlayerEventsCommandOSD | `hlx_sm_msay` | `hlx_amx_msay` |
| PlayerEventsCommandHint | `hlx_sm_hint` | `hlx_amx_hint` |
| PlayerEventsAdminCommand | `sm_chat` | `amx_chat` |

</details>

---

## After a change: reload the daemon

The daemon reads the servers and their settings when it starts. After adding a server, or changing a server's
settings or one marked `*`: **Tools > Daemon Control > Reload Configuration**, or restart the daemon
(`hlstatsz.ps1` or `hlstatsz.sh`, then `1`).

Daemon Control reaches a daemon on the same machine as the website. On another machine, it needs the
**Key to use when sending remote commands to Daemon** (HLstats Settings), and the daemon restarted once.

---

## Check the load: the profiler

HLstatsZ is light, and it can show it. The profiler makes the daemon time its own work, and a page turns that
into a plain answer: how busy it is, and how many game servers it has room for on your machine.
Use it out of curiosity, before adding servers, before choosing a smaller (or bigger) VPS, or if you a developper.

### Run it

1. In `hlstats.conf`, set `Profile 1`, and restart the daemon (`hlstatsz.ps1` or `hlstatsz.sh`, then `1`).
2. Let it run while your game servers are busy. An evening is good, a whole day is better.
3. Open `profile/hlstatsz_profile_viewer.html` in a browser, click **Open log…** and pick
   `hlstatsz_profile.log`, in the same `profile` folder, or drop it on the page.
   With a `hlstatsz_profile.old.log` next to it, open both together to see further back.
4. When you are done, set `Profile 0` and restart the daemon.

A daemon on Linux: copy the log to your PC with WinSCP, and open the viewer from the HLstatsZ ZIP.

The profiler is safe to leave on for a while: the log is limited to two files of 5 MB, and with nothing to do the
daemon writes one short line a minute. The page reads the log in your browser, works without internet, and
sends nothing anywhere.

### Read it

**The verdict**, at the top, is the answer in one line:

| Verdict | What it means |
|---|---|
| **Good**: handles the load well | Nothing to do. |
| **Watch**: keeps up, but… | It keeps up. The lines under the verdict say what to look at before adding servers. |
| **Overloaded**: runs out of time at peak | Log lines wait at the busiest moments. The lines under the verdict say what takes the time. |
| **No verdict** | Nothing happened in this period: leave the profiler on while players are on the servers. |

With it: the peak in log lines a second, how busy the daemon was then (in % of its time), and the **ceiling**:
the lines a second this machine can take.

**Capacity** turns the ceiling into game servers: how many it can handle **with ease** (70% busy), and its
**limit** (100% busy). It counts as if every server were full and busy at the same moment, which never happens:
more fit in practice. Your servers aren't like the ones it assumes? Change **Lines a second from one busy server**.

**Whole log**, **Busiest hour** and **Last hour** choose the period. Drag across a chart to zoom on a moment.

**Timeline** and **Time budget** show where the time goes: handling the log lines, the database, RCON, lookups.

### When it says something

Most of the time the cause is around HLstatsZ, not in it, and the fix is one setting:

| It says | What to do |
|---|---|
| **Its own output is expensive** | `DebugLevel 0` in `hlstats.conf`. Debug output is for setting up, not for every day. |
| **Slow query** | The database is short of memory: the [database settings](INSTALL.md#database-settings-recommended) of INSTALL.md. An old database full of events: lower **HLstats automatically removes older events** ([HLstats Settings](#hlstats-settings)). |
| **Short of processor time** | Another program takes the CPU, the VPS is thin, or the machine is swapping. HLstatsZ on a game server's machine? Move it next to the database. |
| **Pauses**, with RCON as the cause | A game server is slow to answer, or its RCON password is wrong: check the server in **Edit Servers**. |
| **Lookups are expensive** | GeoIP, DNS or server queries are slow: check the machine's DNS. |
| **Started … after a run that did not stop normally** | The daemon was killed or crashed: [see what it says](INSTALL.md#something-doesnt-work). |

### When you done geeking
- Stop it: Profile 0 to avoid unnecessary resource usage, and **restart** the daemon.
- Share the project and give it a star.


Asking for help on [snipezilla.com](https://snipezilla.com)? Attach the profile log: it says more than any description.
