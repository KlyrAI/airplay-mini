# shellcheck shell=bash
# The standard (non-admin) account that auto-logs in and owns the audio session.

setup_audio_user() {
  step "Audio user '$AUDIO_USER'"

  if id "$AUDIO_USER" >/dev/null 2>&1; then
    # Auto-login stores this password; a mismatch makes it fail silently at boot.
    dscl . -authonly "$AUDIO_USER" "$AUDIO_USER_PASSWORD" >/dev/null 2>&1 \
      || die "AUDIO_USER_PASSWORD does not match the existing '$AUDIO_USER' account"
    ok "user exists, password matches"
  else
    # sysadminctl can exit 0 on failure, so check that the user exists afterwards.
    # The password is briefly visible in the process list while this runs.
    sudo sysadminctl -addUser "$AUDIO_USER" \
      -fullName "$AUDIO_USER_FULLNAME" \
      -password "$AUDIO_USER_PASSWORD" \
      -home "/Users/$AUDIO_USER" >/dev/null 2>&1 || true
    id "$AUDIO_USER" >/dev/null 2>&1 || die "sysadminctl could not create user '$AUDIO_USER'"
    ok "user created"
  fi

  # sysadminctl does not always create the home folder until first login.
  sudo createhomedir -c -u "$AUDIO_USER" >/dev/null 2>&1 || true
  AUDIO_HOME=$(user_home "$AUDIO_USER")
  [ -n "$AUDIO_HOME" ] && [ -d "$AUDIO_HOME" ] || die "no home folder for '$AUDIO_USER'"

  case "$(dseditgroup -o checkmember -m "$AUDIO_USER" admin 2>/dev/null || true)" in
    yes*) die "'$AUDIO_USER' is an admin. Auto-login must use a standard account; pick another AUDIO_USER or remove admin rights." ;;
  esac
  ok "standard account (not admin), home $AUDIO_HOME"

  if sudo sysadminctl -autologin set -userName "$AUDIO_USER" -password "$AUDIO_USER_PASSWORD" >/dev/null 2>&1 \
     && [ "$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)" = "$AUDIO_USER" ]; then
    ok "auto-login set"
  else
    warn "auto-login not confirmed. Set it in System Settings > Users & Groups > Automatically log in as: $AUDIO_USER"
  fi
}
