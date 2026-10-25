# shellcheck shell=bash disable=SC2034  # constants are used by the scripts that source this file
# Shared helpers for bootstrap.sh, status.sh and uninstall.sh.
# Targets macOS /bin/bash 3.2: no associative arrays, no ${var,,}, no mapfile.

INSTALL_DIR="/usr/local/airplay-mini"
AGENT_ENV="$INSTALL_DIR/agent.env"
BREW_PREFIX="/opt/homebrew"
BREW="$BREW_PREFIX/bin/brew"

LABEL_AGENT="com.airplaymini.agent"
LABEL_SPOTIFYD="com.airplaymini.spotifyd"
LABEL_REBOOT="com.airplaymini.reboot"

WARNINGS=""

if [ -t 1 ]; then
  C_BLUE=$'\033[1;34m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_RED=$'\033[31m' C_OFF=$'\033[0m'
else
  C_BLUE="" C_GREEN="" C_YELLOW="" C_RED="" C_OFF=""
fi

step() { printf '\n%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
ok()   { printf '  %sok%s    %s\n' "$C_GREEN" "$C_OFF" "$*"; }
info() { printf '        %s\n' "$*"; }
warn() {
  printf '  %swarn%s  %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2
  WARNINGS="${WARNINGS}  - $*"$'\n'
}
die()  { printf '\n%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# Lowercase slug for hostnames: "Lobby Audio" -> "lobby-audio".
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed -e 's/^-*//' -e 's/-*$//'
}

# Home directory of a local user, from Directory Services.
user_home() {
  dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
}

# True if the user has a GUI (Aqua) session right now, i.e. is logged in at
# the screen. LaunchAgents can only be loaded into such a session.
has_gui_session() {
  local uid
  uid=$(id -u "$1" 2>/dev/null) || return 1
  sudo launchctl print "gui/$uid" >/dev/null 2>&1
}

# render_template SRC DST KEY=VALUE...
# Replaces @KEY@ in SRC and writes DST. Values are inserted literally.
render_template() {
  local src=$1 dst=$2 content pair key val
  shift 2
  content=$(cat "$src")
  for pair in "$@"; do
    key=${pair%%=*}
    val=${pair#*=}
    content=${content//@$key@/$val}
  done
  case "$content" in
    *@[A-Z_]*@*) die "unfilled placeholder left in $src" ;;
  esac
  printf '%s\n' "$content" > "$dst"
}

# bootout_quietly DOMAIN LABEL: stop a launchd job if it is loaded.
bootout_quietly() {
  sudo launchctl bootout "$1/$2" >/dev/null 2>&1 || true
}
