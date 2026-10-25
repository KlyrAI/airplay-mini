# shellcheck shell=bash
# Shairport Sync (AirPlay 2 receiver) and NQPTP (its timing companion), built
# from pinned, checksummed source.
#
# Homebrew's shairport-sync formula is classic AirPlay only: no AirPlay 2 and
# no CoreAudio backend. Both arrived on macOS in Shairport Sync 5.6 /
# NQPTP 1.2.9. Both programs run as the audio user (LaunchAgents): NQPTP
# shares its clock with Shairport Sync through POSIX shared memory, and macOS
# lets ordinary users bind NQPTP's ports 319/320.

SHAIRPORT_VERSION="5.6.1"
SHAIRPORT_SHA256="48d2ac1afa52d86766bc328694fa5d2d5f13a674f3e980f00d95d957453e5ee1"
NQPTP_VERSION="1.2.9"
NQPTP_SHA256="6aa1d73b8ee760bf19378c319db0d0537a867ff961764b150e19f87d96a02210"

SPS_BIN="/usr/local/bin/shairport-sync"
NQPTP_BIN="/usr/local/bin/nqptp"
# Build tools + AirPlay 2 libraries. plistutil comes with libplist; xxd ships
# with macOS. These stay installed: shairport-sync links against them.
SPS_BREW_DEPS="autoconf automake pkgconf popt libconfig libsodium libgcrypt libplist ffmpeg openssl@3"

# True if the installed binaries are the pinned versions and still run
# (a Homebrew upgrade of a linked library can break them).
shairport_ok() {
  case "$("$SPS_BIN" -V 2>/dev/null || true)" in
    "$SHAIRPORT_VERSION"-AirPlay2*) return 0 ;;
  esac
  return 1
}
nqptp_ok() {
  case "$("$NQPTP_BIN" -V 2>/dev/null || true)" in
    *"Version: $NQPTP_VERSION."*) return 0 ;;
  esac
  return 1
}

# fetch_source URL SHA256 FILE
fetch_source() {
  curl -fsSL -o "$3" "$1" || die "download failed: $1"
  local got
  got=$(shasum -a 256 "$3" | awk '{print $1}')
  [ "$got" = "$2" ] || die "checksum mismatch for $1 (expected $2, got $got)"
}

# build_project NAME DIR CONFIGURE_ARGS...: autoreconf, configure, make,
# sudo make install. Output goes to the build log.
build_project() {
  local name=$1 dir=$2
  shift 2
  info "building $name (log: $SPS_BUILD_LOG)"
  (
    cd "$dir" || exit 1
    ssl=$(brew --prefix openssl@3)
    export PATH="$BREW_PREFIX/bin:$PATH"
    export PKG_CONFIG_PATH="$ssl/lib/pkgconfig:$BREW_PREFIX/lib/pkgconfig"
    export CPPFLAGS="-I$BREW_PREFIX/include -I$ssl/include"
    export LDFLAGS="-L$BREW_PREFIX/lib -L$ssl/lib"
    autoreconf -fi && ./configure --prefix=/usr/local "$@" && make -j "$(sysctl -n hw.ncpu)"
  ) >>"$SPS_BUILD_LOG" 2>&1 || die "$name build failed. Last lines of $SPS_BUILD_LOG:
$(tail -n 15 "$SPS_BUILD_LOG")"
  # The log belongs to the admin user, so the redirect is meant to run unprivileged.
  # shellcheck disable=SC2024
  sudo make -C "$dir" install >>"$SPS_BUILD_LOG" 2>&1 || die "$name install failed; see $SPS_BUILD_LOG"
}

setup_shairport() {
  step "AirPlay receiver: Shairport Sync $SHAIRPORT_VERSION + NQPTP $NQPTP_VERSION"

  if [ "${AIRPLAY_MINI_REBUILD:-}" != "1" ] && shairport_ok && nqptp_ok; then
    ok "already built ($("$SPS_BIN" -V 2>/dev/null))"
    return 0
  fi

  local pkg missing=""
  for pkg in $SPS_BREW_DEPS; do
    brew list --formula "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
  done
  if [ -n "$missing" ]; then
    info "installing build dependencies:$missing (ffmpeg takes a few minutes)"
    # shellcheck disable=SC2086  # word-split the package list
    brew install $missing || die "brew install failed for:$missing"
  fi
  command -v xxd >/dev/null 2>&1 || die "xxd not found (it ships with macOS; is /usr/bin on PATH?)"
  ok "build dependencies installed"

  local src="$HOME/Library/Caches/airplay-mini/build"
  SPS_BUILD_LOG="$HOME/Library/Logs/airplay-mini-build.log"
  rm -rf "$src"
  mkdir -p "$src" "$(dirname "$SPS_BUILD_LOG")"
  : > "$SPS_BUILD_LOG"

  # NQPTP first: Shairport Sync must match its shared-memory interface (smi11).
  if [ "${AIRPLAY_MINI_REBUILD:-}" = "1" ] || ! nqptp_ok; then
    fetch_source "https://github.com/mikebrady/nqptp/archive/refs/tags/$NQPTP_VERSION.tar.gz" \
      "$NQPTP_SHA256" "$src/nqptp.tar.gz"
    tar -xzf "$src/nqptp.tar.gz" -C "$src"
    build_project "NQPTP $NQPTP_VERSION" "$src/nqptp-$NQPTP_VERSION"
    nqptp_ok || die "NQPTP installed but '$NQPTP_BIN -V' does not report $NQPTP_VERSION"
    ok "NQPTP $NQPTP_VERSION installed"
  fi

  if [ "${AIRPLAY_MINI_REBUILD:-}" = "1" ] || ! shairport_ok; then
    fetch_source "https://github.com/mikebrady/shairport-sync/archive/refs/tags/$SHAIRPORT_VERSION.tar.gz" \
      "$SHAIRPORT_SHA256" "$src/shairport-sync.tar.gz"
    tar -xzf "$src/shairport-sync.tar.gz" -C "$src"
    build_project "Shairport Sync $SHAIRPORT_VERSION" "$src/shairport-sync-$SHAIRPORT_VERSION" \
      --sysconfdir=/usr/local/etc --with-os=darwin --with-airplay-2 \
      --with-coreaudio --with-dns_sd --with-ssl=openssl
    shairport_ok || die "Shairport Sync installed but '$SPS_BIN -V' does not report $SHAIRPORT_VERSION-AirPlay2"
    ok "Shairport Sync installed ($("$SPS_BIN" -V 2>/dev/null))"
  fi
}
