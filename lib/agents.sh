# shellcheck shell=bash
# Installs the watchdog agent, spotifyd and the weekly reboot as launchd jobs.
#
# Layout on the Mac:
#   /usr/local/airplay-mini/            scripts + agent.env (no secrets), root-owned
#   ~audio/Library/LaunchAgents/        agent + spotifyd jobs, run in the audio user's session
#   ~audio/.config/spotifyd/            spotifyd.conf
#   /Library/LaunchDaemons/             weekly reboot job

# bootstrap_retry DOMAIN PLIST: launchd sometimes refuses a bootstrap
# right after a bootout of the same label, so retry briefly.
bootstrap_retry() {
  local _
  for _ in 1 2 3 4 5; do
    sudo launchctl bootstrap "$1" "$2" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

# install_as OWNER MODE SRC DST
install_as() {
  sudo install -o "$1" -g "$(id -gn "$1")" -m "$2" "$3" "$4"
}

install_scripts() {
  step "Scripts in $INSTALL_DIR"
  sudo install -d -o root -g wheel -m 755 "$INSTALL_DIR" "$INSTALL_DIR/lib"
  sudo install -o root -g wheel -m 755 "$REPO_DIR/agent/node-agent.sh" "$INSTALL_DIR/node-agent.sh"
  sudo install -o root -g wheel -m 755 "$REPO_DIR/status.sh" "$INSTALL_DIR/status.sh"
  sudo install -o root -g wheel -m 755 "$REPO_DIR/tools/doctor.sh" "$INSTALL_DIR/doctor"
  sudo install -o root -g wheel -m 644 "$REPO_DIR/lib/common.sh" "$INSTALL_DIR/lib/common.sh"

  # Only what the agent and status.sh need. Readable by every local user.
  local env="$WORK_DIR/agent.env"
  {
    echo "# Written by bootstrap.sh $(date '+%Y-%m-%d %H:%M'). Edit config.env and re-run instead."
    printf 'DEVICE_NAME=%q\n' "$DEVICE_NAME"
    printf 'AUDIO_USER=%q\n' "$AUDIO_USER"
    printf 'OUTPUT_MATCH=%q\n' "$OUTPUT_MATCH"
    printf 'LOGIN_VOLUME=%q\n' "$LOGIN_VOLUME"
    printf 'AIRPLAY_ACCESS=%q\n' "$AIRPLAY_ACCESS"
    printf 'SPOTIFY_ENABLED=%q\n' "$SPOTIFY_ENABLED"
    printf 'HEALTHCHECK_URL=%q\n' "$HEALTHCHECK_URL"
    printf 'TAILSCALE_HOSTNAME=%q\n' "$TAILSCALE_HOSTNAME"
    printf 'BOOTSTRAP_VERSION=%q\n' "$BOOTSTRAP_VERSION"
  } > "$env"
  sudo install -o root -g wheel -m 644 "$env" "$AGENT_ENV"
  ok "node-agent.sh, status.sh, doctor, agent.env installed"
}

install_user_agents() {
  step "LaunchAgents for '$AUDIO_USER'"
  local la="$AUDIO_HOME/Library/LaunchAgents"
  local uid
  uid=$(id -u "$AUDIO_USER")
  # Created as the audio user so existing folders (~/Library is 700) keep
  # their permissions.
  sudo -u "$AUDIO_USER" mkdir -p "$la" "$AUDIO_HOME/Library/Logs" "$AUDIO_HOME/Library/Caches"

  render_template "$REPO_DIR/launchd/$LABEL_AGENT.plist.tmpl" "$WORK_DIR/$LABEL_AGENT.plist" \
    "LABEL=$LABEL_AGENT" "INSTALL_DIR=$INSTALL_DIR" "AUDIO_HOME=$AUDIO_HOME"
  plutil -lint -s "$WORK_DIR/$LABEL_AGENT.plist" || die "bad plist: $LABEL_AGENT"
  install_as "$AUDIO_USER" 644 "$WORK_DIR/$LABEL_AGENT.plist" "$la/$LABEL_AGENT.plist"
  ok "$LABEL_AGENT"

  if [ "$SPOTIFY_ENABLED" = "true" ]; then
    local conf_dir="$AUDIO_HOME/.config/spotifyd"
    sudo -u "$AUDIO_USER" mkdir -p "$conf_dir"
    sudo chmod 700 "$AUDIO_HOME/.config" "$conf_dir"
    render_template "$REPO_DIR/templates/spotifyd.conf.tmpl" "$WORK_DIR/spotifyd.conf" \
      "DEVICE_NAME=$DEVICE_NAME" "BITRATE=$SPOTIFY_BITRATE" "CACHE_DIR=$AUDIO_HOME/Library/Caches/spotifyd"
    install_as "$AUDIO_USER" 600 "$WORK_DIR/spotifyd.conf" "$conf_dir/spotifyd.conf"

    render_template "$REPO_DIR/launchd/$LABEL_SPOTIFYD.plist.tmpl" "$WORK_DIR/$LABEL_SPOTIFYD.plist" \
      "LABEL=$LABEL_SPOTIFYD" "SPOTIFYD=$BREW_PREFIX/bin/spotifyd" \
      "CONF=$conf_dir/spotifyd.conf" "AUDIO_HOME=$AUDIO_HOME"
    plutil -lint -s "$WORK_DIR/$LABEL_SPOTIFYD.plist" || die "bad plist: $LABEL_SPOTIFYD"
    install_as "$AUDIO_USER" 644 "$WORK_DIR/$LABEL_SPOTIFYD.plist" "$la/$LABEL_SPOTIFYD.plist"
    ok "$LABEL_SPOTIFYD ('$DEVICE_NAME', $SPOTIFY_BITRATE kbps)"
  else
    bootout_quietly "gui/$uid" "$LABEL_SPOTIFYD"
    sudo rm -f "$la/$LABEL_SPOTIFYD.plist"
    ok "Spotify Connect off (spotifyd job removed if it was there)"
  fi

  # LaunchAgents load at login. If the audio user is already logged in,
  # (re)load them now so changes apply without a reboot.
  if has_gui_session "$AUDIO_USER"; then
    local label
    for label in $LABEL_AGENT $LABEL_SPOTIFYD; do
      [ -f "$la/$label.plist" ] || continue
      bootout_quietly "gui/$uid" "$label"
      if bootstrap_retry "gui/$uid" "$la/$label.plist"; then
        ok "loaded $label"
      else
        warn "could not load $label now; it will load at the next login"
      fi
    done
  else
    info "'$AUDIO_USER' is not logged in; the agents start at its next login"
  fi
}

install_reboot_job() {
  step "Weekly reboot"
  local dst="/Library/LaunchDaemons/$LABEL_REBOOT.plist"
  bootout_quietly system "$LABEL_REBOOT"

  if [ -z "$WEEKLY_REBOOT" ]; then
    sudo rm -f "$dst"
    ok "off"
    return 0
  fi

  render_template "$REPO_DIR/launchd/$LABEL_REBOOT.plist.tmpl" "$WORK_DIR/$LABEL_REBOOT.plist" \
    "LABEL=$LABEL_REBOOT" "WEEKDAY=$REBOOT_WEEKDAY" "HOUR=$REBOOT_HOUR" "MINUTE=$REBOOT_MINUTE"
  plutil -lint -s "$WORK_DIR/$LABEL_REBOOT.plist" || die "bad plist: $LABEL_REBOOT"
  sudo install -o root -g wheel -m 644 "$WORK_DIR/$LABEL_REBOOT.plist" "$dst"
  bootstrap_retry system "$dst" || warn "could not load $LABEL_REBOOT; it will load at next boot"
  ok "every $WEEKLY_REBOOT"
}
