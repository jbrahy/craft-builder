#!/usr/bin/env bash
# Nightly on craft-web, as user "craft" (craft-nightly.service):
#   1. Mirror every github.com/storytold repo into public/git.
#   2. Queue each Rust repo whose HEAD changed since its last good build.
#   3. Power on the builder, have it build the queue (bin/builder-ssh.sh),
#      pull the artifacts, power it off.
#   4. Publish the artifacts, recomputing checksums here.
#   5. Mirror upstream's macOS release binaries (verified against SHA256SUMS).
#   6. Regenerate the site, write status/<date>.tsv for report.sh.
# Everything that comes back from the builder is untrusted: it runs
# unreviewed upstream code. Names are validated, symlinks dropped.
# Exits non-zero only when the run itself breaks.
set -uo pipefail
. /opt/craft-builder/bin/lib.sh
. /opt/craft-builder/deploy/web/web.env   # BUILDER_ID, BUILDER_IP

GIT_PUBLIC=$DATA/public/git
BUILDS=$DATA/public/builds
UPSTREAM=$DATA/public/upstream
STATE=$DATA/state
INCOMING=$DATA/incoming
DATE=$(date +%F)
LOGS=$DATA/logs/$DATE
STATUS=$DATA/status/$DATE.tsv
KEEP_BUILDS=7
KEEP_UPSTREAM=3

mkdir -p "$GIT_PUBLIC" "$BUILDS" "$UPSTREAM" "$STATE" "$LOGS" "$DATA/status"
: > "$STATUS"

# status line: repo <tab> step <tab> result (ok|fail|skip) <tab> note
record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$STATUS"; }

SSH=(ssh -i "$HOME/.ssh/builder" -o BatchMode=yes -o StrictHostKeyChecking=accept-new
  -o ServerAliveInterval=60 -o ConnectTimeout=10 "driver@$BUILDER_IP")

builder_power() {  # START|SOFTSTOP  RUNNING|STOPPED
  oci --auth instance_principal compute instance action --instance-id "$BUILDER_ID" \
    --action "$1" --wait-for-state "$2" --max-wait-seconds 900 >/dev/null
}

# --- 1. mirror --------------------------------------------------------------

if ! gh_api "orgs/$ORG/repos?per_page=100&type=all" > "$STATE/repos.json.tmp"; then
  record "-" list fail "GitHub API repo listing failed"
  exit 1
fi
mv "$STATE/repos.json.tmp" "$STATE/repos.json"
repos=""
for r in $(jq -r '.[].name' "$STATE/repos.json" | sort); do
  if safe_name "$r"; then repos="$repos $r"; else record "$r" list fail "unsafe repo name, skipped"; fi
done

for r in $repos; do
  m=$GIT_PUBLIC/$r.git
  if [ -d "$m" ]; then
    git -C "$m" remote update --prune >"$LOGS/$r-mirror.log" 2>&1
  else
    git clone -q --mirror "https://github.com/$ORG/$r.git" "$m" >"$LOGS/$r-mirror.log" 2>&1
  fi
  if [ $? -eq 0 ]; then
    git -C "$m" update-server-info
    record "$r" mirror ok "$(git -C "$m" rev-parse --short HEAD 2>/dev/null || echo empty)"
  else
    record "$r" mirror fail "see logs/$DATE/$r-mirror.log"
  fi
done

# --- 2. queue ---------------------------------------------------------------

queue=$STATE/queue.tsv
: > "$queue"
for r in $repos; do
  m=$GIT_PUBLIC/$r.git
  git -C "$m" cat-file -e HEAD:Cargo.toml 2>/dev/null || continue
  sha=$(git -C "$m" rev-parse HEAD)
  if [ "$(cat "$BUILDS/$r/.last-built" 2>/dev/null)" = "$sha" ]; then
    record "$r" build skip "unchanged at ${sha:0:9}"
  else
    printf '%s\t%s\n' "$r" "$sha" >> "$queue"
  fi
done

# --- 3. build on the builder ------------------------------------------------

stop_builder() {
  if builder_power SOFTSTOP STOPPED; then
    record "-" builder ok "powered off"
  else
    record "-" builder fail "SOFTSTOP failed: the builder may still be running (and billing)"
  fi
}

