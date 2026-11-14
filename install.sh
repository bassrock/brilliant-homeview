#!/bin/sh
# Install Brilliant HomeView on a Brilliant panel over SSH.
#
#   ./install.sh <panel-ip> <config.js> [timezone]
#   e.g. ./install.sh 192.168.1.50 my-kitchen.config.js America/Los_Angeles
#
# Needs root SSH to the panel. Everything lands under /etc (which survives
# Brilliant's OSTree OTA updates). Undo with ./uninstall.sh <panel-ip>.
set -e
IP=$1 CONFIG=$2 TZ_NAME=${3:-UTC}
if [ -z "$IP" ] || [ ! -f "$CONFIG" ]; then
  sed -n 2,9p "$0"; exit 1
fi
cd "$(dirname "$0")"

echo "== copying to $IP"
COPYFILE_DISABLE=1 tar cf - -C panel main.qml hv_sliders.py hv_bus_set.py fonts system | \
  ssh root@"$IP" 'rm -rf /tmp/hvinst && mkdir -p /tmp/hvinst && tar xf - -C /tmp/hvinst'
ssh root@"$IP" 'umask 077; mkdir -p /etc/homeview; cat > /etc/homeview/config.js' < "$CONFIG"

echo "== installing"
ssh root@"$IP" "TZ_NAME='$TZ_NAME' sh -s" <<'EOF'
set -e
cd /tmp/hvinst
install -m 644 main.qml /etc/homeview/main.qml
install -m 755 hv_sliders.py /etc/homeview/hv_sliders.py
install -m 644 hv_bus_set.py /etc/homeview/hv_bus_set.py
mkdir -p /etc/homeview/fonts && cp fonts/* /etc/homeview/fonts/
chmod 600 /etc/homeview/config.js
echo "TZ=$TZ_NAME" > /etc/homeview/env
mkdir -p /etc/systemd/system/switch_ui_app.service.d
install -m 644 system/switch_ui_offscreen.conf /etc/systemd/system/switch_ui_app.service.d/homeview.conf
install -m 644 system/homeview.service /etc/systemd/system/homeview.service
install -m 644 system/hv-sliders.service /etc/systemd/system/hv-sliders.service
chown -R root:root /etc/homeview
# Brilliant's boot splash (fbi) lingers and fights HomeView for the framebuffer.
systemctl mask bootsplash.service >/dev/null 2>&1 || true
systemctl daemon-reload
pkill -x fbi || true
systemctl restart switch_ui_app
systemctl enable --now hv-sliders homeview >/dev/null 2>&1
sleep 15
systemctl is-active switch_ui_app homeview hv-sliders
rm -rf /tmp/hvinst
EOF
echo "== done"
