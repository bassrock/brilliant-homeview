#!/bin/sh
# Put a Brilliant panel back on its stock interface.
#   ./uninstall.sh <panel-ip>
set -e
IP=$1
[ -n "$IP" ] || { echo "usage: $0 <panel-ip>"; exit 1; }
ssh root@"$IP" '
systemctl disable --now homeview hv-sliders 2>/dev/null || true
rm -f /etc/systemd/system/homeview.service /etc/systemd/system/hv-sliders.service
rm -f /etc/systemd/system/switch_ui_app.service.d/homeview.conf
systemctl unmask bootsplash.service 2>/dev/null || true
systemctl daemon-reload
systemctl restart switch_ui_app
rm -rf /etc/homeview
systemctl is-active switch_ui_app'
