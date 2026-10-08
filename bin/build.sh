#!/usr/bin/env bash
# Builder side of the nightly, as user "builder" (craft-build.service), started
# by craft-web through bin/builder-ssh.sh. Reads /srv/craft/queue.tsv
# (repo <tab> sha, already validated), builds each repo for linux-x86_64
# natively and windows-x64 by cross-compile (cargo-xwin), and writes:
#   /srv/craft/out/<repo>/<date>-<short sha>/   artifacts
#   /srv/craft/out/logs/<repo>-<platform>.log   build logs
#   /srv/craft/out/results.tsv                  repo, platform, ok|fail, note
# Per-repo failures are recorded and the run continues.
set -uo pipefail
. /opt/craft-builder/bin/lib.sh

WORK=$DATA/work
OUT=$DATA/out
QUEUE=$DATA/queue.tsv
LOGS=$OUT/logs
RESULTS=$OUT/results.tsv
DATE=$(date +%F)
BUILD_TIMEOUT=${BUILD_TIMEOUT:-5400}
WIN_TARGET=x86_64-pc-windows-msvc

export CRAFT_FONTS_DIR=$WORK/craft-fonts
export CRAFT_FONTS_REQUIRED=1

mkdir -p "$WORK" "$LOGS"
: > "$RESULTS"

result() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; }

# Check out <sha> of storytold/<repo> into $WORK/<repo>, keeping target/.
checkout() {
  local r=$1 sha=$2 w=$WORK/$1 url=https://github.com/$ORG/$1.git
  [ -d "$w/.git" ] || git clone -q "$url" "$w" || return 1
  git -C "$w" remote set-url origin "$url" &&
    git -C "$w" fetch -q origin "$sha" &&
    git -C "$w" checkout -q --force --detach "$sha" &&
    git -C "$w" clean -qffdx -e /target &&
    git -C "$w" submodule update -q --init --recursive
}

# Fonts are embedded by the craft apps at build time.
fonts_sha=$(git ls-remote "https://github.com/$ORG/craft-fonts.git" HEAD | cut -f1)
[ -n "$fonts_sha" ] && checkout craft-fonts "$fonts_sha" >/dev/null 2>&1

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

while IFS=$'\t' read -r r sha; do
  short=${sha:0:9}
  if ! checkout "$r" "$sha" >"$LOGS/$r-checkout.log" 2>&1; then
    result "$r" linux fail "$short, checkout failed"
    result "$r" windows fail "$short, checkout failed"
    continue
  fi
  NAME=$r-$DATE-$short
  dest=$OUT/$r/$DATE-$short
  mkdir -p "$dest"
  for plat in linux windows; do
    start=$(date +%s)
    if (cd "$WORK/$r" && "build_$plat" "$dest") >"$LOGS/$r-$plat.log" 2>&1; then
      result "$r" "$plat" ok "$short in $(( ($(date +%s) - start) / 60 ))m"
    else
      result "$r" "$plat" fail "$short"
    fi
  done
  rmdir "$dest" 2>/dev/null
done < "$QUEUE"

exit 0
