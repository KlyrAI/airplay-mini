#!/bin/bash
# One-screen health report for IT. Run as the admin user (uses sudo):
#   /usr/local/airplay-mini/status.sh
# Exit code = number of failed checks (0 = healthy).

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

[ -r "$AGENT_ENV" ] || die "$AGENT_ENV not found. Has bootstrap.sh been run?"
# shellcheck source=/dev/null
. "$AGENT_ENV"

sudo -v || die "status.sh needs sudo"

FAILS=0
pass() { printf '  %sok%s    %-16s %s\n' "$C_GREEN" "$C_OFF" "$1" "$2"; }
fail() { printf '  %sFAIL%s  %-16s %s\n' "$C_RED" "$C_OFF" "$1" "$2"; FAILS=$((FAILS + 1)); }
note() { printf '  %s--%s    %-16s %s\n' "$C_YELLOW" "$C_OFF" "$1" "$2"; }

# as_audio CMD...: run inside the audio user's login session, where its
# CoreAudio and preferences live.
AUDIO_UID=$(id -u "$AUDIO_USER" 2>/dev/null || echo "")
as_audio() { sudo launchctl asuser "$AUDIO_UID" sudo -u "$AUDIO_USER" "$@"; }

# browses_as TYPE NAME: true if NAME is advertised as TYPE on the local network.
browses_as() {
  local out
  out=$(mktemp)
  dns-sd -B "$1" local. >"$out" 2>&1 &
  local pid=$!
  sleep 2
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  grep -qF -- "$2" "$out"
  local rc=$?
  rm -f "$out"
  return $rc
}

job_state() { # job_state DOMAIN LABEL -> "running pid 123" / "loaded" / ""
  sudo launchctl print "$1/$2" 2>/dev/null | awk '
    /^\tstate = / { state = $3 }
    /^\tpid = /   { pid = $3 }
    END { if (state != "") { printf "%s", state; if (pid != "") printf " (pid %s)", pid } }'
}

printf '\n%s%s%s  %s, macOS %s, up %s\n' "$C_BLUE" "$(scutil --get ComputerName)" "$C_OFF" \
  "$(hostname -s)" "$(sw_vers -productVersion)" \
  "$(uptime | sed -E 's/.*up +([^,]+(, *[0-9]+:[0-9]+)?),.*/\1/')"
printf '  bootstrap %s, disk free %s\n\n' "${BOOTSTRAP_VERSION:-?}" "$(df -h / | awk 'NR==2 {print $4}')"

# --- session
auto=$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || echo "")
if [ "$auto" = "$AUDIO_USER" ]; then
  pass "auto-login" "$AUDIO_USER"
else
  fail "auto-login" "set to '${auto:-nobody}', expected $AUDIO_USER"
fi

console=$(stat -f %Su /dev/console)
if [ "$console" = "$AUDIO_USER" ]; then
  pass "logged in" "$AUDIO_USER is at the screen"
else
  fail "logged in" "console user is '$console'; audio only plays in $AUDIO_USER's session"
fi

st=$(job_state "gui/$AUDIO_UID" "$LABEL_AGENT")
case "$st" in running*) pass "watchdog" "$st" ;; *) fail "watchdog" "${st:-not loaded}" ;; esac

# --- audio output
if [ "$console" = "$AUDIO_USER" ]; then
  cur=$(as_audio "$BREW_PREFIX/bin/SwitchAudioSource" -c -t output 2>/dev/null | sed 's/ (output)$//')
  case "$cur" in
    *"$OUTPUT_MATCH"*) pass "output" "$cur" ;;
    *) fail "output" "'$cur' does not match '$OUTPUT_MATCH'. Devices: $(as_audio "$BREW_PREFIX/bin/SwitchAudioSource" -a -t output 2>/dev/null | sed 's/ (output)$//' | paste -sd ',' - | sed 's/,/, /g')" ;;
  esac
  vol=$(as_audio osascript -e 'output volume of (get volume settings)' 2>/dev/null)
  muted=$(as_audio osascript -e 'output muted of (get volume settings)' 2>/dev/null)
  if [ "$muted" = "true" ]; then
    fail "volume" "MUTED (volume $vol)"
  elif [ "${AIRPLAY_RECEIVER:-builtin}" = "shairport" ]; then
    note "volume" "${vol:-?} (Mac level; AirPlay volume is applied on top by Shairport Sync)"
  else
    note "volume" "${vol:-?} (the AirPlay sender's slider changes this)"
  fi
fi

