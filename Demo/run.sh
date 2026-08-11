#!/bin/zsh
# Assemble a real application bundle with a real XPC service inside it, then run it.
#
# SwiftPM cannot emit a `.xpc` bundle, and launchd will not start a service it cannot find, so
# the layout has to be built by hand. It is only a directory tree and two Info.plists:
#
#   XPCActorsDemo.app/
#     Contents/
#       Info.plist                     <- the host's, so `.xpcService` lookup has a bundle
#       MacOS/XPCActorsDemo            <- the host executable
#       XPCServices/
#         com.example.XPCActorsDemo.GreeterService.xpc/
#           Contents/
#             Info.plist               <- CFBundleIdentifier is the name the host dials
#             MacOS/GreeterService     <- the service executable
#
# Nothing is installed and nothing is registered: launchd finds the service *because* it is
# inside the calling application's bundle, starts it on demand, and reaps it afterwards. Delete
# the directory and every trace is gone -- which is why this is an XPC service rather than a
# launchd agent with a plist in ~/Library/LaunchAgents.

set -e
cd "$(dirname "$0")"

CONFIG=${CONFIG:-debug}
SCRATCH=${SCRATCH:-.build}
SERVICE_ID="com.example.XPCActorsDemo.GreeterService"

echo "==> building"
swift build -c "$CONFIG" --scratch-path "$SCRATCH"
BIN="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)"

APP="$SCRATCH/XPCActorsDemo.app"
SVC="$APP/Contents/XPCServices/$SERVICE_ID.xpc"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$SVC/Contents/MacOS"
cp "$BIN/DemoHost"    "$APP/Contents/MacOS/XPCActorsDemo"
cp "$BIN/DemoService" "$SVC/Contents/MacOS/GreeterService"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.XPCActorsDemo</string>
  <key>CFBundleName</key><string>XPCActorsDemo</string>
  <key>CFBundleExecutable</key><string>XPCActorsDemo</string>
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
  <key>CFBundleName</key><string>GreeterService</string>
  <key>CFBundleExecutable</key><string>GreeterService</string>
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
exec "$APP/Contents/MacOS/XPCActorsDemo"
