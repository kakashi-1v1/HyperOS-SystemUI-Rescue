#!/system/bin/sh
# systemui-rescue - SystemUI / SystemUI plugin crash-loop watchdog (root, KernelSU/Magisk module).
#
# Event driven (blocks on the crash log, no polling). After STABLE seconds without a SystemUI crash, the installed SystemUI apk and the plugin update
# (/data/app) are copied to /data/adb/systemui_rescue/good as "last good".
# When SystemUI crash-loops (LOOP_COUNT crashes within LOOP_WINDOW seconds) it saves the crash log,
# puts back the last good copy of whichever of the two changed most
# recently, restarts SystemUI and posts a notification. Still looping -> the other one. No good plugin
# copy -> the plugin update is removed (stock /product plugin).
#
# Commands (as root):
#   sh systemui-rescue.sh daemon          watchdog loop (started by service.sh)
#   sh systemui-rescue.sh status          what is installed vs. saved, last log lines
#   sh systemui-rescue.sh save            save the current SystemUI + plugin as last good now
#   sh systemui-rescue.sh restore-sysui   put back the good SystemUI now
#   sh systemui-rescue.sh restore-plugin  put back the good plugin now
#   sh systemui-rescue.sh stock-plugin    remove the plugin update (stock plugin)
# Pause: touch /data/adb/systemui_rescue/disable   (rm it to resume)

D=/data/adb/systemui_rescue
G=$D/good
LOG=$D/rescue.log
SUI=com.android.systemui
PLG=miui.systemui.plugin
LOOP_COUNT=${LOOP_COUNT:-3}
LOOP_WINDOW=${LOOP_WINDOW:-120}
STABLE=${STABLE:-300}

mkdir -p "$G"

log() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
  # keep the log short
  [ "$(wc -l < "$LOG")" -gt 400 ] && { tail -n 200 "$LOG" > "$LOG.t" && mv -f "$LOG.t" "$LOG"; }
}
sui_pid() { pidof "$SUI" 2>/dev/null | awk '{print $1}'; }
apk_of() { pm path "$1" 2>/dev/null | head -1 | sed 's/^package://'; }
stamp() { [ -f "$1" ] && echo "$1|$(stat -c '%s:%Y' "$1")"; }
mtime_of() { stat -c '%Y' "$1" 2>/dev/null || echo 0; }

notify() {
  cmd notification post -S bigtext -t "SystemUI Rescue" systemui_rescue "$1" >/dev/null 2>&1
}

restart_sui() {
  killall "$SUI" 2>/dev/null || pkill -f "$SUI" 2>/dev/null
}

# ------------------------------------------------------------------ last good copies

# save <name> <apk>   (name = systemui | plugin)
save_one() {
  name=$1; src=$2
  [ -n "$src" ] && [ -f "$src" ] || return 1
  cur=$(stamp "$src")
  [ "$cur" = "$(cat "$G/$name.src" 2>/dev/null)" ] && return 0
  if cp -f "$src" "$G/$name.apk.tmp" && mv -f "$G/$name.apk.tmp" "$G/$name.apk"; then
    echo "$cur" > "$G/$name.src"
    log "saved good $name: $src"
  else
    rm -f "$G/$name.apk.tmp"
    log "could not save $name from $src"
  fi
}

