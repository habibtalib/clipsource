#!/bin/bash
# End-to-end sync check against the LOCAL Supabase stack only (never a hosted project).
# Starts the stack if needed, resets the schema, and creates throwaway users with generated passwords.
# Usage: Scripts/sync-e2e.sh            run the two-device check (clipsrc on two temp databases)
#        Scripts/sync-e2e.sh -- CMD...  set up, then run CMD with SB_URL, SB_KEY, SB_EMAIL_A/B, SB_PASS_A/B exported
set -euo pipefail
cd "$(dirname "$0")/.."

command -v supabase >/dev/null || { echo "supabase CLI not found" >&2; exit 1; }
supabase status >/dev/null 2>&1 || supabase start -x edge-runtime,logflare,vector,imgproxy,storage-api
supabase db reset >/dev/null

eval "$(supabase status -o env 2>/dev/null | grep -E '^(API_URL|ANON_KEY)=')"
case "$API_URL" in http://127.0.0.1:*|http://localhost:*) ;; *) echo "refusing non-local API_URL" >&2; exit 1 ;; esac
export SB_URL="$API_URL" SB_KEY="$ANON_KEY"

signup() {
    curl -sf "$SB_URL/auth/v1/signup" -H "apikey: $SB_KEY" -H 'Content-Type: application/json' \
        -d "{\"email\":\"$1\",\"password\":\"$2\"}" >/dev/null
}
run=$(openssl rand -hex 4)
export SB_EMAIL_A="a-$run@test.local" SB_PASS_A=$(openssl rand -hex 16)
export SB_EMAIL_B="b-$run@test.local" SB_PASS_B=$(openssl rand -hex 16)
signup "$SB_EMAIL_A" "$SB_PASS_A"
signup "$SB_EMAIL_B" "$SB_PASS_B"

if [[ "${1:-}" == "--" ]]; then
    shift
    exec "$@"
fi

# Two simulated Macs: separate databases and file-based secrets, one account.
swift build -q --product clipsrc
CLI="$(swift build --show-bin-path)/clipsrc"
WORK=$(mktemp -d)
SAVED_CLIPBOARD=$(pbpaste 2>/dev/null || true)
trap 'printf %s "$SAVED_CLIPBOARD" | pbcopy; rm -rf "$WORK"' EXIT
export CLIPSOURCE_SYNC_SECRETS=file
PASSPHRASE=$(openssl rand -hex 12)
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
on() { CLIPSOURCE_DB="$WORK/$1/history.sqlite" "$CLI" "${@:2}"; }

for d in A B; do
    mkdir -p "$WORK/$d"
    on $d sync setup --url "$SB_URL" --anon-key "$SB_KEY" >/dev/null
    python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["device"]["name"]=sys.argv[2]; json.dump(d,open(p,"w"))' \
        "$WORK/$d/sync.json" "Mac $d"
    echo "$SB_PASS_A" | on $d sync login --email "$SB_EMAIL_A" >/dev/null
done
echo "$PASSPHRASE" | on A sync unlock >/dev/null
check "unlock on B with the same passphrase" 'echo "$PASSPHRASE" | on B sync unlock >/dev/null'
mkdir -p "$WORK/C"
on C sync setup --url "$SB_URL" --anon-key "$SB_KEY" >/dev/null
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["device"]["name"]="Mac C"; json.dump(d,open(p,"w"))' "$WORK/C/sync.json"
echo "$SB_PASS_A" | on C sync login --email "$SB_EMAIL_A" >/dev/null
check "wrong passphrase is refused" '! echo "not-it" | on C sync unlock >/dev/null 2>&1'

SECRET_TEXT="e2e-plaintext-$(openssl rand -hex 6)"
echo "$SECRET_TEXT" | on A copy --label "e2e label" >/dev/null
echo "second entry" | on A copy >/dev/null
on A sync once >/dev/null
on B sync once >/dev/null
check "B received both entries" '[ "$(on B list --json | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")" = 2 ]'
check "B shows the source device" 'on B list | grep -q "(from Mac A)"'
check "B keeps the label" 'on B list | grep -q "\[e2e label\]"'
check "A shows its own entries as local" '! on A list | grep -q "(from "'

