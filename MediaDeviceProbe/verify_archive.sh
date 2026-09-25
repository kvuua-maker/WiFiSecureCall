#!/bin/bash
set -euo pipefail

archive_path="${1:?archive path required}"
report_path="${2:?report path required}"
team_id="9V5XXDXF3N"
protocol_id="media-device-protocol.com.vkapps.wifisecurecall.mediadeviceprobe"
container_id="com.vkapps.wifisecurecall.mediadeviceprobe"
extension_id="com.vkapps.wifisecurecall.mediadeviceprobe.extension"

app_path="$archive_path/Products/Applications/MediaDeviceProbe.app"
extension_path="$app_path/PlugIns/MediaDeviceProbeExtension.appex"
verification_dir="$(mktemp -d /tmp/wsc-media-archive-verification.XXXXXX)"
trap 'rm -rf "$verification_dir"' EXIT

[[ -d "$app_path" ]]
[[ -d "$extension_path" ]]

actual_container_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")"
actual_extension_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$extension_path/Info.plist")"
[[ "$actual_container_id" == "$container_id" ]]
[[ "$actual_extension_id" == "$extension_id" ]]

codesign --verify --deep --strict --verbose=2 "$app_path"
codesign --verify --strict --verbose=2 "$extension_path"

app_signing="$(codesign -dvvv "$app_path" 2>&1)"
extension_signing="$(codesign -dvvv "$extension_path" 2>&1)"
grep -Fq "Authority=Apple Distribution: Vladyslav Khomenko ($team_id)" <<<"$app_signing"
grep -Fq "Authority=Apple Distribution: Vladyslav Khomenko ($team_id)" <<<"$extension_signing"
grep -Fq "TeamIdentifier=$team_id" <<<"$app_signing"
grep -Fq "TeamIdentifier=$team_id" <<<"$extension_signing"

codesign -d --entitlements :- "$app_path" > "$verification_dir/app-entitlements.plist" 2>/dev/null
codesign -d --entitlements :- "$extension_path" > "$verification_dir/extension-entitlements.plist" 2>/dev/null
security cms -D -i "$app_path/embedded.mobileprovision" > "$verification_dir/app-profile.plist"
security cms -D -i "$extension_path/embedded.mobileprovision" > "$verification_dir/extension-profile.plist"

verify_absent() {
  local plist="$1"
  local key="$2"
  if /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
    echo "unexpected entitlement: $key" >&2
    return 1
  fi
}

verify_product_entitlements() {
  local plist="$1"
  local value
  value="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.media-device-extension:0' "$plist")"
  [[ "$value" == "$protocol_id" ]]
  verify_absent "$plist" com.apple.developer.calling-app
  verify_absent "$plist" com.apple.developer.dialing-app
}

verify_profile() {
  local plist="$1"
  local expected_name="$2"
  local expected_bundle="$3"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :Name' "$plist")" == "$expected_name" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$plist")" == "$team_id" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$plist")" == "$team_id.$expected_bundle" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.media-device-extension:0' "$plist")" == "$protocol_id" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:get-task-allow' "$plist")" == "false" ]]
  ! /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$plist" >/dev/null 2>&1
  ! /usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$plist" >/dev/null 2>&1
  verify_absent "$plist" Entitlements:com.apple.developer.calling-app
  verify_absent "$plist" Entitlements:com.apple.developer.dialing-app
}

verify_product_entitlements "$verification_dir/app-entitlements.plist"
verify_product_entitlements "$verification_dir/extension-entitlements.plist"
verify_profile "$verification_dir/app-profile.plist" WiFiSecureCallMediaDeviceProbeAppStore "$container_id"
verify_profile "$verification_dir/extension-profile.plist" WiFiSecureCallMediaDeviceExtensionAppStore "$extension_id"

{
  echo "SIGNED_ARCHIVE=PASS"
  echo "CONTAINER_BUNDLE_ID=$actual_container_id"
  echo "EXTENSION_BUNDLE_ID=$actual_extension_id"
  echo "CONTAINER_SIGNING=PASS"
  echo "EXTENSION_SIGNING=PASS"
  echo "CONTAINER_ENTITLEMENT=PASS"
  echo "EXTENSION_ENTITLEMENT=PASS"
  echo "CALLING_APP_ENTITLEMENT=ABSENT"
  echo "DIALING_APP_ENTITLEMENT=ABSENT"
} | tee "$report_path"