save_good() {
  rm -f "$D/tried"
  save_one systemui "$(apk_of $SUI)"
  p=$(apk_of $PLG)
  case "$p" in /data/*) save_one plugin "$p" ;; esac
}

# changed <name> <pkg>: 0 if the installed apk is not the saved good one
changed() {
  src=$(apk_of "$2")
  [ -n "$src" ] || return 1
  [ -f "$G/$1.apk" ] || return 1
  [ "$(stamp "$src")" != "$(cat "$G/$1.src" 2>/dev/null)" ]
}

# ------------------------------------------------------------------ restore

mount_of() {
  awk -v p="$1" '{ m = $5; if (m == "/" || index(p, m "/") == 1 || p == m) if (length(m) > length(best)) best = m } END { print best }' /proc/self/mountinfo
}
is_rw() { awk -v m="$1" '$5 == m { print $6 }' /proc/self/mountinfo | tail -1 | grep -q -E '^rw(,|$)'; }
make_ro() {
  mount -o remount,ro "$1" 2>/dev/null
  is_rw "$1" && mount -o remount,ro "$1" 2>/dev/null
}

is_mountpoint() { awk -v m="$1" '$5 == m { f = 1 } END { exit !f }' /proc/self/mountinfo; }

# read-only partition (EROFS, shared blocks...): put the good apk over the bad one with a bind mount.
# No write needed, works at once, lasts until reboot (after a reboot the loop is caught again).
bind_sysui() {
  good=$1; path=$2
  chmod 644 "$good"; chcon u:object_r:system_file:s0 "$good" 2>/dev/null
  mount --bind "$good" "$path" || { log "cannot remount $(mount_of "$path") rw and the bind mount failed"; return 1; }
  cache=$(echo "${path#/}" | tr "/" "@")
  rm -f /data/dalvik-cache/*/"$cache"@classes.* 2>/dev/null
  stamp "$path" > "$G/systemui.src"
  log "partition is read-only: bind-mounted the good SystemUI over $path (until reboot)"
  restart_sui
  return 0
}

restore_sysui() {
  good=$G/systemui.apk
  [ -f "$good" ] || { log "no good SystemUI saved"; return 1; }
  path=$(apk_of $SUI)
  case "$path" in
    /data/*|"") log "SystemUI is not a system apk ($path), not restoring"; return 1 ;;
  esac
  dir=${path%/*}
  # an older bind mount from a previous rescue would hide the swap
  is_mountpoint "$path" && umount "$path" 2>/dev/null
  mp=$(mount_of "$path")
  if ! mount -o remount,rw "$mp" 2>/dev/null; then
    bind_sysui "$good" "$path"; return $?
  fi
  ok=1
  if cp -f "$good" "$path.new"; then
    chown 0:0 "$path.new"; chmod 644 "$path.new"
    chcon u:object_r:system_file:s0 "$path.new" 2>/dev/null
    mv -f "$path.new" "$path" || { rm -f "$path.new"; ok=0; }
  else
    rm -f "$path.new"; ok=0
  fi
  rm -rf "$dir/oat" 2>/dev/null
  make_ro "$mp"
  cache=$(echo "${path#/}" | tr '/' '@')
  rm -f /data/dalvik-cache/*/"$cache"@classes.* 2>/dev/null
  [ "$ok" = 1 ] || { log "SystemUI swap failed"; return 1; }
  # the restored apk is now "good" by definition
  stamp "$path" > "$G/systemui.src"
  log "restored good SystemUI -> $path"
  restart_sui
  ( sleep 20; cmd package compile -m speed -f $SUI >/dev/null 2>&1 ) &
  return 0
}

stock_plugin() {
  if pm uninstall-system-updates $PLG >/dev/null 2>&1; then
    log "plugin update removed (stock plugin)"
    restart_sui
    return 0
  fi
  log "could not remove the plugin update"
  return 1
}

restore_plugin() {
  good=$G/plugin.apk
  if [ -f "$good" ] && pm install -r -d -t "$good" >/dev/null 2>&1; then
    p=$(apk_of $PLG)
    stamp "$p" > "$G/plugin.src"
    log "restored good plugin -> $p"
    restart_sui
    return 0
  fi
  [ -f "$good" ] && log "good plugin install failed, falling back to stock"
  stock_plugin
}

save_crash_log() {
  f=$D/crash-$(date '+%m%d-%H%M%S').txt
  logcat -b crash -d -t 400 > "$f" 2>/dev/null
  ls -t "$D"/crash-*.txt 2>/dev/null | tail -n +6 | while read -r old; do rm -f "$old"; done
  log "crash log saved: $f"
}

