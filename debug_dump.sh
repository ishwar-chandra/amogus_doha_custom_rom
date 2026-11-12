#!/usr/bin/env bash
# =============================================================================
# LineageOS 23.2 amogus_doha — Full Device Diagnostic Dump
# =============================================================================
# Run this from your PC with the device connected via ADB.
# Usage: ./debug_dump.sh [output_dir]
# Default output: <script_dir>/device_dump_<timestamp>/
#
# Options (environment variables):
#   TMO=90          per-command timeout in seconds (a stuck sysfs read can no longer hang the run)
#   LIGHT=1         skip the very large dumpsys services (package, activity, window, batterystats)
#   REPRO_SIM1=1    at the end: clear the logs, ask you to place a call from SIM 1, then capture the logs
#   REPRO_WAIT=30   seconds to wait instead of pressing Enter when stdin is not a terminal
#   REDACT=0        archive the raw dump instead of a redacted copy (default 1)
#                   Default leaves one raw directory + one redacted .tar.gz; no duplicate tree
#   ALL_SERVICES=0 skip the catch-all loop that runs `dumpsys <name>` for EVERY registered service (default 1)
#   GUIDED=1        guided feature tests: you are asked to use each feature (camera, call, NFC, ...) and the logs of
#                   every step are saved separately in guided/. GUIDED_ONLY="touch call_sim1" runs only some steps
#   BUGREPORT=1     also run `adb bugreport` (big, takes minutes; stays OUT of the redacted copy)
#   HASH_VENDOR=1   also sha1 every file under /vendor (slow) for byte-exact ROM comparisons
#   ANALYZE=0       do not run analyze_dump.sh at the end (default 1, if it sits next to this script)
# A full run takes roughly 10 to 25 minutes and 50 to 300 MB. LIGHT=1 is faster.
# Run it on the stable ROM and on the new build, then use compare_dumps.sh on the two directories.
# COVERAGE.md lists every area and file. Nothing here can prove a feature works: only the guided steps and your own use do that.
# Use ANDROID_SERIAL=<serial> if more than one device is connected.
#
# This script captures EVERYTHING needed to debug any issue on the device.
# It creates a timestamped directory with all logs, dumps, and diagnostics
# next to this script, plus one archive. After it finishes, the dump can be
# analyzed offline.
# =============================================================================
set -u   # no -e on purpose: one failing grep/command must never end a diagnostic run

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
OUTDIR="${1:-$SCRIPT_DIR/device_dump_${TIMESTAMP}}"
TMO=${TMO:-90}; LIGHT=${LIGHT:-0}; REPRO_SIM1=${REPRO_SIM1:-0}; REPRO_WAIT=${REPRO_WAIT:-30}; REDACT=${REDACT:-1}
ALL_SERVICES=${ALL_SERVICES:-1}; GUIDED=${GUIDED:-0}; GUIDED_ONLY=${GUIDED_ONLY:-}; BUGREPORT=${BUGREPORT:-0}; HASH_VENDOR=${HASH_VENDOR:-0}; ANALYZE=${ANALYZE:-1}
HAVE_TIMEOUT=0; command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1

# Prefer the adb bundled alongside this script, then fall back to PATH.
# (Resolved BEFORE creating OUTDIR so a missing adb leaves no stray dir.)
ADB_BIN="$REPO_ROOT/platform-tools/adb.exe"
if [ ! -f "$ADB_BIN" ]; then
  ADB_BIN=$(command -v adb 2>/dev/null) || {
    echo "ERROR: adb not found in PATH" >&2; exit 1
  }
fi
adb() { "$ADB_BIN" "$@"; }

# Same rule for a present-but-idle adb: without a device every probe below is
# empty, so refuse before creating OUTDIR instead of leaving a useless dump.
if [ "$(adb get-state 2>/dev/null || echo none)" != device ]; then
  echo "ERROR: no device connected - connect the phone (adb devices)" >&2
  exit 1
fi

mkdir -p "$OUTDIR"

# Ensure a device is connected
DEVICE_STATE=$(adb get-state 2>/dev/null || echo "none")
if [ "$DEVICE_STATE" != "device" ]; then
  echo "ERROR: No device connected (state=$DEVICE_STATE). Connect via USB and authorize ADB." >&2
  exit 1
fi

# Try to get root — needed for dmesg, some sysfs reads, tombstones
ROOT_RESULT=$(adb root 2>&1 || true)
adb wait-for-device 2>/dev/null || true
sleep 3
# Verify connection recovered
if ! adb shell echo ok >/dev/null 2>&1; then
  echo "Waiting for ADB to recover after root..."
  sleep 5
  adb wait-for-device 2>/dev/null
fi

mkdir -p "$OUTDIR/info"
{ echo "adb root: $ROOT_RESULT"; echo "shell id: $(adb shell id 2>&1)"; echo "su: $(adb shell 'su -c id' 2>&1 | head -1)"
  echo "getenforce: $(adb shell getenforce 2>&1)"; echo "NOTE: without root, dmesg, /data/tombstones, iptables, debugfs and some sysfs reads come back empty"; } > "$OUTDIR/info/root_status.txt"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   LineageOS amogus_doha — Full Diagnostic Dump              ║"
echo "║   Output: $OUTDIR"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Helper: run a shell command on device and save output
# Usage: dcmd <output_file> <shell_command>
dcmd() {
  local out="$OUTDIR/$1"
  mkdir -p "$(dirname "$out")"
  shift
  echo "  ▸ $out"
  if [ "$HAVE_TIMEOUT" = 1 ]; then timeout "$TMO" "$ADB_BIN" shell "$@" >"$out" 2>&1 || true
  else adb shell "$@" >"$out" 2>&1 || true; fi
}

# Helper: pull a file from device
# Usage: dpull <device_path> <local_subdir>
dpull() {
  local src="$1" dst="$OUTDIR/${2:-pulled}"
  mkdir -p "$dst"
  adb pull "$src" "$dst/" >/dev/null 2>&1 || echo "  (could not pull $src)" >>"$OUTDIR/_pull_errors.log"
}

# Helper: ensure ADB is still alive, reconnect if needed
check_adb() {
  if ! adb shell echo ok >/dev/null 2>&1; then
    echo "  ⚠  ADB disconnected, waiting for reconnect..."
    adb wait-for-device 2>/dev/null
    sleep 2
  fi
}

# Helper: run dumpsys for a service
# Usage: dsvc <service_name>
dsvc() {
  dcmd "dumpsys/${1}.txt" "dumpsys $1"
}

