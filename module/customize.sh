SKIPUNZIP=0
set_perm "$MODPATH/systemui-rescue.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
ui_print "- SystemUI Rescue: the watchdog starts on boot"
ui_print "  start it now without reboot: su -c sh /data/adb/modules_update/systemui_rescue/service.sh"
