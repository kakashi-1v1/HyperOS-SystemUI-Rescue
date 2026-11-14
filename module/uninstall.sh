#!/system/bin/sh
for f in daemon.pid saver.pid; do
  pid=$(cat /data/adb/kashi_rescue/$f 2>/dev/null)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
done
pkill -f "kashi_rescue.sh daemon" 2>/dev/null
rm -rf /data/adb/kashi_rescue