# ═══════════════════════════════════════════════════════════════════
echo "▶ [1/35] Device Identity & Build Info"
# ═══════════════════════════════════════════════════════════════════
dcmd "info/build_props.txt" "getprop"
dcmd "info/build_display.txt" "getprop ro.build.display.id"
dcmd "info/build_date.txt" "getprop ro.build.date"
dcmd "info/kernel_version.txt" "uname -a"
dcmd "info/device_codename.txt" "getprop ro.product.device"
dcmd "info/lineage_version.txt" "getprop ro.lineage.version"
dcmd "info/build_type.txt" "getprop ro.build.type"
dcmd "info/build_fingerprint.txt" "getprop ro.build.fingerprint"
dcmd "info/selinux_mode.txt" "getenforce"
dcmd "info/uptime.txt" "uptime"
dcmd "info/date.txt" "date"
dcmd "info/meminfo.txt" "cat /proc/meminfo"
dcmd "info/cpuinfo.txt" "cat /proc/cpuinfo"
dcmd "info/mounts.txt" "mount"
dcmd "info/df.txt" "df -h"
dcmd "info/lsblk.txt" "ls -la /dev/block/by-name/"
dcmd "info/cmdline.txt" "cat /proc/cmdline"
dcmd "info/version.txt" "cat /proc/version"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [2/35] Kernel Logs (dmesg)"
# ═══════════════════════════════════════════════════════════════════
dcmd "kernel/dmesg_full.txt" "dmesg"
dcmd "kernel/dmesg_errors.txt" "dmesg | grep -iE 'err|warn|crit|alert|emerg|fail'"
dcmd "kernel/dmesg_touch.txt" "dmesg | grep -iE 'fts|touch|input|ts_doha|spi0|hx8|himax|goodix|synaptics|atmel'"
dcmd "kernel/dmesg_thermal.txt" "dmesg | grep -iE 'thermal|therm|trip|cool|throttl|tsens'"
dcmd "kernel/dmesg_power.txt" "dmesg | grep -iE 'cpufreq|cpu_boost|governor|schedutil|performance|sched_energy|suspend|resume|wakeup|sleep'"
dcmd "kernel/dmesg_network.txt" "dmesg | grep -iE 'wlan|wifi|rmnet|rndis|tether|bpf|netbpf|offload|ipa|qmi'"
dcmd "kernel/dmesg_audio.txt" "dmesg | grep -iE 'audio|codec|sound|alsa|wcd|bolero|apr|adsp'"
dcmd "kernel/dmesg_camera.txt" "dmesg | grep -iE 'camera|msm_cam|cci|actuator|eeprom|flash|isp|sensor.*cci'"
dcmd "kernel/dmesg_display.txt" "dmesg | grep -iE 'drm|display|dsi|mdss|mdp|panel|fb0|backlight|blank'"
dcmd "kernel/dmesg_usb.txt" "dmesg | grep -iE 'usb|dwc3|gadget|configfs|otg|xhci'"
dcmd "kernel/dmesg_battery.txt" "dmesg | grep -iE 'battery|charger|smb|qpnp|fg|fuel|bms|chg'"
dcmd "kernel/dmesg_bt.txt" "dmesg | grep -iE 'bluetooth|bt_|hci|btfm|wcnss'"
dcmd "kernel/dmesg_nfc.txt" "dmesg | grep -iE 'nfc|nxp|pn5|sec-nfc|snxxx|ese|nq'"
dcmd "kernel/dmesg_gps.txt" "dmesg | grep -iE 'gps|gnss|loc_|lowi|xtra|slim'"
dcmd "kernel/dmesg_firmware.txt" "dmesg | grep -iE 'firmware|request_firmware|ueventd.*firmware|\.bin|\.mdt'"
dcmd "kernel/dmesg_selinux.txt" "dmesg | grep -iE 'avc.*denied|selinux|audit'"
dcmd "kernel/dmesg_modules.txt" "dmesg | grep -iE 'module|modprobe|insmod'"
dcmd "kernel/dmesg_init_errors.txt" "dmesg | grep -iE 'init.*fail|init.*error|init.*denied|init.*cannot'"
dcmd "kernel/dmesg_crash.txt" "dmesg | grep -iE 'panic|oops|BUG|FORTIFY|fatal|abort|segfault'"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [3/35] Logcat (all buffers)"
# ═══════════════════════════════════════════════════════════════════
dcmd "logcat/main_system_crash.txt" "logcat -d -b main,system,crash"
dcmd "logcat/events.txt" "logcat -d -b events"
dcmd "logcat/radio.txt" "logcat -d -b radio"
dcmd "logcat/kernel.txt" "logcat -d -b kernel"
# Filtered views for quick analysis
dcmd "logcat/errors_only.txt" "logcat -d *:E"
dcmd "logcat/fatal_only.txt" "logcat -d -b crash"
dcmd "logcat/grep_touch.txt" "logcat -d | grep -iE 'fts|touch|input.*mapper|InputReader|InputDispatcher|viewport|isActive'"
dcmd "logcat/grep_thermal.txt" "logcat -d | grep -iE 'thermal|temperature|throttl|cooling'"
dcmd "logcat/grep_battery.txt" "logcat -d | grep -iE 'battery|wakelock|doze|idle|suspend|PowerManager'"
dcmd "logcat/grep_wifi.txt" "logcat -d | grep -iE 'wifi|wlan|supplicant|hostapd|softap|SoftApManager|WifiService|WifiHal'"
dcmd "logcat/grep_tether.txt" "logcat -d | grep -iE 'tether|hotspot|rndis|usb_tether|UsbDeviceManager|TetheringService|offload'"
dcmd "logcat/grep_telephony.txt" "logcat -d | grep -iE 'telephony|ril|qcrild|radio|signal|SIM|ims|volte|modem|ServiceState|NetworkRegistration|CallState'"
dcmd "logcat/grep_bt.txt" "logcat -d | grep -iE 'bluetooth|bt_|BtGatt|AdapterService|btif|hci_'"
dcmd "logcat/grep_nfc.txt" "logcat -d | grep -iE 'nfc|NfcService|nxp|NativeNfc'"
dcmd "logcat/grep_camera.txt" "logcat -d | grep -iE 'camera|CameraService|CameraProvider|CameraDevice'"
dcmd "logcat/grep_audio.txt" "logcat -d | grep -iE 'audio|AudioFlinger|AudioPolicy|AudioHAL|mixer|volume'"
dcmd "logcat/grep_display.txt" "logcat -d | grep -iE 'display|surfaceflinger|hwcomposer|gralloc|drm|DisplayManager|DisplayDevice'"
dcmd "logcat/grep_gps.txt" "logcat -d | grep -iE 'gps|location|gnss|GnssHAL|GpsLocation|LocationManager'"
dcmd "logcat/grep_fingerprint.txt" "logcat -d | grep -iE 'fingerprint|fps_id|biometric|egis|fpc|goodix'"
dcmd "logcat/grep_selinux.txt" "logcat -d | grep -iE 'avc.*denied|SELinux'"
dcmd "logcat/grep_crash.txt" "logcat -d | grep -iE 'FATAL|fatal|FORTIFY|tombstone|crash|ANR|native.*crash|signal.*SIG'"
dcmd "logcat/grep_services.txt" "logcat -d | grep -iE 'ServiceManager.*died|service.*restart|service.*start|service.*crash'"
dcmd "logcat/grep_init.txt" "logcat -d | grep -iE 'init.*service|starting.*service|init.*oneshot|init.*exec|post_boot'"
dcmd "logcat/grep_usb.txt" "logcat -d | grep -iE 'UsbDeviceManager|usb.*gadget|configfs|mtp|ptp|adb.*function'"
dcmd "logcat/grep_vibrator.txt" "logcat -d | grep -iE 'vibrat|haptic|aw86'"
dcmd "logcat/grep_sensors.txt" "logcat -d | grep -iE 'sensor|SensorService|SensorHal|accelerometer|gyro|proximity|light'"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [4/35] Touch & Input Diagnostics"
# ═══════════════════════════════════════════════════════════════════
dcmd "touch/sys_class_touchscreen.txt" 'ls -laR /sys/class/touchscreen/ 2>&1; for d in /sys/class/touchscreen/*; do echo "=== $d ==="; for n in ic_ver drv_irq poweron productinfo buildid; do [ -r "$d/$n" ] && echo "$n: $(cat "$d/$n" 2>&1)"; done; done'
dcmd "touch/find_touch_nodes.txt" 'find /sys/devices -maxdepth 9 \( -name "fts_*" -o -name "ic_ver" -o -name "panel_supplier" -o -name "hx_*" -o -name "nvt_*" \) 2>/dev/null | head -80'
dcmd "touch/touch_modules.txt" 'lsmod | grep -iE "focal|nova|nt36|fts|himax"; echo "--- files ---"; ls -l /vendor/lib/modules | grep -iE "focal|nova|nt36|fts|himax"; echo "--- modules.load ---"; cat /vendor/lib/modules/modules.load 2>&1'
dcmd "touch/panel_scripts_and_props.txt" 'ls -l /vendor/bin/init.oem.panel.sh /vendor/bin/init.mmi.touch.sh 2>&1; getprop | grep -iE "touch|panel|supplier|ro.vendor.hw|ro.boot.hardware|hwrev|sku"'
dcmd "touch/getevent_info.txt" "getevent -lp"
dcmd "touch/dumpsys_input.txt" "dumpsys input"
dcmd "touch/input_devices.txt" "cat /proc/bus/input/devices"
dcmd "touch/fts_fw_version.txt" "cat /sys/devices/platform/soc/4a88000.spi/spi_master/spi0/spi0.0/fts_fw_version"
dcmd "touch/fts_ic_ver.txt" "cat /sys/devices/platform/soc/4a88000.spi/spi_master/spi0/spi0.0/ic_ver"
dcmd "touch/fts_gesture_mode.txt" "cat /sys/devices/platform/soc/4a88000.spi/spi_master/spi0/spi0.0/fts_gesture_mode"
dcmd "touch/fts_irq.txt" "cat /sys/devices/platform/soc/4a88000.spi/spi_master/spi0/spi0.0/fts_irq"
dcmd "touch/fts_touch_point.txt" "cat /sys/devices/platform/soc/4a88000.spi/spi_master/spi0/spi0.0/fts_touch_point"
dcmd "touch/fts_driver_info.txt" "cat /sys/devices/platform/soc/4a88000.spi/spi_master/spi0/spi0.0/fts_driver_info"
dcmd "touch/fts_panel_supplier.txt" "cat /sys/devices/platform/soc/4a88000.spi/spi_master/spi0/spi0.0/panel_supplier"
dcmd "touch/fts_boot_mode.txt" "cat /sys/devices/platform/soc/4a88000.spi/spi_master/spi0/spi0.0/fts_boot_mode"
dcmd "touch/fts_charger_mode.txt" "cat /sys/devices/platform/soc/4a88000.spi/spi_master/spi0/spi0.0/fts_charger_mode"
dcmd "touch/fts_glove_mode.txt" "cat /sys/devices/platform/soc/4a88000.spi/spi_master/spi0/spi0.0/fts_glove_mode"
dcmd "touch/fts_cover_mode.txt" "cat /sys/devices/platform/soc/4a88000.spi/spi_master/spi0/spi0.0/fts_cover_mode"
dcmd "touch/fts_dump_reg.txt" "cat /sys/devices/platform/soc/4a88000.spi/spi_master/spi0/spi0.0/fts_dump_reg"
dcmd "touch/irq_count.txt" "cat /proc/interrupts | grep -iE 'fts|touch|input'"
dcmd "touch/firmware_files.txt" "find /vendor/firmware -name '*fts*' -o -name '*ft8*' -o -name '*focal*' -o -name '*touch*' 2>/dev/null"
dcmd "touch/idc_files.txt" "find /vendor/usr/idc /system/usr/idc -name '*.idc' 2>/dev/null -exec echo '=== {} ===' \\; -exec cat {} \\;"
dcmd "touch/keylayout_files.txt" "find /vendor/usr/keylayout /system/usr/keylayout -name '*.kl' 2>/dev/null"
# Capture 3 seconds of touch events in background (user should touch screen)
echo "    ⚠  Touch the screen for the next 5 seconds... (all input devices are captured; the event number varies)"
if [ "$HAVE_TIMEOUT" = 1 ]; then timeout 5 "$ADB_BIN" shell getevent -lt >"$OUTDIR/touch/live_events_5s.txt" 2>&1 || true
else echo "(no 'timeout' command on this PC: live capture skipped)" >"$OUTDIR/touch/live_events_5s.txt"; fi