# culprit: whose code crashed in the newest SystemUI crash -> "plugin", "sysui" or nothing (unknown).
#  native: backtrace goes through the plugin apk path, or its JIT/odex frames name a class (as java)
#  java:   first stack-frame class (frameworks skipped) that only ONE of the two apks contains
culprit() {
  blk=$(logcat -b crash -d -v epoch -t 800 2>/dev/null | awk -v s="$SUI" '
    index($0, "Process: " s ", PID") || index($0, ">>> " s " <<<") { n = 0; pid = $2; on = 1 }
    on && $2 == pid { L[n++] = $0 }
    END { for (i = 0; i < n; i++) print L[i] }')
  [ -n "$blk" ] || return 0
  case "$blk" in *"$PLG"*) echo plugin; return 0 ;; esac
  w=$D/culprit; rm -rf "$w"; mkdir -p "$w"
  # java: "at pkg.Class.method(File.java:1)"   native JIT/odex frame: "(pkg.Class.method+123)"
  echo "$blk" | sed -n -e 's/.*[[:space:]]at \([A-Za-z0-9_$.]*\)\.[^.(]*(.*/\1/p' \
    -e 's/.*(\([A-Za-z0-9_$]*\.[A-Za-z0-9_$.]*\)\.[A-Za-z0-9_$<>]*+[0-9]*)$/\1/p' \
    | grep -vE '^(java|javax|android|androidx|dalvik|libcore|kotlin|kotlinx|sun|com\.android\.internal)\.' \
    | awk '!seen[$0]++' | head -20 | sed 's|\.|/|g; s|^|L|; s|$|;|' > "$w/frames"
  if [ -s "$w/frames" ]; then
    unzip -p "$(apk_of $SUI)" 'classes*.dex' > "$w/sui.dex" 2>/dev/null
    pl=$(apk_of $PLG); : > "$w/plg.dex"
    [ -n "$pl" ] && unzip -p "$pl" 'classes*.dex' > "$w/plg.dex" 2>/dev/null
    while read -r d; do
      a=0; b=0
      grep -qaF "$d" "$w/sui.dex" && a=1
      grep -qaF "$d" "$w/plg.dex" && b=1
      [ $a = 1 ] && [ $b = 0 ] && { echo sysui; break; }
      [ $b = 1 ] && [ $a = 0 ] && { echo plugin; break; }
    done < "$w/frames"
  fi
  rm -rf "$w"
}

