#!/bin/zsh
# End-to-end scenarios against an installed (or freshly built) Nexus.app, in a sandboxed fake home.
# Usage: scripts/e2e.sh [/Applications/Nexus.app]
set -uo pipefail
cd "$(dirname "$0")/.."
APP=${1:-/Applications/Nexus.app}
BIN=$APP/Contents/MacOS/Nexus
S=$PWD/.build/e2e; H=$S/home
PASS=0; FAIL=0; FAILED=()
ok()  { PASS=$((PASS+1)); print "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); FAILED+=("$1"); print "  ❌ $1  ${2:-}" | cut -c1-400; }
step() { print "\n━━ $1"; }
waitfor() { local n=$1; shift; for i in {1..$n}; do eval "$@" && return 0; sleep 1; done; return 1; }
pdf() { printf "%b" "$2" > "$S/tmp.txt"; cupsfilter "$S/tmp.txt" > "$1" 2>/dev/null; }

pkill -f "Nexus.app/Contents/MacOS/Nexus$" 2>/dev/null; pkill -f "Helpers/llama/llama-server" 2>/dev/null; sleep 1
rm -rf $S; mkdir -p $S/support $H/Downloads $H/Desktop "$H/Documents/School/Physics" "$H/Documents/Finance/Invoices" "$H/Documents/English" "$H/Desktop/Science" "$H/Pictures"
printf "Kinematics notes: velocity acceleration momentum newton force friction projectile motion\n" > "$H/Documents/School/Physics/kinematics-notes.txt"
printf "Essay draft: Macbeth ambition theme analysis, Shakespeare tragedy, literary devices\n" > "$H/Documents/English/macbeth-essay.txt"
pdf "$H/Documents/Finance/Invoices/old-invoice.pdf" "INVOICE #1001\\nBill to: Aditya\\nAmount due: \$120.00\\nDue date: Oct 1 2026\\nPayment terms net 30"
printf "Photosynthesis lab: chlorophyll light reaction hypothesis experiment results\n" > "$H/Desktop/Science/photosynthesis.txt"

launch() {
  rm -f $S/support/api.json
  (NEXUS_HOME=$S/support NEXUS_HOME_ROOT=$H NEXUS_HEADLESS=1 NEXUS_TRASH_DIR=$S/trash "$BIN" >> $S/app.log 2>&1 &)
  waitfor 60 '[[ -f $S/support/api.json ]] && TOK=$(python3 -c "import json;print(json.load(open(\"$S/support/api.json\"))[\"token\"])") && curl -s -m 2 http://127.0.0.1:7788/v1/status -H "Authorization: Bearer $TOK" | grep -q status'
}
api() { curl -s -m 240 -X "$1" -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" ${3:+-d "$3"} "http://127.0.0.1:7788$2"; }
jq_() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }
cmd() { api POST /v1/command "{\"text\":\"$1\",\"confirm\":true}"; }

step "1 · Launch the installed app"
print "  app: $APP"
launch && ok "installed app launches, local API answers" || { bad "launch"; tail -20 $S/app.log; exit 1; }
st=$(api GET /v1/status); print "  status: $st" | cut -c1-200
[[ $(curl -s -o /dev/null -w "%{http_code}" -m 2 http://127.0.0.1:7788/v1/status) == 401 ]] && ok "API rejects requests without token" || bad "API auth"

step "2 · First run: nothing is moved or deleted before setup"
sleep 3
pdf "$H/Downloads/acme-invoice-2211.pdf" "INVOICE #2211\\nAcme Supplies LLC\\nBill to: Aditya\\nAmount due: \$84.00\\nDue date: Nov 5 2026\\nPayment terms net 30"
cp "$H/Documents/Finance/Invoices/old-invoice.pdf" "$H/Downloads/old-invoice (1).pdf"
sleep 12
[[ -f "$H/Downloads/acme-invoice-2211.pdf" ]] && ok "new download left in place before onboarding" || bad "file moved before onboarding"
[[ -f "$H/Downloads/old-invoice (1).pdf" ]] && ok "duplicate not deleted before onboarding" || bad "duplicate deleted before onboarding"

step "3 · Setup complete → learning & autopilot"
api POST /v1/settings '{"onboardingComplete":true,"llmProvider":"bundled"}' >/dev/null
api POST /v1/tasks '{"operation":"learnTaxonomy"}' >/dev/null
for f in "$H/Documents" "$H/Desktop"; do api POST /v1/tasks "{\"operation\":\"classifyFolder\",\"path\":\"$f\"}" >/dev/null; done
sleep 10
rm -f "$H/Downloads/acme-invoice-2211.pdf" "$H/Downloads/old-invoice (1).pdf"; sleep 3
pdf "$H/Downloads/brightsparks-invoice.pdf" "INVOICE #3345\\nBrightSparks Electronics\\nBill to: Aditya\\nAmount due: \$64.50\\nDue date: Dec 12 2026\\nPayment terms net 30 invoice"
waitfor 40 '[[ ! -f "$H/Downloads/brightsparks-invoice.pdf" ]] || [[ "$(api GET /v1/review)" == *brightsparks* ]]'
if [[ -f "$H/Documents/Finance/Invoices/brightsparks-invoice.pdf" ]] || find $H/Documents/Finance -name brightsparks-invoice.pdf | grep -q .; then
  ok "autopilot filed invoice into existing Finance folder"
else
  rv=$(api GET /v1/review)
  id=$(print -r -- "$rv" | jq_ "[i['id'] for i in d if 'brightsparks' in i['path']][0]")
  dest=$(print -r -- "$rv" | jq_ "[i['destination'] for i in d if 'brightsparks' in i['path']][0]")
  if [[ -n "$id" ]]; then
    ok "invoice queued for review → $dest"
    api POST /v1/review/$id/approve '{}' >/dev/null; sleep 2
    find $H -name brightsparks-invoice.pdf -not -path "*/Downloads/*" | grep -q . && ok "approving the review item actually moved the file" || bad "approve did not move file"
  else bad "invoice neither filed nor queued" "$rv $(api GET "/v1/files?path=$H/Downloads/brightsparks-invoice.pdf")"; fi
fi

step "4 · Duplicates"
cp "$H/Documents/School/Physics/kinematics-notes.txt" "$H/Downloads/kinematics-notes copy.txt"
waitfor 30 '[[ ! -f "$H/Downloads/kinematics-notes copy.txt" ]]' && ok "re-downloaded duplicate removed automatically (to Trash)" || bad "auto duplicate removal"
ls $S/trash 2>/dev/null | grep -q kinematics && ok "duplicate is recoverable from Trash" || bad "duplicate in trash"
cp "$H/Documents/English/macbeth-essay.txt" "$H/Documents/English/macbeth-essay-2.txt"
cp "$H/Documents/English/macbeth-essay.txt" "$H/Documents/English/macbeth-essay-3.txt"
api POST /v1/tasks "{\"operation\":\"classifyFolder\",\"path\":\"$H/Documents/English\"}" >/dev/null; sleep 6
r=$(cmd "clean up duplicates"); print "  → $(print -r -- $r | jq_ "d['message']")"
n=$(ls "$H/Documents/English" | grep -c macbeth)
[[ $n == 1 ]] && ok "“clean up duplicates” removed extra copies" || bad "clean up duplicates" "$n left: $r"
api POST /v1/undo >/dev/null; sleep 1
[[ $(ls "$H/Documents/English" | grep -c macbeth) == 3 ]] && ok "undo restored the duplicates" || bad "undo duplicates"

step "5 · Plain-English rule → watcher → undo"
r=$(api POST /v1/rules "{\"text\":\"If a PDF in Downloads contains 'MYP3' → move to $H/Documents/School, tag myp3\"}")
[[ "$r" == *myp3* ]] && ok "rule compiled & saved" || bad "rule create" "$r"
pdf "$H/Downloads/myp3-report.pdf" "MYP3 unit report on energy transfer"
waitfor 40 '[[ -f "$H/Documents/School/myp3-report.pdf" ]]' && ok "rule fired: file moved" || bad "rule fired"
api POST /v1/undo >/dev/null; waitfor 5 '[[ -f "$H/Downloads/myp3-report.pdf" ]]' && ok "undo moved it back" || bad "undo rule"
rm -f "$H/Downloads/myp3-report.pdf"

step "6 · Pause / resume"
api POST /v1/pause >/dev/null
pdf "$H/Downloads/myp3-paused.pdf" "MYP3 paused test"; sleep 8
[[ -f "$H/Downloads/myp3-paused.pdf" ]] && ok "paused: nothing happens" || bad "pause"
api POST /v1/resume >/dev/null
api POST /v1/ingest "{\"path\":\"$H/Downloads/myp3-paused.pdf\"}" >/dev/null
waitfor 30 '[[ -f "$H/Documents/School/myp3-paused.pdf" ]]' && ok "resumed: file processed" || bad "resume"

step "7 · Commands"
mkdir -p "$H/Desktop"; for i in 1 2; do cp /System/Library/Desktop\ Pictures/*.heic(N[1]) "$H/Desktop/Screenshot 2026-09-1$i at 10.0$i.00.heic" 2>/dev/null || printf "img" > "$H/Desktop/Screenshot 2026-09-1$i at 10.0$i.00.png"; done
sleep 4
r=$(cmd "move all screenshots from Desktop to ~/Pictures/Screenshots and tag them shots")
print "  → $(print -r -- $r | jq_ "d['message']")" | cut -c1-200
waitfor 15 '[[ $(ls "$H/Pictures/Screenshots" 2>/dev/null | wc -l) -ge 2 ]]' && ok "multi-step move + tag command" || bad "move screenshots" "$r"
q=""; waitfor 30 'q=$(cmd "find everything about kinematics"); [[ "$q" == *kinematics-notes* ]]' && ok "content search" || bad "search" "$q"
a=$(cmd "when is the brightsparks invoice due?"); print "  → $(print -r -- $a | jq_ "d['message']")" | cut -c1-240
[[ "$a" == *Dec* || "$a" == *12* ]] && ok "question answered from files (offline)" || bad "ask" "$a"
b=$(cmd "brief me"); [[ ${#b} -gt 60 ]] && ok "briefing" || bad "briefing" "$b"
s=$(cmd "every Sunday at 9am generate weekly report"); sc=$(api GET /v1/schedule); [[ "$sc" == *eport* ]] && ok "schedule created" || bad "schedule" "$s $sc"
rep=$(api GET "/v1/report?type=weekly"); [[ ${#rep} -gt 100 ]] && ok "weekly report generated" || bad "report"
p=$(cmd "move kinematics-notes.txt to ~/Library/Keychains")
[[ -f "$H/Documents/School/Physics/kinematics-notes.txt" ]] && ok "protected location refused" || bad "protected path" "$p"

step "8 · Insights"
api POST /v1/tasks '{"operation":"scanInsights"}' >/dev/null; sleep 6
ins=$(api GET /v1/insights); print "  $(print -r -- $ins | jq_ "', '.join(i['title'] for i in d)")" | cut -c1-240
[[ "$ins" == \[* ]] && ok "insights scan completes" || bad "insights" "$ins"

step "9 · iPhone remote protocol"
api POST /v1/settings '{"remoteEnabled":true}' >/dev/null; sleep 3
code=$(api POST /v1/remote/pairing | jq_ "d.get('code','')")
rt=$($APP/Contents/MacOS/nexusctl remote-test 127.0.0.1 "$code" 2>&1)
[[ "$rt" == *"paired as"* && "$rt" == *"replayed request rejected"* && "$rt" == *"tampered ciphertext rejected"* && "$rt" != *"✗"* ]] && ok "pair, encrypted commands, replay & tamper protection" || bad "remote" "$rt"

step "10 · Crash recovery & persistence"
rules_before=$(api GET /v1/rules | jq_ "len(d)")
pkill -9 -f "Nexus.app/Contents/MacOS/Nexus$"; sleep 2
pdf "$H/Downloads/myp3-while-closed.pdf" "MYP3 created while Nexus was not running"
launch && ok "relaunch after kill -9" || bad "relaunch"
[[ $(api GET /v1/rules | jq_ "len(d)") == $rules_before ]] && ok "rules persisted ($rules_before)" || bad "rules persisted"
waitfor 40 '[[ -f "$H/Documents/School/myp3-while-closed.pdf" ]]' && ok "file added while app was closed gets processed on relaunch" || bad "catch-up after restart"
sleep 5; pkill -9 -f "Nexus.app/Contents/MacOS/Nexus$"; sleep 5
pgrep -f "Helpers/llama/llama-server" >/dev/null && bad "llama-server orphaned after crash" || ok "offline model server exits with the app"

step "11 · System integration"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
ls_=$($lsregister -dump 2>/dev/null); [[ "$ls_" == *"nexus:"* ]] && ok "nexus:// URL scheme registered" || bad "URL scheme"
pk=$(pluginkit -m -A 2>/dev/null); [[ "$pk" == *app.nexus.mac.widgets* ]] && ok "widget extension registered with macOS" || bad "widget registration"
[[ -f ~/Library/Application\ Support/Nexus/widget/snapshot.json ]] && ok "widget snapshot written" || bad "widget snapshot"

print "\n━━ E2E result: $PASS passed, $FAIL failed"
(( FAIL )) && { print "Failed: ${(j:, :)FAILED}"; exit 1; }
exit 0
