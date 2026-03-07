NEWt Watchdog package
=====================

Contents:
- newt-watchdog.sh        main watchdog script
- newt-watchdog.service   systemd oneshot service
- newt-watchdog.timer     systemd timer (runs every 60s)
- install.sh              installer
- uninstall.sh            optional removal script

Installation:
1. unzip the package
2. run as root: ./install.sh
3. test manually: systemctl start newt-watchdog.service
4. read logs: journalctl -u newt-watchdog.service -n 100 --no-pager

The watchdog avoids restart loops with:
- cooldown between restarts
- post-restart grace period
- restart burst limit + backoff window
- persistent restart history in /var/lib/newt-watchdog
- pause of restart attempts while network is unavailable

The log patterns include:
- failed to connect
- failed to get token
- failed to report peer bandwidth.*not connected
- periodic ping failed
- failed to connect to websocket
- no route to host
- ping failed:.*i/o timeout
- failed to read icmp packet
- Connection to server lost after X failures
- Continuous reconnection attempts will be made
