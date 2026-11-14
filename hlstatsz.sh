#!/bin/bash
# HLstatsZ on Linux: runs hlstats.pl as a systemd service, which starts it at boot and again when it stops.

NAME=hlstatsz
UNIT=/etc/systemd/system/$NAME.service
DIR=$(cd "$(dirname "$0")" && pwd)

# Not root: ask for it
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo > /dev/null || { echo "Run this as root."; exit 1; }
    exec sudo bash "$0" "$@"
fi
command -v systemctl > /dev/null || { echo "This needs systemd (systemctl not found)."; exit 1; }

# Ends this folder's hlstats.pl (started by run_hlstats or by hand): not hlstats-awards.pl, nothing from another folder
stop_daemon() {
    for pid in $(pgrep -f 'hlstats\.pl'); do
        if [ "$(readlink "/proc/$pid/cwd")" = "$DIR" ] || tr '\0' ' ' < "/proc/$pid/cmdline" 2> /dev/null | grep -qF "$DIR/hlstats.pl"; then
            kill -9 "$pid" 2> /dev/null
        fi
    done
    sleep 1
}

if [ -f "$UNIT" ]; then
    # Installed: restart (start when it isn't running), stop, or uninstall
    state=$(systemctl is-active $NAME)
    start=Restart
    [ "$state" = active ] || start=Start
    echo "HLstatsZ: the service $NAME is $state."
    read -r -p "1 = $start, 2 = Stop, 3 = Uninstall, Enter = nothing: " choice
    case "$choice" in
        1)  systemctl stop $NAME; stop_daemon
            systemctl start $NAME && echo "HLstatsZ started." ;;
        2)  systemctl stop $NAME; stop_daemon
            echo "HLstatsZ stopped. The service starts it again at boot." ;;
        3)  systemctl disable --now $NAME; stop_daemon
            rm -f "$UNIT"; systemctl daemon-reload
            echo "HLstatsZ stopped, and the service $NAME removed." ;;
    esac
    exit
fi

read -r -p "Install the service $NAME (runs HLstatsZ at boot, and again when it stops)? A HLstatsZ running from this folder is ended. [y/n] " answer
case "$answer" in [Yy]*) ;; *) exit ;; esac

PERL=$(command -v perl) || { echo "Perl not found: install it first."; exit 1; }
stop_daemon
cat > "$UNIT" <<EOF
[Unit]
Description=HLstatsZ daemon ($DIR)
After=network-online.target mariadb.service mysql.service
Wants=network-online.target

[Service]
WorkingDirectory=$DIR
ExecStart="$PERL" "$DIR/hlstats.pl" -n
Restart=always
RestartSec=5
# hlstats.pl saves its stats on SIGINT (the default SIGTERM would skip that)
KillSignal=SIGINT
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now $NAME && echo "Service $NAME installed and started. Its output:  journalctl -u $NAME"

# A cron job running run_hlstats would start a second HLstatsZ
cron=$(grep -ls 'run_hlstats' /etc/crontab /etc/cron.d/* /var/spool/cron/crontabs/* /var/spool/cron/* 2> /dev/null)
[ -n "$cron" ] && echo "Remove the run_hlstats line from: $cron  (it would start a second HLstatsZ)"
exit 0
