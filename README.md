# deploy.sh

Turn your VPS into a PaaS with ~800 lines of Bash script!

Featuring…

- `git push` to deploy
- Automatic TLS certificates
- Static sites and single-page apps
- Containerized server-side code
- Logging

## Why deploy.sh?

deploy.sh is significantly less powerful than other open source PaaS options like [Coolify](https://coolify.io) and [Dokku](https://dokku.com). Those apps comprise tens or hundreds of thousands of lines of server-side code and dependencies that must be installed and maintained.

On the other hand, deploy.sh is ~800 lines of Bash script in a single file that you can read, debug and customize to fit your needs. Under the hood, it's a thin wrapper over software that's (mostly) already installed on your system: [Git](https://git-scm.com), [Caddy](https://caddyserver.com)[^nginx] and [systemd-nspawn](https://www.man7.org/linux/man-pages/man1/systemd-nspawn.1.html).

[^nginx]: Why Caddy over something like nginx, which _is_ preinstalled on most Linux systems? nginx doesn't support automatic TLS certificate renewal out of the box. Since we'd need to install a package either way, we use Caddy for a more integrated web server.

## Directory structure

`deploy init` creates the following layout at `/srv/deploy`:

```
/srv/deploy/
├── .internal/
│   ├── machine/              # Alpine Linux base image
│   ├── caddy.service         # Caddy systemd unit (linked into /etc/systemd/system/)
│   ├── Caddyfile             # Global Caddy config (imports all app caddy.conf files)
│   └── ports                 # Port assignments (app--release=port)
└── <app-name>/
    ├── repo.git/             # Bare git repo (push target)
    ├── releases/
    │   └── <YYYYMMDDHHMMSS>/ # Checkout of each deploy (last 5 kept)
    │       ├── deploy.conf   # App config (committed in repo)
    │       ├── machine/      # Container rootfs (container apps only)
    │       ├── start.sh      # Container entrypoint (container apps only)
    │       └── deploy-<app>--<release>.service  # systemd unit (container apps only)
    ├── current -> releases/<latest>  # Symlink to active release
    ├── data/                 # Persistent data volume (mounted as /data inside container)
    ├── caddy.conf            # Per-app Caddy config snippet (generated)
    ├── server.conf           # Server-side config (domain, env, mounts)
    └── access.log            # HTTP access log (JSON; written by Caddy)
```

## Configuration

App configuration is in two main files:

- `deploy.conf` should be placed at the root of your repo, and contains instructions for deploying your app.
- `server.conf` resides on the server at `/srv/deploy/<name>/server.conf`, and contains sensitive server-specific information.

Both files use `key=value` syntax. Repeated keys are allowed. Lines beginning with `#` are comments.

The reason for the two files is that `deploy.conf` contains configuration for deploying your app on _any_ server, whereas `server.conf` contains additional configuration for _your specific_ `deploy.sh` server.

### deploy.conf

```conf
# For static sites
# ----------------

# optional: build in ephemeral container before deploy
build=npm ci && npm run build

# optional: assets directory (default: repo root)
assets=dist

# optional: single-page app mode (serve /index.html with 200 for non-files)
spa=true

# For containers
# --------------

# required: the long-running process command
start=npm start

# optional: runs before each deploy
build=npm ci && npm run build

# optional: serve assets before proxying
assets=public
```

The `start` command receives the port to bind to as the `PORT` environment variable.

Changes to deploy.conf take effect on next `git push`.

### server.conf

```conf
# optional: domain routing
domain=example.com

# read-write mount
mount=/data/uploads:/app/uploads

# read-only mount (:ro)
mount=/etc/secrets:/app/secrets:ro

# environment variable
env=SECRET_KEY=...
```

Changes to server.conf take effect on next `git push` or `deploy config <name> --edit`.
