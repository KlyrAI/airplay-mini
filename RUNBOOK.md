# airplay-mini runbook

For IT support. This Mac mini is a speaker: phones play to it over AirPlay
or Spotify Connect, and it sends the audio to the preamp through a USB-C DAC
cable (or the 3.5 mm jack). There is no screen.

## Accounts

| Account | Type | Use |
|---|---|---|
| `support` (or your admin name) | Admin | IT. Log in over SSH or Screen Sharing. |
| `audio` | Standard | Logs in automatically at boot. All audio plays in its session. Don't use it for admin work. |

**If `audio` is not logged in, nothing plays.** If someone logs out or
switches user, reboot.

## Connect

From any device on your tailnet:

```sh
tailscale ssh support@<hostname>      # e.g. support@lobby-audio
```

Screen Sharing: on a Mac, Finder > Go > Connect to Server >
`vnc://<tailnet IP>`. On Windows, use RealVNC Viewer, which supports the
macOS login. Get the IP with `tailscale status` on your machine or from the
Tailscale admin console.

## Check health

```sh
/usr/local/airplay-mini/status.sh
```

Each line is `ok`, `FAIL` or `--` (information only). The exit code is the
number of failures. The last lines show the watchdog log.

## Troubleshoot with Claude

Once per Mac, as the admin user (over SSH is fine):

```sh
cd ~/airplay-mini && ./tools/claude-setup.sh
```

It installs Claude Code (CLI only) and an `airplay-doctor` command. Then,
any time:

```sh
airplay-doctor                           # health check + diagnosis
airplay-doctor "spotify isn't showing"   # start from a description
airplay-doctor --continue                # pick up the last session
```

First run: accept "trust this folder", then log in with your Claude account
(Pro, Max, Team or Enterprise). Over SSH, press `c` to copy the login URL,
open it on your laptop, and paste the code back into the terminal.

What Claude can do there:
- Root access only through `/usr/local/airplay-mini/doctor`, which runs
  fixed diagnostics and a few safe fixes. The admin user can run it without
  a password; every other `sudo` still needs the password, which Claude
  doesn't have.
- It asks before any restart, reboot or file edit. It is told never to touch
  Tailscale, the `audio` user or auto-login, and it is blocked from reading
  `config.env`.
- When something needs more, it gives you the command to run yourself in a
  second SSH session.

You can use the same helper by hand: `sudo /usr/local/airplay-mini/doctor help`.

If Claude says you're not logged in over SSH, the macOS keychain is probably
locked. Run `security unlock-keychain ~/Library/Keychains/login.keychain-db`,
then `/login` inside Claude. Revoke Claude's root access with
`sudo rm /etc/sudoers.d/airplay-doctor`.

## Fixes

| Symptom | Check | Fix |
|---|---|---|
| Speaker missing from the AirPlay list | Is the phone on the same network/VLAN as the Mac? `status.sh`: `nqptp`, `shairport`, `airplay port`, `airplay mdns` | `sudo /usr/local/airplay-mini/doctor restart-airplay` (the watchdog also does this after 90 s). Still missing: `doctor logs` for Shairport Sync errors, then reboot. |
| Mac shows an "Accept AirPlay?" prompt, or `airplay port` held by ControlCenter | macOS's built-in receiver is on (`status.sh`: `built-in recv`). Shairport Sync can't start while it holds port 7000 ("could not establish a service on port 7000" in its log). | As `audio`: System Settings > General > AirDrop & Handoff > AirPlay Receiver off (if it shows off, switch it on and off). Then `doctor restart-airplay`. |
| Phone says "Unable to connect" | macOS Local Network permission: System Settings > Privacy & Security > Local Network, as `audio`. | Turn on `shairport-sync`, `nqptp` and `spotifyd`, or click Allow on the prompt on the Mac's screen. Programs only appear there after they have run once. |
| AirPlay stopped after playing all day | Shairport Sync 5.6.1 bug: playback stops after ~12.5 h of continuous play. | Reconnect from the phone, or `doctor restart-airplay`. Keep `REBOOT_SCHEDULE="Daily 04:30"`. |
| `shairport` FAIL after `brew upgrade` | A library it links to changed. | Re-run `./bootstrap.sh`; it notices the broken binary and rebuilds. |
| Connects but no sound | `status.sh`: `output`, `volume`. Preamp input and volume. | Re-plug the DAC cable; the watchdog switches back to it within 30 s. If it's not listed at all, the cable or port is bad. |
| Very quiet | The phone's AirPlay slider, then the Mac level (`LOGIN_VOLUME`), then the preamp. | Turn it up on the phone, or raise `LOGIN_VOLUME` and re-run bootstrap. Set the room level on the preamp. To ignore phone sliders entirely: `AIRPLAY_FIXED_VOLUME="yes"`. |
| Speaker missing in Spotify | `status.sh`: `spotifyd`, `spotify mdns`. Log: `~audio/Library/Logs/spotifyd.log` | Restart it: `sudo launchctl kickstart -k gui/$(id -u audio)/com.airplaymini.spotifyd` |
| `logged in` FAIL | Someone logged out or the login screen is showing. | `sudo shutdown -r now` |
| `watchdog` FAIL | `sudo cat ~audio/Library/Logs/airplay-mini.launchd.log` | Re-run `./bootstrap.sh` from the repo folder. |
| Alert or startup sounds come out of the speakers | Settings were changed. | Re-run `./bootstrap.sh`; the watchdog re-applies them at the next login. |
| Healthcheck says down | Power, network, or a `FAIL` in `status.sh`. | If Tailscale is unreachable too, someone on site needs to power-cycle the Mac. |
| Tailscale offline, Mac is on | Client network blocks outbound UDP? | Tailscale falls back to HTTPS relays, so this is rare. Needs someone on site. |

