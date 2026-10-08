# craft-builder

Nightly mirror and builds of the ArtCraft "Crafting Apps"
(github.com/storytold) for Reach X, served at https://craft.reach-x.com/.

Two OCI VMs in compartment `prod-craft` (Terraform in aws-terraform:
`oci/hosts-craft-web.tf`, `oci/hosts-craft.tf`):

- **craft-web**, always on, small. Serves the site and the git mirrors
  (Caddy), runs the nightly, sends the email.
- **craft** (the builder), 8 OCPU. Powered off except during the build.

Each night at 01:00 Pacific, `craft-nightly.timer` on craft-web:

1. Mirrors every storytold repo into `/srv/craft/public/git`
   (`git clone https://craft.reach-x.com/git/<repo>.git`).
2. Queues each Rust repo whose HEAD changed since its last good build.
3. Powers on the builder (OCI instance principal, allowed to power-cycle that
   one instance only), sends the queue over ssh, waits, pulls the artifacts,
   powers it off. The builder builds linux-x86_64 natively (upstream's
   `packaging/linux/package.sh`, or plain `cargo build --release`) and
   windows-x64 by cross-compile (cargo-xwin, unsigned zip of the .exe).
4. Publishes the artifacts, recomputing checksums. Keeps 7 builds per repo.
5. Mirrors upstream's macOS releases, verified against SHA256SUMS. Keeps 3.
6. Regenerates the site (`site/build_site.py`) and emails a summary to
   john@brahy.com through SES (`craft-report.service`).

## Deploy

    ssh ubuntu@craft.reach-x.com
    sudo git -C /opt/craft-builder pull
    sudo bash /opt/craft-builder/bootstrap.sh web

The builder is off most of the time. To update it, start it, then:

    ssh ubuntu@<builder public IP>
    sudo git -C /opt/craft-builder pull
    sudo bash /opt/craft-builder/bootstrap.sh builder

and stop it again (the nightly also stops it).

Run a night by hand on craft-web: `sudo systemctl start --no-block craft-nightly`.
Follow it: `journalctl -fu craft-nightly`; results in `/srv/craft/status/<date>.tsv`.

## Security

The builder runs unreviewed upstream code, so:

- It holds no keys. Its compartment matches no dynamic group, and the build
  user is blocked from the instance metadata service anyway.
- craft-web reaches it as user `driver`, whose key is locked to
  `bin/builder-ssh.sh` (ping, build, fetch, clean); `driver` may only
  `systemctl start craft-build.service`. Builds run in that unit as `builder`,
  without privileges, writing only to `/srv/craft`.
- craft-web treats everything returned as untrusted: names are validated,
  symlinks dropped, only package file types published, checksums recomputed.
- Caddy serves everything under `/builds`, `/upstream` and `/git` as a
  sandboxed download, and the site's CSP allows only `/assets/site.js`.
- The SES key is in `/etc/craft/ses.env` on craft-web, mode 600, readable only
  by `craft-report`. The IAM user `craft-nightly-mail` may only send from
  craft@reach-x.com to john@brahy.com.
