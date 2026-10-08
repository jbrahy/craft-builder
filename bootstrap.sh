#!/usr/bin/env bash
# Set up (or update) a craft box. Idempotent. Run as root:
#   sudo bash /opt/craft-builder/bootstrap.sh web       # craft-web (always on)
#   sudo bash /opt/craft-builder/bootstrap.sh builder   # craft (on only during builds)
# First time:
#   sudo git clone https://github.com/jbrahy/craft-builder /opt/craft-builder
# Deploy a change: git -C /opt/craft-builder pull, then re-run this script.
#
# web: the SES key for report.sh is NOT installed here. Write /etc/craft/ses.env
# (AWS_ACCESS_KEY_ID=..., AWS_SECRET_ACCESS_KEY=...) separately, mode 600, owner
# craft-report. The first run prints craft's ssh public key: commit it as
# deploy/builder/web-to-builder.pub, then bootstrap the builder.
set -euo pipefail

ROLE=${1:-}
case $ROLE in web|builder) ;; *) echo "usage: $0 web|builder" >&2; exit 2 ;; esac

SRC=$(cd "$(dirname "$0")" && pwd)
DATA=/srv/craft
DEV=/dev/sdb
TC=$DATA/toolchain
NFPM_VERSION=2.47.0
export DEBIAN_FRONTEND=noninteractive

apt-get update -q
apt-get install -yq --no-install-recommends git curl jq unzip zip ca-certificates iptables-persistent

# --- data volume ------------------------------------------------------------
# Format only a device with no filesystem at all, never a mounted one.
LABEL=craft-data
[ "$ROLE" = web ] && LABEL=craft-web-data
if ! blkid "$DEV" >/dev/null 2>&1 && ! findmnt -S "$DEV" >/dev/null; then
  mkfs.ext4 -q -L "$LABEL" "$DEV"
fi
mkdir -p "$DATA"
grep -q "LABEL=$LABEL" /etc/fstab || echo "LABEL=$LABEL $DATA ext4 defaults,nofail 0 2" >> /etc/fstab
findmnt "$DATA" >/dev/null || mount "$DATA"

getent group craft >/dev/null || groupadd --system craft
install -d -o root -g craft -m 2775 "$DATA"
install -d -o root -g root -m 0755 /etc/craft

# Insert an iptables rule before the image's final REJECT, once.
fw_allow() {
  iptables -C "$@" 2>/dev/null && return
  local pos
  pos=$(iptables -L "$1" --line-numbers -n | awk '$2=="REJECT"{print $1; exit}')
  iptables -I "$1" "${pos:-1}" "${@:2}"
}

