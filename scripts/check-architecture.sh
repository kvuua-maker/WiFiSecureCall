#!/usr/bin/env bash
# Guards the contract in Docs/CallArchitecture.md.
#
# Two kinds of drift are worth failing a build over, and neither is caught by a
# compiler:
#
#   1. a third-party media stack appearing in the project (SIP, WebRTC, LiveKit,
#      Twilio). The app's calls are its own WSS path; adding one of these changes
#      the product, the licence surface and the cost model at once.
#   2. the network audio format changing. 16 kHz / 320 samples / 640 bytes / 34
#      byte header are the numbers the server and both clients agree on, and a
#      change to any of them breaks interoperability with every older build.
#
# The Swift test suite asserts the same numbers from the inside; this script is the
# outside check that also covers manifests and files the test target never sees.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

fail() {
  echo "::error::$1" >&2
  exit 1
}

# --- 1. No third-party media stack ------------------------------------------

for manifest in Package.swift Podfile Cartfile Cartfile.resolved Podfile.lock; do
  if [ -e "$manifest" ]; then
    fail "$manifest appeared. This project has no third-party dependencies by design; see Docs/CallArchitecture.md."
  fi
done

# Source and build files only: the documentation is allowed to name these stacks,
# and so is this script.
mapfile -t sources < <(find Shared Watch iOS Tests -type f \( -name '*.swift' -o -name '*.plist' -o -name '*.entitlements' \) 2>/dev/null)
[ "${#sources[@]}" -gt 0 ] || fail "no sources found; the guard is looking in the wrong place"

forbidden='\b(SIP|WebRTC|LiveKit|Twilio|Agora|Jitsi)\b'
if grep -nEi "$forbidden" "${sources[@]}" 2>/dev/null | grep -vE 'SIPGW|REPLACE_WITH' >/tmp/architecture-forbidden.txt; then
  echo "--- forbidden references:" >&2
  cat /tmp/architecture-forbidden.txt >&2
  fail "a third-party calling stack is referenced in the sources. See Docs/CallArchitecture.md."
fi

# --- 2. The audio format is unchanged ---------------------------------------

grep -q 'networkSampleRate: Double = 16_000' Shared/AudioEngine.swift \
  || fail "the network sample rate is no longer 16 kHz (Shared/AudioEngine.swift)."

grep -q 'samplesPerFrame: AVAudioFrameCount = 320' Shared/AudioEngine.swift \
  || fail "the frame is no longer 320 samples (Shared/AudioEngine.swift)."

grep -q 'bytesPerFrame = 640' Shared/AudioEngine.swift \
  || fail "the payload is no longer 640 bytes (Shared/AudioEngine.swift)."

grep -q 'static let headerSize = 34' Shared/AudioPacket.swift \
  || fail "the packet header is no longer 34 bytes (Shared/AudioPacket.swift)."

# --- 3. The modes stay separate ---------------------------------------------

if grep -qs 'AVAudioEngine' iOS/IOSSystemDialCoordinator.swift 2>/dev/null; then
  fail "the system-dial coordinator touches AVAudioEngine: Mode B must never own audio."
fi

echo "architecture guard passed: no third-party media stack, audio format and modes intact"