# ═══════════════════════════════════════════════════════════════════
echo "▶ [5/35] Display & Graphics"
# ═══════════════════════════════════════════════════════════════════
dsvc "display"
dsvc "SurfaceFlinger"
dcmd "display/dumpsys_gpu.txt" "dumpsys gpu"
dcmd "display/drm_info.txt" "cat /sys/class/drm/card0/device/status 2>/dev/null; ls -la /sys/class/drm/"
dcmd "display/backlight.txt" "cat /sys/class/backlight/*/brightness /sys/class/backlight/*/max_brightness 2>/dev/null"
dcmd "display/panel_info.txt" "cat /sys/class/graphics/fb0/msm_fb_panel_info 2>/dev/null"
dcmd "display/fb0_info.txt" "cat /sys/class/graphics/fb0/virtual_size 2>/dev/null; cat /sys/class/graphics/fb0/stride 2>/dev/null"
dcmd "display/hwcomposer.txt" "dumpsys hwcomposer 2>/dev/null || dumpsys SurfaceFlinger --hwc"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [6/35] Thermal & Temperature"
# ═══════════════════════════════════════════════════════════════════
dcmd "thermal/dumpsys_thermalservice.txt" "dumpsys thermalservice"
dcmd "thermal/zones_all.txt" "for z in /sys/class/thermal/thermal_zone*; do echo \"--- \$(basename \$z): \$(cat \$z/type 2>/dev/null) ---\"; echo \"  temp: \$(cat \$z/temp 2>/dev/null)\"; echo \"  mode: \$(cat \$z/mode 2>/dev/null)\"; echo \"  policy: \$(cat \$z/policy 2>/dev/null)\"; for t in \$z/trip_point_*_temp; do [ -f \"\$t\" ] && echo \"  \$(basename \$t): \$(cat \$t 2>/dev/null)\"; done; done"
dcmd "thermal/cooling_devices.txt" "for c in /sys/class/thermal/cooling_device*; do echo \"--- \$(basename \$c): \$(cat \$c/type 2>/dev/null) ---\"; echo \"  cur_state: \$(cat \$c/cur_state 2>/dev/null)\"; echo \"  max_state: \$(cat \$c/max_state 2>/dev/null)\"; done"
dcmd "thermal/thermal_hal_config.txt" "cat /vendor/etc/thermal-engine*.conf 2>/dev/null; cat /vendor/etc/thermal_info_config.json 2>/dev/null"
dcmd "thermal/thermal_hal_process.txt" "ps -A | grep -iE 'thermal'"
dcmd "thermal/thermal_vintf.txt" "cat /vendor/etc/vintf/manifest/*.xml 2>/dev/null | grep -A5 -B2 thermal"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [7/35] CPU, Governor & Performance"
# ═══════════════════════════════════════════════════════════════════
dcmd "cpu/governors.txt" "for cpu in /sys/devices/system/cpu/cpu*/cpufreq; do echo \"--- \$(basename \$(dirname \$cpu)) ---\"; echo \"  governor: \$(cat \$cpu/scaling_governor 2>/dev/null)\"; echo \"  cur_freq: \$(cat \$cpu/scaling_cur_freq 2>/dev/null)\"; echo \"  min_freq: \$(cat \$cpu/scaling_min_freq 2>/dev/null)\"; echo \"  max_freq: \$(cat \$cpu/scaling_max_freq 2>/dev/null)\"; echo \"  avail_govs: \$(cat \$cpu/scaling_available_governors 2>/dev/null)\"; echo \"  avail_freqs: \$(cat \$cpu/scaling_available_frequencies 2>/dev/null)\"; done"
dcmd "cpu/online.txt" "cat /sys/devices/system/cpu/online"
dcmd "cpu/topology.txt" "for cpu in /sys/devices/system/cpu/cpu*/topology; do echo \"--- \$(basename \$(dirname \$cpu)) ---\"; echo \"  core_id: \$(cat \$cpu/core_id 2>/dev/null)\"; echo \"  cluster: \$(cat \$cpu/physical_package_id 2>/dev/null)\"; done"
dcmd "cpu/sched_energy_aware.txt" "cat /proc/sys/kernel/sched_energy_aware 2>/dev/null"
dcmd "cpu/sched_features.txt" "cat /sys/kernel/debug/sched_features 2>/dev/null"
dcmd "cpu/loadavg.txt" "cat /proc/loadavg"
dcmd "cpu/stat.txt" "cat /proc/stat"
dcmd "cpu/top_snapshot.txt" "top -b -n 1 -H | head -80"
dcmd "cpu/ps_all.txt" "ps -A -o pid,ppid,uid,user,pcpu,pmem,vsz,rss,wchan,stat,name,args"
dcmd "cpu/post_boot_script.txt" "cat /vendor/bin/init.qcom.post_boot.sh"
dcmd "cpu/post_boot_service_status.txt" "getprop init.svc.qcom-post-boot"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [8/35] Battery, Power & Wakelocks"
# ═══════════════════════════════════════════════════════════════════
dsvc "battery"
[ "$LIGHT" = 1 ] || dsvc "batterystats"
dsvc "power"
dcmd "battery/battery_sysfs.txt" "for f in /sys/class/power_supply/battery/*; do echo \"\$(basename \$f): \$(cat \$f 2>/dev/null)\"; done"
dcmd "battery/usb_supply.txt" "for f in /sys/class/power_supply/usb/*; do echo \"\$(basename \$f): \$(cat \$f 2>/dev/null)\"; done"
dcmd "battery/charger.txt" "for f in /sys/class/power_supply/qcom_battery/*; do echo \"\$(basename \$f): \$(cat \$f 2>/dev/null)\"; done 2>/dev/null; for f in /sys/class/power_supply/bms/*; do echo \"\$(basename \$f): \$(cat \$f 2>/dev/null)\"; done 2>/dev/null"
dcmd "battery/wakelocks_kernel.txt" "cat /proc/wakelocks 2>/dev/null || cat /d/wakeup_sources 2>/dev/null || cat /sys/kernel/debug/wakeup_sources 2>/dev/null"
dcmd "battery/wakelock_stats.txt" "dumpsys batterystats --wakelock"
dcmd "battery/alarm_stats.txt" "dumpsys alarm"
dcmd "battery/deviceidle.txt" "dumpsys deviceidle"
dcmd "battery/suspend_stats.txt" "cat /sys/kernel/debug/suspend_stats 2>/dev/null"
dcmd "battery/power_supply_list.txt" "ls -la /sys/class/power_supply/"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [9/35] Network, WiFi, Hotspot & Tethering"
# ═══════════════════════════════════════════════════════════════════
dsvc "wifi"
dsvc "connectivity"
dsvc "tethering"
dsvc "netd"
dsvc "network_management"
dcmd "network/ifconfig.txt" "ifconfig -a 2>/dev/null || ip addr"
dcmd "network/ip_route.txt" "ip route"
dcmd "network/ip_rule.txt" "ip rule"
dcmd "network/iptables.txt" "iptables -L -n -v 2>/dev/null"
dcmd "network/ip6tables.txt" "ip6tables -L -n -v 2>/dev/null"
dcmd "network/netstat.txt" "netstat -tlnp 2>/dev/null"
dcmd "network/wpa_supplicant_status.txt" "ps -A | grep -i wpa; dumpsys wifi | grep -A20 'WifiConfigManager'"
dcmd "network/wifi_config.txt" "cat /vendor/etc/wifi/wpa_supplicant.conf 2>/dev/null; cat /vendor/etc/wifi/wpa_supplicant_overlay.conf 2>/dev/null; cat /vendor/etc/wifi/p2p_supplicant_overlay.conf 2>/dev/null"
dcmd "network/wcnss_config.txt" "cat /vendor/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini 2>/dev/null"
dcmd "network/hostapd_config.txt" "cat /data/vendor/wifi/hostapd/hostapd.conf 2>/dev/null; cat /data/misc/wifi/hostapd.conf 2>/dev/null"
dcmd "network/softap_state.txt" "dumpsys wifi | grep -iE 'SoftAp|softap|HalDevMgr|SAP|concurrency|iface|ActiveMode|num.*Manager'"
dcmd "network/usb_gadget.txt" "cat /config/usb_gadget/g1/UDC 2>/dev/null; echo '---functions---'; ls /config/usb_gadget/g1/functions/ 2>/dev/null; echo '---configs---'; ls -la /config/usb_gadget/g1/configs/b.1/ 2>/dev/null"
dcmd "network/rndis_state.txt" "ls -la /sys/class/android_usb/android0/f_rndis/ 2>/dev/null; cat /sys/class/android_usb/android0/f_rndis/ethaddr 2>/dev/null"
dcmd "network/tether_offload.txt" "dumpsys tethering | grep -iE 'offload|bpf|Hardware'"
dcmd "network/bpf_progs.txt" "ls -la /sys/fs/bpf/ 2>/dev/null | head -40"
dcmd "network/netbpfload.txt" "dmesg | grep -i netbpfload"
dcmd "network/dns.txt" "getprop | grep dns"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [10/35] Telephony, SIM & Calls"
# ═══════════════════════════════════════════════════════════════════
dsvc "phone"
dsvc "isms"
dsvc "isub"
dsvc "telecom"
dcmd "telephony/telephony_registry.txt" "dumpsys telephony.registry"
dcmd "telephony/carrier_config.txt" "dumpsys carrier_config"
dcmd "telephony/ril_props.txt" "getprop | grep -iE 'ril|gsm|radio|telephony|sim|cdma|lte|ims|volte|vowifi|carrier|network\.type|signal'"
dcmd "telephony/sim_state.txt" "getprop gsm.sim.state; getprop gsm.sim.state2; getprop persist.radio.multisim.config"
dcmd "telephony/signal_strength.txt" "dumpsys telephony.registry | grep -iE 'signal|strength|dbm|rsrp|rsrq|rssi|snr|level'"
dcmd "telephony/service_state.txt" "dumpsys telephony.registry | grep -iE 'ServiceState|registration|roaming|operator|dataState|voiceRegState|dataRegState'"
dcmd "telephony/call_state.txt" "dumpsys telephony.registry | grep -iE 'callState|ringing|offhook|idle'"
dcmd "telephony/data_connection.txt" "dumpsys telephony.registry | grep -iE 'dataConnection|apn|dataActivity|mDataConnectionState'"
dcmd "telephony/ims_status.txt" "dumpsys telephony.registry | grep -iE 'ims|volte|vonr|vowifi|mmtel|rcs'"
dcmd "telephony/ril_daemon.txt" "ps -A | grep -iE 'ril|qcrild|rild'"
dcmd "telephony/modem_fw.txt" "getprop gsm.version.baseband"
dcmd "telephony/network_type.txt" "getprop gsm.network.type; getprop gsm.network.type2"
dcmd "telephony/data_enabled.txt" "settings get global mobile_data; settings get global data_roaming"
dcmd "telephony/preferred_network.txt" "settings get global preferred_network_mode; settings get global preferred_network_mode1"
dcmd "telephony/multisim_config.txt" "getprop persist.radio.multisim.config; getprop ro.telephony.default_network"
dsvc "telephony_ims"
dcmd "telephony/multi_sim_settings.txt" "settings get global multi_sim_voice_call; settings get global multi_sim_data_call; settings get global multi_sim_sms; settings get global multi_sim_voice_prompt"
dcmd "telephony/iphonesubinfo.txt" "dumpsys iphonesubinfo"
dcmd "telephony/phone_app_dump.txt" "dumpsys activity service com.android.phone | head -400"
dcmd "telephony/radio_processes.txt" "ps -A | grep -iE 'qcril|rild|ims|qti|netmgr|dataservice|radio'"
dcmd "telephony/radio_hals.txt" "lshal --neat 2>/dev/null | grep -iE 'radio|ims|qcril|qti'"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [11/35] Bluetooth"
# ═══════════════════════════════════════════════════════════════════
dsvc "bluetooth_manager"
dcmd "bluetooth/bt_state.txt" "settings get global bluetooth_on; getprop persist.sys.bluetooth.on"
dcmd "bluetooth/bt_props.txt" "getprop | grep -iE 'bluetooth|bt\\.'"
dcmd "bluetooth/bt_hal.txt" "ps -A | grep -iE 'bluetooth|bt_'"
dcmd "bluetooth/bt_firmware.txt" "ls -la /vendor/bt_firmware/ 2>/dev/null"
dcmd "bluetooth/fm_hal.txt" "ls -la /vendor/lib64/vendor.qti.hardware.fm@1.0.so 2>/dev/null; ls -la /vendor/lib/vendor.qti.hardware.fm@1.0.so 2>/dev/null"
dcmd "bluetooth/bt_vintf.txt" "cat /vendor/etc/vintf/manifest.xml 2>/dev/null | grep -A10 -B2 bluetooth"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [12/35] Audio"
# ═══════════════════════════════════════════════════════════════════
dsvc "audio"
dsvc "media.audio_flinger"
dsvc "media.audio_policy"
dcmd "audio/audio_props.txt" "getprop | grep -iE 'audio|sound|volume'"
dcmd "audio/audio_hal.txt" "ps -A | grep -iE 'audio'"
dcmd "audio/mixer_state.txt" "tinymix 2>/dev/null | head -200"
dcmd "audio/pcm_devices.txt" "ls /dev/snd/ 2>/dev/null"
dcmd "audio/audio_policy.txt" "cat /vendor/etc/audio_policy_configuration.xml 2>/dev/null | head -100"
dcmd "audio/codec_info.txt" "cat /proc/asound/cards 2>/dev/null"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [13/35] Camera"
# ═══════════════════════════════════════════════════════════════════
dsvc "media.camera"
dcmd "camera/camera_props.txt" "getprop | grep -iE 'camera'"
dcmd "camera/camera_hal.txt" "ps -A | grep -iE 'camera|provider'"
dcmd "camera/camera_devices.txt" "ls -la /dev/video* /dev/v4l* 2>/dev/null"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [14/35] GPS & Location"
# ═══════════════════════════════════════════════════════════════════
dsvc "location"
dcmd "gps/gps_props.txt" "getprop | grep -iE 'gps|gnss|location|loc_|lowi|xtra'"
dcmd "gps/gps_hal.txt" "ps -A | grep -iE 'gps|gnss|lowi|xtra|loc_|slim'"
dcmd "gps/gps_config.txt" "cat /vendor/etc/gps.conf 2>/dev/null; cat /vendor/etc/flp.conf 2>/dev/null; cat /vendor/etc/izat.conf 2>/dev/null"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [15/35] Sensors, Fingerprint & Vibrator"
# ═══════════════════════════════════════════════════════════════════
dsvc "sensorservice"
dcmd "sensors/sensor_list.txt" "dumpsys sensorservice | head -100"
dcmd "sensors/sensor_props.txt" "getprop | grep -iE 'sensor'"
dcmd "sensors/sensor_hal.txt" "ps -A | grep -iE 'sensor'"
dcmd "sensors/sensor_config_dir.txt" "ls -laR /vendor/etc/sensors/ 2>/dev/null"

