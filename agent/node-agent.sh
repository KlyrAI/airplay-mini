#!/bin/bash
# airplay-mini watchdog. Runs as the audio user (LaunchAgent, KeepAlive).
#
# At start it applies per-user settings: system sounds off, output pinned to
# the DAC, login volume, and the AirPlay receiver setup:
#   - AIRPLAY_RECEIVER=shairport: macOS's built-in receiver is kept OFF (it
#     would hold port 7000 and ask for approval on screen); Shairport Sync and
#     NQPTP run as their own LaunchAgents.
#   - AIRPLAY_RECEIVER=builtin: the built-in receiver is kept on.
# ControlCenter is restarted only when a built-in receiver setting actually
# changed, so a launchd restart of this script never cuts playback.
#
# Then, every 30 s, it keeps the DAC as the default output, restarts the
# AirPlay receiver if it stops answering, watches nqptp/spotifyd, trims logs,
# and pings the healthcheck URL.
#
# bootstrap.sh installs this to /usr/local/airplay-mini. Settings come from
# agent.env next to it. Log: ~/Library/Logs/airplay-mini.log

set -u

# The AIRPLAY_MINI_* overrides exist for tests/agent-test.sh only.
ENV_FILE=${AIRPLAY_MINI_ENV:-/usr/local/airplay-mini/agent.env}
SWITCH=${AIRPLAY_MINI_SWITCH:-/opt/homebrew/bin/SwitchAudioSource}
LOG="$HOME/Library/Logs/airplay-mini.log"
LOG_MAX_BYTES=1048576
OTHER_LOGS="shairport-sync.log nqptp.log spotifyd.log airplay-mini.launchd.log"
OTHER_LOG_MAX_BYTES=5242880

INTERVAL=${AIRPLAY_MINI_INTERVAL:-30}   # seconds between checks
REPORT_AFTER=2       # failed checks before a problem is reported (~1 min)
HEARTBEAT_EVERY=10   # healthy checks between heartbeat pings (~5 min)
TRIM_EVERY=20        # checks between log trims (~10 min)

LABEL_NQPTP="com.airplaymini.nqptp"
LABEL_SHAIRPORT="com.airplaymini.shairport"

# The built-in AirPlay Receiver's settings live in ControlCenter's ByHost
# preferences. Apple does not document these keys ("Reciever" is Apple's
# spelling). Confirm them on new macOS versions with tools/find-airplay-keys.sh.
AIRPLAY_DOMAIN="com.apple.controlcenter"
KEY_ENABLED="AirplayRecieverEnabled"
KEY_ACCESS="AirplayReceiverAdvertising"   # 1 current user, 2 same network, 3 everyone
AIRPLAY_PORT=7000

mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

# Sleep that a TERM from launchd can interrupt (a plain foreground sleep
# delays the trap until it finishes).
nap() { sleep "$1" & wait $!; }

