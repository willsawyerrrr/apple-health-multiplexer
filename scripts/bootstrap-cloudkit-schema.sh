#!/bin/sh
# Creates the CloudKit system record types the app needs in the Development
# environment by running a Debug build in the iOS Simulator with
# `-BootstrapCloudKitSchema`, then exports the Development schema.
#
# Usage: scripts/bootstrap-cloudkit-schema.sh [simulator name]
# Needs an iCloud account signed in on the Simulator (Settings > Apple Account).
set -eu

cd "$(dirname "$0")/.."
CONTAINER=iCloud.dev.willsawyerrrr.kintemp
BUNDLE_ID=dev.willsawyerrrr.kintemp
APPLE_ENV=b5zkkwxuutlttwbrv5xhgojye4
DERIVED=build/bootstrap
SCHEMA_OUT=build/development-schema.ckdb

name=${1:-}
if [ -z "$name" ]; then
  name=$(xcrun simctl list devices available | sed -n 's/^ *\(iPhone [^(]*[^( ]\) (.*/\1/p' | head -n 1)
fi
[ -n "$name" ] || { echo "No available iPhone simulator" >&2; exit 1; }
udid=$(xcrun simctl list devices available | grep -F "    $name (" | head -n 1 | sed 's/.*(\([0-9A-F-]\{36\}\)).*/\1/')
[ -n "$udid" ] || { echo "Simulator '$name' not found" >&2; exit 1; }
echo "Simulator: $name ($udid)"

xcrun simctl bootstatus "$udid" -b >/dev/null

# Ad-hoc signing (not CODE_SIGNING_ALLOWED=NO) so the iCloud entitlement is
# embedded in the simulator binary; no team is needed.
DEVELOPMENT_TEAM= xcodegen generate >/dev/null
xcodebuild build -quiet -scheme Kintemp -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES

xcrun simctl install "$udid" "$DERIVED/Build/Products/Debug-iphonesimulator/Kintemp.app"
xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true

status=0
xcrun simctl launch --console-pty --terminate-running-process "$udid" "$BUNDLE_ID" \
  -BootstrapCloudKitSchema | tee build/bootstrap.log || status=$?
if ! grep -q '^bootstrap: OK' build/bootstrap.log; then
  grep '^bootstrap: FAILED' build/bootstrap.log >&2 || echo "bootstrap did not report a result" >&2
  exit 1
fi

# The token never leaves the child process environment and is not printed.
op run --no-masking --environment "$APPLE_ENV" -- sh -c '
  xcrun cktool export-schema --token "$CLOUDKIT_MANAGEMENT_TOKEN" --team-id "$DEVELOPMENT_TEAM" \
    --container-id "$0" --environment development --output-file "$1"' "$CONTAINER" "$SCHEMA_OUT"
echo "Development schema exported to $SCHEMA_OUT:"
grep -n 'RECORD TYPE' "$SCHEMA_OUT"
