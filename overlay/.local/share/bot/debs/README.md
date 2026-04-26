# Bundled .deb packages

This directory holds Debian packages that BoT installs on first run. They are bundled in the release tarball so the installer can succeed even before the user has connected to the network.

## Current contents

| Package | Purpose | Source |
|---|---|---|
| `yad_*.deb` | GUI toolkit used by `bot-menu` and other dialogs | Debian Bookworm `main` |

## Build-time refresh

Maintainers refresh these debs at release-cut time so the bundled version tracks Debian stable. From a Debian Bookworm machine (or `docker run --rm -it debian:bookworm`):

```bash
cd overlay/.local/share/bot/debs
rm -f yad_*.deb SHA256SUMS
apt-get update
apt-get download yad
sha256sum yad_*.deb > SHA256SUMS
```

Commit both the `.deb` and the `SHA256SUMS` file.

## Install-time verification

The BoT installer (`b`) verifies these packages before installing:

```bash
cd "$BOT_DIR/overlay/.local/share/bot/debs"
sha256sum -c SHA256SUMS || exit 1
sudo apt-get install -y ./yad_*.deb     # or: sudo dpkg -i yad_*.deb
```

If `SHA256SUMS` is missing or any hash mismatches, the installer aborts. Do not edit the `.deb` files in place — refresh them via the build-time procedure above.
