SKIPUNZIP=0
set_perm "$MODPATH/kashi_rescue.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
ui_print "- Kashi SystemUI rescue: watchdog starts on boot"
ui_print "  (to start now without reboot: su -c sh /data/adb/modules/kashi_rescue/service.sh)"
