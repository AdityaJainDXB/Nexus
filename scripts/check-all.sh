#!/bin/zsh
# Full compile + smoke test for every Nexus deliverable. Usage: scripts/check-all.sh [--no-dmg]
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
PASS=0; FAIL=0; FAILED=()
ok()  { PASS=$((PASS+1)); print "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); FAILED+=("$1"); print "  ❌ $1 ${2:-}"; }
step() { print "\n━━ $1"; }
run() { local name=$1; shift; if "$@" > .build/check-$$.log 2>&1; then ok "$name"; else bad "$name" "(see log)"; tail -20 .build/check-$$.log; fi }
mkdir -p .build

step "1 · Unit tests"
run "swift test (NexusCore)" swift test

step "2 · macOS app, CLI, widgets, offline AI bundle"
run "scripts/build-app.sh (release)" ./scripts/build-app.sh
[[ -x dist/Nexus.app/Contents/MacOS/Nexus ]] && ok "Nexus.app executable" || bad "Nexus.app executable"
[[ -d dist/Nexus.app/Contents/PlugIns/NexusWidgets.appex ]] && ok "WidgetKit extension bundled" || bad "widgets bundled"
[[ -x dist/Nexus.app/Contents/Helpers/llama/llama-server ]] && ok "llama.cpp runtime bundled" || bad "llama runtime"
ls dist/Nexus.app/Contents/Resources/Models/*.gguf >/dev/null 2>&1 && ok "offline model bundled" || bad "model bundled"
codesign --verify --deep --strict dist/Nexus.app 2>/dev/null && ok "code signature valid" || bad "code signature"

step "3 · iOS companion (device + simulator)"
run "NexusRemote iphoneos Release" xcodebuild -project iOS/NexusRemote.xcodeproj -scheme NexusRemote -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath iOS/build CODE_SIGNING_ALLOWED=NO build
run "NexusRemote iphonesimulator Release" xcodebuild -project iOS/NexusRemote.xcodeproj -scheme NexusRemote -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath iOS/build CODE_SIGNING_ALLOWED=NO build

step "4 · Smoke test: release app in an isolated sandbox"
S=$ROOT/.build/smoke; rm -rf $S; mkdir -p "$S/support" "$S/home/Downloads" "$S/home/Documents/School/Physics" "$S/home/Documents/Finance" "$S/home/Desktop"
printf "Kinematics notes: velocity acceleration momentum newton force friction projectile\n" > "$S/home/Documents/School/Physics/notes.txt"
pkill -f "dist/Nexus.app/Contents/MacOS/Nexus$" 2>/dev/null; sleep 1
(NEXUS_HOME=$S/support NEXUS_HOME_ROOT=$S/home NEXUS_HEADLESS=1 NEXUS_TRASH_DIR=$S/trash NEXUS_API_TEST=1 dist/Nexus.app/Contents/MacOS/Nexus > $S/app.log 2>&1 &)
for i in {1..60}; do [[ -f $S/support/api.json ]] && curl -s -m 2 http://127.0.0.1:7788/v1/status -H "Authorization: Bearer $(python3 -c "import json;print(json.load(open('$S/support/api.json'))['token'])")" | grep -q status && break; sleep 0.5; done
TOK=$(python3 -c "import json;print(json.load(open('$S/support/api.json'))['token'])" 2>/dev/null)
api() { curl -s -m 180 -X "$1" -H "Authorization: Bearer $TOK" ${3:+-d "$3"} "http://127.0.0.1:7788$2"; }
[[ -n "$(api GET /v1/status)" ]] && ok "app launches headless, API answers" || bad "app launch"
api POST /v1/tasks '{"operation":"learnTaxonomy"}' >/dev/null; sleep 4
r=$(api POST /v1/rules "{\"text\":\"If a PDF in Downloads contains 'MYP3' → move to $S/home/Documents/School, tag myp3\"}")
[[ "$r" == *myp3* ]] && ok "natural-language rule compiled & saved" || bad "rule create" "$r"
printf "MYP3 unit report\n" > $S/m.txt; cupsfilter $S/m.txt > "$S/home/Downloads/myp3-report.pdf" 2>/dev/null
for i in {1..40}; do [[ -f "$S/home/Documents/School/myp3-report.pdf" ]] && break; sleep 1; done
[[ -f "$S/home/Documents/School/myp3-report.pdf" ]] && ok "watcher → rule → file moved" || bad "rule fired"
u=$(api POST /v1/undo); [[ -f "$S/home/Downloads/myp3-report.pdf" ]] && ok "undo restored the file" || bad "undo" "$u"
for i in {1..40}; do q=$(api POST /v1/command '{"text":"find everything about kinematics","confirm":true}'); [[ "$q" == *notes.txt* ]] && break; sleep 1; done
[[ "$q" == *notes.txt* ]] && ok "search command finds content" || bad "search" "$q"
api POST /v1/settings '{"llmProvider":"bundled"}' >/dev/null; sleep 1
a=$(api POST /v1/command '{"text":"summarize my Physics folder","confirm":true}')
[[ ${#a} -gt 60 ]] && ok "bundled offline model answers" || bad "offline model" "$a"
api POST /v1/settings '{"remoteEnabled":true}' >/dev/null; sleep 3
code=$(api POST /v1/remote/pairing | python3 -c "import json,sys;print(json.load(sys.stdin).get('code',''))" 2>/dev/null)
rt=$(dist/Nexus.app/Contents/MacOS/nexusctl remote-test 127.0.0.1 "$code" 2>&1)
[[ "$rt" == *"paired as"* && "$rt" == *"replayed request rejected"* && "$rt" == *"tampered ciphertext rejected"* && "$rt" != *"✗"* ]] && ok "iPhone remote protocol: pair, encrypt, replay & tamper protection" || bad "remote protocol" "$rt"
pkill -f "dist/Nexus.app/Contents/MacOS/Nexus$"; sleep 4
pgrep -f "Helpers/llama/llama-server" >/dev/null && bad "model server stopped with app" || ok "model server exits with app"

if [[ "${1:-}" != "--no-dmg" ]]; then
  step "5 · DMG"
  run "scripts/make-dmg.sh" ./scripts/make-dmg.sh
  M=$(hdiutil attach dist/Nexus-${VERSION:-1.0.0}.dmg -readonly -nobrowse -noautoopen 2>/dev/null | awk -F'\t' '/\/Volumes\// {print $NF}')
  [[ -d "$M/Nexus.app" && -L "$M/Applications" ]] && ok "DMG mounts with Nexus.app + Applications link" || bad "DMG contents"
  codesign --verify --deep --strict "$M/Nexus.app" 2>/dev/null && ok "app inside DMG is intact" || bad "DMG app signature"
  [[ -n "$M" ]] && hdiutil detach "$M" -quiet
fi

print "\n━━ RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || { print "Failed: ${(j:, :)FAILED}"; exit 1; }
