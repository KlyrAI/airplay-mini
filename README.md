# airplay-mini

Turns an Apple Silicon Mac mini into a headless speaker for a client space:
phones play to it over **AirPlay** or **Spotify Connect**, and it feeds a
preamp. IT can reach it remotely over **Tailscale** with no firewall changes
at the client.

One script, `bootstrap.sh`, sets everything up and is safe to re-run. After
that, launchd runs it all: a watchdog that keeps the audio path healthy, and
spotifyd for Spotify Connect.

For day-to-day support, see [RUNBOOK.md](RUNBOOK.md).

## How it works

- **AirPlay:** macOS's own AirPlay Receiver (AirPlay 2, maintained by Apple).
  Nothing to install. It runs inside a logged-in session, so the Mac
  auto-logs in to a standard account, `audio`.
- **Spotify Connect:** `spotifyd` (Homebrew), run as the `audio` user. Phones
  on the same network see the speaker. Senders need Spotify Premium.
- **Watchdog** (`agent/node-agent.sh`): every 30 s it puts the output back
  on the DAC if anything else takes over, restarts the AirPlay receiver if it
  stops answering, and pings an optional healthcheck URL. It also mutes
  alert and UI sounds so they never reach the preamp.
- **Remote access:** the open-source `tailscaled`, installed as a system
  daemon so it is up before login, with Tailscale SSH and macOS Screen
  Sharing over the tailnet.
- **Self-recovery:** never sleeps, boots by itself after a power cut,
  restarts after a freeze, and reboots weekly (optional).

Why not Volumio: it is a Linux OS image and does not run on Apple Silicon.
Why not an Electron app: a headless box has no screen to show it on, and
launchd already handles start-at-boot and restart-on-crash.

## Before you start: check the cable

Macs do not support *passive* USB-C to RCA cables (the kind sold for
Android phones). The cable needs a DAC inside it. Plug it in and open
System Settings > Sound > Output: if it is listed there, it works. If not,
use the Mac mini's 3.5 mm headphone jack with a 3.5 mm to RCA cable and set
`OUTPUT_MATCH="External Headphones"`.

## Set up at the bench (monitor and keyboard attached)

1. Update macOS. In Setup Assistant, create the admin account IT will use
   (e.g. `support`) with a strong password. **Leave FileVault off**
   (auto-login needs it off).
2. Create a Tailscale auth key: pre-approved, tagged `tag:audio-node`, and
   add the ACL from [RUNBOOK.md](RUNBOOK.md#tailscale-admin-setup).
3. Get this folder onto the Mac (git clone, AirDrop or a USB stick), then:
   ```sh
   cd airplay-mini
   cp config.env.example config.env
   open -e config.env          # fill in the name, password, auth key
   ./bootstrap.sh
   ```
4. Do the manual steps it prints. Apple blocks these from scripts without
   MDM:
   - turn on Screen Sharing for `support` only;
   - log in once as `audio` and click through Setup Assistant;
   - confirm AirPlay Receiver is set to "Anyone on the same network".
5. While logged in as `audio`, run `./tools/find-airplay-keys.sh` once and
   toggle the AirPlay Receiver settings. It shows which preference keys this
   macOS version uses. If they differ from the ones in
   `agent/node-agent.sh`, update them there and re-run `./bootstrap.sh`.
   Apple doesn't document these keys.
6. Reboot. It should log in as `audio` by itself. Then run
   `/usr/local/airplay-mini/status.sh`; every line should be `ok`.
7. Test: AirPlay from an iPhone, Spotify Connect from the Spotify app, then
   the failure drills in [RUNBOOK.md](RUNBOOK.md#failure-drills).
8. Optional: `./tools/claude-setup.sh` installs Claude Code, so you can
   SSH in later and run `airplay-doctor` to troubleshoot. No IDE needed.
   See [RUNBOOK.md](RUNBOOK.md#troubleshoot-with-claude). You can also run
   it before bootstrap, to get help if bootstrap fails.

The repo is private, so cloning on the Mac needs GitHub access: either
`brew install gh && gh auth login && gh repo clone KlyrAI/airplay-mini`
(Homebrew needs installing first), or download the zip from GitHub on
another machine and copy it over.

## On site

- Wired Ethernet with a DHCP reservation.
- **The same network (VLAN) as the phones that will play to it, with
  client isolation off.** AirPlay and Spotify Connect discovery do not
  cross VLANs, and most guest Wi-Fi blocks it.
- Run `status.sh` again from a phone's network: the `mdns` lines must pass.

## Files

| Path | What |
|---|---|
| `bootstrap.sh` | Entry point. Validates `config.env`, then runs the steps in `lib/`. |
| `config.env.example` | Per-site settings, documented inline. Copy to `config.env` (gitignored). |
| `lib/system.sh` | Names, power, startup chime, update policy, Bluetooth assistant. |
| `lib/users.sh` | Creates the `audio` user and sets auto-login. |
| `lib/brew.sh` | Homebrew + `switchaudio-osx`, `tailscale`, `spotifyd`. |
| `lib/tailscale.sh` | tailscaled system daemon + login with Tailscale SSH. |
| `lib/agents.sh` | Installs scripts to `/usr/local/airplay-mini` and the launchd jobs. |
| `agent/node-agent.sh` | The watchdog, run as `audio` by launchd. |
| `launchd/*.plist.tmpl` | Watchdog, spotifyd and weekly-reboot jobs. |
| `templates/spotifyd.conf.tmpl` | spotifyd config. |
| `status.sh` | Health report for IT (also installed to `/usr/local/airplay-mini`). |
| `uninstall.sh` | Removes the jobs and installed scripts. Leaves Tailscale. |
| `tools/find-airplay-keys.sh` | Finds the AirPlay Receiver preference keys on a new macOS. |
| `tools/doctor.sh` | Diagnostics and safe fixes as root; installed as `/usr/local/airplay-mini/doctor`. |
| `tools/claude-setup.sh` | Installs Claude Code + the `airplay-doctor` command for troubleshooting over SSH. |
| `tools/claude/doctor-prompt.md` | On-device rules `airplay-doctor` gives Claude. |
| `.claude/settings.json`, `CLAUDE.md` | Claude Code permissions and project notes. |
| `tests/` | Runs anywhere bash runs, with macOS tools mocked. |

## Tests

```sh
./tests/agent-test.sh       # watchdog: DAC loss, AirPlay restart, spotifyd, healthcheck, log rotation
./tests/bootstrap-test.sh   # config validation, rendered plists/TOML, reboot-loop guard
```

The scripts target macOS's `/bin/bash` 3.2, so avoid bash 4+ features.
Lint with `shellcheck -x` (or `uvx --from shellcheck-py shellcheck -x`).

## Not yet verified on a real Mac

- The AirPlay preference keys (`AirplayRecieverEnabled`,
  `AirplayReceiverAdvertising`) come from community reports. Check them with
  `tools/find-airplay-keys.sh`.
- spotifyd's own mDNS responder alongside macOS's. If the speaker doesn't
  show in the Spotify app, see the runbook; `librespot` is the fallback.
- `sysadminctl -autologin set`. If it fails, bootstrap warns and you set
  auto-login in System Settings > Users & Groups.
