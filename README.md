# craft-builder

Nightly mirror and builds of the ArtCraft "Crafting Apps"
(github.com/storytold) for Reach X, served at https://craft.reach-x.com/.

Runs on the OCI VM `craft` (Terraform: `oci/hosts-craft.tf` in aws-terraform).

Each night at 01:00 Pacific (`craft-nightly.timer`):

1. Mirror every storytold repo into `/srv/craft/public/git` (clone with
   `git clone https://craft.reach-x.com/git/<repo>.git`).
2. Build each Rust repo that changed: linux-x86_64 natively (upstream's
   `packaging/linux/package.sh` when it works, plain `cargo build --release`
   otherwise) and windows-x64 by cross-compile with cargo-xwin (unsigned zip of
   the .exe, no MSI). Keeps the last 7 builds per repo.
3. Mirror upstream's macOS release binaries, verified against SHA256SUMS.
   Keeps the last 3 tags.
4. Email a summary to john@brahy.com through SES (`craft-report.service`).

## Deploy

    ssh ubuntu@craft.reach-x.com
    sudo git -C /opt/craft-builder pull
    sudo bash /opt/craft-builder/bootstrap.sh

Run a night by hand: `sudo systemctl start --no-block craft-nightly`.
Follow it: `journalctl -fu craft-nightly`; results in `/srv/craft/status/<date>.tsv`.

## Security

The build user runs unreviewed upstream code. It has no sudo, writes only to
`/srv/craft`, and cannot read `/etc/craft` (the SES key, owned by
`craft-report`, mode 600). The SES IAM user `craft-nightly-mail` may only send
from craft@reach-x.com to john@brahy.com.
