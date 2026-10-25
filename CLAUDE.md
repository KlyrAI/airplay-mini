# airplay-mini

Bash provisioning for a headless Apple Silicon Mac mini that acts as an
AirPlay + Spotify Connect speaker at a client site. README.md explains the
design; RUNBOOK.md is the IT guide.

- Entry point `bootstrap.sh` sources `lib/*.sh`. It runs on the Mac as the
  admin user and is idempotent.
- `agent/node-agent.sh` is the watchdog, run by launchd as the `audio` user.
- `tools/doctor.sh` is installed as `/usr/local/airplay-mini/doctor`, the
  only thing Claude can run as root on the device (via a sudoers rule from
  `tools/claude-setup.sh`).
- On-device troubleshooting rules live in `tools/claude/doctor-prompt.md`.
  The `airplay-doctor` launcher appends them to the system prompt; they
  don't apply to development sessions.

## Rules for changes

- Target macOS `/bin/bash` 3.2: no associative arrays, `${var,,}`, `mapfile`,
  or `&` in pattern substitutions.
- Keep `set -euo pipefail` pitfalls in mind: `cmd | grep -q` can fail under
  pipefail, and a failing `[ ]` as a function's last command fails it.
- Lint: `shellcheck -x -s bash` on every `.sh` (`uvx --from shellcheck-py
  shellcheck` works on Windows).
- Tests: `./tests/agent-test.sh` and `./tests/bootstrap-test.sh`. They mock
  the macOS tools and run under Git Bash.
- Files must stay LF (`.gitattributes`); new scripts need
  `git update-index --chmod=+x` when committed from Windows.
- Never commit `config.env` (gitignored; holds a password and the Tailscale
  key).
