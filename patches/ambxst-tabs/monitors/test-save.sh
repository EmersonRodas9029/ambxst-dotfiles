#!/bin/bash
# Check del merge de MonitorsTab.save(): saca el script del QML y verifica que
# reemplace solo la regla del monitor editado y conserve las demas.
cd "$(dirname "$0")"
export HOME=$(mktemp -d); f="$HOME/.config/hypr/monitors.conf"; mkdir -p "$HOME/.config/hypr"
printf '# viejo\nmonitor = eDP-1,preferred,0x0,1.50,transform,0\nmonitor = DP-1,1920x1080@60,1280x0,1.00,transform,1\n' > "$f"
script=$(python3 -c "
s=open('MonitorsTab.qml').read(); i=s.index('saveScript: \`')+len('saveScript: \`'); print(s[i:s.index('\`',i)])")
sh -c "${script/hyprctl reload/true}" _ DP-1 "DP-1,1360x768@60.02,-768x0,1.00,transform,3"
got=$(grep -c "^monitor = " "$f")
grep -q "^monitor = eDP-1,preferred,0x0,1.50,transform,0$" "$f" || { echo "FALLA: perdio eDP-1"; exit 1; }
grep -q "^monitor = DP-1,1360x768@60.02,-768x0,1.00,transform,3$" "$f" || { echo "FALLA: no escribio DP-1"; exit 1; }
[ "$got" = 2 ] || { echo "FALLA: $got reglas, esperaba 2 (duplico?)"; exit 1; }
echo ok