log() {
  local size
  size=$(stat -f %z "$LOG" 2>/dev/null || echo 0)
  if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
    mv -f "$LOG" "$LOG.1"
    exec >>"$LOG" 2>&1
  fi
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

if [ ! -r "$ENV_FILE" ]; then
  log "missing $ENV_FILE; run bootstrap.sh"
  nap 60
  exit 1
fi
# shellcheck source=/dev/null
. "$ENV_FILE"

RECEIVER=${AIRPLAY_RECEIVER:-builtin}

# ---------------------------------------------------------------- healthcheck

# ping_health ok|fail MESSAGE. Runs in the background so a slow network never
# delays the checks.
ping_health() {
  [ -n "${HEALTHCHECK_URL:-}" ] || return 0
  local url=$HEALTHCHECK_URL
  [ "$1" = "fail" ] && url="$url/fail"
  curl -fsS -m 10 --retry 2 --data-raw "$2" "$url" >/dev/null 2>&1 &
}

# ------------------------------------------------------------------ settings

apply_sound_prefs() {
  # Alerts, UI sounds and volume-change clicks would all reach the preamp.
  osascript -e 'set volume alert volume 0' >/dev/null 2>&1
  defaults write com.apple.systemsound com.apple.sound.uiaudio.enabled -int 0
  defaults write -g com.apple.sound.beep.feedback -int 0
  defaults write -g com.apple.sound.beep.volume -float 0
  # No screen saver, so the session never locks.
  defaults -currentHost write com.apple.screensaver idleTime -int 0
}

# Built-in receiver on (with the access level) for "builtin"; off for
# "shairport". Cheap when nothing changed, so it also runs every check in
# shairport mode, in case someone switches the built-in receiver back on.
apply_airplay_prefs() {
  local want_enabled=1 want_access="" changed=0
  if [ "$RECEIVER" = "shairport" ]; then
    want_enabled=0
  else
    case "${AIRPLAY_ACCESS:-same-network}" in
      current-user) want_access=1 ;;
      *)            want_access=2 ;;
    esac
  fi

  if [ "$(defaults -currentHost read "$AIRPLAY_DOMAIN" "$KEY_ENABLED" 2>/dev/null)" != "$want_enabled" ]; then
    if [ "$want_enabled" -eq 1 ]; then
      defaults -currentHost write "$AIRPLAY_DOMAIN" "$KEY_ENABLED" -bool true
    else
      defaults -currentHost write "$AIRPLAY_DOMAIN" "$KEY_ENABLED" -bool false
    fi
    changed=1
  fi
  if [ -n "$want_access" ] \
     && [ "$(defaults -currentHost read "$AIRPLAY_DOMAIN" "$KEY_ACCESS" 2>/dev/null)" != "$want_access" ]; then
    defaults -currentHost write "$AIRPLAY_DOMAIN" "$KEY_ACCESS" -int "$want_access"
    changed=1
  fi

  if [ "$changed" -eq 1 ]; then
    if [ "$want_enabled" -eq 1 ]; then
      log "airplay: built-in receiver on (access ${AIRPLAY_ACCESS:-same-network}); restarting ControlCenter"
    else
      log "airplay: built-in receiver off (Shairport Sync is the receiver); restarting ControlCenter"
    fi
    killall ControlCenter 2>/dev/null
    nap 3
  fi
}

apply_login_volume() {
  local v=${LOGIN_VOLUME:-70}
  osascript -e 'set volume without output muted' -e "set volume output volume $v" >/dev/null 2>&1 \
    && log "output: volume set to $v"
}

# ------------------------------------------------------------------- checks

# Some SwitchAudioSource versions add " (output)" after each name.
current_output()  { "$SWITCH" -c -t output 2>/dev/null | sed 's/ (output)$//'; }
matching_output() { "$SWITCH" -a -t output 2>/dev/null | sed 's/ (output)$//' | grep -F -- "$OUTPUT_MATCH" | head -n 1; }

OUTPUT_STATE=""
check_output() {
  local want cur
  want=$(matching_output)
  if [ -z "$want" ]; then
    if [ "$OUTPUT_STATE" != "missing" ]; then
      log "output: no device matching '$OUTPUT_MATCH' (cable unplugged?)"
      OUTPUT_STATE=missing
    fi
    return 1
  fi
  [ "$OUTPUT_STATE" = "missing" ] && log "output: '$want' is back"
  OUTPUT_STATE=ok

  cur=$(current_output)
  if [ "$cur" != "$want" ]; then
    if "$SWITCH" -t output -s "$want" >/dev/null 2>&1; then
      log "output: switched from '$cur' to '$want'"
    else
      log "output: could not switch to '$want'"
      return 1
    fi
  fi
  return 0
}

running() { pgrep -u "$(id -u)" -x "$1" >/dev/null 2>&1; }

# The receiver answers on port 7000. In shairport mode it must also be
# Shairport Sync holding it, not a built-in receiver someone switched on.
airplay_answering() {
  nc -z -G 2 127.0.0.1 "$AIRPLAY_PORT" >/dev/null 2>&1 || return 1
  [ "$RECEIVER" != "shairport" ] || running shairport-sync
}

restart_receiver() {
  if [ "$RECEIVER" = "shairport" ]; then
    launchctl kickstart -k "gui/$(id -u)/$LABEL_NQPTP" >/dev/null 2>&1
    nap 1
    launchctl kickstart -k "gui/$(id -u)/$LABEL_SHAIRPORT" >/dev/null 2>&1
  else
    killall ControlCenter 2>/dev/null
  fi
}