if [ "$ROLE" = web ]; then
  # ==========================================================================
  apt-get install -yq --no-install-recommends caddy python3 python3-venv fonts-overpass

  if ! command -v aws >/dev/null; then
    curl -fsSL -o /tmp/awscli.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
    (cd /tmp && unzip -q -o awscli.zip && ./aws/install)
    rm -rf -- /tmp/aws /tmp/awscli.zip
  fi
  if [ ! -x /opt/oci-cli/bin/oci ]; then
    python3 -m venv /opt/oci-cli
    /opt/oci-cli/bin/pip install -q oci-cli
  fi

  # Ubuntu OCI images REJECT everything but ssh; open 80/443 (the NSG also allows them).
  for p in 80 443; do
    fw_allow INPUT -p tcp --dport "$p" -m conntrack --ctstate NEW -j ACCEPT
  done
  netfilter-persistent save >/dev/null

  id craft >/dev/null 2>&1 || useradd --system --gid craft --home-dir "$DATA/home/craft" --create-home --shell /usr/sbin/nologin craft
  id craft-report >/dev/null 2>&1 || useradd --system --gid craft --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin craft-report
  install -d -o craft -g craft -m 2775 "$DATA/status" "$DATA/logs" "$DATA/state"
  install -d -o craft -g craft -m 0755 "$DATA/public"
  install -d -o craft -g craft -m 0700 "$DATA/home/craft/.ssh"
  if [ ! -f "$DATA/home/craft/.ssh/builder" ]; then
    sudo -u craft ssh-keygen -q -t ed25519 -N '' -C craft-web-to-builder -f "$DATA/home/craft/.ssh/builder"
  fi

  install -m 0644 "$SRC"/deploy/web/craft-nightly.service "$SRC"/deploy/web/craft-nightly.timer \
    "$SRC"/deploy/web/craft-report.service /etc/systemd/system/
  install -m 0644 "$SRC"/deploy/web/Caddyfile /etc/caddy/Caddyfile
  chmod 0755 "$SRC"/bin/*.sh
  systemctl daemon-reload
  systemctl enable --now craft-nightly.timer
  systemctl enable caddy
  systemctl reload-or-restart caddy

  [ -f /etc/craft/ses.env ] || echo "NOTE: /etc/craft/ses.env missing; the nightly email will fail until it exists."
  echo "craft-web -> builder public key (deploy/builder/web-to-builder.pub):"
  cat "$DATA/home/craft/.ssh/builder.pub"
  systemctl list-timers craft-nightly.timer --no-pager
  exit 0
fi

# ============================================================================
# builder
apt-get install -yq --no-install-recommends \
  build-essential pkg-config clang lld llvm cmake nasm ninja-build golang-go file \
  rpm zsync desktop-file-utils appstream python3-yaml \
  libxkbcommon-dev libwayland-dev libx11-dev libxrandr-dev libxi-dev \
  libgl1-mesa-dev libssl-dev libfontconfig-dev libasound2-dev libudev-dev \
  libgtk-3-dev libwebkit2gtk-4.1-dev libsoup-3.0-dev libayatana-appindicator3-dev librsvg2-dev \
  clang-19 lld-19 llvm-19

if ! command -v nfpm >/dev/null; then
  curl -fsSL -o /tmp/nfpm.deb "https://github.com/goreleaser/nfpm/releases/download/v${NFPM_VERSION}/nfpm_${NFPM_VERSION}_amd64.deb"
  dpkg -i /tmp/nfpm.deb && rm -f /tmp/nfpm.deb
fi

# clang-cl is just clang under another name; Ubuntu's clang-19 doesn't ship it.
install -d /usr/local/lib/craft-llvm/bin
ln -sfn /usr/lib/llvm-19/bin/clang /usr/local/lib/craft-llvm/bin/clang-cl

id builder >/dev/null 2>&1 || useradd --system --gid craft --home-dir "$DATA/home/builder" --create-home --shell /usr/sbin/nologin builder
id driver >/dev/null 2>&1 || useradd --system --gid craft --create-home --home-dir /home/driver --shell /bin/bash driver
install -d -o builder -g craft -m 2775 "$DATA/work" "$DATA/out" "$TC"

# The build user must never reach the instance metadata service (instance
# principal credentials), whatever the compartment's policies say.
iptables -C OUTPUT -d 169.254.169.254 -m owner --uid-owner builder -j REJECT 2>/dev/null ||
  iptables -I OUTPUT 1 -d 169.254.169.254 -m owner --uid-owner builder -j REJECT
# Nothing is served from here any more.
for p in 80 443; do
  iptables -D INPUT -p tcp --dport "$p" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null || true
done
netfilter-persistent save >/dev/null

# craft-web's key, locked to bin/builder-ssh.sh.
install -d -o driver -g craft -m 0700 /home/driver/.ssh
if [ -s "$SRC/deploy/builder/web-to-builder.pub" ]; then
  printf 'restrict,command="/opt/craft-builder/bin/builder-ssh.sh" %s\n' "$(cat "$SRC/deploy/builder/web-to-builder.pub")" > /home/driver/.ssh/authorized_keys
  chown driver:craft /home/driver/.ssh/authorized_keys
  chmod 0600 /home/driver/.ssh/authorized_keys
else
  echo "NOTE: deploy/builder/web-to-builder.pub missing; craft-web cannot drive this builder yet."
fi
install -m 0440 "$SRC/deploy/builder/sudoers-driver" /etc/sudoers.d/craft-driver
visudo -cq -f /etc/sudoers.d/craft-driver

as_builder() {
  sudo -u builder env HOME="$DATA/home/builder" RUSTUP_HOME="$TC/rustup" CARGO_HOME="$TC/cargo" \
    PATH="$TC/cargo/bin:/usr/local/bin:/usr/bin:/bin" "$@"
}
if [ ! -x "$TC/cargo/bin/rustup" ]; then
  curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
  as_builder sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal
  rm -f /tmp/rustup-init.sh
fi
as_builder rustup update stable
as_builder rustup target add x86_64-pc-windows-msvc
as_builder cargo install --locked --quiet cargo-xwin

# Leftovers from when this box was also the web server: nothing here may run
# on its own or hold a key.
for u in craft-nightly.timer craft-nightly.service craft-report.service caddy.service; do
  systemctl disable --now "$u" 2>/dev/null || true
done
rm -f /etc/systemd/system/craft-nightly.timer /etc/systemd/system/craft-nightly.service \
  /etc/systemd/system/craft-report.service /etc/craft/ses.env

install -m 0644 "$SRC"/deploy/builder/craft-build.service /etc/systemd/system/
chmod 0755 "$SRC"/bin/*.sh
systemctl daemon-reload
echo "builder ready"
