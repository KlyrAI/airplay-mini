#!/bin/bash
# Exercises agent/node-agent.sh against mocked macOS tools, so the watchdog
# logic can be tested anywhere bash runs (macOS, Linux, Git Bash).
#
#   ./tests/agent-test.sh
#
# Mocks: SwitchAudioSource, nc, defaults, osascript, killall, pgrep, curl,
# stat. Each mock reads its state from files in $MOCK and appends what it was
# asked to do to $MOCK/calls.

# Mock bodies are literal text written to files, so single quotes are intended.
# shellcheck disable=SC2016
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AGENT="$ROOT/agent/node-agent.sh"

T=$(mktemp -d)
MOCK="$T/mock"
BIN="$T/bin"
export HOME="$T/home"
mkdir -p "$MOCK" "$BIN" "$HOME/Library/Logs"
export MOCK
trap 'rm -rf "$T"' EXIT

PASS=0 FAILED=0
check() { # check DESCRIPTION COMMAND...
  if "${@:2}"; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"
  else FAILED=$((FAILED + 1)); printf '  FAIL  %s\n' "$1"; fi
}
count() { grep -cF -- "$1" "$2" 2>/dev/null || true; }
at_least() { [ "$(count "$2" "$3")" -ge "$1" ]; }   # at_least N TEXT FILE
wait_for() { # wait_for SECONDS COMMAND...: retry COMMAND until it passes or time runs out
  local deadline=$(( $(date +%s) + $1 ))
  shift
  until "$@"; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.1
  done
}
calls() { cat "$MOCK/calls" 2>/dev/null; }

# ------------------------------------------------------------------- mocks

mock() { printf '#!/bin/bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }

mock SwitchAudioSource '
case "$*" in
  "-c -t output") cat "$MOCK/current" ;;
  "-a -t output") cat "$MOCK/devices" ;;
  "-t output -s "*)
    all="$*"
    dev=${all#-t output -s }
    sed "s/ (output)\$//" "$MOCK/devices" | grep -qxF -- "$dev" || exit 1
    printf "%s\n" "$dev" > "$MOCK/current"
    echo "switch $dev" >> "$MOCK/calls" ;;
  *) echo "SwitchAudioSource: unexpected args $*" >> "$MOCK/calls"; exit 2 ;;
esac'

mock nc '[ -f "$MOCK/airplay_up" ]'

mock killall '
echo "killall $*" >> "$MOCK/calls"
[ "$1" = ControlCenter ] && [ -f "$MOCK/heal_on_restart" ] && touch "$MOCK/airplay_up"
exit 0'

mock pgrep '[ -f "$MOCK/spotifyd_up" ]'
mock osascript 'echo "osascript $*" >> "$MOCK/calls"'
mock curl 'for a in "$@"; do last=$a; done; echo "curl $last" >> "$MOCK/calls"'
mock stat 'wc -c < "${!#}" | tr -d " "'

# Minimal key store: "domain|key|value" lines.
mock defaults '
[ "$1" = -currentHost ] && shift
op=$1; shift
if [ "$1" = -g ]; then domain=NSGlobalDomain; shift; else domain=$1; shift; fi
key=$1; shift
case $op in
  read)
    line=$(grep -F "$domain|$key|" "$MOCK/defaults.db" 2>/dev/null | tail -n 1)
    [ -n "$line" ] || exit 1
    echo "${line##*|}" ;;
  write)
    val=$2
    [ "$1" = -bool ] && { [ "$val" = true ] && val=1 || val=0; }
    echo "$domain|$key|$val" >> "$MOCK/defaults.db"
    echo "defaults write $domain $key $val" >> "$MOCK/calls" ;;
esac'

export PATH="$BIN:$PATH"
export AIRPLAY_MINI_SWITCH="$BIN/SwitchAudioSource"
export AIRPLAY_MINI_ENV="$T/agent.env"
export AIRPLAY_MINI_INTERVAL=0.3

cat > "$AIRPLAY_MINI_ENV" <<'EOF'
DEVICE_NAME='Test Room'
AUDIO_USER=audio
OUTPUT_MATCH=USB
LOGIN_VOLUME=65
AIRPLAY_ACCESS=same-network
SPOTIFY_ENABLED=true
HEALTHCHECK_URL=https://hc.example/abc
BOOTSTRAP_VERSION=test
EOF

LOG="$HOME/Library/Logs/airplay-mini.log"

# stop_agent PID: send TERM and fail the test if it takes over 2 s to exit.
stop_agent() {
  kill -TERM "$1"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.2
  done
  kill -9 "$1" 2>/dev/null
  return 1
}

# Print the agent log and mock calls when a run had failures.
RUN_FAILED_BEFORE=0
dump_if_failed() {
  [ "$FAILED" -eq "$RUN_FAILED_BEFORE" ] && return 0
  RUN_FAILED_BEFORE=$FAILED
  echo "  --- agent log"; sed 's/^/  | /' "$LOG" | grep -v xxxxxxxx
  echo "  --- mock calls"; sed 's/^/  | /' "$MOCK/calls"
}