results=$STATE/results.tsv
: > "$results"
if [ -s "$queue" ]; then
  start=$(date +%s)
  if ! builder_power START RUNNING; then
    record "-" builder fail "could not power on the builder"
  else
    trap stop_builder EXIT
    for i in $(seq 1 30); do "${SSH[@]}" ping >/dev/null 2>&1 && break; sleep 10; done
    if "${SSH[@]}" build < "$queue" > "$results" 2>"$LOGS/builder-ssh.log"; then
      record "-" builder ok "$(wc -l < "$queue" | xargs) repos built in $(( ($(date +%s) - start) / 60 ))m"
    else
      record "-" builder fail "build command failed, see logs/$DATE/builder-ssh.log"
    fi
    case $INCOMING in "$DATA"/incoming) rm -rf -- "${INCOMING:?}" ;; esac
    mkdir -p "$INCOMING"
    if "${SSH[@]}" fetch | tar -x --no-same-owner --no-same-permissions -C "$INCOMING"; then
      "${SSH[@]}" clean || true
    else
      record "-" builder fail "artifact fetch failed"
    fi
    trap - EXIT
    stop_builder
  fi
fi

# --- 4. publish -------------------------------------------------------------

find "$INCOMING" -type l -delete 2>/dev/null

# results.tsv: repo, platform, ok|fail, note -- from the builder, so checked.
declare -A both_ok=()
while IFS=$'\t' read -r r plat res note; do
  safe_name "$r" || continue
  [[ $plat =~ ^(linux|windows)$ && $res =~ ^(ok|fail)$ ]] || continue
  note=$(printf '%s' "$note" | tr -cd '[:alnum:] ._,-' | cut -c1-80)
  [ "$res" = fail ] && note="$note, see logs/$DATE/$r-$plat.log"
  record "$r" "$plat" "$res" "$note"
  [ "$res" = ok ] && both_ok[$r]=$(( ${both_ok[$r]:-0} + 1 ))
done < "$results"

for f in "$INCOMING"/logs/*.log; do
  [ -f "$f" ] && safe_name "$(basename "$f")" && cp "$f" "$LOGS/"
done

while IFS=$'\t' read -r r sha; do
  for d in "$INCOMING/$r"/*/; do
    [ -d "$d" ] || continue
    build=$(basename "$d")
    [[ $build =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9a-f]{9}$ ]] || continue
    dest=$BUILDS/$r/$build
    mkdir -p "$dest"
    for f in "$d"*; do
      n=$(basename "$f")
      [ -f "$f" ] && safe_name "$n" && [ "$n" != SHA256SUMS.txt ] && mv "$f" "$dest/$n"
    done
    if [ -n "$(ls -A "$dest")" ]; then
      (cd "$dest" && sha256sum -- * > SHA256SUMS.txt)
      ln -sfn "$build" "$BUILDS/$r/latest"
    else
      rmdir "$dest"
    fi
  done
  [ "${both_ok[$r]:-0}" -eq 2 ] && echo "$sha" > "$BUILDS/$r/.last-built"
  prune "$BUILDS/$r" "$KEEP_BUILDS"
done < "$queue"

# --- 5. upstream macOS releases ---------------------------------------------

for r in $repos; do
  rel=$(gh_api "repos/$ORG/$r/releases?per_page=1") || { record "$r" macos fail "release lookup failed"; continue; }
  tag=$(jq -r '.[0].tag_name // empty' <<<"$rel")
  [ -n "$tag" ] || continue
  safe_name "$tag" || { record "$r" macos fail "unsafe tag name, skipped"; continue; }
  dest=$UPSTREAM/$r/$tag
  [ -f "$dest/.complete" ] && { record "$r" macos skip "$tag already mirrored"; continue; }
  assets=$(jq -r '.[0].assets[] | select(.name | test("macos|SHA256SUMS")) | .browser_download_url' <<<"$rel")
  [ -n "$assets" ] || continue
  mkdir -p "$dest"
  if (cd "$dest" && for u in $assets; do curl -fsSL --retry 3 -O "$u" || exit 1; done &&
      grep -E 'macos' SHA256SUMS.txt | sha256sum -c --quiet -) >"$LOGS/$r-macos.log" 2>&1; then
    jq '.[0] | {tag_name, name, published_at, html_url, prerelease}' <<<"$rel" > "$dest/release.json"
    touch "$dest/.complete"
    ln -sfn "$tag" "$UPSTREAM/$r/latest"
    record "$r" macos ok "$tag"
  else
    case $dest in "$UPSTREAM"/*/*) rm -rf -- "${dest:?}" ;; esac
    record "$r" macos fail "$tag download or checksum failed, see logs/$DATE/$r-macos.log"
  fi
  prune "$UPSTREAM/$r" "$KEEP_UPSTREAM"
done

# --- 6. site ----------------------------------------------------------------

record "-" disk ok "$(df -h --output=used,size,pcent "$DATA" | tail -1 | xargs)"
if ! python3 /opt/craft-builder/site/build_site.py; then
  record "-" site fail "site generation failed"
fi
exit 0
