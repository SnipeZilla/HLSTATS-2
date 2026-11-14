# HLstatsZ

**Real-time player stats and rankings for GoldSrc, Source and Counter-Strike 2 servers.**

HLstatsZ is the HLstatsX you know, kept alive and brought up to date. Your players get their rank, their points
after each kill, awards, and a website with their whole history. You get one small program that takes the logs of
all your game servers and never needs watching.

It is the only active HLstatsX fork with ***native*** **Counter-Strike 2 support**, through Valve's HTTP log
transport, and it still runs every GoldSrc and Source game that HLstatsX:CE did.

| | |
| --- | --- |
| **[INSTALL.md](INSTALL.md)** | Install it on Windows or Linux, step by step, with every command to copy and paste. |
| **[GUIDE.md](GUIDE.md)** | The settings worth knowing: add a server, bans, rankings, the profiler. |
| **[HLstatsZ web](https://github.com/SnipeZilla/hlstatsz-web)** | The website that shows the stats, with its installer for the database. |
| **[HLstatsZ Classics](https://github.com/SnipeZilla/HLstatsZ-Classics)** | The CS2 plugin (CounterStrikeSharp), with SourceBans. |

---

## Why people stay with it

- **Players like it.** Points after a kill, `rank` and `top10` in the chat, awards every day, a rank to defend:
  it gives people a reason to come back to your server.
- **Already on HLstatsX:CE? Keep everything.** HLstatsZ uses your database as it is: same players, same history,
  same plugins on the game servers.
- **One daemon for all your servers.** CS 1.6, TF2 and CS2 side by side, on one port, in one process.
- **Set it up and forget it.** It starts with the machine, starts again by itself if it stops, reconnects by itself
  when a connection goes stale, and runs the daily awards and bans without cron.
- **Windows and Linux**, with MariaDB or MySQL.

## Light, and you can check

Stats daemons have a reputation of being heavy. This one is built to stay out of the way:

- **It never waits.** The daemon is event-driven (Mojolicious): logs, timers and RCON answers are handled as they
  come, and a busy server never holds back the others.
- **It writes in batches.** Events are queued and inserted together, so the database does a few big writes
  and not thousands of small ones.
- **Housekeeping comes last.** Cleanup, snapshots and saves run on timers, after the incoming logs.
- **It doesn't touch your game servers.** It runs next to the database. A game server only sends its log lines,
  as it does for any log address.

Don't take our word for it: **HLstatsZ has a profiler built in.** Set `Profile 1` in `hlstats.conf`, restart, let it
run while your servers are busy, and drop the log on the viewer page that comes with it. It tells you, for *your*
machine:

- how busy the daemon is at your peak hour, in % of its time;
- how many log lines a second it can take before it reaches its limit;
- **how many game servers it can handle with ease**, and where its limit is;
- what it is waiting for, when it waits: the database, RCON, a slow query, the processor.

The viewer is one HTML page that works offline: your log is read in your browser and goes nowhere. The log is
limited to about 10 MB, so it is safe to leave on for a day, even on a small VPS.
How to use it: [Check the load](GUIDE.md#check-the-load-the-profiler) in GUIDE.md.

---

## What's inside

<details>
<summary>For the curious: what changed since HLstatsX:CE</summary>

- **Two protocols, one port.** GoldSrc and Source logs arrive over UDP, CS2 logs over HTTP. Both are listened to
  on the same port and feed the same parser.
- **Non-blocking by design.** UDP and HTTP each have their own queue. A burst of CS2 traffic never starves the
  UDP servers, or the other way round, and neither blocks the main loop.
- **Buffered batch INSERTs.** Events queue up and flush in bulk, which keeps the write pressure on InnoDB low at
  high log rates.
- **Hardened code and config loading.** `use strict` everywhere, no `eval` to apply the settings read from the
  database, and raw log bytes are always decoded: a bad value in the database can't inject code in the daemon.
- **CS2 userid handling.** CS2 gives every connecting player `userid=0` first, then the real one. The daemon
  follows the player through the change.
- **Socket health-check.** A stale connection is detected and opened again, without a restart.
- **Built-in daily job.** Awards and bans run once a day from the daemon itself.
- **MariaDB or MySQL**, with InnoDB-optimised queries.
- **GeoIP2.** Optional GeoIP2-City lookup, for the players' location and the map on the website.
- **Profiler.** Off by default, one line in `hlstats.conf` to turn on.

</details>

> **Why Perl + Mojolicious?**
> A stats daemon reads log lines all day, and matching text is what Perl does best. Mojolicious brings the modern
> part: an actively maintained, non-blocking event loop for the sockets, the timers and the HTTP listener CS2 needs.
> Together: a small, stable daemon made to run for months.

---

## FAQ

**Where should I run HLstatsZ?**
On the machine that hosts your database, not on a game server. HLstatsZ works with the database all the time, so
it belongs next to it, and your game servers keep their CPU for the game.

**How many game servers can one daemon take?**
All of yours go in a single process, and communities run it with many. The exact number depends on your machine
and on how busy your servers are, so measure it: the [profiler](GUIDE.md#check-the-load-the-profiler) gives you
the figure.

**I run HLstatsX:CE. Can I switch?**
Yes. Keep your database, point the daemon at it, and your game servers keep sending their logs to the same port.
For the website, [HLstatsZ web](https://github.com/SnipeZilla/hlstatsz-web) brings an old database up to date, or
keep the frontend you have.

**Why don't the daily awards run?**
Set `PathPerl` and `PathAwards` (and `PathBans` for the bans) in `hlstats.conf`. The daemon runs them once a day
by itself.

**Who's using it?**
Hosting companies, internet cafés and gaming communities around the world.

---

## Also from SnipeZilla

**[SZM, SnipeZilla Server Manager 2](https://github.com/SnipeZilla/szm)**: the game servers themselves, managed
from a web page. It installs them, updates them when Steam has a new version, and starts them again after a
crash. One file to run, on Windows, and on Linux too: no PHP, web server or database to install. It also installs
SourceMod, AMX Mod X and CounterStrikeSharp, which the HLstatsZ plugins need. A good match: Szm keeps the servers
up, HLstatsZ keeps the score.

---

## Lineage

```
HLstats (Simon Garner)
  └─ HLstatsX (Tobias Oetzel)
       └─ ELstatsNEO (Malte Bayer)
            └─ HLstatsX:CE (Nicholas Hastings)
                 └─ HLstatsZ (SnipeZilla) ← now you are stuck here
```

## Credits

Based on HLstatsX:CE 1.6.19  
Maintained and modernized by [SnipeZilla](https://github.com/SnipeZilla)  
Validation and help by [ghost-](https://github.com/ghostt187)

Help and news: [snipezilla.com](https://snipezilla.com)

Licensed under the GNU General Public License v2 or later.
