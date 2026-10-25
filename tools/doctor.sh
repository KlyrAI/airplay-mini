#!/bin/bash
# airplay-mini doctor: diagnostics and safe fixes, run as root.
#
#   sudo /usr/local/airplay-mini/doctor <command>
#
# Read-only:
#   status            health report (status.sh)
#   logs [N]          last N lines (default 150) of the watchdog, receiver and spotifyd logs
#   syslog [MIN]      macOS log for AirPlay / CoreAudio, last MIN minutes (default 30)
#   audio             output devices, current output, volume, USB audio hardware
#   mdns              AirPlay and Spotify speakers advertised on the network (3 s browse)
#   prefs             the audio user's AirPlay Receiver and sound preferences
#   tailscale         Tailscale status and network check (read-only)
#   versions          macOS, package and bootstrap versions
#
# Fixes:
#   restart-airplay   restart the AirPlay receiver (NQPTP + Shairport Sync, or ControlCenter)
#   restart-spotifyd  restart spotifyd
#   restart-agent     restart the watchdog
#   reboot            reboot in 1 minute
#
# tools/claude-setup.sh lets the admin user run this without a password, so
# Claude Code can troubleshoot. It never touches Tailscale's daemon, users,
# auto-login or FileVault.

set -u

if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
if [ -r "$SCRIPT_DIR/lib/common.sh" ]; then
  # shellcheck source=lib/common.sh
  . "$SCRIPT_DIR/lib/common.sh"            # installed copy
else
  # shellcheck source=lib/common.sh
  . "$SCRIPT_DIR/../lib/common.sh"         # repo copy
fi

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; }

cmd=${1:-help}
[ $# -gt 0 ] && shift
case "$cmd" in
  help|-h|--help) usage; exit 0 ;;
esac

if [ ! -r "$AGENT_ENV" ]; then
  echo "doctor: $AGENT_ENV not found; bootstrap.sh has not been run yet." >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$AGENT_ENV"

AUDIO_UID=$(id -u "$AUDIO_USER" 2>/dev/null || echo "")
AUDIO_HOME=$(user_home "$AUDIO_USER")
SWITCH="$BREW_PREFIX/bin/SwitchAudioSource"
TS="$BREW_PREFIX/bin/tailscale"

need_session() {
  if [ -z "$AUDIO_UID" ] || [ "$(stat -f %Su /dev/console)" != "$AUDIO_USER" ]; then
    echo "doctor: '$AUDIO_USER' is not logged in at the screen (console user: $(stat -f %Su /dev/console))." >&2
    echo "        Audio only works in that session. A reboot logs it in automatically." >&2
    exit 1
  fi
}

# Run inside the audio user's login session.
as_audio() { launchctl asuser "$AUDIO_UID" sudo -u "$AUDIO_USER" "$@"; }

section() { printf '\n== %s ==\n' "$*"; }

positive_int() { # positive_int VALUE DEFAULT MAX
  local v=${1:-$2}
  case "$v" in ''|*[!0-9]*) v=$2 ;; esac
  [ "$v" -gt "$3" ] && v=$3
  printf '%s' "$v"
}

