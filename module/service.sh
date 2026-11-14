#!/system/bin/sh
# start the SystemUI Rescue watchdog once (also safe to run by hand: sh service.sh)
MODDIR=${0%/*}
D=/data/adb/systemui_rescue
mkdir -p "$D"
pid=$(cat "$D/daemon.pid" 2>/dev/null)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && grep -q systemui-rescue "/proc/$pid/cmdline" 2>/dev/null; then
  exit 0
fi
nohup sh "$MODDIR/systemui-rescue.sh" daemon > /dev/null 2>&1 &