# rescue: undo the change whose code crashed (culprit), else the newest change; $D/tried remembers what
# this crash loop already undid
# (cleared when the next good copies are saved)
rescue() {
  TRIED=$(cat "$D/tried" 2>/dev/null)
  save_crash_log
  c=$(culprit)
  [ -n "$c" ] && log "crash is in the $c code"
  s=0; p=0
  changed systemui $SUI && s=1
  changed plugin $PLG && p=1
  case " $TRIED " in *" sysui "*) s=0 ;; esac
  case " $TRIED " in *" plugin "*) p=0 ;; esac
  order=""
  if [ $s = 1 ] && [ $p = 1 ]; then
    # both changed: the one whose code crashed first, else the newest change
    if [ "$c" = plugin ]; then order="plugin sysui"
    elif [ "$c" = sysui ]; then order="sysui plugin"
    elif [ "$(mtime_of "$(apk_of $PLG)")" -gt "$(mtime_of "$(apk_of $SUI)")" ]; then order="plugin sysui"
    else order="sysui plugin"; fi
  elif [ $s = 1 ]; then order="sysui"
  elif [ $p = 1 ]; then order="plugin"
  fi
  for what in $order; do
    TRIED="$TRIED $what"; echo "$TRIED" > "$D/tried"
    if [ $what = sysui ]; then
      restore_sysui && { notify "SystemUI kept crashing: restored the last good SystemUI. Crash log in $D"; return 0; }
    else
      restore_plugin && { notify "SystemUI kept crashing: restored the last good SystemUI plugin. Crash log in $D"; return 0; }
    fi
  done
  # nothing saved differs: last resort = stock plugin (only while the plugin is an update)
  case " $TRIED " in *" stock "*) ;; *)
    case "$(apk_of $PLG)" in /data/*)
      TRIED="$TRIED stock"; echo "$TRIED" > "$D/tried"
      stock_plugin && { notify "SystemUI kept crashing: removed the SystemUI plugin update. Crash log in $D"; return 0; }
      ;;
    esac
  esac
  log "crash loop, nothing left to restore"
  notify "SystemUI keeps crashing and nothing is left to restore. Crash log in $D"
  return 1
}

# ------------------------------------------------------------------ watchdog
# Event driven: blocks on the crash log buffer (no polling, no CPU while nothing crashes).
# Every SystemUI crash (Java "FATAL EXCEPTION ... Process: com.android.systemui" or native
# ">>> com.android.systemui <<<") is one event; LOOP_COUNT events within LOOP_WINDOW = crash loop.
# A separate sleeper saves the last good copies every SAVE_EVERY seconds when nothing crashed lately.

SAVE_EVERY=${SAVE_EVERY:-600}

crash_events() {
  # -v epoch: first field = seconds; start from "now" so old crashes are not replayed
  start=$(date +%s)
  logcat -b crash -v epoch -T 1 2>/dev/null | while read -r ts rest; do
    sec=${ts%%.*}
    case "$sec" in ''|*[!0-9]*) continue ;; esac
    [ "$sec" -lt "$start" ] && continue
    case "$rest" in
      *"Process: $SUI, PID"*|*">>> $SUI <<<"*) echo "$sec" ;;
    esac
  done
}

saver() {
  while true; do
    sleep "$SAVE_EVERY"
    [ -f "$D/disable" ] && continue
    last=$(cat "$D/last_crash" 2>/dev/null || echo 0)
    [ $(( $(date +%s) - last )) -lt "$STABLE" ] && continue
    [ -n "$(sui_pid)" ] || continue
    save_good
  done
}

daemon() {
  echo $$ > "$D/daemon.pid"
  renice -n 19 -p $$ >/dev/null 2>&1
  i=0
  while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 120 ]; do sleep 2; i=$((i + 2)); done
  log "watchdog started (loop: $LOOP_COUNT SystemUI crashes / ${LOOP_WINDOW}s; good copies after ${STABLE}s without crash)"
  # first good copies once this boot looks healthy
  ( sleep "$STABLE"; last=$(cat "$D/last_crash" 2>/dev/null || echo 0)
    [ $(( $(date +%s) - last )) -ge "$STABLE" ] && [ -n "$(sui_pid)" ] && save_good; saver ) &
  echo $! > "$D/saver.pid"

  while true; do
    times=""; idle_until=0
    crash_events | while read -r t; do
      [ -f "$D/disable" ] && continue
      echo "$t" > "$D/last_crash"
      [ "$t" -lt "$idle_until" ] && continue
      kept=""
      for r in $times $t; do [ $((t - r)) -le "$LOOP_WINDOW" ] && kept="$kept $r"; done
      times=$kept
      n=$(echo $times | wc -w)
      [ "$n" -ge "$LOOP_COUNT" ] || continue
      log "crash loop: $n SystemUI crashes in ${LOOP_WINDOW}s"
      rescue
      times=""
      idle_until=$(( $(date +%s) + 25 ))   # restored SystemUI gets time to start
    done
    # logcat ended (logd restart): start it again
    sleep 5
  done
}

status() {
  echo "SystemUI: $(apk_of $SUI)  pid $(sui_pid)"
  echo "plugin:   $(apk_of $PLG)"
  for n in systemui plugin; do
    if [ -f "$G/$n.apk" ]; then echo "good $n: $(cat "$G/$n.src")"; else echo "good $n: (none yet)"; fi
  done
  changed systemui $SUI && echo "-> SystemUI differs from the good copy"
  changed plugin $PLG && echo "-> plugin differs from the good copy"
  dp=$(cat "$D/daemon.pid" 2>/dev/null)
  if [ -n "$dp" ] && kill -0 "$dp" 2>/dev/null; then echo "watchdog: running (pid $dp)"; else echo "watchdog: NOT running"; fi
  [ -f "$D/disable" ] && echo "watchdog: paused ($D/disable)"
  echo "--- log"; tail -n 8 "$LOG" 2>/dev/null
}

[ "$(id -u)" = "0" ] || { echo "run as root"; exit 1; }
[ -n "$SYSUI_RESCUE_LIB" ] && return 0 2>/dev/null
case "$1" in
  daemon) daemon ;;
  save) STABLE=0; save_good; status ;;
  restore-sysui) restore_sysui && echo ok ;;
  restore-plugin) restore_plugin && echo ok ;;
  stock-plugin) stock_plugin && echo ok ;;
  status|"") status ;;
  *) sed -n '2,20p' "$0" ;;
esac
