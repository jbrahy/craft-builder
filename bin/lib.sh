# shellcheck shell=bash
# Shared by the web and builder scripts. Sourced, not run.

ORG=storytold
DATA=/srv/craft

# Repo names, tags and file names come from upstream or from the builder,
# which runs unreviewed code. They become paths and HTML, so anything outside
# this set is refused.
safe_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; }

gh_api() { curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' "https://api.github.com/$1"; }

# Delete all but the newest $2 entries in $1, refusing any path outside
# $DATA/public/<kind>/<repo>/.
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
