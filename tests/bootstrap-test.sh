#!/bin/bash
# Tests bootstrap.sh's config validation and the launchd/spotifyd templates,
# without touching the machine. Runs on macOS, Linux or Git Bash.
#
#   ./tests/bootstrap-test.sh
#
# Plists are checked with plutil (macOS) or Python's plistlib; the spotifyd
# TOML with Python 3.11+ tomllib (found via python3, python or uv).

# Single-quoted strings below are evaluated later, on purpose.
# shellcheck disable=SC2016
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
. "$ROOT/bootstrap.sh"
set +e +o pipefail   # bootstrap.sh turns these on; the checks below expect failures

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

PASS=0 FAILED=0
check() {
  if "${@:2}"; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"
  else FAILED=$((FAILED + 1)); printf '  FAIL  %s\n' "$1"; fi
}

VALID='DEVICE_NAME="Lobby Audio"
AUDIO_USER="audio"
AUDIO_USER_PASSWORD="pw"
OUTPUT_MATCH="USB"
LOGIN_VOLUME="70"
AIRPLAY_ACCESS="same-network"
SPOTIFY_ENABLED="true"
SPOTIFY_BITRATE="320"
HEALTHCHECK_URL=""
WEEKLY_REBOOT="Mon 05:00"'

# config_with KEY=VALUE...: valid config with some lines replaced or added.
config_with() {
  local cfg=$VALID pair key
  for pair in "$@"; do
    key=${pair%%=*}
    cfg=$(printf '%s\n' "$cfg" | grep -v "^$key=")
    cfg="$cfg"$'\n'"$pair"
  done
  mkdir -p "$T/repo"
  printf '%s\n' "$cfg" > "$T/repo/config.env"
}

# loads OK|FAIL KEY=VALUE...: load_config in a subshell (die exits it).
loads() {
  local want=$1
  shift
  config_with "$@"
  if (REPO_DIR="$T/repo"; load_config) >/dev/null 2>&1; then [ "$want" = OK ]; else [ "$want" = FAIL ]; fi
}

# loaded VAR EXPECTED KEY=VALUE...: value of VAR after load_config.
loaded() {
  local var=$1 want=$2 got
  shift 2
  config_with "$@"
  # shellcheck disable=SC2034  # REPO_DIR is read by load_config
  got=$(REPO_DIR="$T/repo"; load_config >/dev/null 2>&1; eval "printf '%s' \"\$$var\"")
  [ "$got" = "$want" ] || { echo "        $var='$got', expected '$want'"; return 1; }
}

