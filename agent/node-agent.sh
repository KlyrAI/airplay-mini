#!/bin/bash
# airplay-mini watchdog. Runs as the audio user (LaunchAgent, KeepAlive).
#
# At start it applies per-user settings: AirPlay Receiver on, system sounds
# off, output pinned to the DAC, login volume. ControlCenter is restarted only
# if an AirPlay setting actually changed, so a launchd restart of this script
# never cuts playback.
#
# Then, every 30 s, it keeps the DAC as the default output, restarts the
# AirPlay receiver if it stops answering, and pings the healthcheck URL.
#
# bootstrap.sh installs this to /usr/local/airplay-mini. Settings come from
# agent.env next to it. Log: ~/Library/Logs/airplay-mini.log

set -u

# The AIRPLAY_MINI_* overrides exist for tests/agent-test.sh only.
ENV_FILE=${AIRPLAY_MINI_ENV:-/usr/local/airplay-mini/agent.env}
SWITCH=${AIRPLAY_MINI_SWITCH:-/opt/homebrew/bin/SwitchAudioSource}
LOG="$HOME/Library/Logs/airplay-mini.log"
LOG_MAX_BYTES=1048576

INTERVAL=${AIRPLAY_MINI_INTERVAL:-30}   # seconds between checks
REPORT_AFTER=2       # failed checks before a problem is reported (~1 min)
HEARTBEAT_EVERY=10   # healthy checks between heartbeat pings (~5 min)

# AirPlay Receiver settings live in ControlCenter's ByHost preferences. Apple
# does not document these keys ("Reciever" is Apple's spelling). Confirm them
# on each new macOS version with tools/find-airplay-keys.sh.
AIRPLAY_DOMAIN="com.apple.controlcenter"
KEY_ENABLED="AirplayRecieverEnabled"
KEY_ACCESS="AirplayReceiverAdvertising"   # 1 current user, 2 same network, 3 everyone
AIRPLAY_PORT=7000

mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

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
  sleep 60
  exit 1
fi
# shellcheck source=/dev/null
. "$ENV_FILE"

# ---------------------------------------------------------------- healthcheck

# ping_health ok|fail MESSAGE. Runs in the background so a slow network never
# delays the checks.
ping_health() {
  [ -n "${HEALTHCHECK_URL:-}" ] || return 0
  local url=$HEALTHCHECK_URL
  [ "$1" = "fail" ] && url="$url/fail"
  curl -fsS -m 10 --retry 2 --data-raw "$2" "$url" >/dev/null 2>&1 &
}

# ------------------------------------------------------------- one-time setup

apply_sound_prefs() {
  # Alerts, UI sounds and volume-change clicks would all reach the preamp.
  osascript -e 'set volume alert volume 0' >/dev/null 2>&1
  defaults write com.apple.systemsound com.apple.sound.uiaudio.enabled -int 0
  defaults write -g com.apple.sound.beep.feedback -int 0
  defaults write -g com.apple.sound.beep.volume -float 0
  # No screen saver, so the session never locks.
  defaults -currentHost write com.apple.screensaver idleTime -int 0
}

apply_airplay_prefs() {
  local want_access changed=0
  case "${AIRPLAY_ACCESS:-same-network}" in
    current-user) want_access=1 ;;
    *)            want_access=2 ;;
  esac

  if [ "$(defaults -currentHost read "$AIRPLAY_DOMAIN" "$KEY_ENABLED" 2>/dev/null)" != "1" ]; then
    defaults -currentHost write "$AIRPLAY_DOMAIN" "$KEY_ENABLED" -bool true
    changed=1
  fi
  if [ "$(defaults -currentHost read "$AIRPLAY_DOMAIN" "$KEY_ACCESS" 2>/dev/null)" != "$want_access" ]; then
    defaults -currentHost write "$AIRPLAY_DOMAIN" "$KEY_ACCESS" -int "$want_access"
    changed=1
  fi

  if [ "$changed" -eq 1 ]; then
    log "airplay: settings updated (on, access ${AIRPLAY_ACCESS:-same-network}); restarting ControlCenter"
    killall ControlCenter 2>/dev/null
    sleep 3
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

# A TCP connect to the receiver's port works whichever process owns it.
airplay_answering() { nc -z -G 2 127.0.0.1 "$AIRPLAY_PORT" >/dev/null 2>&1; }

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
  [ "$AIRPLAY_MISSES" -eq 1 ] && log "airplay: nothing answering on port $AIRPLAY_PORT"

  # Restart after 3 misses (90 s). After 5 restarts in a row, back off to
  # every 10 minutes so a permanent fault doesn't churn ControlCenter.
  local limit=3
  [ "$AIRPLAY_RESTARTS" -ge 5 ] && limit=20
  if [ $((AIRPLAY_MISSES % limit)) -eq 0 ]; then
    AIRPLAY_RESTARTS=$((AIRPLAY_RESTARTS + 1))
    log "airplay: restarting ControlCenter (attempt $AIRPLAY_RESTARTS)"
    killall ControlCenter 2>/dev/null
  fi
  [ "$AIRPLAY_MISSES" -lt "$REPORT_AFTER" ]
}

SPOTIFY_MISSES=0
check_spotifyd() {
  [ "${SPOTIFY_ENABLED:-false}" = "true" ] || return 0
  if pgrep -u "$(id -u)" -x spotifyd >/dev/null 2>&1; then
    [ "$SPOTIFY_MISSES" -ge "$REPORT_AFTER" ] && log "spotifyd: running again"
    SPOTIFY_MISSES=0
    return 0
  fi
  SPOTIFY_MISSES=$((SPOTIFY_MISSES + 1))
  # launchd restarts it; reaching here means it keeps crashing.
  [ "$SPOTIFY_MISSES" -eq "$REPORT_AFTER" ] && log "spotifyd: not running (see ~/Library/Logs/spotifyd.log)"
  [ "$SPOTIFY_MISSES" -lt "$REPORT_AFTER" ]
}

# --------------------------------------------------------------------- main

trap 'log "stopping"; exit 0' TERM INT

log "starting (version ${BOOTSTRAP_VERSION:-?}, device '${DEVICE_NAME:-?}', output match '${OUTPUT_MATCH:-?}')"
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
  check_airplay  || problems="${problems}airplay-not-answering "
  check_spotifyd || problems="${problems}spotifyd-down "

  if [ -n "$problems" ]; then
    if [ "$problems" != "$last_problems" ]; then
      log "problems: $problems"
      ping_health fail "${DEVICE_NAME:-airplay-mini}: $problems"
    fi
  elif [ "$last_problems" != "" ] || [ $((tick % HEARTBEAT_EVERY)) -eq 0 ]; then
    [ "$last_problems" != "" ] && [ "$last_problems" != "(start)" ] && log "all checks ok"
    ping_health ok "${DEVICE_NAME:-airplay-mini}: ok"
  fi

  last_problems=$problems
  tick=$((tick + 1))
  sleep "$INTERVAL" &
  wait $!
done