dsvc "fingerprint"
dcmd "fingerprint/fps_hal.txt" "ps -A | grep -iE 'fingerprint|fps|biometric|egis|fpc'"
dcmd "fingerprint/fps_props.txt" "getprop | grep -iE 'fingerprint|fps|biometric'"
dcmd "fingerprint/fps_id.txt" "cat /proc/hw/fps_id/ascii 2>/dev/null"
dcmd "fingerprint/fps_script.txt" "cat /vendor/bin/init.oem.fingerprint2.sh 2>/dev/null"

dcmd "vibrator/vibrator_hal.txt" "ps -A | grep -iE 'vibrat'"
dcmd "vibrator/vibrator_sysfs.txt" "ls -la /sys/class/leds/vibrator/ 2>/dev/null; cat /sys/class/leds/vibrator/activate 2>/dev/null"
dcmd "vibrator/aw_haptic.txt" "find /sys -name '*aw86*' -o -name '*haptic*' 2>/dev/null | head -20"
dcmd "vibrator/modules_load.txt" "cat /vendor/lib/modules/modules.load 2>/dev/null"
dcmd "vibrator/loaded_modules.txt" "lsmod 2>/dev/null || cat /proc/modules"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [16/35] USB & Storage"
# ═══════════════════════════════════════════════════════════════════
dsvc "usb"
dcmd "usb/usb_state.txt" "getprop | grep -iE 'usb|mtp|ptp|adb'"
dcmd "usb/usb_gadget.txt" "cat /config/usb_gadget/g1/UDC 2>/dev/null"
dcmd "usb/usb_functions.txt" "ls -la /config/usb_gadget/g1/functions/ 2>/dev/null"
dcmd "usb/usb_speed.txt" "cat /sys/class/udc/*/device/speed 2>/dev/null"
dcmd "usb/usb_hal.txt" "ps -A | grep -iE 'usb'"
dcmd "usb/usb_devices.txt" "cat /sys/kernel/debug/usb/devices 2>/dev/null"
dsvc "mount"
dsvc "diskstats"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [17/35] SELinux & Security"
# ═══════════════════════════════════════════════════════════════════
dcmd "selinux/enforcing.txt" "getenforce"
dcmd "selinux/all_denials_dmesg.txt" "dmesg | grep 'avc.*denied'"
dcmd "selinux/all_denials_logcat.txt" "logcat -d -b all | grep -iE 'avc.*denied|selinux'"
dcmd "selinux/file_contexts_check.txt" "ls -laZ /vendor/bin/hw/android.hardware.thermal* 2>/dev/null; ls -laZ /vendor/bin/init.qcom.post_boot.sh 2>/dev/null; ls -laZ /vendor/bin/sh 2>/dev/null"
dcmd "selinux/property_denials.txt" "dmesg | grep 'avc.*denied.*property_service'"
dcmd "selinux/boot_props.txt" "getprop | grep -iE 'selinux|verity|avb|dm_verity'"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [18/35] Crashes, Tombstones & ANRs"
# ═══════════════════════════════════════════════════════════════════
dcmd "crashes/tombstone_list.txt" "ls -la /data/tombstones/ 2>/dev/null"
# Pull whole directories (root only; failures are listed in _pull_errors.log). On Android 10+ ANR traces are anr_* files, not traces.txt.
dpull "/data/tombstones" "crashes"
check_adb
dpull "/data/anr" "crashes"
check_adb
dcmd "crashes/dropbox_list.txt" "ls -la /data/system/dropbox/ 2>/dev/null | tail -40"
dcmd "crashes/native_crashes.txt" "logcat -d -b crash"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [19/35] Services, Init & VINTF"
# ═══════════════════════════════════════════════════════════════════
dcmd "services/service_list.txt" "service list"
dcmd "services/init_services.txt" "getprop | grep 'init.svc\.' | sort"
dcmd "services/crashed_services.txt" "getprop | grep 'init.svc\.' | grep -iE 'stopped|restarting'"
dcmd "services/hal_processes.txt" "ps -A | grep -E 'android\.(hardware|hidl)|vendor\.' | sort"
dcmd "services/all_processes.txt" "ps -Af"
dcmd "services/vintf_manifest.txt" "cat /vendor/etc/vintf/manifest.xml 2>/dev/null"
dcmd "services/vintf_fragments.txt" 'for f in /vendor/etc/vintf/manifest/*.xml; do echo "=== $f ==="; cat "$f" 2>/dev/null; done' 
dcmd "services/device_manifest.txt" "cat /vendor/etc/vintf/manifest.xml 2>/dev/null"
dcmd "services/framework_manifest.txt" "cat /system/etc/vintf/manifest.xml 2>/dev/null | head -100"
dcmd "services/compatibility_matrix.txt" "cat /system/etc/vintf/compatibility_matrix.current.xml 2>/dev/null | head -100"
dcmd "services/init_rc_files.txt" "find /vendor/etc/init -name '*.rc' 2>/dev/null"
dcmd "services/init_rc_contents.txt" 'for f in /vendor/etc/init/*.rc; do echo "=== $f ==="; cat "$f" 2>/dev/null; echo; done' 
dcmd "services/hwservicemanager.txt" "lshal --neat 2>/dev/null | head -200"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [20/35] Miscellaneous & System Health"
# ═══════════════════════════════════════════════════════════════════
[ "$LIGHT" = 1 ] || dsvc "window"
[ "$LIGHT" = 1 ] || dsvc "package"
[ "$LIGHT" = 1 ] || dsvc "activity"
dsvc "notification"
dsvc "accessibility"
dcmd "misc/settings_system.txt" "settings list system"
dcmd "misc/settings_secure.txt" "settings list secure"
dcmd "misc/settings_global.txt" "settings list global"
dcmd "misc/installed_packages.txt" "pm list packages -f"
dcmd "misc/disabled_packages.txt" "pm list packages -d"
dcmd "misc/overlays.txt" "cmd overlay list 2>/dev/null"
dcmd "misc/runtime_permissions.txt" "dumpsys package | grep -A5 'runtime permissions' | head -100"
dcmd "misc/disk_io.txt" "cat /proc/diskstats"
dcmd "misc/vmstat.txt" "cat /proc/vmstat"
dcmd "misc/zoneinfo.txt" "cat /proc/zoneinfo | head -100"
dcmd "misc/slabinfo.txt" "cat /proc/slabinfo 2>/dev/null | head -50"
dcmd "misc/timezone.txt" "getprop persist.sys.timezone"
dcmd "misc/locale.txt" "getprop persist.sys.locale"
dcmd "misc/encryption.txt" "getprop ro.crypto.state"
dcmd "misc/treble.txt" "getprop ro.treble.enabled"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [21/35] Kernel modules, kernel config & reference snapshot (for comparing ROMs)"
# ═══════════════════════════════════════════════════════════════════
dcmd "modules/ls_vendor_lib_modules.txt" "ls -la /vendor/lib/modules/"
dcmd "modules/modules_load.txt" "cat /vendor/lib/modules/modules.load 2>&1"
dcmd "modules/modules_files.txt" "ls -la /vendor/lib/modules/modules.* 2>&1"
dcmd "modules/lsmod.txt" "lsmod"
dcmd "modules/proc_modules.txt" "cat /proc/modules"
dcmd "modules/kernel_config.txt" "zcat /proc/config.gz 2>&1"
dcmd "modules/kernel_config_touch.txt" "zcat /proc/config.gz 2>/dev/null | grep -iE 'touchscreen|focal|nt36|himax|0flash'"
dcmd "modules/init_modprobe_scripts.txt" "cat /vendor/bin/init.modprobe.sh /vendor/bin/vendor_modprobe.sh 2>&1"
dcmd "reference/getprop_sorted.txt" "getprop | sort"
dcmd "reference/settings_global_sorted.txt" "settings list global | sort"
dcmd "reference/settings_secure_sorted.txt" "settings list secure | sort"
dcmd "reference/settings_system_sorted.txt" "settings list system | sort"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [22/35] Pulling configuration files (small, no root needed)"
# ═══════════════════════════════════════════════════════════════════
dpull /vendor/build.prop pulled/vendor
dpull /system/build.prop pulled/system
dpull /vendor/etc/init pulled/vendor_etc
dpull /vendor/etc/vintf pulled/vendor_etc
dpull /system/etc/init pulled/system_etc
dpull /vendor/lib/modules/modules.load pulled/modules
dpull /vendor/lib/modules/modules.dep pulled/modules
dpull /vendor/lib/modules/modules.alias pulled/modules
for f in $(adb shell 'ls /vendor/bin/init*.sh /vendor/bin/*modprobe*.sh 2>/dev/null' | tr -d '\r'); do dpull "$f" pulled/vendor_bin; done