echo "Config validation"
check "valid config loads"                 loads OK
check "host name derived from device name" loaded HOST_SLUG lobby-audio
check "tailscale name defaults to slug"    loaded TAILSCALE_HOSTNAME lobby-audio
check "tailscale name can be set"          loaded TAILSCALE_HOSTNAME cafe-1 'TAILSCALE_HOSTNAME="cafe-1"'
check "slug squeezes punctuation"          loaded HOST_SLUG kevin-s-lobby-2 "DEVICE_NAME=\"Kevin's Lobby 2\""
check "Mon 05:00 -> weekday 1"             loaded REBOOT_WEEKDAY 1
check "Mon 05:00 -> hour 5"                loaded REBOOT_HOUR 5
check "Mon 05:00 -> minute 0"              loaded REBOOT_MINUTE 0
check "Sun 23:59 -> weekday 0"             loaded REBOOT_WEEKDAY 0 'WEEKLY_REBOOT="Sun 23:59"'
check "Sun 23:59 -> minute 59"             loaded REBOOT_MINUTE 59 'WEEKLY_REBOOT="Sun 23:59"'
check "08:09 is not read as octal"         loaded REBOOT_HOUR 8 'WEEKLY_REBOOT="Fri 08:09"'
check "empty WEEKLY_REBOOT is allowed"     loads OK 'WEEKLY_REBOOT=""'
check "rejects day 'Monday'"               loads FAIL 'WEEKLY_REBOOT="Monday 05:00"'
check "rejects time 5:00"                  loads FAIL 'WEEKLY_REBOOT="Mon 5:00"'
check "rejects hour 24"                    loads FAIL 'WEEKLY_REBOOT="Mon 24:00"'
check "rejects quote in device name"       loads FAIL 'DEVICE_NAME="Bad\"Name"'
check "rejects ampersand in device name"   loads FAIL 'DEVICE_NAME="Bar & Grill"'
check "rejects empty device name"          loads FAIL 'DEVICE_NAME=""'
check "rejects AIRPLAY_ACCESS=everyone"    loads FAIL 'AIRPLAY_ACCESS="everyone"'
check "accepts AIRPLAY_ACCESS=current-user" loads OK 'AIRPLAY_ACCESS="current-user"'
check "rejects LOGIN_VOLUME 101"           loads FAIL 'LOGIN_VOLUME="101"'
check "rejects LOGIN_VOLUME abc"           loads FAIL 'LOGIN_VOLUME="abc"'
check "accepts LOGIN_VOLUME 0"             loads OK 'LOGIN_VOLUME="0"'
check "rejects bitrate 128"                loads FAIL 'SPOTIFY_BITRATE="128"'
check "rejects SPOTIFY_ENABLED yes"        loads FAIL 'SPOTIFY_ENABLED="yes"'
check "rejects http healthcheck"           loads FAIL 'HEALTHCHECK_URL="http://hc-ping.com/x"'
check "accepts https healthcheck"          loads OK 'HEALTHCHECK_URL="https://hc-ping.com/x"'
check "rejects uppercase AUDIO_USER"       loads FAIL 'AUDIO_USER="Audio"'
check "rejects empty password"             loads FAIL 'AUDIO_USER_PASSWORD=""'
check "rejects empty OUTPUT_MATCH"         loads FAIL 'OUTPUT_MATCH=""'
check "rejects bad tailscale name"         loads FAIL 'TAILSCALE_HOSTNAME="Cafe_1"'
check "receiver defaults to shairport"     loaded AIRPLAY_RECEIVER shairport
check "accepts AIRPLAY_RECEIVER=builtin"   loads OK 'AIRPLAY_RECEIVER="builtin"'
check "rejects AIRPLAY_RECEIVER=airplay"   loads FAIL 'AIRPLAY_RECEIVER="airplay"'
check "fixed volume defaults to no"        loaded AIRPLAY_FIXED_VOLUME no
check "rejects AIRPLAY_FIXED_VOLUME=1"     loads FAIL 'AIRPLAY_FIXED_VOLUME="1"'
check "Daily 04:30 -> no weekday"          loaded REBOOT_WEEKDAY "" 'REBOOT_SCHEDULE="Daily 04:30"'
check "Daily 04:30 -> hour 4"              loaded REBOOT_HOUR 4 'REBOOT_SCHEDULE="Daily 04:30"'
check "Daily 04:30 -> minute 30"           loaded REBOOT_MINUTE 30 'REBOOT_SCHEDULE="Daily 04:30"'
check "REBOOT_SCHEDULE beats WEEKLY_REBOOT" loaded REBOOT_WEEKDAY 3 'REBOOT_SCHEDULE="Wed 01:00"'
check "empty REBOOT_SCHEDULE turns it off" loaded REBOOT_HOUR "" 'REBOOT_SCHEDULE=""'
check "rejects 'daily' lowercase"          loads FAIL 'REBOOT_SCHEDULE="daily 04:30"'
mkdir -p "$T/repo"
sed 's/^AUDIO_USER_PASSWORD=""/AUDIO_USER_PASSWORD="x"/' "$ROOT/config.env.example" > "$T/repo/config.env"
check "config.env.example validates once a password is set"   eval '(REPO_DIR="$T/repo"; load_config) >/dev/null 2>&1'

# -------------------------------------------------------------- templates

echo "Templates"
WORK_DIR="$T/out"
mkdir -p "$WORK_DIR"
render_template "$ROOT/launchd/$LABEL_AGENT.plist.tmpl" "$WORK_DIR/agent.plist" \
  "LABEL=$LABEL_AGENT" "INSTALL_DIR=$INSTALL_DIR" "AUDIO_HOME=/Users/audio"
render_template "$ROOT/launchd/$LABEL_SPOTIFYD.plist.tmpl" "$WORK_DIR/spotifyd.plist" \
  "LABEL=$LABEL_SPOTIFYD" "SPOTIFYD=/opt/homebrew/bin/spotifyd" \
  "CONF=/Users/audio/.config/spotifyd/spotifyd.conf" "AUDIO_HOME=/Users/audio"
REBOOT_WEEKDAY=1
render_template "$ROOT/launchd/$LABEL_REBOOT.plist.tmpl" "$WORK_DIR/reboot.plist" \
  "LABEL=$LABEL_REBOOT" "WEEKDAY_XML=$(reboot_weekday_xml)" "HOUR=5" "MINUTE=0"
