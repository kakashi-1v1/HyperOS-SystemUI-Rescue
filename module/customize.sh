SKIPUNZIP=0
set_perm "$MODPATH/systemui-rescue.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755

# v1.0 / v1.1 were installed as "kashi_rescue": stop that watchdog and remove the old module
if [ -d /data/adb/modules/kashi_rescue ] || [ -d /data/adb/kashi_rescue ]; then
  for f in daemon.pid saver.pid; do
    pid=$(cat /data/adb/kashi_rescue/$f 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  pkill -f "kashi_rescue.sh daemon" 2>/dev/null
  [ -d /data/adb/modules/kashi_rescue ] && touch /data/adb/modules/kashi_rescue/remove
  # keep the saved good copies
  if [ -d /data/adb/kashi_rescue/good ] && [ ! -d /data/adb/systemui_rescue/good ]; then
    mkdir -p /data/adb/systemui_rescue && cp -a /data/adb/kashi_rescue/good /data/adb/systemui_rescue/
  fi
  rm -rf /data/adb/kashi_rescue
  ui_print "- Replaced the old kashi_rescue module (saved copies kept)"
fi

ui_print "- SystemUI Rescue: the watchdog starts on boot"
ui_print "  start it now without reboot: su -c sh /data/adb/modules_update/systemui_rescue/service.sh"