# ═══════════════════════════════════════════════════════════════════
echo "▶ [24/35] Boot history, reboot reasons & crash records"
# ═══════════════════════════════════════════════════════════════════
dcmd "boot/boot_reason_props.txt" "getprop | grep -iE 'boot.reason|bootreason|ro.boottime|boot_completed|bootanim|sys.boot'"
dcmd "boot/pstore.txt" 'ls -la /sys/fs/pstore/ 2>&1; for f in /sys/fs/pstore/*; do echo "=== $f ==="; tail -n 300 "$f" 2>&1; done'
dcmd "boot/last_kmsg.txt" "cat /proc/last_kmsg 2>&1 | tail -n 300"
dcmd "boot/bootstat.txt" 'ls -la /data/misc/bootstat/ 2>&1; cat /data/misc/bootstat/* 2>&1 | head -200'
dcmd "boot/recovery_logs.txt" 'ls -la /cache/recovery /data/misc/recovery 2>&1; for f in /cache/recovery/last_log /cache/recovery/last_install /data/misc/recovery/*; do echo "=== $f ==="; tail -n 200 "$f" 2>&1; done'
dcmd "boot/events_boot_progress.txt" "logcat -d -b events | grep -iE 'boot_progress|watchdog|system_server' | head -200"
dcmd "boot/logcat_buffer_stats.txt" "logcat -g; logcat -b all -S 2>&1 | head -40"
dcmd "boot/logcat_all_full.txt" "logcat -b all -d -v threadtime,year"
dcmd "boot/dropbox_list.txt" "dumpsys dropbox 2>&1 | head -100"
dcmd "boot/dropbox_print.txt" "dumpsys dropbox --print 2>&1 | head -c 8000000"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [25/35] Hardware probe: buses, subsystems, device tree, input, LEDs, USB-C"
# ═══════════════════════════════════════════════════════════════════
dcmd "hardware/spi_i2c_devices.txt" 'for d in /sys/bus/spi/devices/* /sys/bus/i2c/devices/* /sys/bus/platform/devices/*; do [ -e "$d" ] || continue; echo "$d driver=$(basename "$(readlink "$d/driver" 2>/dev/null)") name=$(cat "$d/name" 2>/dev/null) modalias=$(cat "$d/modalias" 2>/dev/null)"; done'
dcmd "hardware/devices_deferred.txt" "cat /sys/kernel/debug/devices_deferred 2>&1"
dcmd "hardware/subsystems.txt" 'for d in /sys/bus/msm_subsys/devices/*; do echo "$d name=$(cat "$d/name" 2>/dev/null) state=$(cat "$d/state" 2>/dev/null) restart_level=$(cat "$d/restart_level" 2>/dev/null) crash_count=$(cat "$d/crash_count" 2>/dev/null)"; done; ls /sys/class/remoteproc 2>&1'
dcmd "hardware/device_tree_mmi.txt" 'cat /proc/device-tree/model 2>&1; echo; for f in /proc/device-tree/chosen/mmi,* /proc/device-tree/chosen/bootargs; do echo "$f: $(cat "$f" 2>/dev/null | tr -d "\000")"; done'
dcmd "hardware/proc_hw.txt" 'ls -laR /proc/hw 2>&1 | head -60; for f in /proc/hw/*/*; do [ -f "$f" ] && echo "$f: $(cat "$f" 2>/dev/null)"; done'
dcmd "hardware/soc_info.txt" 'for f in /sys/devices/soc0/*; do [ -f "$f" ] && echo "$(basename "$f"): $(cat "$f" 2>/dev/null)"; done'
dcmd "hardware/input_device_names.txt" 'for d in /sys/class/input/input*; do echo "$d: $(cat "$d/name" 2>/dev/null)"; done; ls -l /dev/input/'
dcmd "hardware/dev_listing_labels.txt" "ls -lZ /dev/ 2>&1 | head -400"
dcmd "hardware/hwmon_iio.txt" 'for d in /sys/class/hwmon/hwmon*; do echo "$d name=$(cat "$d/name" 2>/dev/null)"; done; for d in /sys/bus/iio/devices/iio:device*; do echo "$d name=$(cat "$d/name" 2>/dev/null)"; done'
dcmd "hardware/leds.txt" 'for d in /sys/class/leds/*; do echo "$d brightness=$(cat "$d/brightness" 2>/dev/null) max=$(cat "$d/max_brightness" 2>/dev/null)"; done'
dcmd "hardware/headset_extcon.txt" 'for f in /sys/class/switch/*/state /sys/class/extcon/*/state /sys/class/extcon/*/name; do echo "$f: $(cat "$f" 2>/dev/null)"; done'
dcmd "hardware/typec_pd.txt" 'ls -la /sys/class/typec/ 2>&1; for f in /sys/class/typec/*/data_role /sys/class/typec/*/power_role /sys/class/typec/*/power_operation_mode; do echo "$f: $(cat "$f" 2>/dev/null)"; done'
dcmd "hardware/power_supply_uevents.txt" 'for d in /sys/class/power_supply/*; do echo "=== $d ==="; cat "$d/uevent" 2>/dev/null; done'
dcmd "hardware/rtc.txt" 'for f in /sys/class/rtc/rtc0/name /sys/class/rtc/rtc0/date /sys/class/rtc/rtc0/time /sys/class/rtc/rtc0/since_epoch; do echo "$f: $(cat "$f" 2>/dev/null)"; done; date'
dcmd "hardware/proc_hw_tables.txt" "cat /proc/interrupts; cat /proc/iomem 2>&1 | head -150; cat /proc/devices; cat /proc/misc"
dcmd "hardware/kernel_sysctl.txt" 'for f in panic panic_on_oops printk kptr_restrict dmesg_restrict perf_event_paranoid sched_energy_aware; do echo "kernel.$f: $(cat /proc/sys/kernel/$f 2>&1)"; done; for f in swappiness min_free_kbytes overcommit_memory vfs_cache_pressure; do echo "vm.$f: $(cat /proc/sys/vm/$f 2>&1)"; done'

