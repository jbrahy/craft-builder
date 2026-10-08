#!/usr/bin/env bash
# Nightly run on the craft VM, as user "builder" (craft-nightly.service).
#   1. Mirror every github.com/storytold repo into public/git (clonable over HTTPS).
#   2. Build each Rust repo that changed since its last good build:
#      linux-x86_64 natively, windows-x64 by cross-compile (cargo-xwin).
#   3. Mirror upstream's macOS release binaries (verified against SHA256SUMS).
#   4. Publish into public/, write status/<date>.tsv for report.sh.
# Exits non-zero only when the run itself breaks; per-repo failures are
# recorded in the status file and the run continues.
set -uo pipefail

ORG=storytold
DATA=/srv/craft
GIT_PUBLIC=$DATA/public/git
WORK=$DATA/work
BUILDS=$DATA/public/builds
UPSTREAM=$DATA/public/upstream
DATE=$(date +%F)
LOGS=$DATA/logs/$DATE
STATUS=$DATA/status/$DATE.tsv
KEEP_BUILDS=7
KEEP_UPSTREAM=3
BUILD_TIMEOUT=${BUILD_TIMEOUT:-5400}
WIN_TARGET=x86_64-pc-windows-msvc

export CRAFT_FONTS_DIR=$WORK/craft-fonts
export CRAFT_FONTS_REQUIRED=1

mkdir -p "$GIT_PUBLIC" "$WORK" "$BUILDS" "$UPSTREAM" "$LOGS" "$DATA/status"
: > "$STATUS"

# status line: repo <tab> step <tab> result (ok|fail|skip) <tab> note
record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$STATUS"; }

# Repo names and release tags come from upstream: they become paths and HTML,
# so anything outside this set is refused.
safe_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; }