# shellcheck disable=SC2034  # read by reboot_weekday_xml
REBOOT_WEEKDAY=""
render_template "$ROOT/launchd/$LABEL_REBOOT.plist.tmpl" "$WORK_DIR/reboot-daily.plist" \
  "LABEL=$LABEL_REBOOT" "WEEKDAY_XML=$(reboot_weekday_xml)" "HOUR=4" "MINUTE=30"
render_template "$ROOT/launchd/$LABEL_NQPTP.plist.tmpl" "$WORK_DIR/nqptp.plist" \
  "LABEL=$LABEL_NQPTP" "NQPTP=$NQPTP_BIN" "AUDIO_HOME=/Users/audio"
render_template "$ROOT/launchd/$LABEL_SHAIRPORT.plist.tmpl" "$WORK_DIR/shairport.plist" \
  "LABEL=$LABEL_SHAIRPORT" "SHAIRPORT=$SPS_BIN" \
  "CONF=/Users/audio/.config/shairport-sync/shairport-sync.conf" "AUDIO_HOME=/Users/audio"
render_template "$ROOT/templates/spotifyd.conf.tmpl" "$WORK_DIR/spotifyd.conf" \
  "DEVICE_NAME=Kevin's Lobby" "BITRATE=320" "CACHE_DIR=/Users/audio/Library/Caches/spotifyd"
render_template "$ROOT/templates/shairport-sync.conf.tmpl" "$WORK_DIR/shairport-sync.conf" \
  "DEVICE_NAME=Kevin's Lobby" "IGNORE_VOLUME=no"

check "no placeholders left" bash -c "! grep -l '@[A-Z_]*@' '$WORK_DIR'/*"
check "unfilled placeholder is caught" bash -c "
  . '$ROOT/lib/common.sh'
  ! (render_template '$ROOT/launchd/$LABEL_REBOOT.plist.tmpl' '$T/x' LABEL=x) 2>/dev/null"

