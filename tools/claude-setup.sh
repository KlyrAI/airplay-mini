#!/bin/bash
# Sets up Claude Code on this Mac for troubleshooting over SSH. No IDE needed.
#
#   ./tools/claude-setup.sh                   # once, as the admin user (SSH is fine)
#   airplay-doctor                            # then: Claude runs a health check
#   airplay-doctor "spotify isn't showing"    # or starts from your description
#   airplay-doctor --continue                 # resume the last session
#
# Installs:
#   - Claude Code (native installer: ~/.local/bin/claude, auto-updates)
#   - /usr/local/airplay-mini/doctor: fixed diagnostics and safe fixes, run as root
#   - /etc/sudoers.d/airplay-doctor: lets this admin user run doctor, and only
#     doctor, without a password, so Claude can use it
#   - /usr/local/bin/airplay-doctor: starts Claude in this repo with the
#     on-device rules in tools/claude/doctor-prompt.md
#
# First run of airplay-doctor: accept the folder trust prompt, then log in
# with your Claude account. Over SSH, press c to copy the login URL, open it
# on your laptop, and paste the code it shows back into the terminal.
# Remove everything with: ./uninstall.sh (also removes these).

set -euo pipefail
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
. "$REPO_DIR/lib/common.sh"

ADMIN=$(id -un)
SUDOERS=/etc/sudoers.d/airplay-doctor
LAUNCHER=/usr/local/bin/airplay-doctor
CLAUDE_BIN="$HOME/.local/bin/claude"

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown option '$1'" ;;
esac

step "Preflight"
[ "$(uname -s)" = "Darwin" ] || die "run this on the Mac"
ver=$(sw_vers -productVersion)
[ "${ver%%.*}" -ge 13 ] || die "Claude Code needs macOS 13 or newer (found $ver)"
[ "$(id -u)" -ne 0 ] || die "run as your admin user, without sudo"
case " $(id -Gn) " in *" admin "*) ;; *) die "'$ADMIN' is not an admin" ;; esac
[[ $ADMIN =~ ^[a-z_][a-z0-9_-]*$ ]] || die "unexpected user name '$ADMIN'"
sudo -v || die "sudo is needed"
ok "macOS $ver, admin '$ADMIN'"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

step "doctor helper"
sudo install -d -o root -g wheel -m 755 "$INSTALL_DIR" "$INSTALL_DIR/lib" /usr/local/bin
sudo install -o root -g wheel -m 755 "$REPO_DIR/tools/doctor.sh" "$INSTALL_DIR/doctor"
sudo install -o root -g wheel -m 644 "$REPO_DIR/lib/common.sh" "$INSTALL_DIR/lib/common.sh"
ok "$INSTALL_DIR/doctor"
[ -f "$AGENT_ENV" ] || warn "bootstrap.sh hasn't run yet. doctor works once it has; until then Claude can still read the repo and help with bootstrap."

step "Password-free sudo for doctor only"
cat > "$WORK/sudoers" <<EOF
# Installed by airplay-mini tools/claude-setup.sh.
# Lets $ADMIN run the doctor helper as root without a password, so Claude
# Code can troubleshoot over SSH. doctor only runs fixed diagnostics and safe
# fixes (see $INSTALL_DIR/doctor help). Delete this file to revoke.
$ADMIN ALL=(root) NOPASSWD: $INSTALL_DIR/doctor
EOF
sudo /usr/sbin/visudo -cf "$WORK/sudoers" >/dev/null || die "generated sudoers rule failed visudo check"
sudo install -o root -g wheel -m 440 "$WORK/sudoers" "$SUDOERS"
ok "$SUDOERS"

step "Claude Code"
if [ -x "$CLAUDE_BIN" ]; then
  ok "already installed ($("$CLAUDE_BIN" --version 2>/dev/null | head -n 1))"
else
  info "installing with the native installer"
  curl -fsSL https://claude.ai/install.sh | bash || die "Claude Code install failed"
  [ -x "$CLAUDE_BIN" ] || die "installer finished but $CLAUDE_BIN is missing"
  ok "installed ($("$CLAUDE_BIN" --version 2>/dev/null | head -n 1))"
fi
if ! grep -qs '.local/bin' "$HOME/.zprofile"; then
  # shellcheck disable=SC2016  # expanded later by zsh, not here
  printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.zprofile"
  ok "added ~/.local/bin to PATH in ~/.zprofile"
fi

step "airplay-doctor command"
cat > "$WORK/airplay-doctor" <<EOF
#!/bin/bash
# airplay-doctor: Claude Code in the airplay-mini repo with the on-device
# troubleshooting rules. Installed by $REPO_DIR/tools/claude-setup.sh.
#   airplay-doctor                   health check and diagnosis
#   airplay-doctor "describe issue"  start from a description
#   airplay-doctor --continue        resume the last session
cd "$REPO_DIR" || exit 1
CLAUDE="\$HOME/.local/bin/claude"
if [ ! -x "\$CLAUDE" ]; then
  CLAUDE=\$(command -v claude) || { echo "Claude Code isn't installed. Run $REPO_DIR/tools/claude-setup.sh" >&2; exit 1; }
fi
if [ \$# -eq 0 ]; then
  set -- "Run the doctor status check, then tell me what's wrong, if anything, and what you would do about it."
fi
exec "\$CLAUDE" --append-system-prompt-file "$REPO_DIR/tools/claude/doctor-prompt.md" "\$@"
EOF
bash -n "$WORK/airplay-doctor" || die "generated launcher has a syntax error"
sudo install -o root -g wheel -m 755 "$WORK/airplay-doctor" "$LAUNCHER"
ok "$LAUNCHER"

step "Check"
sudo -k   # drop the cached password, so this tests the sudoers rule itself
if sudo -n "$INSTALL_DIR/doctor" help >/dev/null 2>&1; then
  ok "doctor runs as root without a password"
else
  warn "sudo -n doctor failed; check $SUDOERS"
fi

if [ -n "$WARNINGS" ]; then
  step "Warnings"
  printf '%s' "$WARNINGS"
fi

cat <<EOF

Ready. Start it with:  airplay-doctor

First run: accept "trust this folder", then log in with your Claude account.
Over SSH, press c to copy the login URL, open it on your laptop, and paste
the code it shows back here.
EOF

if [ -t 0 ] && [ -t 1 ]; then
  printf '\nStart airplay-doctor now? [Y/n] '
  read -r answer
  case "$answer" in [nN]*) exit 0 ;; esac
  exec "$LAUNCHER"
fi
