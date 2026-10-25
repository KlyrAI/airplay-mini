#!/bin/bash
# airplay-mini bootstrap: turns an Apple Silicon Mac mini into a headless
# AirPlay + Spotify Connect speaker feeding a preamp, with Tailscale remote
# access for IT.
#
#   cp config.env.example config.env    # then fill it in
#   ./bootstrap.sh
#
# Run as an admin user, not with sudo; it asks for your password once.
# Safe to re-run after editing config.env or pulling a new version.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$REPO_DIR/lib/common.sh"
# shellcheck source=lib/system.sh
. "$REPO_DIR/lib/system.sh"
# shellcheck source=lib/users.sh
. "$REPO_DIR/lib/users.sh"
# shellcheck source=lib/brew.sh
. "$REPO_DIR/lib/brew.sh"
# shellcheck source=lib/tailscale.sh
. "$REPO_DIR/lib/tailscale.sh"
# shellcheck source=lib/agents.sh
. "$REPO_DIR/lib/agents.sh"

# ------------------------------------------------------------------ preflight

load_config() {
  [ -f "$REPO_DIR/config.env" ] \
    || die "no config.env. Copy config.env.example to config.env and fill it in."
  # shellcheck source=/dev/null
  . "$REPO_DIR/config.env"

  DEVICE_NAME=${DEVICE_NAME:-}
  AUDIO_USER=${AUDIO_USER:-audio}
  AUDIO_USER_FULLNAME=${AUDIO_USER_FULLNAME:-Audio}
  AUDIO_USER_PASSWORD=${AUDIO_USER_PASSWORD:-}
  OUTPUT_MATCH=${OUTPUT_MATCH:-}
  LOGIN_VOLUME=${LOGIN_VOLUME:-70}
  AIRPLAY_ACCESS=${AIRPLAY_ACCESS:-same-network}
  TAILSCALE_AUTHKEY=${TAILSCALE_AUTHKEY:-}
  TAILSCALE_HOSTNAME=${TAILSCALE_HOSTNAME:-}
  SPOTIFY_ENABLED=${SPOTIFY_ENABLED:-true}
  SPOTIFY_BITRATE=${SPOTIFY_BITRATE:-320}
  HEALTHCHECK_URL=${HEALTHCHECK_URL:-}
  WEEKLY_REBOOT=${WEEKLY_REBOOT:-}

  local re_name="^[A-Za-z0-9][A-Za-z0-9 ._'-]*$"
  [[ $DEVICE_NAME =~ $re_name ]] \
    || die "DEVICE_NAME '$DEVICE_NAME' is empty or has characters other than letters, digits, spaces and . _ - '"
  HOST_SLUG=$(slugify "$DEVICE_NAME")
  [ -n "$HOST_SLUG" ] || die "DEVICE_NAME gives an empty host name"
  TAILSCALE_HOSTNAME=${TAILSCALE_HOSTNAME:-$HOST_SLUG}
  [[ $TAILSCALE_HOSTNAME =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "TAILSCALE_HOSTNAME must be lowercase letters, digits and -"

  [[ $AUDIO_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die "AUDIO_USER must be a lowercase short name"
  [ "$AUDIO_USER" != "$(id -un)" ] || die "AUDIO_USER must be a separate account, not the admin running this"
  [ -n "$AUDIO_USER_PASSWORD" ] || die "AUDIO_USER_PASSWORD is empty (auto-login needs it)"
  [ -n "$OUTPUT_MATCH" ] || die "OUTPUT_MATCH is empty"

  if ! [[ $LOGIN_VOLUME =~ ^[0-9]+$ ]] || [ "$LOGIN_VOLUME" -gt 100 ]; then
    die "LOGIN_VOLUME must be 0-100"
  fi

  case "$AIRPLAY_ACCESS" in
    same-network|current-user) ;;
    everyone) die "AIRPLAY_ACCESS=everyone lets any nearby iPhone connect without joining the network. Use same-network." ;;
    *) die "AIRPLAY_ACCESS must be same-network or current-user" ;;
  esac

  case "$SPOTIFY_ENABLED" in true|false) ;; *) die "SPOTIFY_ENABLED must be true or false" ;; esac
  case "$SPOTIFY_BITRATE" in 96|160|320) ;; *) die "SPOTIFY_BITRATE must be 96, 160 or 320" ;; esac

  case "$HEALTHCHECK_URL" in ""|https://*) ;; *) die "HEALTHCHECK_URL must start with https://" ;; esac

  REBOOT_WEEKDAY="" REBOOT_HOUR="" REBOOT_MINUTE=""
  if [ -n "$WEEKLY_REBOOT" ]; then
    local day time
    day=${WEEKLY_REBOOT%% *}
    time=${WEEKLY_REBOOT#* }
    case "$day" in
      Sun) REBOOT_WEEKDAY=0 ;; Mon) REBOOT_WEEKDAY=1 ;; Tue) REBOOT_WEEKDAY=2 ;;
      Wed) REBOOT_WEEKDAY=3 ;; Thu) REBOOT_WEEKDAY=4 ;; Fri) REBOOT_WEEKDAY=5 ;;
      Sat) REBOOT_WEEKDAY=6 ;;
      *) die "WEEKLY_REBOOT day must be Sun..Sat (got '$day')" ;;
    esac
    [[ $time =~ ^[0-2][0-9]:[0-5][0-9]$ ]] || die "WEEKLY_REBOOT time must be HH:MM (got '$time')"
    REBOOT_HOUR=$((10#${time%%:*}))
    REBOOT_MINUTE=$((10#${time#*:}))
    [ "$REBOOT_HOUR" -le 23 ] || die "WEEKLY_REBOOT hour must be 00-23"
  fi
}

preflight() {
  step "Preflight"
  [ "$(uname -s)" = "Darwin" ] || die "run this on the Mac"
  [ "$(uname -m)" = "arm64" ] || die "Apple Silicon only (found $(uname -m))"
  local ver
  ver=$(sw_vers -productVersion)
  [ "${ver%%.*}" -ge 12 ] || die "macOS 12 or newer is needed for AirPlay Receiver (found $ver)"
  ok "macOS $ver on $(sysctl -n hw.model)"

  [ "$(id -u)" -ne 0 ] || die "run as your admin user, without sudo (Homebrew refuses to run as root)"
  case " $(id -Gn) " in
    *" admin "*) ok "running as admin '$(id -un)'" ;;
    *) die "'$(id -un)' is not an admin" ;;
  esac

  load_config
  ok "config.env valid: '$DEVICE_NAME', user '$AUDIO_USER', output match '$OUTPUT_MATCH'"

  # Auto-login is impossible with FileVault on.
  local fv
  fv=$(fdesetup status 2>/dev/null || true)
  case "$fv" in
    *"FileVault is Off"*) ok "FileVault off (needed for auto-login)" ;;
    *) die "FileVault must be off for auto-login. Status: '$fv'. Turn it off in System Settings > Privacy & Security > FileVault, wait for decryption to finish, then re-run." ;;
  esac

  [ -n "$TAILSCALE_AUTHKEY" ] || warn "TAILSCALE_AUTHKEY is empty; Tailscale will need a manual login"
}