# Find a Python with tomllib (3.11+).
PY=()
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import tomllib' 2>/dev/null; then PY=("$cand"); break; fi
done
if [ ${#PY[@]} -eq 0 ] && command -v uv >/dev/null 2>&1; then
  PY=(uv run --quiet --no-project --python 3.12 python)
fi

if command -v plutil >/dev/null 2>&1; then
  for f in agent spotifyd reboot reboot-daily nqptp shairport; do
    check "$f.plist passes plutil -lint" plutil -lint -s "$WORK_DIR/$f.plist"
  done
fi

if [ ${#PY[@]} -gt 0 ]; then
  check "plists parse and hold the right values" "${PY[@]}" - "$WORK_DIR" <<'EOF'
import plistlib, sys, os
d = sys.argv[1]
def load(n):
    with open(os.path.join(d, n), "rb") as f:
        return plistlib.load(f)
a = load("agent.plist")
assert a["Label"] == "com.airplaymini.agent", a
assert a["ProgramArguments"] == ["/bin/bash", "/usr/local/airplay-mini/node-agent.sh"], a
assert a["KeepAlive"] is True and a["RunAtLoad"] is True
assert a["StandardOutPath"] == "/Users/audio/Library/Logs/airplay-mini.launchd.log"
s = load("spotifyd.plist")
assert s["ProgramArguments"] == ["/opt/homebrew/bin/spotifyd", "--no-daemon", "--config-path",
                                 "/Users/audio/.config/spotifyd/spotifyd.conf"], s
r = load("reboot.plist")
assert r["StartCalendarInterval"] == {"Weekday": 1, "Hour": 5, "Minute": 0}, r
cmd = r["ProgramArguments"]
assert cmd[:2] == ["/bin/sh", "-c"] and "&&" in cmd[2] and "shutdown -r now" in cmd[2], cmd
rd = load("reboot-daily.plist")
assert rd["StartCalendarInterval"] == {"Hour": 4, "Minute": 30}, rd
n = load("nqptp.plist")
assert n["Label"] == "com.airplaymini.nqptp" and n["ProgramArguments"] == ["/usr/local/bin/nqptp"], n
assert n["KeepAlive"] is True and n["LimitLoadToSessionType"] == "Aqua"
sp = load("shairport.plist")
assert sp["ProgramArguments"] == ["/usr/local/bin/shairport-sync", "-c",
                                  "/Users/audio/.config/shairport-sync/shairport-sync.conf"], sp
assert sp["StandardErrorPath"] == "/Users/audio/Library/Logs/shairport-sync.log"
EOF
  check "spotifyd.conf is valid TOML with the right values" "${PY[@]}" - "$WORK_DIR/spotifyd.conf" <<'EOF'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    g = tomllib.load(f)["global"]
assert g["device_name"] == "Kevin's Lobby", g
assert g["backend"] == "portaudio" and g["bitrate"] == 320 and g["no_audio_cache"] is True, g
EOF
else
  echo "  skip  plist/TOML parsing (no Python 3.11+ or uv found)"
fi

sps_conf="$WORK_DIR/shairport-sync.conf"
check "shairport conf: device name"     grep -qF "name = \"Kevin's Lobby\";" "$sps_conf"
check "shairport conf: CoreAudio"       grep -qF 'output_backend = "coreaudio";' "$sps_conf"
check "shairport conf: macOS mDNS"      grep -qF 'mdns_backend = "dns-sd";' "$sps_conf"
check "shairport conf: volume follows sender" grep -qF 'ignore_volume_control = "no";' "$sps_conf"
check "shairport conf: no session_timeout (must be 0 or >= 60)" bash -c "! grep -q session_timeout '$sps_conf'"
check "shairport conf: braces balanced" bash -c "[ \$(tr -cd '{' < '$sps_conf' | wc -c) -eq \$(tr -cd '}' < '$sps_conf' | wc -c) ]"

echo "Pinned sources"
check "shairport version check accepts the pinned build" bash -c "
  . '$ROOT/lib/common.sh'; . '$ROOT/lib/shairport.sh'
  SPS_BIN='$T/fake-sps'; printf '#!/bin/sh\necho %s-AirPlay2-smi11\n' \"\$SHAIRPORT_VERSION\" > \"\$SPS_BIN\"; chmod +x \"\$SPS_BIN\"
  shairport_ok"
check "shairport version check rejects a classic build" bash -c "
  . '$ROOT/lib/common.sh'; . '$ROOT/lib/shairport.sh'
  SPS_BIN='$T/fake-sps2'; printf '#!/bin/sh\necho %s-OpenSSL-ao\n' \"\$SHAIRPORT_VERSION\" > \"\$SPS_BIN\"; chmod +x \"\$SPS_BIN\"
  ! shairport_ok"
check "nqptp version check" bash -c "
  . '$ROOT/lib/common.sh'; . '$ROOT/lib/shairport.sh'
  NQPTP_BIN='$T/fake-nq'; printf '#!/bin/sh\necho \"Version: %s. Shared Memory Interface Version: smi11.\"\n' \"\$NQPTP_VERSION\" > \"\$NQPTP_BIN\"; chmod +x \"\$NQPTP_BIN\"
  nqptp_ok"
check "missing binary is not ok" bash -c "
  . '$ROOT/lib/common.sh'; . '$ROOT/lib/shairport.sh'
  SPS_BIN='$T/does-not-exist'; ! shairport_ok"

echo "Reboot guard"
# Run the rendered reboot command with sysctl/logger/shutdown swapped for mocks.
if [ ${#PY[@]} -gt 0 ]; then
  "${PY[@]}" -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))["ProgramArguments"][2])' \
    "$WORK_DIR/reboot.plist" > "$T/reboot.cmd"

  mkdir -p "$T/bin"
  cat > "$T/bin/sysctl" <<'EOF'
#!/bin/sh
echo "{ sec = $BOOT, usec = 999999 } Mon Oct 26 05:00:00 2026"
EOF
  cat > "$T/bin/shutdown" <<EOF
#!/bin/sh
echo shutdown "\$@" >> "$T/calls"
EOF
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/logger"
  chmod +x "$T/bin/"*

  sed -e "s#/usr/sbin/sysctl#$T/bin/sysctl#" \
      -e "s#/usr/bin/logger#$T/bin/logger#" \
      -e "s#/sbin/shutdown#$T/bin/shutdown#" \
      -e "s#/usr/bin/sed#sed#" \
      -e "s#/bin/date#date#" \
      "$T/reboot.cmd" > "$T/reboot.sh"

  # run_reboot SECONDS_SINCE_BOOT
  run_reboot() {
    rm -f "$T/calls"
    BOOT=$(( $(date +%s) - $1 )) sh "$T/reboot.sh"
  }
  no_reboot_after() { run_reboot "$1"; [ ! -f "$T/calls" ]; }
  reboots_after()   { run_reboot "$1"; grep -qx 'shutdown -r now' "$T/calls"; }
  check "no reboot 2 minutes after boot" no_reboot_after 120
  check "reboots after 2 hours up"       reboots_after 7200
else
  echo "  skip  reboot guard (no Python)"
fi

echo
echo "$PASS passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
