# 🚀 Presto v2

**Docker Stack Manager for Raspberry Pi and Debian-based systems**

Pick your self-hosted services, generate a `docker-compose.yml`, and manage your stack — all from a clean terminal UI powered by [gum](https://github.com/charmbracelet/gum).

---

## Requirements

- Raspberry Pi 4/5 or any Debian/Ubuntu/Raspberry Pi OS system (64-bit recommended)
- `git` (installed by presto if missing)
- `gum` (installed automatically on first run)
- `docker` + `docker compose` (installable via the presto menu)

---

## Install

```bash
git clone https://github.com/piklz/presto.git ~/presto
cd ~/presto
./presto_launch.sh
```

That's it. `gum` installs itself on first launch if not present.

---

## First-time setup order

```
1. Install Docker + Compose      →  menu: Install Docker + Compose
2. Add your templates            →  already in .templates/
3. Build your stack              →  menu: Build / Manage Stack
4. Edit .env files               →  services/<name>/<name>.env
5. Start                         →  menu: Docker Commands > Start stack
                                    or:  docker compose up -d
```

---

## Logs

```bash
journalctl -t presto          # all presto logs
journalctl -t presto -f       # live tail
```

---

## Adding a new service

1. Create `.templates/<service-name>/`
2. Add `meta.sh` (copy the template below)
3. Add `service.yml` (your docker compose service snippet)
4. Optionally add `<service-name>.env.example`

**meta.sh template:**
```bash
#!/usr/bin/env bash
SERVICE_DESC="What this service does"
SERVICE_ICON="📦"
SERVICE_ARCH="all"   # all | arm64 | amd64 | armv7
SERVICE_TAGS="tag1 tag2"
```

The service appears automatically in the Build Stack picker — no script edits needed.

---

## Repo structure

```
presto/
├── presto_launch.sh       ← entry point
├── lib/
│   ├── log.sh             ← logging + spinner
│   ├── ui.sh              ← gum UI helpers + auto-install
│   ├── system.sh          ← git, disk, arch, swap, log2ram
│   ├── docker.sh          ← docker install + commands
│   ├── stack.sh           ← service discovery + compose builder
│   └── backup.sh          ← rclone backup/restore
├── scripts/               ← start/stop/restart/prune/update
├── .templates/
│   └── <service>/
│       ├── meta.sh        ← icon, description, arch filter
│       ├── service.yml    ← docker compose service block
│       └── *.env.example  ← copied to services/ on first deploy
└── services/              ← generated, gitignored, your live configs
```

---

## Included services

| Service | Port | Description |
|---|---|---|
| Portainer | 9000 | GUI Docker manager |
| Sonarr | 8989 | TV downloader |
| Radarr | 7878 | Movie downloader |
| Lidarr | 8686 | Music downloader |
| Jackett | 9117 | Torrent indexer |
| Prowlarr | 9696 | Indexer manager |
| qBittorrent | 8080 | Torrent client |
| Jellyfin | 8096 | Media server (free) |
| Plex | 32400 | Media server |
| Tautulli | 8181 | Plex stats |
| Seerr | 5055 | Media request manager |
| Heimdall | 80/443 | Dashboard |
| Homarr | 7575 | Dashboard |
| Homepage | 3000 | Dashboard |
| Home Assistant | 8123 | Home automation |
| MotionEye | 8765 | Security cameras |
| WireGuard | 51820 | VPN |
| WireGuard UI | 5000 | VPN web UI |
| Pi-hole | 80/53 | Ad blocker + DNS |
| Uptime Kuma | 3001 | Uptime monitor |
| Syncthing | 8384 | File sync |
| PhotoPrism | 2342 | Photo manager |
| Immich | 2283 | Photo manager (AI) |
| Glances | 61208 | System monitor |
| IT-Tools | 8080 | IT utilities |
| Caddy | 80/443 | Reverse proxy |
| Vaultwarden | 80 | Password manager |
| Trilium | 8080 | Notes |
| HomeBox | 7745 | Home inventory |
| Mosquitto | 1883 | MQTT broker |
| FlareSolverr | 8191 | Cloudflare bypass |
| Immich Power Tools | — | Immich extras |
| Omni-Tools | — | PDF tools |
| DockSentry | — | Container alerts |
| presto-x728 | 7728 | UPS Hat monitor (Pi only) |

---

## License

GPL-3.0 — see [LICENSE](LICENSE)
