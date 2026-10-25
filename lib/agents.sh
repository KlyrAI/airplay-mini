# shellcheck shell=bash
# Installs the watchdog, the AirPlay receiver, spotifyd and the scheduled
# reboot as launchd jobs.
#
# Layout on the Mac:
#   /usr/local/airplay-mini/            scripts + agent.env (no secrets), root-owned
#   /usr/local/bin/{shairport-sync,nqptp}   built by lib/shairport.sh
#   ~audio/Library/LaunchAgents/        agent, nqptp, shairport, spotifyd jobs (audio user's session)
#   ~audio/.config/{shairport-sync,spotifyd}/   their configs
#   /Library/LaunchDaemons/             scheduled reboot job

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

  # Only what the agent, status.sh and doctor need. Readable by every local user.
  local env="$WORK_DIR/agent.env"
  {
    echo "# Written by bootstrap.sh $(date '+%Y-%m-%d %H:%M'). Edit config.env and re-run instead."
    printf 'DEVICE_NAME=%q\n' "$DEVICE_NAME"
    printf 'AUDIO_USER=%q\n' "$AUDIO_USER"
    printf 'OUTPUT_MATCH=%q\n' "$OUTPUT_MATCH"
    printf 'LOGIN_VOLUME=%q\n' "$LOGIN_VOLUME"
    printf 'AIRPLAY_RECEIVER=%q\n' "$AIRPLAY_RECEIVER"
    printf 'AIRPLAY_ACCESS=%q\n' "$AIRPLAY_ACCESS"
    printf 'SPOTIFY_ENABLED=%q\n' "$SPOTIFY_ENABLED"
    printf 'HEALTHCHECK_URL=%q\n' "$HEALTHCHECK_URL"
    printf 'TAILSCALE_HOSTNAME=%q\n' "$TAILSCALE_HOSTNAME"
    printf 'BOOTSTRAP_VERSION=%q\n' "$BOOTSTRAP_VERSION"
  } > "$env"
  sudo install -o root -g wheel -m 644 "$env" "$AGENT_ENV"
  ok "node-agent.sh, status.sh, doctor, agent.env installed"
}

# install_user_plist LABEL KEY=VALUE...: render launchd/LABEL.plist.tmpl,
# lint it, and install it into the audio user's LaunchAgents.
install_user_plist() {
  local label=$1
  shift
  render_template "$REPO_DIR/launchd/$label.plist.tmpl" "$WORK_DIR/$label.plist" "LABEL=$label" "$@"
  plutil -lint -s "$WORK_DIR/$label.plist" || die "bad plist: $label"
  install_as "$AUDIO_USER" 644 "$WORK_DIR/$label.plist" "$AUDIO_HOME/Library/LaunchAgents/$label.plist"
}

# remove_user_plist LABEL: stop and delete a job that is no longer wanted.
remove_user_plist() {
  bootout_quietly "gui/$(id -u "$AUDIO_USER")" "$1"
  sudo rm -f "$AUDIO_HOME/Library/LaunchAgents/$1.plist"
}

# user_config_dir NAME: ~audio/.config/NAME, private to the audio user.
user_config_dir() {
  local dir="$AUDIO_HOME/.config/$1"
  sudo -u "$AUDIO_USER" mkdir -p "$dir"
  sudo chmod 700 "$AUDIO_HOME/.config" "$dir"
  printf '%s' "$dir"
}