# ═══════════════════════════════════════════════════════════════════
echo "▶ [26/35] Firmware, modem partitions & persist"
# ═══════════════════════════════════════════════════════════════════
dcmd "firmware/mounts_firmware.txt" "mount | grep -iE 'firmware|modem|persist|bt_firmware|dsp|vendor|odm|metadata'"
dcmd "firmware/firmware_dirs.txt" "ls -la /vendor/firmware /vendor/firmware_mnt /vendor/firmware_mnt/image /vendor/bt_firmware /vendor/dsp /vendor/radio /firmware 2>&1 | head -300"
dcmd "firmware/modem_ver_info.txt" "cat /vendor/firmware_mnt/verinfo/ver_info.txt 2>&1; getprop gsm.version.baseband; getprop ro.boot.baseband; getprop ro.boot.radio"
dcmd "firmware/persist_listing.txt" "ls -laR /mnt/vendor/persist 2>&1 | head -300"
dcmd "firmware/wlan_bt_config_files.txt" "ls -la /vendor/firmware/wlan/qca_cld /vendor/etc/wifi /vendor/etc/bluetooth 2>&1 | head -200"
dcmd "firmware/kernel_firmware_requests.txt" "dmesg | grep -iE 'firmware' | tail -150"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [27/35] GPU, memory, storage & I/O"
# ═══════════════════════════════════════════════════════════════════
dcmd "gpu/kgsl.txt" 'for f in gpu_model gpuclk max_gpuclk min_clock_mhz thermal_pwrlevel gpu_busy_percentage gpubusy idle_timer num_pwrlevels devfreq/cur_freq devfreq/available_frequencies devfreq/governor; do echo "$f: $(cat /sys/class/kgsl/kgsl-3d0/$f 2>&1)"; done'
dcmd "gpu/gpu_props.txt" "getprop | grep -iE 'gpu|egl|vulkan|opengl|gles|hwui|renderer|debug.sf|ro.sf'"
dcmd "gpu/devfreq.txt" 'for d in /sys/class/devfreq/*; do echo "$d cur=$(cat "$d/cur_freq" 2>/dev/null) gov=$(cat "$d/governor" 2>/dev/null) min=$(cat "$d/min_freq" 2>/dev/null) max=$(cat "$d/max_freq" 2>/dev/null)"; done'
dcmd "memory/free_pressure_swaps.txt" "free -m 2>&1; cat /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io 2>&1; cat /proc/swaps"
dcmd "memory/zram.txt" 'for f in disksize comp_algorithm mm_stat orig_data_size; do echo "$f: $(cat /sys/block/zram0/$f 2>&1)"; done'
dcmd "memory/lmk_props.txt" "getprop | grep -iE 'lmk|lowmemory|zram|swap|extra_free|ro.config.low_ram'"
dcmd "memory/dumpsys_meminfo.txt" "dumpsys meminfo | head -150"
dcmd "storage/partitions.txt" "cat /proc/partitions; ls -l /dev/block/by-name 2>&1; cat /proc/filesystems"
dcmd "storage/fstab.txt" "cat /vendor/etc/fstab.* 2>&1; mount"
dcmd "storage/emmc_ufs_health.txt" 'for d in /sys/block/mmcblk0/device /sys/devices/platform/soc/*.ufshc; do echo "== $d"; for n in life_time pre_eol_info name manfid date fwrev rev; do [ -e "$d/$n" ] && echo "$n: $(cat "$d/$n" 2>&1)"; done; done; ls /sys/block'
dcmd "storage/f2fs_stats.txt" 'for d in /sys/fs/f2fs/*; do echo "== $d"; for n in dirty_segments free_segments lifetime_write_kbytes; do [ -e "$d/$n" ] && echo "$n: $(cat "$d/$n")"; done; done; cat /proc/fs/f2fs/*/status 2>/dev/null | head -60'
dcmd "storage/io_schedulers.txt" 'for d in /sys/block/*/queue/scheduler; do echo "$d: $(cat $d)"; done'

# ═══════════════════════════════════════════════════════════════════
echo "▶ [28/35] Security stack: keystore/KeyMint/TEE, DRM/Widevine, verified boot, SELinux"
# ═══════════════════════════════════════════════════════════════════
dcmd "security/keystore_hals_and_tee.txt" "lshal --neat 2>/dev/null | grep -iE 'keymaster|keymint|gatekeeper|weaver|strongbox|confirmationui|secure_element|oemlock|boot'; ps -A | grep -iE 'keymaster|keymint|gatekeeper|keystore|qseecom|qsee|tzd|weaver'; ls -l /dev/qseecom /dev/ion 2>&1"
dcmd "security/tee_dmesg.txt" "dmesg | grep -iE 'qseecom|keymaster|keymint|tzapp|tee|smcinvoke|qtee|hdcp' | tail -150"
dcmd "security/verified_boot_props.txt" "getprop | grep -iE 'verifiedbootstate|veritymode|vbmeta|flash.locked|boot.avb|avb|secure_boot|ro.secure|ro.debuggable|ro.adb.secure|oem_unlock|crypto'"
dcmd "security/drm_widevine.txt" "dumpsys media.drm 2>&1 | head -200; getprop | grep -iE 'drm|widevine|hdcp'; ls -l /vendor/lib64/mediadrm /vendor/lib/mediadrm 2>&1; ps -A | grep -iE 'drm|widevine|clearkey'"
dcmd "security/security_services.txt" "service list | grep -iE 'keystore|security|biometric|fingerprint|face|gatekeeper'"
dcmd "security/selinux_policy_info.txt" "getenforce; cat /sys/fs/selinux/policyvers 2>&1; ls -lZ /vendor/etc/selinux 2>&1 | head -30"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [29/35] Media, codecs & video devices"
# ═══════════════════════════════════════════════════════════════════
dcmd "media/dumpsys_media_codec.txt" "dumpsys media.codec 2>&1 | head -c 4000000"
dcmd "media/media_services.txt" "dumpsys media.player 2>&1 | head -100; dumpsys media.extractor 2>&1 | head -100; dumpsys media.resource_manager 2>&1 | head -100"
dcmd "media/media_session.txt" "dumpsys media_session | head -100"
dcmd "media/codec_files.txt" "ls -la /vendor/etc/media_codecs*.xml /vendor/etc/media_profiles*.xml 2>&1; ls /vendor/lib64 | grep -iE 'omx|codec2|c2' | head -80"
dcmd "media/media_props.txt" "getprop | grep -iE 'media|codec|omx|c2|vpp|vidc|venus'"
dcmd "media/video_devices.txt" 'ls -l /dev/video* /dev/media* /dev/v4l-subdev* 2>&1 | head -80; cat /sys/class/video4linux/*/name 2>/dev/null'
dcmd "media/venus_dmesg.txt" "dmesg | grep -iE 'venus|vidc|msm_vidc|video' | tail -120"
dcmd "media/nfc_extra.txt" "dumpsys nfc 2>&1 | head -150; ls -l /dev | grep -iE 'nq|nci|pn5|nfc|st21'"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [30/35] Declared features, permissions, libraries, HALs & VINTF"
# ═══════════════════════════════════════════════════════════════════
dcmd "platform/system_features.txt" "pm list features | sort"
dcmd "platform/shared_libraries.txt" "pm list libraries | sort"
dcmd "platform/permission_xml_listing.txt" "ls -la /vendor/etc/permissions /system/etc/permissions /product/etc/permissions /system_ext/etc/permissions /odm/etc/permissions 2>&1"
dcmd "platform/hardware_feature_xmls.txt" 'for f in $(ls /vendor/etc/permissions/*.xml /system/etc/permissions/*.xml /product/etc/permissions/*.xml 2>/dev/null | grep -iE "telephony|ims|sip|radio|fingerprint|nfc|camera|wifi|bluetooth|sensor|usb|audio|location|gps|vibrat"); do echo "=== $f ==="; cat "$f"; done'
dcmd "platform/lshal_full.txt" "lshal 2>&1"
dcmd "platform/lshal_neat.txt" "lshal --neat 2>&1"
dcmd "platform/vintf_as_init_sees_it.txt" "lshal --init-vintf 2>&1 | head -c 2000000"
dcmd "platform/cmd_services.txt" "cmd -l 2>&1"
dcmd "platform/partition_build_props.txt" "ls -la /vendor/build.prop /system/build.prop /odm/etc/build.prop /product/etc/build.prop /system_ext/etc/build.prop 2>&1; cat /vendor/build.prop /odm/etc/build.prop 2>/dev/null"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [31/35] File inventory with SELinux labels (spots missing or mislabeled files)"
# ═══════════════════════════════════════════════════════════════════
dcmd "inventory/ls_vendor_labels.txt" "ls -lRZ /vendor 2>&1"
dcmd "inventory/ls_odm_product_system_ext.txt" "ls -lRZ /odm /product /system_ext 2>&1 | head -c 10000000"
dcmd "inventory/ls_system_bin_etc.txt" "ls -lZ /system/bin /system/etc /system/lib64 2>&1 | head -c 8000000"
dcmd "inventory/ps_with_contexts.txt" "ps -AZ"
dcmd "inventory/root_and_data_dirs.txt" "ls -laZ / 2>&1; ls -laZ /data /data/vendor /mnt/vendor 2>&1 | head -150"
[ "$HASH_VENDOR" = 1 ] && TMO=900 dcmd "inventory/vendor_sha1.txt" "find /vendor -type f -exec sha1sum {} + 2>&1"

