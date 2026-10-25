#!/bin/bash
# Finds which preference keys the AirPlay Receiver settings use on this macOS
# version, so node-agent.sh can set them. Apple doesn't document them, and
# they have changed between releases.
#
# Run in Terminal at the Mac's screen, logged in as the user whose settings
# you will change (the audio user):
#   ./tools/find-airplay-keys.sh
#
# If the keys differ from KEY_ENABLED / KEY_ACCESS in agent/node-agent.sh,
# update them there and re-run bootstrap.sh.

set -euo pipefail
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

snapshot() {
  {
    echo "## defaults -currentHost read com.apple.controlcenter"
    defaults -currentHost read com.apple.controlcenter 2>/dev/null || true
    echo "## defaults read com.apple.controlcenter"
    defaults read com.apple.controlcenter 2>/dev/null || true
    echo "## defaults read com.apple.airplay"
    defaults read com.apple.airplay 2>/dev/null || true
  } > "$1"
}

snapshot "$tmp/before"
touch "$tmp/marker"
sleep 1

cat <<'EOF'
Now open System Settings > General > AirDrop & Handoff and change the AirPlay
Receiver settings: turn it off and on, and switch "Allow AirPlay for" between
"Current User" and "Anyone on the same network".

EOF
read -r -p "Press Enter when done... " _

snapshot "$tmp/after"

echo
echo "=== Changes in the ControlCenter / AirPlay preferences ==="
diff "$tmp/before" "$tmp/after" || true

echo
echo "=== Preference files changed in the last few minutes (other places to look) ==="
find "$HOME/Library/Preferences" /Library/Preferences -name '*.plist' -newer "$tmp/marker" 2>/dev/null || true

cat <<'EOF'

Current values in node-agent.sh:
  KEY_ENABLED = AirplayRecieverEnabled      (-currentHost com.apple.controlcenter, bool)
  KEY_ACCESS  = AirplayReceiverAdvertising  (-currentHost com.apple.controlcenter, int 1/2/3)
EOF