start_sudo() {
  sudo -v || die "sudo is needed"
  # Keep the sudo timestamp fresh for the whole run (Homebrew's installer
  # needs it too). Stops when this script exits.
  ( while kill -0 "$$" 2>/dev/null; do sudo -n true; sleep 50; done ) >/dev/null 2>&1 &
  SUDO_KEEPALIVE=$!
}

version_string() {
  # Only call git once the Command Line Tools exist; on a fresh Mac the git
  # shim pops up an installer dialog instead.
  if xcode-select -p >/dev/null 2>&1 && [ -d "$REPO_DIR/.git" ]; then
    git -C "$REPO_DIR" describe --always --dirty 2>/dev/null && return 0
  fi
  date '+%Y%m%d'
}

# ------------------------------------------------------------ manual checklist

print_checklist() {
  step "Manual steps (Apple blocks these from scripts without MDM)"
  local n=1

  if nc -z -G 2 127.0.0.1 5900 >/dev/null 2>&1; then
    ok "Screen Sharing is on. Check that only '$(id -un)' is allowed."
  else
    info "$n. System Settings > General > Sharing > Screen Sharing: turn on,"
    info "   then (i) > Allow access for: Only these users > '$(id -un)'."
    n=$((n + 1))
  fi

  if [ "$(tailscale_state)" != "Running" ]; then
    info "$n. Log in to Tailscale: sudo $BREW_PREFIX/bin/tailscale up --ssh --accept-dns=false --hostname=$TAILSCALE_HOSTNAME"
    n=$((n + 1))
  fi

  if [ "$(stat -f %Su /dev/console)" != "$AUDIO_USER" ]; then
    info "$n. Log out, then log in once as '$AUDIO_USER' and click through Setup Assistant"
    info "   (skip Apple ID, no Siri, no Screen Time, no analytics). Otherwise those"
    info "   screens come back on every boot."
    n=$((n + 1))
  fi

  info "$n. As '$AUDIO_USER': System Settings > General > AirDrop & Handoff > AirPlay Receiver"
  info "   is on, Allow AirPlay for: 'Anyone on the same network'. Set a password here if wanted."
  n=$((n + 1))
  info "$n. Reboot. It should log in as '$AUDIO_USER' by itself. Then run:"
  info "   $INSTALL_DIR/status.sh"
  if [ ! -x /usr/local/bin/airplay-doctor ]; then
    info "Optional: $REPO_DIR/tools/claude-setup.sh sets up Claude Code for troubleshooting over SSH."
  fi
}

# ----------------------------------------------------------------------- main

WORK_DIR=""
SUDO_KEEPALIVE=""
cleanup() {
  [ -n "$SUDO_KEEPALIVE" ] && kill "$SUDO_KEEPALIVE" 2>/dev/null
  [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
  return 0
}

main() {
  case "${1:-}" in
    "") ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option '$1' (see --help)" ;;
  esac

  WORK_DIR=$(mktemp -d)
  trap cleanup EXIT

  preflight
  start_sudo
  setup_system
  setup_audio_user
  setup_brew
  setup_tailscale
  BOOTSTRAP_VERSION=$(version_string)
  install_scripts
  install_user_agents
  install_reboot_job
  print_checklist

  if [ -n "$WARNINGS" ]; then
    step "Warnings"
    printf '%s' "$WARNINGS"
  fi

  step "Status"
  "$INSTALL_DIR/status.sh" || true
}

# Sourcing this file (tests/bootstrap-test.sh) loads the functions only.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