install_user_agents() {
  step "LaunchAgents for '$AUDIO_USER'"
  local uid
  uid=$(id -u "$AUDIO_USER")
  # Created as the audio user so existing folders (~/Library is 700) keep
  # their permissions.
  sudo -u "$AUDIO_USER" mkdir -p "$AUDIO_HOME/Library/LaunchAgents" \
    "$AUDIO_HOME/Library/Logs" "$AUDIO_HOME/Library/Caches"

  install_user_plist "$LABEL_AGENT" "INSTALL_DIR=$INSTALL_DIR" "AUDIO_HOME=$AUDIO_HOME"
  ok "$LABEL_AGENT (watchdog)"

  if [ "$AIRPLAY_RECEIVER" = "shairport" ]; then
    local sps_dir ignore=no
    [ "$AIRPLAY_FIXED_VOLUME" = "yes" ] && ignore=yes
    sps_dir=$(user_config_dir shairport-sync)
    render_template "$REPO_DIR/templates/shairport-sync.conf.tmpl" "$WORK_DIR/shairport-sync.conf" \
      "DEVICE_NAME=$DEVICE_NAME" "IGNORE_VOLUME=$ignore"
    install_as "$AUDIO_USER" 600 "$WORK_DIR/shairport-sync.conf" "$sps_dir/shairport-sync.conf"
    install_user_plist "$LABEL_NQPTP" "NQPTP=$NQPTP_BIN" "AUDIO_HOME=$AUDIO_HOME"
    install_user_plist "$LABEL_SHAIRPORT" "SHAIRPORT=$SPS_BIN" \
      "CONF=$sps_dir/shairport-sync.conf" "AUDIO_HOME=$AUDIO_HOME"
    ok "$LABEL_NQPTP + $LABEL_SHAIRPORT ('$DEVICE_NAME', fixed volume: $AIRPLAY_FIXED_VOLUME)"
  else
    remove_user_plist "$LABEL_SHAIRPORT"
    remove_user_plist "$LABEL_NQPTP"
    ok "AirPlay is macOS's built-in receiver (Shairport Sync jobs removed if they were there)"
  fi

  if [ "$SPOTIFY_ENABLED" = "true" ]; then
    local spd_dir
    spd_dir=$(user_config_dir spotifyd)
    render_template "$REPO_DIR/templates/spotifyd.conf.tmpl" "$WORK_DIR/spotifyd.conf" \
      "DEVICE_NAME=$DEVICE_NAME" "BITRATE=$SPOTIFY_BITRATE" "CACHE_DIR=$AUDIO_HOME/Library/Caches/spotifyd"
    install_as "$AUDIO_USER" 600 "$WORK_DIR/spotifyd.conf" "$spd_dir/spotifyd.conf"
    install_user_plist "$LABEL_SPOTIFYD" "SPOTIFYD=$BREW_PREFIX/bin/spotifyd" \
      "CONF=$spd_dir/spotifyd.conf" "AUDIO_HOME=$AUDIO_HOME"
    ok "$LABEL_SPOTIFYD ('$DEVICE_NAME', $SPOTIFY_BITRATE kbps)"
  else
    remove_user_plist "$LABEL_SPOTIFYD"
    ok "Spotify Connect off (spotifyd job removed if it was there)"
  fi

  # LaunchAgents load at login. If the audio user is already logged in,
  # (re)load them now so changes apply without a reboot. The watchdog goes
  # first so it turns the built-in receiver off before Shairport Sync needs
  # port 7000, and NQPTP goes before Shairport Sync.
  if has_gui_session "$AUDIO_USER"; then
    local label
    for label in $LABEL_AGENT $LABEL_NQPTP $LABEL_SHAIRPORT $LABEL_SPOTIFYD; do
      [ -f "$AUDIO_HOME/Library/LaunchAgents/$label.plist" ] || continue
      bootout_quietly "gui/$uid" "$label"
      if bootstrap_retry "gui/$uid" "$AUDIO_HOME/Library/LaunchAgents/$label.plist"; then
        ok "loaded $label"
      else
        warn "could not load $label now; it will load at the next login"
      fi
      if [ "$label" = "$LABEL_AGENT" ]; then
        sleep 5   # let it switch the built-in receiver off
      fi
    done
  else
    info "'$AUDIO_USER' is not logged in; the agents start at its next login"
  fi
}

# The reboot plist's Weekday entry; empty for a daily reboot.
reboot_weekday_xml() {
  [ -n "$REBOOT_WEEKDAY" ] || return 0
  printf '    <key>Weekday</key>\n    <integer>%s</integer>' "$REBOOT_WEEKDAY"
}

install_reboot_job() {
  step "Scheduled reboot"
  local dst="/Library/LaunchDaemons/$LABEL_REBOOT.plist"
  bootout_quietly system "$LABEL_REBOOT"

  if [ -z "$REBOOT_SCHEDULE" ]; then
    sudo rm -f "$dst"
    ok "off"
    return 0
  fi

  render_template "$REPO_DIR/launchd/$LABEL_REBOOT.plist.tmpl" "$WORK_DIR/$LABEL_REBOOT.plist" \
    "LABEL=$LABEL_REBOOT" "WEEKDAY_XML=$(reboot_weekday_xml)" "HOUR=$REBOOT_HOUR" "MINUTE=$REBOOT_MINUTE"
  plutil -lint -s "$WORK_DIR/$LABEL_REBOOT.plist" || die "bad plist: $LABEL_REBOOT"
  sudo install -o root -g wheel -m 644 "$WORK_DIR/$LABEL_REBOOT.plist" "$dst"
  bootstrap_retry system "$dst" || warn "could not load $LABEL_REBOOT; it will load at next boot"
  ok "$REBOOT_SCHEDULE"
}