AIRPLAY_MISSES=0
AIRPLAY_RESTARTS=0
check_airplay() {
  if airplay_answering; then
    [ "$AIRPLAY_MISSES" -gt 0 ] && log "airplay: answering again"
    AIRPLAY_MISSES=0
    AIRPLAY_RESTARTS=0
    return 0
  fi
  AIRPLAY_MISSES=$((AIRPLAY_MISSES + 1))
  [ "$AIRPLAY_MISSES" -eq 1 ] && log "airplay: $RECEIVER receiver not answering on port $AIRPLAY_PORT"

  # Restart after 3 misses (90 s). After 5 restarts in a row, back off to
  # every 10 minutes so a permanent fault doesn't churn.
  local limit=3
  [ "$AIRPLAY_RESTARTS" -ge 5 ] && limit=20
  if [ $((AIRPLAY_MISSES % limit)) -eq 0 ]; then
    AIRPLAY_RESTARTS=$((AIRPLAY_RESTARTS + 1))
    log "airplay: restarting the $RECEIVER receiver (attempt $AIRPLAY_RESTARTS)"
    restart_receiver
  fi
  [ "$AIRPLAY_MISSES" -lt "$REPORT_AFTER" ]
}

# check_process NAME LOGFILE: launchd restarts crashed jobs, so a process
# missing for REPORT_AFTER checks in a row means it keeps crashing.
# shellcheck disable=SC2034  # read through eval in check_process
MISSES_spotifyd=0 MISSES_nqptp=0
check_process() {
  local name=$1 var="MISSES_$1" misses
  eval "misses=\$$var"
  if running "$name"; then
    [ "$misses" -ge "$REPORT_AFTER" ] && log "$name: running again"
    eval "$var=0"
    return 0
  fi
  misses=$((misses + 1))
  eval "$var=$misses"
  [ "$misses" -eq "$REPORT_AFTER" ] && log "$name: not running (see ~/Library/Logs/$2)"
  [ "$misses" -lt "$REPORT_AFTER" ]
}

# Keep the other services' logs from filling the disk. Truncating in place
# works because launchd appends to them.
trim_logs() {
  local f size
  for f in $OTHER_LOGS; do
    f="$HOME/Library/Logs/$f"
    [ -f "$f" ] || continue
    size=$(stat -f %z "$f" 2>/dev/null || echo 0)
    if [ "$size" -gt "$OTHER_LOG_MAX_BYTES" ]; then
      cp -f "$f" "$f.1" && : > "$f" && log "logs: trimmed $f"
    fi
  done
}

# --------------------------------------------------------------------- main

trap 'log "stopping"; exit 0' TERM INT

log "starting (version ${BOOTSTRAP_VERSION:-?}, device '${DEVICE_NAME:-?}', receiver $RECEIVER, output match '${OUTPUT_MATCH:-?}')"
apply_sound_prefs
apply_airplay_prefs

volume_done=0
last_problems="(start)"
tick=0
while true; do
  problems=""
  if check_output; then
    # Apply the login volume once, after the DAC is the default output.
    if [ "$volume_done" -eq 0 ]; then
      apply_login_volume
      volume_done=1
    fi
  else
    problems="${problems}output-missing "
  fi

  if [ "$RECEIVER" = "shairport" ]; then
    apply_airplay_prefs
    check_process nqptp nqptp.log || problems="${problems}nqptp-down "
  fi
  check_airplay || problems="${problems}airplay-not-answering "
  if [ "${SPOTIFY_ENABLED:-false}" = "true" ]; then
    check_process spotifyd spotifyd.log || problems="${problems}spotifyd-down "
  fi

  if [ -n "$problems" ]; then
    if [ "$problems" != "$last_problems" ]; then
      log "problems: $problems"
      ping_health fail "${DEVICE_NAME:-airplay-mini}: $problems"
    fi
  elif [ "$last_problems" != "" ] || [ $((tick % HEARTBEAT_EVERY)) -eq 0 ]; then
    [ "$last_problems" != "" ] && [ "$last_problems" != "(start)" ] && log "all checks ok"
    ping_health ok "${DEVICE_NAME:-airplay-mini}: ok"
  fi

  if [ $((tick % TRIM_EVERY)) -eq 0 ]; then
    trim_logs
  fi

  last_problems=$problems
  tick=$((tick + 1))
  nap "$INTERVAL"
done
