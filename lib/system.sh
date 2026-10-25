# shellcheck shell=bash
# Machine-wide settings: names, power, sounds, updates, Bluetooth assistant.

setup_system() {
  step "System settings"

  # The AirPlay Receiver advertises the ComputerName.
  sudo scutil --set ComputerName "$DEVICE_NAME"
  sudo scutil --set LocalHostName "$HOST_SLUG"
  sudo scutil --set HostName "$HOST_SLUG"
  ok "computer name '$DEVICE_NAME', host name '$HOST_SLUG'"

  # Never sleep; wake for network access; boot again after a power cut.
  sudo pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0 womp 1 autorestart 1
  ok "power: no sleep, wake on network, restart after power loss"

  # Restart after a kernel freeze. systemsetup needs Full Disk Access on some
  # macOS versions, so a failure here is only a warning.
  if sudo systemsetup -setrestartfreeze on >/dev/null 2>&1; then
    ok "restart after freeze"
  else
    warn "could not turn on restart-after-freeze (systemsetup refused; harmless)"
  fi

  # No startup chime through the preamp.
  sudo nvram StartupMute=%01
  ok "startup chime muted"

  # No surprise macOS upgrades. Security data updates stay on.
  # Without MDM, macOS may still prompt for or schedule major upgrades.
  local su=/Library/Preferences/com.apple.SoftwareUpdate
  sudo defaults write "$su" AutomaticCheckEnabled -bool true
  sudo defaults write "$su" AutomaticDownload -bool true
  sudo defaults write "$su" AutomaticallyInstallMacOSUpdates -bool false
  sudo defaults write "$su" ConfigDataInstall -bool true
  sudo defaults write "$su" CriticalUpdateInstall -bool true
  ok "automatic macOS installs off, security data updates on"

  # A headless Mac otherwise opens the Bluetooth keyboard/mouse setup
  # assistant at every boot.
  local bt=/Library/Preferences/com.apple.Bluetooth
  sudo defaults write "$bt" BluetoothAutoSeekKeyboard -int 0
  sudo defaults write "$bt" BluetoothAutoSeekPointingDevice -int 0
  ok "Bluetooth keyboard/mouse setup assistant off"
}
