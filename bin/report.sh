#!/usr/bin/env bash
# Email the nightly result. Runs as user "craft-report" (craft-report.service),
# triggered by craft-nightly.service on success or failure. The SES key lives
# in /etc/craft/ses.env, readable only by this user: the build user runs
# unreviewed upstream code and must never see it.
set -euo pipefail

FROM=craft@reach-x.com
TO=john@brahy.com
DATA=/srv/craft
DATE=$(date +%F)
STATUS=$DATA/status/$DATE.tsv
RESULT=${MONITOR_SERVICE_RESULT:-unknown}

count() { [ -f "$STATUS" ] && awk -F'\t' -v s="$1" -v r="$2" '$2 ~ s && $3 == r' "$STATUS" | wc -l | xargs || echo 0; }

if [ ! -s "$STATUS" ]; then
  subject="craft nightly $DATE: NO STATUS (run result: $RESULT)"
  body="The nightly run wrote no status file. Check: ssh ubuntu@craft.reach-x.com 'journalctl -u craft-nightly -n 100'"
else
  built=$(count 'linux|windows' ok)
  failed=$(awk -F'\t' '$3 == "fail"' "$STATUS" | wc -l | xargs)
  mirrored=$(count mirror ok)
  macos=$(count macos ok)
  subject="craft nightly $DATE: $built builds ok, $failed failed, $mirrored repos mirrored"
  body=$(
    echo "Run result: $RESULT"
    echo "Downloads: https://craft.reach-x.com/"
    echo
    echo "Failures:"
    awk -F'\t' '$3 == "fail" {printf "  %-22s %-8s %s\n", $1, $2, $4}' "$STATUS"
    echo
    echo "Builds:"
    awk -F'\t' '($2 == "linux" || $2 == "windows") && $3 == "ok" {printf "  %-22s %-8s %s\n", $1, $2, $4}' "$STATUS"
    awk -F'\t' '$2 == "build" && $3 == "skip" {printf "  %-22s skipped  %s\n", $1, $4}' "$STATUS"
    echo
    echo "New upstream macOS releases mirrored: $macos"
    awk -F'\t' '$2 == "macos" && $3 == "ok" {printf "  %-22s %s\n", $1, $4}' "$STATUS"
    echo
    awk -F'\t' '$2 == "disk" {print "Disk /srv/craft (used, size, pct): " $4}' "$STATUS"
    for f in $(awk -F'\t' '$3 == "fail" && ($2 == "linux" || $2 == "windows") {print $1 "-" $2}' "$STATUS"); do
      echo
      echo "--- tail of $f.log"
      tail -n 15 "$DATA/logs/$DATE/$f.log" 2>/dev/null
    done
  )
fi

msg=$(mktemp)
jq -n --arg s "$subject" --arg b "$body" '{Simple: {Subject: {Data: $s}, Body: {Text: {Data: $b}}}}' > "$msg"
aws sesv2 send-email --region us-east-1 \
  --from-email-address "$FROM" \
  --destination "ToAddresses=$TO" \
  --content "file://$msg" \
  --query MessageId --output text
rm -f "$msg"
