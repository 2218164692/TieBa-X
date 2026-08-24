#!/usr/bin/env bash
# Shared CoreSimulator helpers for the iOS CI workflow.
#
# Source this file; it defines functions and does not run anything on its own.
# It deliberately does not set -e: callers are GitHub `run:` blocks that
# already run under `bash -e`, and the retry loops here rely on non-zero
# returns being observable rather than fatal.

# Match the runtime by version, not build number. Xcode 16.4 on the macOS 15
# runner includes iOS 18.5, which is new enough for UI automation while the
# app itself remains deployable to iOS 14.0.
CI_RUNTIME_VERSION="18.5"

# Restart CoreSimulatorService and wait for the pinned runtime to be reported
# as available again. simctl intermittently loses track of a freshly
# downloaded runtime until the service is kicked.
ci_refresh_core_simulator() {
  local poll
  launchctl kickstart -k "gui/$(id -u)/com.apple.CoreSimulator.CoreSimulatorService" 2>/dev/null ||
    killall -9 com.apple.CoreSimulator.CoreSimulatorService 2>/dev/null || true
  for poll in {1..30}; do
    if xcrun simctl list runtimes -j |
      jq -e --arg v "$CI_RUNTIME_VERSION" \
        '.runtimes[] | select(.version == $v and .isAvailable == true)' >/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

ci_runtime_id() {
  xcrun simctl list runtimes -j |
    jq -r --arg v "$CI_RUNTIME_VERSION" \
      '.runtimes[] | select(.version == $v and .isAvailable == true) | .identifier' |
    head -n 1
}

# Download the pinned runtime only when it is not already present, then make
# sure simctl can see it.
ci_install_runtime() {
  command -v jq >/dev/null || return 1
  if ! xcrun simctl list runtimes -j |
    jq -e --arg v "$CI_RUNTIME_VERSION" \
      '.runtimes[] | select(.version == $v and .isAvailable == true)' >/dev/null; then
    # Self-healing fallback: only reached if the image stops shipping this
    # runtime. It is slow, so it announces itself rather than silently
    # adding a quarter of an hour to every job.
    echo "::warning::iOS $CI_RUNTIME_VERSION is not preinstalled; downloading it (slow)."
    xcodebuild -downloadPlatform iOS -architectureVariant arm64
  fi
  ci_refresh_core_simulator
  test -n "$(ci_runtime_id)"
}

# Boot a device and prove it is actually usable. A booted-but-broken
# simulator is the usual cause of an XCUITest run failing for reasons that
# have nothing to do with the app.
ci_boot_verified_simulator() {
  local candidate_udid="$1" boot_output boot_rc=0 device_dir
  device_dir="$HOME/Library/Developer/CoreSimulator/Devices/$candidate_udid"
  mkdir -p "$device_dir/data/Media/Photos/Videos"
  xcrun simctl boot "$candidate_udid" || return 1
  boot_output="$(xcrun simctl bootstatus "$candidate_udid" -b 2>&1)" || boot_rc=$?
  printf '%s\n' "$boot_output"
  test "$boot_rc" -eq 0 || return 1
  ! grep -Fq 'Data Migration Failed' <<<"$boot_output" || return 1
  xcrun simctl list devices -j |
    jq -e --arg udid "$candidate_udid" \
      '.devices[][] | select(.udid == $udid and .isAvailable == true and .state == "Booted")' >/dev/null || return 1
  xcrun simctl spawn "$candidate_udid" launchctl print system >/dev/null
}

# Create and boot a device, retrying with a fresh one when the boot cannot be
# verified. Echoes the UDID of the surviving device on success.
ci_create_simulator() {
  local device_type="$1" name="$2" runtime_id attempt candidate_udid
  runtime_id="$(ci_runtime_id)"
  test -n "$runtime_id" || return 1
  for attempt in 1 2 3; do
    candidate_udid="$(xcrun simctl create "$name ($attempt)" "$device_type" "$runtime_id")"
    if ci_boot_verified_simulator "$candidate_udid" >&2; then
      printf '%s\n' "$candidate_udid"
      return 0
    fi
    xcrun simctl shutdown "$candidate_udid" 2>/dev/null || true
    xcrun simctl delete "$candidate_udid" 2>/dev/null || true
    ci_refresh_core_simulator >&2
  done
  return 1
}

# Replace a device with a freshly created one. The workflow builds on one
# simulator and tests on another: by the time a build finishes the device has
# been booted for minutes, and reusing it is how the test runner ends up
# aborting during bootstrap. Echoes the new UDID.
ci_reset_simulator() {
  local old_udid="$1" device_type="$2" name="$3"
  if [ -n "$old_udid" ]; then
    xcrun simctl shutdown "$old_udid" 2>/dev/null || true
    xcrun simctl delete "$old_udid" 2>/dev/null || true
  fi
  ci_create_simulator "$device_type" "$name"
}

ci_iphone_device_type() {
  xcrun simctl list devicetypes -j |
    jq -r '([.devicetypes[] | select(.name == "iPhone 16") | .identifier]
            + [.devicetypes[] | select(.name | startswith("iPhone")) | .identifier]) | first // empty'
}

ci_ipad_device_type() {
  xcrun simctl list devicetypes -j |
    jq -r '([.devicetypes[] | select(.name == "iPad Air 11-inch (M2)") | .identifier]
            + [.devicetypes[] | select(.name | startswith("iPad")) | .identifier]) | first // empty'
}