# --- AirPlay
receiver=${AIRPLAY_RECEIVER:-builtin}
owner=$(sudo lsof +c 0 -nP -iTCP:7000 -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1}')
builtin_on=$(sudo -u "$AUDIO_USER" defaults -currentHost read com.apple.controlcenter AirplayRecieverEnabled 2>/dev/null || echo "?")
if [ "$receiver" = "shairport" ]; then
  for job in "$LABEL_NQPTP" "$LABEL_SHAIRPORT"; do
    st=$(job_state "gui/$AUDIO_UID" "$job")
    case "$st" in running*) pass "${job#com.airplaymini.}" "$st" ;; *) fail "${job#com.airplaymini.}" "${st:-not loaded} (doctor logs)" ;; esac
  done
  case "$owner" in
    shairport-sync) pass "airplay port" "7000 held by shairport-sync" ;;
    "") fail "airplay port" "nothing on 7000; Shairport Sync not running (doctor restart-airplay)" ;;
    *) fail "airplay port" "7000 held by '$owner', not shairport-sync (built-in receiver back on?)" ;;
  esac
  if [ "$builtin_on" = "1" ]; then
    fail "built-in recv" "macOS's receiver is ON; the watchdog should switch it off within 30 s"
  else
    pass "built-in recv" "off (Shairport Sync is the receiver)"
  fi
else
  if [ -n "$owner" ]; then
    pass "airplay port" "7000 answering ($owner)"
  else
    fail "airplay port" "nothing on 7000; receiver off or ControlCenter stuck"
  fi
  access=$(sudo -u "$AUDIO_USER" defaults -currentHost read com.apple.controlcenter AirplayReceiverAdvertising 2>/dev/null || echo "?")
  note "airplay prefs" "built-in receiver enabled=$builtin_on access=$access (1 user, 2 same network, 3 everyone)"
fi
if browses_as _airplay._tcp "$DEVICE_NAME"; then
  pass "airplay mdns" "'$DEVICE_NAME' advertised on the network"
else
  fail "airplay mdns" "'$DEVICE_NAME' not seen in a 2 s browse"
fi

# --- Spotify Connect
if [ "${SPOTIFY_ENABLED:-false}" = "true" ]; then
  st=$(job_state "gui/$AUDIO_UID" "$LABEL_SPOTIFYD")
  case "$st" in running*) pass "spotifyd" "$st" ;; *) fail "spotifyd" "${st:-not loaded} (log: ~$AUDIO_USER/Library/Logs/spotifyd.log)" ;; esac
  if browses_as _spotify-connect._tcp "$DEVICE_NAME"; then
    pass "spotify mdns" "'$DEVICE_NAME' advertised"
  else
    fail "spotify mdns" "'$DEVICE_NAME' not seen in a 2 s browse"
  fi
else
  note "spotifyd" "off in config"
fi

# --- remote access
ts="$BREW_PREFIX/bin/tailscale"
ts_state=$(sudo "$ts" status --json 2>/dev/null | sed -n 's/.*"BackendState": *"\([A-Za-z]*\)".*/\1/p' | head -n 1)
if [ "$ts_state" = "Running" ]; then
  ssh_on=$(sudo "$ts" debug prefs 2>/dev/null | sed -n 's/.*"RunSSH": *\([a-z]*\).*/\1/p' | head -n 1)
  pass "tailscale" "$(sudo "$ts" ip -4 2>/dev/null | head -n 1), ssh=${ssh_on:-?}"
else
  fail "tailscale" "state '${ts_state:-daemon not reachable}'"
fi
if nc -z -G 2 127.0.0.1 5900 >/dev/null 2>&1; then
  pass "screen sharing" "on (port 5900)"
else
  fail "screen sharing" "off. System Settings > General > Sharing > Screen Sharing"
fi

# --- power and schedule
sleep_v=$(pmset -g | awk '$1 == "sleep" {print $2}')
restart_v=$(pmset -g | awk '$1 == "autorestart" {print $2}')
if [ "$sleep_v" = "0" ] && [ "$restart_v" = "1" ]; then
  pass "power" "never sleeps, restarts after power loss"
else
  fail "power" "sleep=$sleep_v autorestart=$restart_v (want 0 / 1)"
fi
if [ -n "$(job_state system "$LABEL_REBOOT")" ]; then
  note "weekly reboot" "scheduled"
else
  note "weekly reboot" "off"
fi
if [ -n "${HEALTHCHECK_URL:-}" ]; then
  note "healthcheck" "pinging"
else
  note "healthcheck" "off"
fi

# --- recent log
log_file="$(user_home "$AUDIO_USER")/Library/Logs/airplay-mini.log"
printf '\n  last log lines (%s):\n' "$log_file"
if sudo test -f "$log_file"; then
  sudo tail -n 8 "$log_file" | sed 's/^/    /'
else
  echo "    (no log yet)"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  printf '%sAll checks passed.%s\n' "$C_GREEN" "$C_OFF"
else
  printf '%s%d check(s) failed.%s See RUNBOOK.md, "Fixes".\n' "$C_RED" "$FAILS" "$C_OFF"
fi
exit "$FAILS"
