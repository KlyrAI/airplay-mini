# shellcheck shell=bash
# Tailscale: the open-source tailscaled, run as a root LaunchDaemon so it is up
# before anyone logs in, with Tailscale SSH on.

# Prints Running / NeedsLogin / Stopped..., or nothing if tailscaled is not up.
# Always returns 0 so callers under set -e can poll it.
tailscale_state() {
  sudo "$BREW_PREFIX/bin/tailscale" status --json 2>/dev/null \
    | sed -n 's/.*"BackendState": *"\([A-Za-z]*\)".*/\1/p' | head -n 1
  return 0
}

setup_tailscale() {
  step "Tailscale"
  local ts="$BREW_PREFIX/bin/tailscale"
  local tsd="$BREW_PREFIX/bin/tailscaled"
  local plist=/Library/LaunchDaemons/com.tailscale.tailscaled.plist

  # Only install the daemon once. Reinstalling restarts it, which would cut
  # off anyone re-running this script over Tailscale SSH.
  if [ -f "$plist" ]; then
    ok "tailscaled system daemon already installed"
    if ! cmp -s "$tsd" /usr/local/bin/tailscaled; then
      warn "tailscaled differs from the Homebrew copy (after brew upgrade?). To update, run 'sudo $tsd install-system-daemon' from the local network; it drops Tailscale connections for a few seconds."
    fi
  else
    # install-system-daemon copies the binary here; fresh Apple Silicon Macs
    # may not have the folder.
    sudo mkdir -p /usr/local/bin
    sudo "$tsd" install-system-daemon || die "tailscaled install-system-daemon failed"
    ok "tailscaled system daemon installed"
  fi

  local state=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    state=$(tailscale_state)
    [ -n "$state" ] && break
    sleep 1
  done
  [ -n "$state" ] || die "tailscaled did not start (check: sudo launchctl print system/com.tailscale.tailscaled)"

  if [ "$state" = "Running" ]; then
    sudo "$ts" set --ssh --hostname="$TAILSCALE_HOSTNAME" --accept-dns=false \
      || warn "tailscale set failed"
    ok "already logged in"
  elif [ -n "$TAILSCALE_AUTHKEY" ]; then
    sudo "$ts" up --authkey="$TAILSCALE_AUTHKEY" --hostname="$TAILSCALE_HOSTNAME" \
      --ssh --accept-dns=false || die "tailscale up failed"
    ok "logged in with auth key"
  else
    warn "Tailscale not logged in and TAILSCALE_AUTHKEY is empty. Run: sudo $ts up --ssh --accept-dns=false --hostname=$TAILSCALE_HOSTNAME"
    return 0
  fi

  ok "tailnet address $(sudo "$ts" ip -4 2>/dev/null | head -n 1), name $TAILSCALE_HOSTNAME"
}
