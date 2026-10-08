#!/usr/bin/env bash
# Forced command for craft-web's key on the builder (user "driver";
# authorized_keys: restrict,command="/opt/craft-builder/bin/builder-ssh.sh").
# This is everything craft-web can do here:
#   ping    prove ssh is up
#   build   stdin: "repo<TAB>sha" lines; runs craft-build.service; prints results.tsv
#   fetch   tar of /srv/craft/out on stdout
#   clean   empty /srv/craft/out
set -euo pipefail
. /opt/craft-builder/bin/lib.sh

OUT=$DATA/out

case ${SSH_ORIGINAL_COMMAND:-} in
  ping)
    echo ok
    ;;
  build)
    q=$(mktemp)
    while IFS=$'\t' read -r repo sha; do
      if ! safe_name "$repo" || [[ ! $sha =~ ^[0-9a-f]{40}$ ]]; then
        echo "builder-ssh: bad queue line" >&2
        rm -f "$q"
        exit 2
      fi
      printf '%s\t%s\n' "$repo" "$sha" >> "$q"
    done
    install -m 0644 "$q" "$DATA/queue.tsv"
    rm -f "$q"
    # Type=oneshot: start returns when build.sh finishes.
    sudo /usr/bin/systemctl start craft-build.service
    cat "$OUT/results.tsv"
    ;;
  fetch)
    tar -C "$OUT" -cf - .
    ;;
  clean)
    find "${OUT:?}" -mindepth 1 -delete
    ;;
  *)
    echo "builder-ssh: unknown command" >&2
    exit 2
    ;;
esac