# ═══════════════════════════════════════════════════════════════════
echo "▶ [32/35] Catch-all: dumpsys of EVERY registered service (finds areas nobody listed)"
# ═══════════════════════════════════════════════════════════════════
if [ "$ALL_SERVICES" = 1 ]; then
  SKIP_SVC=" account usagestats appops clipboard autofill backup device_policy lock_settings trust contentsuggestions companiondevice credential content_capture voiceinteraction notification sip user "
  HEAVY_SVC=" package activity window batterystats procstats gfxinfo "
  mkdir -p "$OUTDIR/dumpsys_all"
  adb shell 'dumpsys -l' 2>/dev/null | tr -d '\r' | sed '1d;s/^ *//;/^$/d' > "$OUTDIR/dumpsys_all/_service_names.txt"
  while IFS= read -r svc; do
    case "$SKIP_SVC" in *" $svc "*) echo "$svc (skipped: private data)" >> "$OUTDIR/dumpsys_all/_skipped.txt"; continue ;; esac
    if [ "$LIGHT" = 1 ]; then case "$HEAVY_SVC" in *" $svc "*) echo "$svc (skipped: LIGHT=1)" >> "$OUTDIR/dumpsys_all/_skipped.txt"; continue ;; esac; fi
    dcmd "dumpsys_all/$(printf '%s' "$svc" | tr '/ ' '__').txt" "dumpsys $svc | head -c 8000000"
  done < "$OUTDIR/dumpsys_all/_service_names.txt"
else
  echo "    (ALL_SERVICES=0: skipped)"
fi

# ═══════════════════════════════════════════════════════════════════
if [ "$BUGREPORT" = 1 ]; then
  echo "▶ [33/35] Full bugreport (takes a few minutes)"
  adb bugreport "$OUTDIR/bugreport.zip" >"$OUTDIR/bugreport.log" 2>&1 || true
fi

# ═══════════════════════════════════════════════════════════════════
if [ "$REPRO_SIM1" = 1 ]; then
  echo "▶ [34/35] Reproduce the SIM 1 call failure"
  adb logcat -b all -c >/dev/null 2>&1 || true
  echo "    Place a call from SIM 1 now (let it fail), then press Enter here."
  if [ -t 0 ]; then read -r _; else sleep "$REPRO_WAIT"; fi
  dcmd "repro/radio.txt" "logcat -d -b radio"
  dcmd "repro/main_telephony.txt" "logcat -d -b main,system | grep -iE 'ims|volte|telephony|RILJ|dial|telecom|call|slot|phoneid'"
  dcmd "repro/telecom.txt" "dumpsys telecom"
  dcmd "repro/telephony_registry.txt" "dumpsys telephony.registry"
  dcmd "repro/isub.txt" "dumpsys isub"
fi

# ═══════════════════════════════════════════════════════════════════
if [ "$GUIDED" = 1 ]; then
  echo "▶ [35/35] Guided feature tests: use each feature; the logs of every step are saved separately in guided/"
  GUIDED_STEPS=(
    "touch|Touch, swipe and pinch on the screen for 10 seconds"
    "display|Change brightness from minimum to maximum, switch dark mode, rotate the phone, lock and unlock the screen"
    "camera_rear|Open the camera: take 3 photos with the REAR camera (tap to focus, zoom, flash once)"
    "camera_video|Record a 15 second video with the rear camera and play it back"
    "camera_front|Switch to the FRONT camera: take a photo and a 5 second video"
    "audio_speaker|Play music or a video on the LOUD SPEAKER and change the volume"
    "audio_headset|Plug in wired headphones if you have them, play audio, unplug"
    "mic_record|Record a 10 second voice memo and play it back"
    "bluetooth|Turn Bluetooth on, connect a headset, play audio for 10 seconds, disconnect"
    "wifi|Turn Wi-Fi off and on, connect to a 2.4 GHz then a 5 GHz network, open a web page"
    "hotspot|Turn the Wi-Fi hotspot on, connect another device, turn it off"
    "usb_tether|Connect USB to a PC, turn USB tethering on, then off"
    "data_sim1|Make SIM 1 the mobile data SIM (Wi-Fi off) and load a web page"
    "data_sim2|Make SIM 2 the mobile data SIM (Wi-Fi off) and load a web page"
    "call_sim1|Place a call from SIM 1 (it may fail), then hang up"
    "call_sim2|Place a call from SIM 2, then hang up"
    "sms_sim1|Send an SMS from SIM 1"
    "sms_sim2|Send an SMS from SIM 2"
    "incoming_call|Have someone call each SIM in turn; answer and hang up"
    "volte|With VoLTE on, place a call and check whether the status bar shows VoLTE or HD"
    "nfc|Turn NFC on and tap an NFC tag or another phone"
    "gps|Open a maps app near a window or outdoors for 60 seconds to get a GPS fix"
    "fingerprint|Unlock with the fingerprint 5 times"
    "sensors|Rotate the phone, cover the proximity sensor during a call, change the light on the front"
    "vibration|Turn on vibration and haptic feedback, type on the keyboard, receive a call"
    "flashlight|Turn the flashlight on and off"
    "charging|Plug in the charger, wait 20 seconds, unplug"
    "sleep_wake|Lock the screen, wait 60 seconds, wake it"
  )
  mkdir -p "$OUTDIR/guided"; gn=0
  for gs in "${GUIDED_STEPS[@]}"; do
    gn=$((gn+1)); gkey=${gs%%|*}; gtext=${gs#*|}
    if [ -n "$GUIDED_ONLY" ]; then case " $GUIDED_ONLY " in *" $gkey "*) ;; *) continue ;; esac; fi
    adb logcat -b all -c >/dev/null 2>&1 || true
    printf '\n  ▶ Step %s (%s): %s\n    Do it now, then press Enter (type s then Enter to skip; without a terminal it waits %s s).\n' "$gn" "$gkey" "$gtext" "$REPRO_WAIT"
    gans=""; if [ -t 0 ]; then read -r gans; else sleep "$REPRO_WAIT"; fi
    if [ "$gans" = s ]; then echo "$gkey" >> "$OUTDIR/guided/_skipped.txt"; continue; fi
    dcmd "guided/$(printf '%02d' "$gn")_${gkey}.log" "logcat -b all -d -v threadtime; echo '--- dmesg tail ---'; dmesg | tail -n 300"
  done
fi

# ═══════════════════════════════════════════════════════════════════
# Generate a quick summary report
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "▶ Generating summary..."

