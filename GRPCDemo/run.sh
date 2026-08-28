#!/bin/zsh
# Assemble a real application bundle with a real XPC service inside it, then run it.
#
# Adapted from `Demo/run.sh` -- the recipe is identical, because the recipe is launchd's, not the
# transport's. SwiftPM cannot emit a `.xpc` bundle, so the layout is built by hand:
#
#   GRPCXPCDemo.app/
#     Contents/
#       Info.plist                     <- the host's, so `.xpcService` lookup has a bundle
#       MacOS/GRPCXPCDemo              <- the host executable
#       XPCServices/
#         com.example.GRPCXPCDemo.CalculatorService.xpc/
#           Contents/
#             Info.plist               <- CFBundleIdentifier is the name the host dials
#             MacOS/CalculatorService  <- the service executable
#
# Nothing is installed and nothing is registered: launchd finds the service *because* it is inside
# the calling application's bundle, starts it on demand, and reaps it afterwards.
#
# The service has no terminal -- launchd hands it /dev/null for stdout and stderr -- so everything
# it says goes to the unified log and this script prints it at the end. To watch it live instead:
#
#   log stream --predicate 'subsystem == "com.example.GRPCXPCDemo"' --level info
#
# and for launchd's own view of why a service did or did not start:
#
#   log stream --predicate 'subsystem == "com.apple.xpc"'

set -e
cd "$(dirname "$0")"

CONFIG=${CONFIG:-debug}
SCRATCH=${SCRATCH:-.build}
SERVICE_ID="com.example.GRPCXPCDemo.CalculatorService"

echo "==> building"
swift build -c "$CONFIG" --scratch-path "$SCRATCH"
BIN="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)"

APP="$SCRATCH/GRPCXPCDemo.app"
SVC="$APP/Contents/XPCServices/$SERVICE_ID.xpc"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$SVC/Contents/MacOS"
cp "$BIN/CalcHost"    "$APP/Contents/MacOS/GRPCXPCDemo"
cp "$BIN/CalcService" "$SVC/Contents/MacOS/CalculatorService"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.GRPCXPCDemo</string>
  <key>CFBundleName</key><string>GRPCXPCDemo</string>
  <key>CFBundleExecutable</key><string>GRPCXPCDemo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
</dict></plist>
PLIST

# `XPCService`/`ServiceType: Application` is what tells launchd to run one instance of this
# service per calling application, in the caller's own session. Without the key the bundle is
# just a directory and the lookup fails.
cat > "$SVC/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$SERVICE_ID</string>
  <key>CFBundleName</key><string>CalculatorService</string>
  <key>CFBundleExecutable</key><string>CalculatorService</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>XPCService</key><dict>
    <key>ServiceType</key><string>Application</string>
  </dict>
</dict></plist>
PLIST

# Ad-hoc, inside-out. An XPC service is signed before the application that contains it,
# otherwise the outer signature covers a nested bundle that is about to change.
echo "==> signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$SVC" >/dev/null 2>&1
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "==> running"
# Local time, not UTC: `/usr/bin/log show --start` parses its argument in the machine's own
# timezone, so a `date -u` stamp asks for a window that has not happened yet and prints nothing.
START=$(date "+%Y-%m-%d %H:%M:%S")
set +e
"$APP/Contents/MacOS/GRPCXPCDemo"
STATUS=$?
set -e

# The service's own diagnostics. This is the only place they exist: it never had a terminal.
echo "==> service log (subsystem com.example.GRPCXPCDemo, since $START)"
/usr/bin/log show --start "$START" --predicate 'subsystem == "com.example.GRPCXPCDemo"' --info --style compact 2>/dev/null \
  | sed 's/^/    /' || true

exit $STATUS
