# HyperOS SystemUI Rescue

A KernelSU / Magisk module for people who mod SystemUI. When a broken SystemUI or SystemUI plugin
build puts SystemUI into a crash loop, it puts back the last working version and restarts SystemUI.
No reboot, no recovery, no deleting `/data/app` folders by hand.

Made for HyperOS (SystemUI replaced in `/system_ext/priv-app/MiuiSystemUI`, plugin
`miui.systemui.plugin` installed as an update in `/data/app`).

## How it works

**Watching costs nothing.** The watchdog blocks on Android's crash log (`logcat -b crash`), which only
gets a line when something crashes. While nothing crashes there is no polling, no timer and no CPU
use. It runs at the lowest priority; the only resident process is one sleeping `logcat` (a few MB of RAM).

**Saving the last good versions.** A short check runs 5 minutes after boot and then every 10 minutes.
If SystemUI has not crashed for 5 minutes and is running, the installed SystemUI apk and the plugin
update (only when it is an update in `/data/app`) are copied to `/data/adb/kashi_rescue/good/`.
A stamp (path, size, modification time) next to each copy means an apk is only copied again after you
install a new one.

**Crash loop = 3 SystemUI crashes within 2 minutes** (Java crashes and native crashes; other apps are
ignored). Then it:

1. saves the crash log to `/data/adb/kashi_rescue/crash-*.txt` (last 5 kept),
2. puts back the last good copy of whichever changed most recently, SystemUI or the plugin,
3. if SystemUI still loops, puts back the other one,
4. as a last resort removes the plugin update (stock plugin),
5. restarts SystemUI and posts a notification saying what was restored.

SystemUI is restored the safe way: the good apk is written next to the old one and swapped in with
`mv`, the stock `oat/` folder and stale dalvik-cache code are removed, the partition goes back to
read-only and SystemUI is recompiled in the background.

## Install

Flash `kashi_rescue.zip` (from Releases) in KernelSU or Magisk. The watchdog starts on every boot.

Start it right away without rebooting:

```sh
su -c sh /data/adb/modules_update/kashi_rescue/service.sh
```

(after the next reboot the module lives in `/data/adb/modules/kashi_rescue`).

## Commands

As root: `sh /data/adb/modules/kashi_rescue/kashi_rescue.sh <command>`

| Command | What it does |
| --- | --- |
| `status` | installed vs. saved apks, watchdog state, last log lines |
| `save` | save the current SystemUI + plugin as last good now |
| `restore-sysui` | put back the saved SystemUI now |
| `restore-plugin` | put back the saved plugin now |
| `stock-plugin` | remove the plugin update (stock plugin) |

Pause the watchdog: `touch /data/adb/kashi_rescue/disable` (delete the file to resume).
Log: `/data/adb/kashi_rescue/rescue.log`.

## Limits

- Only crash loops are caught. A build that crashes only when you open one screen is not a loop;
  use `restore-plugin` / `restore-sysui` by hand.
- A build that crashes rarely (never 3 times in 2 minutes) can reach 5 crash-free minutes and be
  saved as "good".
- One generation is kept: the most recent good copy.
- Built for HyperOS SystemUI (`com.android.systemui`) and its plugin (`miui.systemui.plugin`).
