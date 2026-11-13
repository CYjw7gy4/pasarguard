# Licensing notice

This repository is a **packaging/deployment fork**. It bundles and orchestrates
third-party software:

| Component | Source | Licence |
|---|---|---|
| PasarGuard (panel backend + dashboard) | https://github.com/PasarGuard/PasarGuard | see upstream repository (AGPL-3.0 at the time of packaging) |
| vpn-ui binary (downloaded at build time, not stored here) | https://github.com/Sir-MmD/MmD-Panel (`vpn-ui` releases) | see upstream repository |
| Node.js | https://nodejs.org | MIT |
| `ws` (vendored, `vendor/ws`) | https://github.com/websockets/ws | MIT |
| Python dependencies | PyPI, pinned in `requirements-freeze.txt` | per package |

The `Dockerfile`, `compose.yaml`, `deploy.sh` and the deployment documentation
added by this fork are provided as-is, without warranty.

Before publishing or redistributing this repository, keep the upstream licence
files, and if you run a modified AGPL component as a network service, publish
your modifications as the AGPL requires.