gh_api() { curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' "https://api.github.com/$1"; }

# Delete all but the newest $2 entries matching $1/<pattern>, refusing any
# path outside $DATA/public.
prune() {
  local dir=$1 keep=$2 old
  ls -1d "$dir"/*/ 2>/dev/null | sed 's:/$::' | grep -v '/latest$' | sort -V | head -n "-$keep" |
    while read -r old; do
      case $old in
        "$DATA"/public/*/*/*) rm -rf -- "${old:?}" ;;
        *) echo "prune: refusing $old" >&2 ;;
      esac
    done
}

# --- 1. mirror --------------------------------------------------------------

repos=$(gh_api "orgs/$ORG/repos?per_page=100&type=all" | jq -r '.[].name' | sort) || repos=
for r in $repos; do safe_name "$r" || record "$r" list fail "unsafe repo name, skipped"; done
repos=$(for r in $repos; do safe_name "$r" && echo "$r"; done)
if [ -z "$repos" ]; then
  record "-" list fail "GitHub API repo listing failed"
  exit 1
fi

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

# --- 2. build ---------------------------------------------------------------

# Check out the mirror's HEAD into $WORK/<repo>, keeping target/ between runs.
checkout() {
  local r=$1 sha=$2 w=$WORK/$1
  [ -d "$w/.git" ] || git clone -q "$GIT_PUBLIC/$r.git" "$w" || return 1
  git -C "$w" fetch -q origin &&
    git -C "$w" checkout -q --force --detach "$sha" &&
    git -C "$w" clean -qffdx -e /target &&
    git -C "$w" submodule update -q --init --recursive
}

# Fonts are embedded by the craft apps at build time.
fonts_sha=$(git -C "$GIT_PUBLIC/craft-fonts.git" rev-parse HEAD 2>/dev/null) && checkout craft-fonts "$fonts_sha"

build_linux() {  # in the repo dir; artifacts into $1
  local out=$1
  if [ -x packaging/linux/package.sh ] && timeout "$BUILD_TIMEOUT" packaging/linux/package.sh; then
    cp -a dist/release/. "$out"/ && return 0
  fi
  echo "== upstream packaging unavailable or failed; plain cargo build"
  timeout "$BUILD_TIMEOUT" cargo build --release || return 1
  local bins
  bins=$(find target/release -maxdepth 1 -type f -executable ! -name '*.so' ! -name '*.d' -printf '%f\n')
  [ -n "$bins" ] || return 1
  tar -C target/release -czf "$out/$NAME-linux-x86_64.tar.gz" $bins
}

build_windows() {
  local out=$1 dir=target/$WIN_TARGET/release
  timeout "$BUILD_TIMEOUT" cargo xwin build --release --target "$WIN_TARGET" || return 1
  local files
  files=$(cd "$dir" && ls *.exe *.dll 2>/dev/null)
  [ -n "$files" ] || return 1
  (cd "$dir" && zip -q "$out/$NAME-windows-x64.zip" $files)
}

for r in $repos; do
  m=$GIT_PUBLIC/$r.git
  git -C "$m" cat-file -e HEAD:Cargo.toml 2>/dev/null || continue
  sha=$(git -C "$m" rev-parse HEAD)
  short=${sha:0:9}
  if [ "$(cat "$BUILDS/$r/.last-built" 2>/dev/null)" = "$sha" ]; then
    record "$r" build skip "unchanged at $short"
    continue
  fi
  if ! checkout "$r" "$sha" >"$LOGS/$r-checkout.log" 2>&1; then
    record "$r" build fail "checkout failed, see logs/$DATE/$r-checkout.log"
    continue
  fi

  NAME=$r-$DATE-$short
  dest=$BUILDS/$r/$DATE-$short
  mkdir -p "$dest"
  ok=0
  for plat in linux windows; do
    start=$(date +%s)
    if (cd "$WORK/$r" && "build_$plat" "$dest") >"$LOGS/$r-$plat.log" 2>&1; then
      record "$r" "$plat" ok "$short in $(( ($(date +%s) - start) / 60 ))m"
      ok=$((ok + 1))
    else
      record "$r" "$plat" fail "$short, see logs/$DATE/$r-$plat.log"
    fi
  done

  if [ -n "$(ls -A "$dest")" ]; then
    (cd "$dest" && sha256sum -- * > SHA256SUMS.txt)
    ln -sfn "$DATE-$short" "$BUILDS/$r/latest"
  else
    rmdir "$dest"
  fi
  [ "$ok" -eq 2 ] && echo "$sha" > "$BUILDS/$r/.last-built"
  prune "$BUILDS/$r" "$KEEP_BUILDS"
done

# --- 3. upstream macOS releases ---------------------------------------------

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
    touch "$dest/.complete"
    ln -sfn "$tag" "$UPSTREAM/$r/latest"
    record "$r" macos ok "$tag"
  else
    case $dest in "$UPSTREAM"/*/*) rm -rf -- "${dest:?}" ;; esac
    record "$r" macos fail "$tag download or checksum failed, see logs/$DATE/$r-macos.log"
  fi
  prune "$UPSTREAM/$r" "$KEEP_UPSTREAM"
done

# --- 4. index ---------------------------------------------------------------

{
  echo '<!doctype html><meta charset="utf-8"><title>craft.reach-x.com</title>'
  echo '<style>body{font:14px system-ui;margin:2em}td{padding:2px 12px}</style>'
  echo "<h1>Crafting Apps mirror</h1><p>Updated $(date '+%F %H:%M %Z'). Source: github.com/$ORG. Linux and Windows are built here from source (unsigned). macOS is upstream's release, checksum-verified.</p>"
  echo '<table><tr><th>repo</th><th>git</th><th>our build</th><th>upstream macOS</th></tr>'
  for r in $repos; do
    b=-; u=-
    [ -e "$BUILDS/$r/latest" ] && b="<a href=\"builds/$r/latest/\">$(readlink "$BUILDS/$r/latest")</a>"
    [ -e "$UPSTREAM/$r/latest" ] && u="<a href=\"upstream/$r/latest/\">$(readlink "$UPSTREAM/$r/latest")</a>"
    echo "<tr><td>$r</td><td><code>git clone https://craft.reach-x.com/git/$r.git</code></td><td>$b</td><td>$u</td></tr>"
  done
  echo '</table>'
} > "$DATA/public/index.html.tmp" && mv "$DATA/public/index.html.tmp" "$DATA/public/index.html"

record "-" disk ok "$(df -h --output=used,size,pcent "$DATA" | tail -1 | xargs)"
exit 0
