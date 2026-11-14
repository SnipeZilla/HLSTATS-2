# Installing the HLstatsZ daemon

The daemon receives the logs of your game servers and writes the stats to the database.
The website, [HLstatsZ web](https://github.com/SnipeZilla/hlstatsz-web), shows them.

- [Before you start](#before-you-start)
  - [Database settings](#database-settings-recommended)
- [Windows](#windows)
- [Linux](#linux)
- [Game servers](#game-servers)
- [How much can it handle?](#how-much-can-it-handle)
- [Something doesn't work?](#something-doesnt-work)

Every step is a line to copy and paste.

---

## Before you start

**Where to install HLstatsZ:** on the machine that has the database, not on a game server. HLstatsZ works with
the database all the time, so it belongs next to it, and the game server keeps its CPU for the game.
One HLstatsZ takes the logs of all your game servers.

**A database.** The easiest way: install the [HLstatsZ website](https://github.com/SnipeZilla/hlstatsz-web) first.
Its installer creates the database and its tables. Keep the database name, user and password from its
`config.php`: the daemon uses the same ones.
Already running HLstatsX:CE? Keep your database: HLstatsZ uses it as it is.

<details>
<summary>Create a database and its user yourself (optional)</summary>

Change the password, then run this as the database administrator:

```sql
CREATE DATABASE IF NOT EXISTS hlstats CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS 'hlstats'@'localhost' IDENTIFIED BY 'ChangeThisPassword';
GRANT ALL PRIVILEGES ON hlstats.* TO 'hlstats'@'localhost';
FLUSH PRIVILEGES;
```

- Windows: in HeidiSQL (installed with MariaDB) or MySQL Workbench.
- Linux: type `sudo mysql`, paste it, then type `exit`.

</details>

**Port 27500 open**, UDP (GoldSrc and Source servers) and TCP (CS2).
If your host has its own firewall (in its control panel), open the port there too.

### Database settings (recommended)

HLstatsZ writes to the database all the time. With these settings, MariaDB or MySQL keeps up with it easily,
from a small VPS to a big machine with many game servers. Pick the block closest to your machine.

**A small VPS** (2 GB of RAM, 2 cores):

```ini
[mysqld]
default_storage_engine         = InnoDB

# Memory for the database: about half of the RAM.
# Best when the whole database fits in it.
innodb_buffer_pool_size        = 1G
innodb_log_file_size           = 512M
innodb_log_buffer_size         = 64M

# Saves the changes to disk once a second, not after each one: much faster, and still safe.
innodb_flush_log_at_trx_commit = 2

# For an SSD. For a hard disk: 200 and 400.
innodb_io_capacity             = 2000
innodb_io_capacity_max         = 4000

# The number of CPU cores (not threads)
innodb_read_io_threads         = 2
innodb_write_io_threads        = 2
```

**A dedicated machine** (64 GB of RAM, 8 cores):

```ini
[mysqld]
default_storage_engine         = InnoDB

# Memory for the database: about 75% of the RAM when the machine runs only the database, HLstatsZ and a website.
# About half when it runs more than that.
innodb_buffer_pool_size        = 48G
innodb_log_file_size           = 2G
innodb_log_buffer_size         = 256M

# Saves the changes to disk once a second, not after each one: much faster, and still safe.
innodb_flush_log_at_trx_commit = 2

# For an SSD. For a hard disk: 200 and 400.
innodb_io_capacity             = 2000
innodb_io_capacity_max         = 4000

# The number of CPU cores (not threads)
innodb_read_io_threads         = 8
innodb_write_io_threads        = 8
```

Between the two: keep the same lines, with your RAM and your cores.

**Windows:** right-click the Start button > **Terminal (Admin)** or **Windows PowerShell (Admin)**, and open the
file in Notepad (put your MariaDB version in the path):

```
notepad "C:\Program Files\MariaDB 11.8\data\my.ini"
```

MySQL: `C:\ProgramData\MySQL\MySQL Server 8.0\my.ini`. XAMPP: `C:\xampp\mysql\bin\my.ini` (then restart MySQL
in the XAMPP Control Panel). Paste the block at the end of the file, save, and restart the database:

```
Get-Service *mariadb*, *mysql* | Restart-Service
```

**Linux** (Debian, Ubuntu): open a new file for the block:

```
sudo nano /etc/mysql/mariadb.conf.d/99-hlstatsz.cnf
```

Paste the block, save with Ctrl+O then Enter, and quit with Ctrl+X. Then restart the database:

```
sudo systemctl restart mariadb
```

With MySQL, the file is `/etc/mysql/mysql.conf.d/99-hlstatsz.cnf`, and the restart `sudo systemctl restart mysql`.

Keep the `[mysqld]` line on top: it puts the settings in the database server's part of the file.
The database doesn't start again? A value is too big for the machine, or mistyped: fix it, or remove the
block, and restart.

---

## Windows

What you need: Remote Desktop to your server. Do every step on the server.
The examples use the folder `C:\hlz`.

### 1. Download HLstatsZ

Download [the ZIP](https://github.com/SnipeZilla/HLSTATS-2/archive/refs/heads/main.zip), open it, and copy
everything inside its `HLSTATS-2-main` folder to `C:\hlz`. You should now have `C:\hlz\hlstats.pl`.

### 2. Install Perl

Install [Strawberry Perl 5.38.0.1 64-bit](https://github.com/StrawberryPerl/Perl-Dist-Strawberry/releases/download/SP_5380_5361/strawberry-perl-5.38.0.1-64bit.msi)
with its default options (it goes to `C:\Strawberry`).

> [!IMPORTANT]
> Use this exact version: the newer Strawberry Perl releases are missing the files the database drivers need.

### 3. Install the Perl modules

Open a new Command Prompt and paste (it takes a few minutes):

```
cpanm -n Mojolicious GeoIP2 PALI/DBD-MariaDB-1.22.tar.gz
```

DBD::MariaDB must be version 1.22: the newer ones don't build with Strawberry Perl 5.38.
Check that everything is there. It prints `OK`:

```
perl -MMojolicious -MDBD::MariaDB -MGeoIP2::Database::Reader -e "print qq{OK\n}"
```

`Can't locate DBD/MariaDB.pm`? Use the DBD::mysql driver instead, which comes with Strawberry Perl:
in step 4, set `DBDriver "mysql"`.

### 4. Configure

Open `C:\hlz\hlstats.conf` with Notepad and set the database, as in the website's `config.php`:

```ini
DBHost     "localhost"
DBUsername "root"
DBPassword "your password"
DBName     "hlstats"
DBDriver   "mariadb"
```

Daily awards (optional), in the same file:

```ini
PathPerl   "C:\Strawberry\perl\bin\perl.exe"
PathAwards "C:\hlz\hlstats-awards.pl"
```

Importing bans (optional): banned players are taken out of the rankings. Open `importbans.pl` with Notepad, fill in
your bans database at the top (SourceBans or AMXBans), then:

```ini
PathBans   "C:\hlz\importbans.pl"
```

### 5. Open the port

Right-click the Start button > **Terminal (Admin)** or **Windows PowerShell (Admin)**, and paste:

```
New-NetFirewallRule -DisplayName "HLstatsZ UDP 27500" -Direction Inbound -Protocol UDP -LocalPort 27500 -Action Allow
New-NetFirewallRule -DisplayName "HLstatsZ TCP 27500" -Direction Inbound -Protocol TCP -LocalPort 27500 -Action Allow
```

### 6. Start it

Right-click `C:\hlz\hlstatsz.ps1` > **Run with PowerShell**, allow the administrator rights, and answer **y**.

HLstatsZ is running. It starts with Windows, and starts again by itself if it stops.
To check, open <http://127.0.0.1:27500> in a browser on the server: it shows `OK`.

> [!NOTE]
> Coming from an older setup (a `.bat` in Task Scheduler)? Disable that task first: Task Scheduler > right-click it > **Disable**.
> `hlstatsz.ps1` ends the daemon it was running.

### Restart, stop, uninstall

Run `hlstatsz.ps1` again the same way, then choose `1` Restart, `2` Stop or `3` Uninstall.

---

## Linux

What you need, from your Windows PC:

- An SSH terminal: [PuTTY](https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html),
  or type `ssh root@your-server-ip` in Windows Terminal.
- [WinSCP](https://winscp.net/eng/download.php) (optional): to see the files, and edit `hlstats.conf` as in Notepad.

Paste each block in the terminal (in PuTTY, a right-click pastes). The commands are for Debian and Ubuntu.

### 1. Install Perl and the modules

```
sudo apt update
sudo apt install -y perl libdbi-perl libdbd-mysql-perl libmojolicious-perl libgeoip2-perl wget unzip
sudo apt install -y libdbd-mariadb-perl || { sudo apt install -y build-essential libmariadb-dev cpanminus && sudo cpanm -n DBD::MariaDB; }
```

Ubuntu 22.04 and 24.04 have no package for DBD::MariaDB: apt shows an error, then the last line builds it
(a minute or two).
Check that everything is there. It prints `OK`:

```
perl -MMojolicious -MDBD::MariaDB -MGeoIP2::Database::Reader -e 'print "OK\n"'
```

`Can't locate DBD/MariaDB.pm`? Use the DBD::mysql driver instead, installed above: in step 3, set `DBDriver "mysql"`.

### 2. Download HLstatsZ

```
cd /opt
sudo wget -O hlstatsz.zip https://github.com/SnipeZilla/HLSTATS-2/archive/refs/heads/main.zip
sudo unzip -q hlstatsz.zip && sudo mv HLSTATS-2-main hlstatsz && sudo rm hlstatsz.zip
```

HLstatsZ is now in `/opt/hlstatsz`.

### 3. Configure

```
sudo nano /opt/hlstatsz/hlstats.conf
```

Set the database, as in the website's `config.php`. Save with Ctrl+O then Enter, and quit with Ctrl+X.

```ini
DBHost     "localhost"
DBUsername "hlstats"
DBPassword "your password"
DBName     "hlstats"
DBDriver   "mariadb"
```

Daily awards (optional), in the same file:

```ini
PathPerl   "/usr/bin/perl"
PathAwards "/opt/hlstatsz/hlstats-awards.pl"
```

Importing bans (optional): banned players are taken out of the rankings. Fill in your bans database at the top of
`importbans.pl` (SourceBans or AMXBans), then:

```ini
PathBans   "/opt/hlstatsz/importbans.pl"
```

With WinSCP instead: open `/opt/hlstatsz`, right-click `hlstats.conf` > **Edit**.

### 4. Open the port

Only if a firewall is on. With ufw (Ubuntu):

```
sudo ufw allow 27500/udp && sudo ufw allow 27500/tcp
```

With firewalld:

```
sudo firewall-cmd --permanent --add-port=27500/udp --add-port=27500/tcp && sudo firewall-cmd --reload
```

### 5. Start it

```
cd /opt/hlstatsz && sudo bash hlstatsz.sh
```

Answer **y**. HLstatsZ is running as the `hlstatsz` service. It starts with the server, and starts again by itself if it stops.
To check, this shows `OK`:

```
curl http://127.0.0.1:27500
```

What it prints: `journalctl -u hlstatsz -f` (Ctrl+C to quit).

> [!NOTE]
> Coming from `run_hlstats`? `hlstatsz.sh` ends the daemon it started. If cron runs `run_hlstats`, delete that line
> (`sudo crontab -e`): the script tells you when it finds one.

### Restart, stop, uninstall

```
cd /opt/hlstatsz && sudo bash hlstatsz.sh
```

Then choose `1` Restart, `2` Stop or `3` Uninstall.

---

## Game servers

Add these lines to the game server's `server.cfg`. Replace `DAEMON_IP` with the public IP of the machine running
HLstatsZ, and use your own RCON password. Then restart the game server.

**GoldSrc** (CS 1.6, DoD, TFC, ...), with the plugin [hlstats_cs.amxx](plugins/amxmodx/plugins/hlstats_cs.amxx):

```
rcon_password "YourRconPassword"
log on
logaddress_delall
logaddress_add DAEMON_IP 27500
```

**Source** (CS:S, CS:GO, TF2, L4D2, ...), with the plugin [hlstatsx.smx](plugins/sourcemod/plugins/hlstatsx.smx):

```
rcon_password "YourRconPassword"
log on
logaddress_delall
logaddress_add "DAEMON_IP:27500"
```

**Counter-Strike 2**, with the plugin [HLstatsZ Classics](https://github.com/SnipeZilla/HLstatsZ-Classics):

```
rcon_password "YourRconPassword"
log on
logaddress_delall_http
logaddress_add_http "http://DAEMON_IP:27500"
sv_visiblemaxplayers 32
```

Add `-usercon` to the server's launch options.

Then add the server in the website's admin panel, with the same RCON password: [Add a server](GUIDE.md#add-a-server)
in GUIDE.md. It shows up in the website after its first logs.

> [!TIP]
> No game server yet, or tired of restarting them by hand? [SZM, SnipeZilla Server Manager 2](https://github.com/SnipeZilla/szm)
> installs, updates and restarts game servers from a web page, on Windows and Linux. It is one file to run, and it
> installs SourceMod, AMX Mod X and CounterStrikeSharp for you: the plugins above go on top.

---

## How much can it handle?

More than you think. HLstatsZ is light: one process for all your game servers, that never waits and writes to
the database in batches. And you don't have to believe it: the profiler measures it on your machine.

1. In `hlstats.conf`, set `Profile 1`.
2. Restart HLstatsZ: `hlstatsz.ps1` (Windows) or `sudo bash hlstatsz.sh` (Linux), then `1`.
3. Let it run while your game servers are busy: an evening is good, a whole day is better.
4. On your PC, open `profile\hlstatsz_profile_viewer.html` in a browser (it is in the ZIP too), and drop
   `hlstatsz_profile.log` on it. The log is in the `profile` folder of HLstatsZ: on Linux, copy it to your PC
   with WinSCP.
5. Set `Profile 0` and restart.

The page shows how busy the daemon is at your peak, how many game servers it can handle with ease, and what it
is waiting for when it waits. How to read it: [Check the load](GUIDE.md#check-the-load-the-profiler) in GUIDE.md.

The log never takes more than about 10 MB, and the page works without internet: nothing is sent anywhere.

---

## Something doesn't work?

See what the daemon says:

- **Windows:** run `hlstatsz.ps1` and choose `2` (Stop). Then, run `run_hlstatsz.ps1` or in a Command Prompt:

  ```
  cd /d C:\hlz
  perl hlstats.pl
  ```

  Read the messages, quit with Ctrl+C, then run `hlstatsz.ps1` and choose `1` (Start).

- **Linux:** `journalctl -u hlstatsz -n 50`

Not enough to see? Set `DebugLevel 1` in `hlstats.conf` and restart: the daemon says more.
Set it back to `0` when everything works.

The usual causes:

- **Can't connect to the database** (`Access denied`, `Can't connect to MySQL server`): check the four `DB` lines in `hlstats.conf`.
- **`Can't locate Mojo/IOLoop.pm`** or **`GeoIP binary lookup but module not found`**: Windows step 3, or Linux step 1.
- **`Connection attempt 1 failed:`** with nothing after it: the driver in `DBDriver` isn't installed. Run the check
  of Windows step 3 or Linux step 1, or set `DBDriver "mysql"`.
- **No stats**: port 27500 is closed (Windows firewall, ufw, or your host's firewall), `DAEMON_IP` is wrong on the
  game server, or the server isn't [added in the admin panel](GUIDE.md#add-a-server) yet.
- **It works, but is it keeping up?** The [profiler](#how-much-can-it-handle) answers that.

Still stuck? Ask on [snipezilla.com](https://snipezilla.com).
