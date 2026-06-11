#!/usr/bin/env bash
# End-to-end smoke test: boots both services, creates a segment + campaign,
# launches it, waits for the channel simulator's callbacks, prints stats.
set -e
cd "$(dirname "$0")"

(cd channel-service && python -m uvicorn app.main:app --port 8001 > /tmp/channel.log 2>&1) &
CHAN_PID=$!
(cd backend && python -m uvicorn app.main:app --port 8000 > /tmp/crm.log 2>&1) &
CRM_PID=$!
trap "kill $CHAN_PID $CRM_PID 2>/dev/null || true" EXIT
sleep 4

echo "== health =="
curl -s localhost:8000/health; echo; curl -s localhost:8001/health; echo

echo "== preview the audience first (what the UI does live) =="
curl -s -X POST localhost:8000/api/segments/preview -H 'Content-Type: application/json' -d '{
  "rules": {"op":"and","conditions":[
    {"field":"total_spend","cmp":">=","value":5000},
    {"field":"days_since_last_order","cmp":">","value":60}]}}' | python3 -m json.tool
echo

SEG_ID=$(curl -s -X POST localhost:8000/api/segments -H 'Content-Type: application/json' -d '{
  "name": "Lapsed high spenders",
  "rules": {"op":"and","conditions":[
    {"field":"total_spend","cmp":">=","value":5000},
    {"field":"days_since_last_order","cmp":">","value":60}]}}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
echo "segment id: $SEG_ID"

CAMP_ID=$(curl -s -X POST localhost:8000/api/campaigns -H 'Content-Type: application/json' -d "{
  \"name\": \"Win-back: 15% off\",
  \"segment_id\": \"$SEG_ID\",
  \"channel\": \"whatsapp\",
  \"message_template\": \"Hi {{first_name}}! We miss you at Aurelia — here is 15% off with code WELCOME15\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
echo "campaign id: $CAMP_ID"

curl -s -X POST localhost:8000/api/campaigns/$CAMP_ID/launch; echo
echo "== waiting 40s for async lifecycle callbacks =="
sleep 40

echo "== campaign stats after callbacks =="
curl -s localhost:8000/api/campaigns/$CAMP_ID | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(json.dumps({'audience_size': d['audience_size'],
                  'campaign_status': d['status'],
                  'stats': d['stats']}, indent=2))
"
echo "== receipt webhook security check: unsigned callback must be rejected =="
curl -s -o /dev/null -w 'unsigned callback -> HTTP %{http_code}\n' -X POST localhost:8000/api/receipts \
  -H 'Content-Type: application/json' -d '{"events":[]}'