{
  echo "═══════════════════════════════════════════════════════════════"
  echo " DEVICE DIAGNOSTIC SUMMARY"
  echo " Generated: $(date)"
  echo "═══════════════════════════════════════════════════════════════"
  echo ""

  echo "── Device ──"
  cat "$OUTDIR/info/lineage_version.txt" 2>/dev/null
  cat "$OUTDIR/info/kernel_version.txt" 2>/dev/null
  cat "$OUTDIR/info/build_type.txt" 2>/dev/null
  echo ""

  echo "── Critical: CPU Governor ──"
  grep -E "governor:" "$OUTDIR/cpu/governors.txt" 2>/dev/null
  echo ""

  echo "── Critical: Touch ──"
  grep -E "mode -|isActive" "$OUTDIR/touch/dumpsys_input.txt" 2>/dev/null | head -5
  cat "$OUTDIR/touch/fts_fw_version.txt" 2>/dev/null
  cat "$OUTDIR/touch/fts_panel_supplier.txt" 2>/dev/null
  echo ""

  echo "── Critical: Thermal ──"
  grep "Temperature{" "$OUTDIR/thermal/dumpsys_thermalservice.txt" 2>/dev/null | head -12
  echo ""

  echo "── Critical: post_boot status ──"
  cat "$OUTDIR/cpu/post_boot_service_status.txt" 2>/dev/null
  echo ""

  echo "── Root / shell ──"
  cat "$OUTDIR/info/root_status.txt" 2>/dev/null
  echo ""

  echo "── Kernel modules: modules.load and touch modules ──"
  cat "$OUTDIR/modules/modules_load.txt" 2>/dev/null
  grep -iE "focal|nova|nt36|fts|himax" "$OUTDIR/modules/lsmod.txt" 2>/dev/null || echo "(no touch module loaded)"
  head -6 "$OUTDIR/touch/sys_class_touchscreen.txt" 2>/dev/null
  echo ""

  echo "── Crashed/Stopped Services ──"
  cat "$OUTDIR/services/crashed_services.txt" 2>/dev/null
  echo ""

  echo "── SELinux Denials (count) ──"
  wc -l < "$OUTDIR/selinux/all_denials_dmesg.txt" 2>/dev/null || echo "0"
  echo ""

  echo "── Tombstones ──"
  cat "$OUTDIR/crashes/tombstone_list.txt" 2>/dev/null | head -10
  echo ""

  echo "── SIM State ──"
  grep "gsm.sim.state" "$OUTDIR/info/build_props.txt" 2>/dev/null
  echo ""

  echo "── Battery ──"
  grep -E "level:|status:|temperature:|health:" "$OUTDIR/dumpsys/battery.txt" 2>/dev/null
  echo ""

  echo "── WiFi ──"
  grep "mIfaceIsUp" "$OUTDIR/dumpsys/wifi.txt" 2>/dev/null
  grep "STA.*AP.*Concurrency" "$OUTDIR/dumpsys/wifi.txt" 2>/dev/null
  echo ""

  echo "── USB Tethering ──"
  grep "mUsbTetheringFunction" "$OUTDIR/dumpsys/tethering.txt" 2>/dev/null
  grep "Offload HAL" "$OUTDIR/dumpsys/tethering.txt" 2>/dev/null
  echo ""

} > "$OUTDIR/SUMMARY.txt"

cat "$OUTDIR/SUMMARY.txt"

# ---------------------------------------------------------------------------
# Which areas could NOT be collected (so an empty file is never mistaken for "no problem")
# ---------------------------------------------------------------------------
{
  echo "Collection report: $(find "$OUTDIR" -type f | wc -l) files collected"
  echo "--- empty files ---"; find "$OUTDIR" -type f -empty | sed "s|$OUTDIR/||" | sort
  echo "--- files whose content is only an error (permission denied / not found / unknown option / inaccessible) ---"
  find "$OUTDIR" -type f -size -2k -print0 2>/dev/null | while IFS= read -r -d '' f; do
    grep -Iq . "$f" 2>/dev/null || continue
    if [ "$(grep -c . "$f")" -le 3 ] && grep -qiE 'permission denied|not found|unknown option|inaccessible|no such file|operation not permitted|exceeds|not allowed' "$f"; then echo "${f#$OUTDIR/}: $(head -1 "$f" | cut -c1-100)"; fi
  done | sort
} > "$OUTDIR/_collection_report.txt" 2>/dev/null
echo "  Collection report: $OUTDIR/_collection_report.txt ($(grep -c . "$OUTDIR/_collection_report.txt") lines; list of areas that came back empty or denied)"
if [ "$ANALYZE" = 1 ] && [ -f "$(dirname "$0")/analyze_dump.sh" ]; then
  bash "$(dirname "$0")/analyze_dump.sh" "$OUTDIR" >/dev/null 2>&1 || true
  [ -f "$OUTDIR/ANALYSIS.txt" ] && echo "  Analysis (common error signatures, leads only): $OUTDIR/ANALYSIS.txt"
fi

# ---------------------------------------------------------------------------
# Redacted copy (best effort): share THIS one, not the raw directory
# ---------------------------------------------------------------------------
redact_tree() {
  find "$1" -type f -size -60M -print0 | while IFS= read -r -d '' f; do
    # Skip real binaries by extension, but NEVER skip a text file just because
    # grep calls it binary. /proc/device-tree/chosen/bootargs contains NUL
    # bytes and carries androidboot.serialno + wifimacaddr + btmacaddr; the
    # old `grep -Iq .` guard skipped exactly that file and leaked the serial
    # and all three MACs into the "-redacted" copy.
    case "$f" in
      *.so|*.apk|*.jar|*.dex|*.odex|*.vdex|*.art|*.oat|*.img|*.bin|*.png|*.jpg|*.jpeg|*.gif|*.webp|*.zip|*.gz|*.tgz|*.tar|*.db|*.sqlite|*.mp4|*.mp3|*.ogg|*.ttf|*.otf) continue ;;
    esac
    if command -v perl >/dev/null 2>&1; then
      # Perl is byte-oriented: it handles NULs and invalid UTF-8, which
      # MSYS/Windows sed rejects with "stream did not contain valid UTF-8".
      perl -i -pe '
        s/[0-9]{15,20}/<ID-REDACTED>/g;
        s/\+[0-9]{8,15}/+<NUMBER-REDACTED>/g;
        s/([0-9][0-9 ()-]{6,}[0-9])/<NUMBER-REDACTED>/g if /[Nn]umber|msisdn|MSISDN|[Ll]ine1|mdn=/;
        s/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/xx:xx:xx:xx:xx:xx/g;
        s/(serial[A-Za-z_.]*\]?[:=] ?\[?)[A-Za-z0-9]{6,}/$1<REDACTED>/ig;
        s/(SSID[:=] ?)"?[^",\r\n]+"?/$1"<SSID>"/ig;
        s/(wpa_passphrase|psk)=.*/$1=<REDACTED>/ig;
        s/^(android_id|bluetooth_address|bluetooth_name|device_name)=.*/$1=<REDACTED>/;
        s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g;
      ' "$f" 2>/dev/null
    else
      LC_ALL=C sed -E -i \
        -e 's/[0-9]{15,20}/<ID-REDACTED>/g' \
        -e 's/\+[0-9]{8,15}/+<NUMBER-REDACTED>/g' \
        -e '/[Nn]umber|msisdn|MSISDN|[Ll]ine1|mdn=/ s/[0-9][0-9 ()-]{6,}[0-9]/<NUMBER-REDACTED>/g' \
        -e 's/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/xx:xx:xx:xx:xx:xx/g' \
        -e 's/(serial[A-Za-z_.]*\]?[:=] ?\[?)[A-Za-z0-9]{6,}/\1<REDACTED>/Ig' \
        -e 's/(SSID[:=] ?)"?[^",]+"?/\1"<SSID>"/Ig' \
        -e 's/(wpa_passphrase|psk)=.*/\1=<REDACTED>/Ig' \
        -e 's/^(android_id|bluetooth_address|bluetooth_name|device_name)=.*/\1=<REDACTED>/' \
        -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g' \
        "$f" 2>/dev/null
    fi
  done
}
# Exactly two outputs: the raw directory + one archive. With REDACT=1 the
# archive is made from a temporary redacted tree; the redacted tree itself is
# deleted. With REDACT=0 the archive is the raw directory.
ARCHIVE="${OUTDIR%/}.tar.gz"
rm -f "$ARCHIVE"
if [ "$REDACT" = 1 ]; then
  RED_TMP=$(mktemp -d "${TMPDIR:-/tmp}/doha-redact.XXXXXX") || exit 1
  mkdir -p "$RED_TMP/$(basename "$OUTDIR")"
  cp -a "$OUTDIR/." "$RED_TMP/$(basename "$OUTDIR")/"
  redact_tree "$RED_TMP/$(basename "$OUTDIR")"
  tar czf "$ARCHIVE" -C "$RED_TMP" "$(basename "$OUTDIR")" 2>/dev/null || true
  rm -rf "$RED_TMP"
  echo "  Archive: $ARCHIVE (redacted best effort: IMEI/ICCID/IMSI, +numbers, serials, MACs, SSIDs, hotspot passwords, emails)."
else
  tar czf "$ARCHIVE" -C "$(dirname "$OUTDIR")" "$(basename "$OUTDIR")" 2>/dev/null || true
  echo "  Archive: $ARCHIVE (raw: contains identifiers because REDACT=0)."
fi

# Final size
TOTAL_SIZE=$(du -sh "$OUTDIR" | cut -f1)

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   ✅ Diagnostic dump complete!                              ║"
echo "║   Output: $OUTDIR ($TOTAL_SIZE)"
echo "║   Archive: $ARCHIVE"
echo "║                                                              ║"
echo "║   Key files to review first:                                 ║"
echo "║     SUMMARY.txt            — Quick health overview           ║"
echo "║     kernel/dmesg_crash.txt — Kernel crashes/FORTIFY          ║"
echo "║     kernel/dmesg_touch.txt — Touch driver logs               ║"
echo "║     kernel/dmesg_selinux.txt — SELinux denials               ║"
echo "║     logcat/fatal_only.txt  — All fatal crashes               ║"
echo "║     crashes/tombstones/    — Native crash dumps              ║"
echo "║     cpu/governors.txt      — CPU governor state              ║"
echo "║     touch/fts_*.txt        — Touch IC state                  ║"
echo "║     telephony/             — SIM & call diagnostics          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