TOKEN=$(curl -s "$SB_URL/auth/v1/token?grant_type=password" -H "apikey: $SB_KEY" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$SB_EMAIL_A\",\"password\":\"$SB_PASS_A\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
# Clips are only readable by a session with a registered device; register these raw sessions as web viewers.
register_web() {
    curl -s "$SB_URL/rest/v1/rpc/register_device" -H "apikey: $SB_KEY" -H "Authorization: Bearer $1" \
        -H 'Content-Type: application/json' -d "{\"p_device_id\":\"$2\",\"p_name\":\"Web e2e\",\"p_kind\":\"web\"}"
}
check "an unregistered session reads nothing" '[ "$(curl -s "$SB_URL/rest/v1/clips?select=hash" -H "apikey: $SB_KEY" -H "Authorization: Bearer $TOKEN")" = "[]" ]'
register_web "$TOKEN" "web-a-$run" >/dev/null
ROWS=$(curl -s "$SB_URL/rest/v1/clips?select=*" -H "apikey: $SB_KEY" -H "Authorization: Bearer $TOKEN")
check "server stores 2 rows" '[ "$(echo "$ROWS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")" = 2 ]'
check "server never sees plaintext, label or device name" '! echo "$ROWS" | grep -q -e "$SECRET_TEXT" -e "e2e label" -e "Mac A"'
TOKEN_B=$(curl -s "$SB_URL/auth/v1/token?grant_type=password" -H "apikey: $SB_KEY" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$SB_EMAIL_B\",\"password\":\"$SB_PASS_B\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
register_web "$TOKEN_B" "web-b-$run" >/dev/null
check "another account sees none of these rows" '[ "$(curl -s "$SB_URL/rest/v1/clips?select=hash" -H "apikey: $SB_KEY" -H "Authorization: Bearer $TOKEN_B")" = "[]" ]'

ID=$(on B list --json | python3 -c 'import json,sys,os; print(next(e["id"] for e in json.load(sys.stdin) if e["text"].startswith("e2e-plaintext")))')
on B delete "$ID" >/dev/null
on B sync once >/dev/null
on A sync once >/dev/null
check "delete on B reaches A" '! on A list | grep -q "e2e-plaintext"'
check "the other entry survives" 'on A list | grep -q "second entry"'

# A pull larger than two pages (the engine pages by 500).
on A debug-seed 1200 >/dev/null
on A sync once >/dev/null
on B sync once >/dev/null
check "B receives all 1,200 seeded entries" '[ "$(on B list --limit 5000 --label seed --json | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")" = 1200 ]'

# Device ids are bound to the sign-in session that registered them.
mkdir -p "$WORK/D"
on D sync setup --url "$SB_URL" --anon-key "$SB_KEY" >/dev/null
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); c=json.load(open(sys.argv[2])); c["device"]["id"]=d["device"]["id"]; json.dump(c,open(sys.argv[2],"w"))' \
    "$WORK/A/sync.json" "$WORK/D/sync.json"
echo "$SB_PASS_A" | on D sync login --email "$SB_EMAIL_A" >/dev/null
IN_USE_OUT=$(echo "$PASSPHRASE" | on D sync unlock 2>&1 || true)
check "another session reusing A's device id is refused" 'echo "$IN_USE_OUT" | grep -q "in use by another session"'
check "the copied-id session cannot sync" '! on D sync once >/dev/null 2>&1'
on D sync logout >/dev/null
check "logout on one device leaves the others signed in and syncing" \
    'on A sync once >/dev/null && on B sync once >/dev/null && on A sync status | grep -q "Sync: *unlocked"'

# ClipSource Cloud: A and B registered as the account's two Macs; Free allows two.
DEVICE_A=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["device"]["id"])' "$WORK/A/sync.json")
ROWS=$(curl -s "$SB_URL/rest/v1/clips?select=device_id" -H "apikey: $SB_KEY" -H "Authorization: Bearer $TOKEN")
check "server rows carry the writer's device id" 'echo "$ROWS" | grep -q "$DEVICE_A"'
check "account shows Free with 2 of 2 Macs" 'on A sync account | grep -q "Plan: *Free" && on A sync account | grep -q "Macs: *2 of 2"'
LIMIT_OUT=$(echo "$PASSPHRASE" | on C sync unlock 2>&1 || true)
check "a third Mac on Free is refused with a device-limit message" 'echo "$LIMIT_OUT" | grep -q "already has 2 Macs on the Free plan"'
check "the refused unlock still keeps the verified key" 'echo "$LIMIT_OUT" | grep -q "Passphrase OK, key saved"'
check "the refused Mac cannot sync" '! on C sync once >/dev/null 2>&1'
DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -m1 '^supabase_db_')
docker exec "$DB_CONTAINER" psql -U postgres -qtAc \
    "update public.profiles set plan = 'pro' where user_id = (select id from auth.users where email = '$SB_EMAIL_A')" >/dev/null
check "after upgrading to Pro the third Mac registers and syncs" 'on C sync once >/dev/null && on C list | grep -q "second entry"'
check "account shows Pro with 3 Macs" 'on C sync account | grep -q "Plan: *Pro" && on C sync account | grep -q "Macs: *3 (unlimited)"'
check "account marks this device" 'on C sync account | grep -q "^  \* Mac C \[mac\]"'
DEVICE_B=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["device"]["id"])' "$WORK/B/sync.json")
check "devices lists all three Macs with ids" '[ "$(on C sync devices | grep -c "\[mac\]")" = 3 ] && on C sync devices | grep -q "$DEVICE_B"'
check "devices rename renames another Mac" 'on C sync devices rename "$DEVICE_B" "Mac B renamed" >/dev/null && on C sync devices | grep -q "$DEVICE_B  Mac B renamed"'
check "devices remove refuses this device" '! on C sync devices remove "$(python3 -c "import json; print(json.load(open(\"$WORK/C/sync.json\"))[\"device\"][\"id\"])")" >/dev/null 2>&1'
check "devices remove removes another Mac" 'on C sync devices remove "$DEVICE_B" >/dev/null && ! on C sync devices | grep -q "$DEVICE_B"'
TOKEN_REMOVED=$(python3 -c 'import json,sys,base64; print(json.loads(base64.b64decode(json.load(open(sys.argv[1]))["session"]))["accessToken"])' \
    "$WORK/B/sync-secrets.json")
check "the removed Mac reads nothing" '[ "$(curl -s "$SB_URL/rest/v1/clips?select=hash" -H "apikey: $SB_KEY" -H "Authorization: Bearer $TOKEN_REMOVED")" = "[]" ]'
check "the removed Mac cannot sync or re-register" '! on B sync once >/dev/null 2>&1 && ! on C sync devices | grep -q "$DEVICE_B"'

on A sync logout >/dev/null
check "logout clears the session" 'on A sync status | grep -qi "not signed in\|signed out"'
check "no password or passphrase in sync files" '! cat "$WORK"/*/sync.json "$WORK"/*/sync-secrets.json | grep -q -e "$PASSPHRASE" -e "$SB_PASS_A"'

echo
[ "$fails" -eq 0 ] && echo "sync e2e: all checks passed" || { echo "sync e2e: $fails failed"; exit 1; }
