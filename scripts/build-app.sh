#!/bin/zsh
# Builds dist/Nexus.app: app + CLI + WidgetKit extension + offline AI runtime & model. Ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
VERSION=${VERSION:-1.0.0}
BUILD_NUMBER=${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}
INCLUDE_MODEL=${INCLUDE_MODEL:-1}
APP=dist/Nexus.app
C=$APP/Contents

[[ "$INCLUDE_MODEL" == "1" ]] && ./scripts/fetch-vendor.sh

echo "▸ Building Swift targets ($CONFIG)"
swift build -c "$CONFIG" --product Nexus
swift build -c "$CONFIG" --product nexusctl
BIN=$(swift build -c "$CONFIG" --show-bin-path)

echo "▸ Building widget extension"
mkdir -p .build/widgets
swiftc -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos14.0 -parse-as-library -application-extension \
  -module-name NexusWidgets -O Widgets/NexusWidgets.swift -o .build/widgets/NexusWidgets

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Resources/Licenses" "$C/PlugIns" "$C/Helpers"
cp "$BIN/Nexus" "$C/MacOS/Nexus"
cp "$BIN/nexusctl" "$C/MacOS/nexusctl"

if [[ ! -f Resources/AppIcon.icns ]]; then
  rm -rf .build/AppIcon.iconset && swift scripts/make-icon.swift .build/AppIcon.iconset
  iconutil -c icns .build/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$C/Resources/AppIcon.icns"
cp LICENSE "$C/Resources/Licenses/Nexus-LICENSE.txt" 2>/dev/null || true

# Offline AI runtime (llama.cpp server + dylibs) and model
LLAMA_DIR=$(ls -d Vendor/llama/llama-b* 2>/dev/null | head -1 || true)
if [[ -n "$LLAMA_DIR" ]]; then
  mkdir -p "$C/Helpers/llama"
  cp "$LLAMA_DIR/llama-server" "$C/Helpers/llama/"
  cp -a "$LLAMA_DIR"/lib*.dylib "$C/Helpers/llama/"
  rm -f "$C/Helpers/llama"/libllama-{batched-bench,bench,cli,completion,fit-params,perplexity,quantize}-impl.dylib
  cp "$LLAMA_DIR/LICENSE" "$C/Resources/Licenses/llama.cpp-LICENSE.txt"
fi
if [[ "$INCLUDE_MODEL" == "1" ]]; then
  mkdir -p "$C/Resources/Models"
  cp Vendor/models/*.gguf "$C/Resources/Models/"
  cp Vendor/models/LICENSE-Qwen2.5.txt "$C/Resources/Licenses/" 2>/dev/null || true
fi

# Widget extension bundle
WX=$C/PlugIns/NexusWidgets.appex
mkdir -p "$WX/Contents/MacOS"
cp .build/widgets/NexusWidgets "$WX/Contents/MacOS/NexusWidgets"
cat > "$WX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.nexus.mac.widgets</string>
  <key>CFBundleName</key><string>Nexus Widgets</string>
  <key>CFBundleDisplayName</key><string>Nexus</string>
  <key>CFBundleExecutable</key><string>NexusWidgets</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSExtension</key><dict><key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string></dict>
</dict></plist>
PLIST
cat > .build/widgets/entitlements.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
  <array><string>/Library/Application Support/Nexus/widget/</string></array>
</dict></plist>
PLIST

cat > "$C/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Nexus</string>
  <key>CFBundleDisplayName</key><string>Nexus</string>
  <key>CFBundleIdentifier</key><string>app.nexus.mac</string>
  <key>CFBundleExecutable</key><string>Nexus</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>Nexus — local-first agent for your Mac</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>app.nexus.mac</string>
    <key>CFBundleURLSchemes</key><array><string>nexus</string></array>
  </dict></array>
  <key>NSDesktopFolderUsageDescription</key><string>Nexus organizes files you choose to keep on your Desktop.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Nexus learns your folder structure and files documents where they belong.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Nexus sorts new downloads using your rules.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Nexus can sync folders to external drives when you ask it to.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Nexus can organize files on network drives you add.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Nexus adds deadlines it finds in your files and prepares files before meetings.</string>
  <key>NSCalendarsUsageDescription</key><string>Nexus adds deadlines it finds in your files and prepares files before meetings.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>Nexus creates reminders from your automations.</string>
  <key>NSRemindersUsageDescription</key><string>Nexus creates reminders from your automations.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Voice commands are recognized on this Mac.</string>
  <key>NSMicrophoneUsageDescription</key><string>Talk to Nexus to find, organize and automate your files.</string>
  <key>NSAppleEventsUsageDescription</key><string>Nexus reads your Finder selection for “file this” and runs AppleScript steps you add.</string>
</dict></plist>
PLIST

echo "▸ Signing (ad-hoc, inside-out)"
if [[ -d "$C/Helpers/llama" ]]; then
  for f in "$C/Helpers/llama"/*.dylib "$C/Helpers/llama/llama-server"; do codesign --force --sign - "$f" >/dev/null; done
fi
codesign --force --sign - "$C/MacOS/nexusctl"
codesign --force --sign - --entitlements .build/widgets/entitlements.plist "$WX"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "✓ Signature OK"

# Register with LaunchServices so the widget gallery and nexus:// URLs work immediately
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
du -sh "$APP" | awk '{print "✓ Built '"$APP"' (" $1 ")"}'
