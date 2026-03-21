# deploy.sh

Turn your VPS into a PaaS with a ~700 line Bash script!

Featuring…

- `git push` to deploy
- Automatic TLS certificates
- Static sites and single-page apps
- Containerized server-side code
- Zero-downtime deployments

## Why deploy.sh?

deploy.sh is significantly less powerful than other open source PaaS options like [Coolify](https://coolify.io) and [Dokku](https://dokku.com). Those apps give you things like database backups, access control, monitoring… at the cost of tens (or hundreds!) of thousands of lines of server-side code and dependencies that must be installed and maintained.

On the other hand, deploy.sh is a single ~700 line Bash script that you can read, debug and customize to fit your needs. Under the hood, it's a thin wrapper over software that's (mostly) already installed on your system: [Git](https://git-scm.com), [Caddy](https://caddyserver.com)[^nginx] and [systemd-nspawn](https://www.man7.org/linux/man-pages/man1/systemd-nspawn.1.html).

[^nginx]: Why Caddy over something like nginx, which _is_ preinstalled on most Linux systems? nginx doesn't support automatic TLS certificate renewal out of the box. Since we'd need to install a package either way, we use Caddy for a more integrated web server.

## Quickstart

**On the server**, install deploy.sh and run the one-time setup:

```sh
curl -fsSL https://raw.githubusercontent.com/jakelazaroff/deploy.sh/refs/heads/main/deploy.sh -o /usr/local/bin/deploy && chmod +x /usr/local/bin/deploy
sudo deploy init
```

`deploy init` installs dependencies (Caddy and systemd-nspawn), creates a `deploy` user, and sets up the directory structure under `/srv/deploy`.

**Create an app:**

```sh
sudo deploy create myapp
```

This prints the git remote URL to add locally, e.g.:

```
git remote add deploy deploy@myserver.com:/srv/deploy/myapp/repo.git
git push deploy main
```

**In your local repo**, add a `deploy.conf` to tell deploy.sh how to build and run your app:

```sh
# static site: serve the "dist" directory
assets=dist

# single-page app
assets=dist
spa=true

# server: build step + start command (receives $PORT)
build=npm ci && npm run build
start=node dist/server.js
```

Then add the remote and push:

```sh
git remote add deploy deploy@myserver.com:/srv/deploy/myapp/repo.git
git push deploy main
```

deploy.sh will build and start your app. **Add a domain** to make it publicly accessible:

```sh
deploy domains add myapp example.com
```

## Commands

### Apps

```
deploy create <app>            Create a new app
deploy list                    List all apps
deploy info <app>              Show app status and configuration
deploy restart <app>           Restart the app container
deploy rollback <app>          Swap back to the previous release
deploy remove <app> [-f]       Delete the app and all its files
```

### Config

Config changes take effect immediately by reconfiguring and restarting the app.

```
deploy domains list <app>
deploy domains add <app> <domain>
deploy domains remove <app> <domain>

deploy env list <app>
deploy env set <app> KEY=value
deploy env remove <app> KEY

deploy apply <app>             Manually re-apply config (e.g. after editing files directly)
```

### Logs

```
deploy logs <app> [-f] [-n N]
```

### deploy.conf

Place a `deploy.conf` file in your repo root to configure how deploy.sh handles your app:

| Key | Description |
|-----|-------------|
| `build=<cmd>` | Build command, run inside an Alpine container with the repo mounted at `/build` |
| `start=<cmd>` | Start command for server apps; receives `$PORT`. Omit for static sites. |
| `assets=<dir>` | Directory to serve static files from (default: repo root) |
| `spa=true` | Enable single-page app mode (serve `index.html` for all paths) |
| `header=<path> <name>: <value>` | Add a response header (repeatable) |

Environment variables set via `deploy env set` are available in both `build` and `start`.

## remote.sh

`remote.sh` is a client-side helper script that lets you run deploy commands against your server directly from a local repo, without SSH-ing in manually.

**Install** it somewhere on your `$PATH` (or just run it from the repo):

```sh
curl -fsSL https://raw.githubusercontent.com/jakelazaroff/deploy.sh/refs/heads/main/remote.sh -o /usr/local/bin/remote && chmod +x /usr/local/bin/remote
```

It reads your `deploy` git remote to figure out the server and app name, so no configuration is needed:

```sh
# equivalent to: ssh deploy@myserver.com deploy info myapp
remote info

remote logs -f
remote restart
remote env set KEY=value
remote domains add example.com
```

To target a different app than the one in the remote URL:

```sh
remote --app otherapp info
```

## Extending

### Directory structure

deploy.sh is intentionally transparent — everything lives in `/srv/deploy` and is plain text:

```
/srv/deploy/
  .internal/
    Caddyfile          # global Caddy config; imports all app caddy.conf files
    machine/           # base Alpine image, shared across all apps
    ports              # port assignments (app--slot=port)
  .plugins/            # drop plugin scripts here; sourced at startup

  myapp/
    repo.git/          # bare git repo; post-receive hook triggers deploys
    active             # contains "blue" or "green" — the active slot
    domains            # one domain per line
    env                # KEY=value pairs; injected into build and start
    caddy.conf         # generated Caddy config for this app
    data/              # persistent volume; mounted at /data in the container

    blue/              # one of two release slots (the other is "green")
      deploy.conf      # copied from the repo
      build.log        # output from the last build
      machine/         # container filesystem
      machine.nspawn   # generated systemd-nspawn config
      start.sh         # generated start script
    green/
      …
```

Since it's all just files, you can inspect or modify state directly — for example, editing `env` or `domains` and running `deploy apply myapp` to pick up the changes.

### Plugins

Plugins are Bash scripts dropped into `/srv/deploy/.plugins/`. They're sourced at startup, so they have access to all of deploy.sh's internal functions and variables.

#### Adding a command:

```sh
# /srv/deploy/.plugins/hello

cmd:hello() {
  local app_name=${1:-}
  echo "Hello from $app_name!"
}

COMMANDS[hello]="cmd:hello"
```

```sh
deploy hello myapp
# Hello from myapp!
```

#### Adding a hook:

In addition to commands, deploy.sh lets you hook into the deploy process. Currently, deploy.sh supports one hook: post-configure.

Post-configure hooks run after Caddy and systemd configuration is generated on every deploy and `deploy apply`. They receive the app name and release directory as arguments.

```sh
# /srv/deploy/.plugins/notify

notify_hook() {
  local app_name=$1 release_dir=$2
  curl -s -X POST https://hooks.example.com/deploy \
    -d "{\"app\": \"$app_name\"}"
}

POST_CONFIGURE_HOOKS+=(notify_hook)
```
