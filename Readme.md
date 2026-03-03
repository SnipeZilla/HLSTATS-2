# HLstats v2 — event‑driven rewrite built on Mojolicious

- Unified **non-blocking** listener for SRCDS **UDP** + CS2 **HTTP** logs on the same port with **Mojo::IOLoop** (minimalistic event loop based on Mojo::Reactor)
- **Mojo::IOLoop->next_tick()** scheduling, lightweight, precise callbacks that run on the next loop iteration without blocking anything else
- **Mojo::IOLoop->recurring()** timers for low‑priority tasks (cleanup, stats, load...) leaving logs parsing with a higher priority
- Automatic socket **healthcheck** with diagnosis and reconnection
- Log parsing **prioritized** above all auxiliary operations
- Full query set optimized for modern **high‑performance InnoDB** engine (DB ≥ 84) and **fastest collation** (DB ≥ 84)
- DB driver: Choice of **MariaDB** or **MySQL**
- **High‑throughput queued** RCON and log pipeline (can queued thousands of logs/s if needed across multi servers)
- Source plugins supported (hlstatsx.smx, amxmodx)
- Source 2 (CS2) via **[HLstatsZ](https://github.com/SnipeZilla/CS2-HLstatsX-Plugin)** plugin with Sourcemod‑style events (Server mod set as SOURCEMOD for seamless integration hlx_sm_*)
- Optional built‑in daily **cronjob**
- Comprehensive debug mode (Async) that never blocks the main loop
---

## 🤔❓ FAQ

- Where do I install HLstats?<br>
HLstats is required to operate on your SQL database server; it should not be run on your Game Server!

- Why don’t my daily rewards run?<br>
Now with fully optional built‑in daily cronjob (Awards & Bans); solving one of the most common complaints

- How to ignore Warmup or End Of Round?<br>
Edit server details and set `BonusRoundIgnore 1` 

---

## 📦 Installation & Setup
**Windows Perl**(must be compiled with mysql):
   * https://strawberryperl.com/release-notes/5.38.0.1-64bit.html

**Additional modules:**
   * Mojolicious
   * GeoIP2
   * GeoIP2::Database::Reader
   * DBD::MariaDB (optional)

  **Example installation**
   * Linux: $ curl -L https://cpanmin.us | perl - -M https://cpan.metacpan.org -n Mojolicious
   * Windows > cpan install Mojolicious

**GoldSrc**
- server.cfg
```
rcon_password "PaSsWoRd"
log on
logaddress_delall
logaddress_add 64.74.97.164 27500
```
**Source**
- server.cfg
```
rcon_password "PaSsWoRd"
log on
logaddress_delall
logaddress_add "64.74.97.164:27500"
```
**Source 2 (CS2)**
- gamemode-server.cfg
```
rcon_password "PaSsWoRd"
log on
logaddress_delall_http
logaddress_add_http "http://64.74.97.164:27500"
sv_visiblemaxplayers 32 // rcon status is broken for max players
```

`Optionally, an additional log address can be used for testing on a different Daemon/Database`
```
logaddress_add_http_delayed 0.0 "http://64.74.97.164:27501"
```
Add to your launch commands -usercon

### 📈 Web Frontend / Webside Options
- Any of your liking. Pretty much all the same anyway
- Most are available on Github
- Recommended version [HLstatsX-web 1.6.19 (2025)](https://github.com/SnipeZilla/hlstatsx-web)
---

## 🤝 Credits
Based on HLstatsX:CE 1.6.19<br>
Maintained and modernized by SnipeZilla<br>
Help and validation by [ghost-](https://github.com/ghostt187)