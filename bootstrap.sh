#!/usr/bin/env bash
# Set up (or update) the craft VM. Idempotent. Run as root:
#   sudo bash /opt/craft-builder/bootstrap.sh
# First time:
#   sudo git clone https://github.com/jbrahy/craft-builder /opt/craft-builder
# Deploy a change: git -C /opt/craft-builder pull, then re-run this script.
# The SES key for report.sh is NOT installed here: write /etc/craft/ses.env
# (AWS_ACCESS_KEY_ID=..., AWS_SECRET_ACCESS_KEY=...) separately, mode 600,
# owner craft-report.
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
DATA=/srv/craft
DEV=/dev/sdb
LABEL=craft-data
NFPM_VERSION=2.47.0
TC=$DATA/toolchain

# --- packages ---------------------------------------------------------------
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
  build-essential pkg-config clang lld llvm cmake nasm git curl jq unzip zip file \
  ca-certificates rpm zsync desktop-file-utils appstream python3-yaml \
  libxkbcommon-dev libwayland-dev libx11-dev libxrandr-dev libxi-dev \
  libgl1-mesa-dev libssl-dev libfontconfig-dev libasound2-dev libudev-dev caddy iptables-persistent \
  ninja-build golang-go libgtk-3-dev libwebkit2gtk-4.1-dev libsoup-3.0-dev \
  libayatana-appindicator3-dev librsvg2-dev

if ! command -v nfpm >/dev/null; then
  curl -fsSL -o /tmp/nfpm.deb "https://github.com/goreleaser/nfpm/releases/download/v${NFPM_VERSION}/nfpm_${NFPM_VERSION}_amd64.deb"
  dpkg -i /tmp/nfpm.deb && rm -f /tmp/nfpm.deb
fi

if ! command -v aws >/dev/null; then
  curl -fsSL -o /tmp/awscli.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
  (cd /tmp && unzip -q -o awscli.zip && ./aws/install)
  rm -rf -- /tmp/aws /tmp/awscli.zip
fi

# --- host firewall ----------------------------------------------------------
# Ubuntu OCI images ship an iptables REJECT rule in INPUT, so 80 and 443 must be
# opened here as well as in the NSG. Same approach as reach-x/feedback.
for p in 80 443; do
  if ! iptables -C INPUT -p tcp --dport "$p" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null; then
    pos=$(iptables -L INPUT --line-numbers -n | awk '$2=="REJECT"{print $1; exit}')
    iptables -I INPUT "${pos:-1}" -p tcp --dport "$p" -m conntrack --ctstate NEW -j ACCEPT
  fi
done
netfilter-persistent save >/dev/null

# --- data volume ------------------------------------------------------------
# Format only a device with no filesystem at all, never a mounted one.
if ! blkid "$DEV" >/dev/null 2>&1 && ! findmnt -S "$DEV" >/dev/null; then
  mkfs.ext4 -q -L "$LABEL" "$DEV"
fi
mkdir -p "$DATA"
grep -q "LABEL=$LABEL" /etc/fstab || echo "LABEL=$LABEL $DATA ext4 defaults,nofail 0 2" >> /etc/fstab
findmnt "$DATA" >/dev/null || mount "$DATA"

# --- users ------------------------------------------------------------------
getent group craft >/dev/null || groupadd --system craft
id builder >/dev/null 2>&1 || useradd --system --gid craft --home-dir "$DATA/home/builder" --create-home --shell /usr/sbin/nologin builder
id craft-report >/dev/null 2>&1 || useradd --system --gid craft --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin craft-report

install -d -o builder -g craft -m 2775 "$DATA" "$DATA/status" "$DATA/logs" "$DATA/work" "$TC"
install -d -o builder -g craft -m 0755 "$DATA/public"
install -d -o root -g root -m 0755 /etc/craft

# --- Rust toolchain (as builder, on the data volume) ------------------------
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

# --- services ---------------------------------------------------------------
install -m 0644 "$SRC"/deploy/craft-nightly.service "$SRC"/deploy/craft-nightly.timer \
  "$SRC"/deploy/craft-report.service /etc/systemd/system/
install -m 0644 "$SRC"/deploy/Caddyfile /etc/caddy/Caddyfile
chmod 0755 "$SRC"/bin/*.sh
systemctl daemon-reload
systemctl enable --now craft-nightly.timer
systemctl reload-or-restart caddy

[ -f /etc/craft/ses.env ] || echo "NOTE: /etc/craft/ses.env missing; the nightly email will fail until it exists."
systemctl list-timers craft-nightly.timer --no-pager
