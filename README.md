# deploy.sh

Turn your Linux VPS into a PaaS with a ~400 line Bash script!

Featuring…

- `git push` to deploy
- Automatic TLS certificates
- Static sites and single-page apps
- Containerized server-side code
- Logging

## Why deploy.sh?

deploy.sh is significantly less powerful than other open source PaaS options like [Coolify](https://coolify.io) and [Dokku](https://dokku.com). Those apps comprise tens or hundreds of thousands of lines of server-side code and dependencies that must be installed and maintained.

On the other hand, deploy.sh is a single ~400 line shell script that you can read, debug and customize to fit your needs. Under the hood, it's a thin wrapper over software that's (mostly) already installed on your system: [Git](https://git-scm.com), [Caddy](https://caddyserver.com)[^nginx] and [systemd-nspawn](https://www.man7.org/linux/man-pages/man1/systemd-nspawn.1.html).

[^nginx]: Why Caddy over something like nginx, which _is_ preinstalled on most Linux systems? nginx doesn't support automatic TLS certificate renewal out of the box. Since we'd need to install a package either way, we use Caddy for a more integrated web server.

## Configuration

App configuration is in two main files:

- `deploy.conf` should be placed at the root of your repo, and contains instructions for deploying your app.
- `server.conf` resides on the server at `/srv/deploy/apps/<name>/server.conf`, and contains sensitive server-specific information.

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

# optional: container port (default: 7890)
port=3000

# optional: serve assets before proxying
assets=public

# For all apps (static sites and containers)
# ------------------------------------------

# optional: domain routing (multi-value)
domain=example.com

# can specify multiple domains
domain=www.example.com
```

The `start` command receives `PORT` as an environment variable. Containers are accessible at `deploy-<app-name>.nspawn:<port>`.

Changes to deploy.conf take effect on next `git push`.

### server.conf

```conf
# read-write mount
mount=/data/uploads:/app/uploads

# read-only mount (:ro)
mount=/etc/secrets:/app/secrets:ro

# environment variable
env=SECRET_KEY=...
```

Changes to server.conf take effect on next `git push` or `deploy _sync <name>`.