Restart everything: `sudo shutdown -r now`. It comes back by itself: auto-login,
watchdog, NQPTP, Shairport Sync, spotifyd and Tailscale all start at boot.

## Logs

| File | What |
|---|---|
| `~audio/Library/Logs/airplay-mini.log` | Watchdog: output switches, AirPlay restarts, problems. Rotates at 1 MB. |
| `~audio/Library/Logs/airplay-mini.launchd.log` | Watchdog crashes, if any. |
| `~audio/Library/Logs/shairport-sync.log`, `nqptp.log` | The AirPlay receiver and its clock. Trimmed at 5 MB. |
| `~audio/Library/Logs/spotifyd.log` | spotifyd. Trimmed at 5 MB. |
| `log show --last 1h --predicate 'process == "tailscaled"'` | Tailscale. |

Read the files in `~audio` with `sudo`.

## Change settings or update

Settings live in `config.env` in the repo folder (on the admin account).
Edit it and re-run `./bootstrap.sh`. That is safe over Tailscale SSH: it does
not restart Tailscale.

- **Code update:** `git pull` (or copy the new folder), then `./bootstrap.sh`.
- **Homebrew packages:** `brew upgrade`, then `./bootstrap.sh`. If bootstrap
  warns that tailscaled differs, update the daemon from the local network
  (it drops Tailscale for a few seconds):
  `sudo /opt/homebrew/bin/tailscaled install-system-daemon`
- **Rebuild Shairport Sync** (e.g. after a library change):
  `AIRPLAY_MINI_REBUILD=1 ./bootstrap.sh`. The build log is
  `~/Library/Logs/airplay-mini-build.log` on the admin account.
- **macOS updates:** automatic installs are off. After a major macOS
  upgrade, check that `status.sh` still shows `built-in recv: off` and
  AirPlay plays. If the built-in receiver comes back, run
  `tools/find-airplay-keys.sh` as `audio` (needs the screen) to find the new
  preference key.

## Failure drills

Run these at handover; each should recover without anyone touching the Mac.

1. `sudo pkill -x shairport-sync`: launchd restarts it within 5 s; AirPlay
   works again. Then `sudo pkill -x nqptp`: same.
2. Turn macOS's AirPlay Receiver on in System Settings (as `audio`): the
   watchdog turns it off again within 30 s, and AirPlay keeps working with no
   "Accept" prompt on the Mac.
3. Unplug and replug the DAC: output goes back to it within 30 s
   (`airplay-mini.log` shows "switched").
4. `sudo pkill -x spotifyd`: launchd restarts it within 10 s.
5. Pull the power cord, plug it back in: it boots, logs in as `audio`, and
   plays again.
6. From another network: `tailscale ssh support@<hostname>` and Screen
   Sharing both connect. Unplug the Mac and the healthcheck alerts.

## Site requirements

- Wired Ethernet with a DHCP reservation.
- Same network/VLAN as the phones that will play to it, with client
  isolation off. AirPlay and Spotify Connect find speakers via mDNS, which
  does not cross VLANs.
- Outbound internet, for Tailscale and Spotify.
- If the macOS firewall is ever turned on, allow incoming connections for
  `spotifyd`.

## Tailscale admin setup

1. Policy file: add a tag, and let IT reach SSH and Screen Sharing:
   ```jsonc
   {
     "tagOwners": { "tag:audio-node": ["autogroup:admin"] },
     "acls": [
       { "action": "accept", "src": ["group:it"], "dst": ["tag:audio-node:22,5900"] }
     ],
     "ssh": [
       { "action": "accept", "src": ["group:it"], "dst": ["tag:audio-node"], "users": ["support"] }
     ]
   }
   ```
   Merge this into your existing policy. Replace `group:it` with your group
   and `support` with the admin account name.
2. Settings > Keys > Generate auth key: **pre-approved**, tag
   `tag:audio-node`, single use. Put it in `TAILSCALE_AUTHKEY`.
3. Tagged devices don't expire by default. Confirm "Key expiry: disabled" on
   the machine in the admin console.

## Security notes

- Auto-login needs FileVault off, so anyone with physical access gets the
  `audio` session. `audio` is a standard account with no Apple ID. Keep the
  Mac in a locked rack or cabinet.
- Screen Sharing also listens on the client's network, not just the tailnet.
  Allow only the admin account, and give that account a strong, unique
  password.
- `config.env` holds the `audio` password and the Tailscale key. It stays in
  the admin account's folder and is gitignored. The auth key is single-use,
  so it is worthless once the Mac has joined.
- AirPlay is limited to "Anyone on the same network". "Everyone" would let
  any iPhone nearby play to it over peer-to-peer Wi-Fi.

## Uninstall

```sh
./uninstall.sh                      # removes the jobs and /usr/local/airplay-mini
./uninstall.sh --disable-autologin  # also turns auto-login off
```

This leaves Tailscale, Homebrew and the `audio` user. Remove Tailscale last,
from the local network: `sudo tailscaled uninstall-system-daemon`.
