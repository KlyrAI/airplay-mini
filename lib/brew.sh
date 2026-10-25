# shellcheck shell=bash
# Homebrew and the packages the node needs.

setup_brew() {
  step "Homebrew"

  if [ ! -x "$BREW" ]; then
    info "installing Homebrew (also installs the Xcode Command Line Tools; takes a few minutes)"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
      || die "Homebrew install failed"
  fi
  eval "$("$BREW" shellenv)"
  brew analytics off >/dev/null 2>&1 || true
  ok "Homebrew $(brew --version | head -n 1 | awk '{print $2}')"

  # Put brew on PATH for the admin user's future SSH sessions.
  local zprofile="$HOME/.zprofile"
  if ! grep -qs 'brew shellenv' "$zprofile"; then
    # shellcheck disable=SC2016  # the $(...) is for .zprofile to run later
    printf '\neval "$(%s shellenv)"\n' "$BREW" >> "$zprofile"
    ok "added brew to $zprofile"
  fi

  local pkgs="switchaudio-osx tailscale"
  [ "$SPOTIFY_ENABLED" = "true" ] && pkgs="$pkgs spotifyd"
  local pkg
  for pkg in $pkgs; do
    if brew list --formula "$pkg" >/dev/null 2>&1; then
      ok "$pkg already installed"
    else
      info "installing $pkg"
      brew install "$pkg" || die "brew install $pkg failed"
      ok "$pkg installed"
    fi
  done
}