case "$cmd" in
  status)
    "$INSTALL_DIR/status.sh"
    ;;

  logs)
    n=$(positive_int "${1:-}" 150 2000)
    for f in airplay-mini.log airplay-mini.launchd.log shairport-sync.log nqptp.log spotifyd.log; do
      section "$AUDIO_HOME/Library/Logs/$f (last $n)"
      if [ -f "$AUDIO_HOME/Library/Logs/$f" ]; then tail -n "$n" "$AUDIO_HOME/Library/Logs/$f"; else echo "(missing)"; fi
    done
    ;;

  syslog)
    min=$(positive_int "${1:-}" 30 1440)
    section "macOS log, last ${min}m: AirPlay, ControlCenter, CoreAudio (last 300 lines)"
    log show --last "${min}m" --style compact --predicate \
      'process == "ControlCenter" OR process == "AirPlayXPCHelper" OR process == "coreaudiod" OR subsystem BEGINSWITH "com.apple.airplay"' \
      2>/dev/null | tail -n 300
    ;;

  audio)
    need_session
    section "Output devices (OUTPUT_MATCH='$OUTPUT_MATCH')"
    as_audio "$SWITCH" -a -t output
    section "Current output"
    as_audio "$SWITCH" -c -t output
    section "Volume settings"
    as_audio osascript -e 'get volume settings'
    section "Audio hardware"
    system_profiler SPAudioDataType 2>/dev/null
    section "USB devices (a USB-C DAC cable should be listed)"
    system_profiler SPUSBDataType 2>/dev/null | grep -vE '^[[:space:]]*$'
    ;;

  mdns)
    for type in _airplay._tcp _raop._tcp _spotify-connect._tcp; do
      section "$type"
      out=$(mktemp)
      dns-sd -B "$type" local. >"$out" 2>&1 &
      pid=$!
      sleep 3
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      grep -E ' Add ' "$out" | awk '{ $1=$2=$3=$4=$5=$6=""; sub(/^ +/, ""); print }' | sort -u
      rm -f "$out"
    done
    echo
    echo "This Mac should appear as '$DEVICE_NAME'."
    ;;

  prefs)
    section "AirPlay receiver in use: ${AIRPLAY_RECEIVER:-builtin}"
    if [ -f "$AUDIO_HOME/.config/shairport-sync/shairport-sync.conf" ]; then
      grep -vE '^[[:space:]]*(//|$)' "$AUDIO_HOME/.config/shairport-sync/shairport-sync.conf"
    fi
    section "macOS built-in AirPlay Receiver (ByHost com.apple.controlcenter; should be 0 with shairport)"
    sudo -u "$AUDIO_USER" defaults -currentHost read com.apple.controlcenter 2>/dev/null | grep -i airplay || echo "(no AirPlay keys set)"
    section "Sounds"
    for k in "com.apple.systemsound com.apple.sound.uiaudio.enabled" \
             "-g com.apple.sound.beep.feedback" "-g com.apple.sound.beep.volume"; do
      # shellcheck disable=SC2086  # $k is "domain key" on purpose
      printf '%-55s %s\n' "$k" "$(sudo -u "$AUDIO_USER" defaults read $k 2>/dev/null || echo unset)"
    done
    section "agent.env"
    grep -v '^#' "$AGENT_ENV"
    ;;

  tailscale)
    section "tailscale status"
    "$TS" status
    section "tailscale netcheck"
    "$TS" netcheck 2>&1 | head -n 30
    ;;

  versions)
    section "Versions"
    echo "macOS      $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(sysctl -n hw.model)"
    echo "bootstrap  ${BOOTSTRAP_VERSION:-?}"
    for pkg in switchaudio-osx tailscale spotifyd; do
      if [ -d "$BREW_PREFIX/Cellar/$pkg" ]; then
        # shellcheck disable=SC2012  # Cellar holds plain version folders
        printf '%-10s %s\n' "$pkg" "$(ls "$BREW_PREFIX/Cellar/$pkg" | tr '\n' ' ')"
      else
        printf '%-10s %s\n' "$pkg" "not installed"
      fi
    done
    echo "tailscaled $(/usr/local/bin/tailscaled --version 2>/dev/null | head -n 1 || echo '?') (system daemon copy)"
    echo "shairport  $(/usr/local/bin/shairport-sync -V 2>&1 || echo 'not installed')"
    echo "nqptp      $(/usr/local/bin/nqptp -V 2>&1 || echo 'not installed')"
    ;;

  restart-airplay)
    need_session
    if [ "${AIRPLAY_RECEIVER:-builtin}" = "shairport" ]; then
      launchctl kickstart -k "gui/$AUDIO_UID/$LABEL_NQPTP" && sleep 1 \
        && launchctl kickstart -k "gui/$AUDIO_UID/$LABEL_SHAIRPORT" \
        && echo "NQPTP and Shairport Sync restarted; the speaker is back in a few seconds."
    else
      as_audio killall ControlCenter && echo "ControlCenter restarted; the receiver is back in a few seconds."
    fi
    ;;

  restart-spotifyd)
    need_session
    launchctl kickstart -k "gui/$AUDIO_UID/$LABEL_SPOTIFYD" && echo "spotifyd restarted."
    ;;

  restart-agent)
    need_session
    launchctl kickstart -k "gui/$AUDIO_UID/$LABEL_AGENT" && echo "watchdog restarted."
    ;;

  reboot)
    logger -t airplay-mini "doctor: reboot requested by ${SUDO_USER:-root}"
    shutdown -r +1
    echo "Rebooting in 1 minute. It logs in as '$AUDIO_USER' by itself; reconnect in about 3 minutes."
    ;;

  *)
    echo "doctor: unknown command '$cmd'" >&2
    usage >&2
    exit 2
    ;;
esac