# ------------------------------------------------------------ run 1: faults

echo "Run 1: fresh user, DAC missing, AirPlay down, then recovery"
printf '%s\n' "Mac mini Speakers (output)" > "$MOCK/devices"
echo "Mac mini Speakers" > "$MOCK/current"
touch "$MOCK/spotifyd_up"
rm -f "$MOCK/airplay_up" "$MOCK/heal_on_restart"
: > "$MOCK/calls"

bash "$AGENT" &
PID=$!

# Each step waits for the agent to react rather than sleeping a fixed time:
# forks are slow on some hosts (Git Bash), and the agent pauses 3 s after
# restarting ControlCenter.
check "AirPlay turned on at first start" wait_for 10 grep -qF "defaults write com.apple.controlcenter AirplayRecieverEnabled 1" "$MOCK/calls"
check "AirPlay access set to same network (2)" wait_for 5 grep -qF "defaults write com.apple.controlcenter AirplayReceiverAdvertising 2" "$MOCK/calls"
check "alert volume muted" grep -qF "osascript -e set volume alert volume 0" "$MOCK/calls"
# The settings change restarts ControlCenter once. Only after that does a
# restart "fix" AirPlay, so the watchdog's own restart path gets exercised.
check "ControlCenter restarted for the new settings" wait_for 10 at_least 1 "killall ControlCenter" "$MOCK/calls"
touch "$MOCK/heal_on_restart"
check "missing DAC reported" wait_for 10 grep -qF "problems: output-missing" "$LOG"
check "fail ping sent" wait_for 5 grep -qF "curl https://hc.example/abc/fail" "$MOCK/calls"
check "ControlCenter restarted after 3 AirPlay misses" wait_for 15 at_least 2 "killall ControlCenter" "$MOCK/calls"
check "AirPlay recovery logged" wait_for 10 grep -qF "airplay: answering again" "$LOG"

printf '%s\n' "Mac mini Speakers (output)" "USB Audio Device (output)" > "$MOCK/devices.new"
mv "$MOCK/devices.new" "$MOCK/devices"
check "switched output to the DAC" wait_for 10 grep -qF "switch USB Audio Device" "$MOCK/calls"
check "recovery logged" wait_for 10 grep -qF "all checks ok" "$LOG"
check "ok ping sent after recovery" wait_for 5 grep -qxF "curl https://hc.example/abc" "$MOCK/calls"

rm -f "$MOCK/spotifyd_up"
check "spotifyd outage logged" wait_for 10 grep -qF "spotifyd: not running" "$LOG"
touch "$MOCK/spotifyd_up"
check "spotifyd recovery logged" wait_for 10 grep -qF "spotifyd: running again" "$LOG"

echo "HDMI" > "$MOCK/current"   # something steals the default output
check "stolen output switched back" wait_for 10 at_least 2 "switch USB Audio Device" "$MOCK/calls"
check "agent exits promptly on TERM" stop_agent "$PID"

check "login volume set exactly once" test "$(count "set volume output volume 65" "$MOCK/calls")" -eq 1
check "fail pings only on change (4 changes)" test "$(count "curl https://hc.example/abc/fail" "$MOCK/calls")" -le 5
check "final output is the DAC" grep -qxF "USB Audio Device" "$MOCK/current"
check "stop logged" grep -qF "stopping" "$LOG"
check "mock tools never got unexpected args" bash -c '! grep -q unexpected "$MOCK/calls"'
dump_if_failed

# --------------------------------------------- run 2: healthy restart + rotation

echo "Run 2: prefs already set, everything healthy, big log"
touch "$MOCK/airplay_up"
: > "$MOCK/calls"
head -c 1100000 /dev/zero | tr '\0' 'x' > "$LOG"

bash "$AGENT" &
PID=$!
check "healthy ping on start" wait_for 10 grep -qxF "curl https://hc.example/abc" "$MOCK/calls"
check "agent exits promptly on TERM" stop_agent "$PID"

check "no ControlCenter restart when prefs already right" test "$(count "killall" "$MOCK/calls")" -eq 0
check "no prefs rewritten for AirPlay" bash -c '! grep -q "controlcenter" "$MOCK/calls"'
check "no fail ping" bash -c '! grep -qF "/fail" "$MOCK/calls"'
check "log rotated past 1 MB" test -f "$LOG.1"
check "new log is small" test "$(wc -c < "$LOG")" -lt 10000
dump_if_failed

# ------------------------------------------------- run 3: missing env file

echo "Run 3: agent.env missing"
mv "$AIRPLAY_MINI_ENV" "$AIRPLAY_MINI_ENV.bak"
bash "$AGENT" &
PID=$!
check "missing agent.env logged" wait_for 10 grep -qF "missing $AIRPLAY_MINI_ENV" "$LOG"
kill "$PID" 2>/dev/null
mv "$AIRPLAY_MINI_ENV.bak" "$AIRPLAY_MINI_ENV"

echo
echo "$PASS passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
