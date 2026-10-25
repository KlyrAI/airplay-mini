#!/bin/bash
# Removes what bootstrap.sh installed: the watchdog, spotifyd job, weekly
# reboot and /usr/local/airplay-mini.
#
# Leaves in place: the audio user, Homebrew and its packages, power and sound
# settings, and Tailscale. Removing Tailscale would cut off remote access, so
# do that by hand from the local network:
#   sudo tailscaled uninstall-system-daemon
#
#   ./uninstall.sh                      # keep auto-login
#   ./uninstall.sh --disable-autologin  # also turn auto-login off

set -euo pipefail
REPO_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
. "$REPO_DIR/lib/common.sh"

DISABLE_AUTOLOGIN=false
case "${1:-}" in
  "") ;;
  --disable-autologin) DISABLE_AUTOLOGIN=true ;;
  -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown option '$1'" ;;
esac

[ "$(id -u)" -ne 0 ] || die "run as your admin user, without sudo"
sudo -v

AUDIO_USER=""
if [ -r "$AGENT_ENV" ]; then
  # shellcheck source=/dev/null
  . "$AGENT_ENV"
fi
[ -n "$AUDIO_USER" ] || AUDIO_USER=$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || echo "")

step "Removing launchd jobs"
if [ -n "$AUDIO_USER" ] && id "$AUDIO_USER" >/dev/null 2>&1; then
  uid=$(id -u "$AUDIO_USER")
  la="$(user_home "$AUDIO_USER")/Library/LaunchAgents"
  for label in $LABEL_AGENT $LABEL_SPOTIFYD; do
    bootout_quietly "gui/$uid" "$label"
    sudo rm -f "$la/$label.plist"
    ok "$label"
  done
else
  warn "audio user unknown; skipped its LaunchAgents"
fi
bootout_quietly system "$LABEL_REBOOT"
sudo rm -f "/Library/LaunchDaemons/$LABEL_REBOOT.plist"
ok "$LABEL_REBOOT"

step "Removing $INSTALL_DIR"
sudo rm -rf "$INSTALL_DIR"
ok "removed"

if [ "$DISABLE_AUTOLOGIN" = "true" ]; then
  step "Auto-login"
  if sudo sysadminctl -autologin off >/dev/null 2>&1; then
    ok "off"
  else
    warn "could not turn auto-login off"
  fi
fi

printf '\nDone. Tailscale, Homebrew and the audio user are still installed.\n'
