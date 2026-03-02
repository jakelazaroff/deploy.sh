#!/bin/bash
#
# deploy.sh v0.1.0 - minimal vps deployment system
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this#
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2026 Jake Lazaroff https://github.com/jakelazaroff/deploy.sh

# Install: curl -fsSL https://raw.githubusercontent.com/jakelazaroff/deploy.sh/refs/heads/main/deploy.sh -o /usr/local/bin/deploy && chmod +x /usr/local/bin/deploy

set -e

DEPLOY_ROOT=${DEPLOY_ROOT:-/srv/deploy}
DEPLOY_USER=${DEPLOY_USER:-deploy}

# ============================================================================
# UTILITIES
# ============================================================================

# Require an argument or exit with usage message
require_arg() {
	local arg=$1 usage=$2
	[ -z "$arg" ] && { echo "$usage"; exit 1; }
}

check_domain_collision() {
	local domain=$1 exclude_app=${2:-}

	for deployfile in "$DEPLOY_ROOT"/apps/*/current/deployfile; do
		[ ! -f "$deployfile" ] && continue
		local app_name=$(basename "$(dirname "$(dirname "$deployfile")")")
		[ "$app_name" = "$exclude_app" ] && continue

		while IFS= read -r existing_domain; do
			[ "$existing_domain" = "$domain" ] && { echo "❌ Domain $domain already used by $app_name"; exit 1; }
		done < <(get_conf_all "$deployfile" "domain")
	done
}

get_conf() {
	local file=$1 key=$2 default=${3:-}
	[ ! -f "$file" ] && { echo "$default"; return; }
	local value=$(grep "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-)
	echo "${value:-$default}"
}

get_conf_all() {
	local file=$1 key=$2
	[ -f "$file" ] && grep "^${key}=" "$file" 2>/dev/null | cut -d= -f2-
}

validate_deployfile() {
	local file=$1 app_name=$2
	[ ! -f "$file" ] && { echo "❌ No deployfile found"; exit 1; }

	local start_cmd=$(get_conf "$file" "start")
	local has_domains=$(get_conf_all "$file" "domain" | wc -l)
	[ -z "$start_cmd" ] && [ "$has_domains" -eq 0 ] && { echo "❌ deployfile must have either 'start' (for containers) or 'domain' (for static sites)"; exit 1; }

	while IFS= read -r bind; do
		[[ "$bind" =~ ^/[^:]+:/[^:]+(:ro)?$ ]] || { echo "❌ Invalid bind mount syntax: $bind"; echo "   Expected: bind=/host/path:/container/path[:ro]"; exit 1; }
	done < <(get_conf_all "$file" "bind")

	while IFS= read -r domain; do
		check_domain_collision "$domain" "$app_name"
	done < <(get_conf_all "$file" "domain")
}

# ============================================================================
# SUBCOMMANDS
# ============================================================================

cmd_init() {
	echo "🚀 Setting up deploy.sh at $DEPLOY_ROOT..."

	id "$DEPLOY_USER" &>/dev/null || { useradd -m -s /bin/bash "$DEPLOY_USER"; echo "✅ Created user: $DEPLOY_USER"; }

	read -rp "🔑 Public key for SSH access (paste your ~/.ssh/id_*.pub): " public_key
	if [ -n "$public_key" ]; then
		mkdir -p "/home/$DEPLOY_USER/.ssh"
		echo "$public_key" >> "/home/$DEPLOY_USER/.ssh/authorized_keys"
		chown -R "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
		chmod 700 "/home/$DEPLOY_USER/.ssh" && chmod 600 "/home/$DEPLOY_USER/.ssh/authorized_keys"
		echo "✅ Added public key for $DEPLOY_USER"
	else
		echo "⚠️  No public key provided — add it manually to /home/$DEPLOY_USER/.ssh/authorized_keys"
	fi

	mkdir -p "$DEPLOY_ROOT"/{apps,caddy}
	chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_ROOT"

	if ! grep -q "mymachines" /etc/nsswitch.conf 2>/dev/null; then
		echo "🔧 Configuring container hostname resolution..."
		cp /etc/nsswitch.conf /etc/nsswitch.conf.backup
		sed -i 's/^hosts:.*/hosts: mymachines resolve [!UNAVAIL=return] files myhostname dns/' /etc/nsswitch.conf
		echo "✅ Configured /etc/nsswitch.conf for container resolution"
	fi
	systemctl enable systemd-machined 2>/dev/null || true

	command -v caddy &>/dev/null || { echo "📦 Installing Caddy..."; curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=amd64" -o /usr/local/bin/caddy; chmod +x /usr/local/bin/caddy; }

	if [ ! -f "$DEPLOY_ROOT/caddy/Caddyfile" ]; then
		read -rp "📧 Email for Let's Encrypt certificates: " acme_email
		[ -z "$acme_email" ] && { echo "❌ Email is required for HTTPS certificate provisioning"; exit 1; }
		cat > "$DEPLOY_ROOT/caddy/Caddyfile" <<-CADDY
		{
		    email $acme_email
		}

		import /srv/deploy/apps/*/caddy.conf
		CADDY
		echo "📝 Created Caddyfile"
	fi

	cat > /etc/systemd/system/caddy.service <<-SERVICE
	[Unit]
	Description=Caddy
	After=network.target

	[Service]
	Type=notify
	User=root
	ExecStart=/usr/local/bin/caddy run --config $DEPLOY_ROOT/caddy/Caddyfile
	ExecReload=/usr/local/bin/caddy reload --config $DEPLOY_ROOT/caddy/Caddyfile
	Restart=on-failure

	[Install]
	WantedBy=multi-user.target
	SERVICE

	systemctl daemon-reload && systemctl enable caddy && systemctl start caddy

	mkdir -p /etc/systemd/nspawn
	cat > /etc/systemd/system/deploy@.service <<-SERVICE
	[Unit]
	Description=%i container
	After=network.target

	[Service]
	Type=notify
	ExecStart=/usr/bin/systemd-nspawn --quiet --keep-unit --settings=override --machine=deploy-%i --directory=$DEPLOY_ROOT/apps/%i/container
	Restart=always
	KillMode=mixed

	[Install]
	WantedBy=multi-user.target
	SERVICE
	echo "📝 Created deploy@.service template"

	echo -e "\n✅ System initialized!\n   Location: $DEPLOY_ROOT\n\nNext: deploy create <app-name>"
}

cmd_create() {
	require_arg "$1" "Usage: deploy create <app-name>"
	local app_name=$1 app_dir="$DEPLOY_ROOT/apps/$app_name"
	[ -d "$app_dir" ] && { echo "❌ App $app_name already exists"; exit 1; }

	echo "📦 Creating app: $app_name"
	mkdir -p "$app_dir"/{releases,repo.git}
	cd "$app_dir/repo.git" && git init --bare --initial-branch=main

	cat > hooks/post-receive <<-HOOK
	#!/bin/bash
	/usr/local/bin/deploy _deploy-app $app_name
	HOOK
	chmod +x hooks/post-receive
	chown -R "$DEPLOY_USER:$DEPLOY_USER" "$app_dir"

	cat <<-MSG
	✅ Created app: $app_name

	Add a deployfile to your repo root:

	  For a container app:
	    start=npm start
	    build=npm ci && npm run build
	    port=3000
	    domain=yourdomain.com
	    bind=/data/uploads:/app/uploads

	  For a static site:
	    domain=yourdomain.com

	Next steps:
	  git remote add deploy $DEPLOY_USER@\$(hostname):$app_dir/repo.git
	  git push deploy main

	Container will be created automatically on first deploy if 'start=' is present.
	MSG
}

cmd_list() {
	echo -e "📦 Deployed Apps:\n"
	[ ! -d "$DEPLOY_ROOT/apps" ] && { echo "  (none)"; return; }

	for app_dir in "$DEPLOY_ROOT"/apps/*; do
		[ ! -d "$app_dir" ] && continue
		local app_name=$(basename "$app_dir")
		echo "  $app_name"
		echo "    Location: $app_dir"
		systemctl list-unit-files | grep -q "^deploy@.service" && echo "    Status: $(systemctl is-active "deploy@$app_name" 2>/dev/null || true)"
		[ -d "$app_dir/container" ] && echo "    Machine: deploy-$app_name.nspawn"
		if [ -f "$app_dir/current/deployfile" ]; then
			local domains=$(get_conf_all "$app_dir/current/deployfile" "domain" | tr '\n' ' ')
			local bind_count=$(get_conf_all "$app_dir/current/deployfile" "bind" | wc -l)
			[ -n "$domains" ] && echo "    Domains: $domains"
			[ $bind_count -gt 0 ] && echo "    Bind mounts: $bind_count"
		fi
		echo
	done
}

cmd_logs() {
	require_arg "$1" "Usage: deploy logs <app-name> [journalctl-options...]

Examples:
  deploy logs myapi
  deploy logs myapi -f
  deploy logs myapi --since '1 hour ago'"
	local app_name=$1; shift
	journalctl -u "deploy@$app_name" "$@"
}

cmd_restart() {
	require_arg "$1" "Usage: deploy restart <app-name>"
	echo "🔄 Restarting $1..."
	systemctl restart "deploy@$1"
	echo "✅ Restarted"
}

cmd_remove() {
	require_arg "$1" "Usage: deploy remove <app-name>"
	local app_name=$1 app_dir="$DEPLOY_ROOT/apps/$app_name"
	[ ! -d "$app_dir" ] && { echo "❌ App $app_name does not exist"; exit 1; }

	echo "🗑️  Removing app: $app_name"
	systemctl is-active --quiet "deploy@$app_name" 2>/dev/null && { echo "  Stopping service..."; systemctl stop "deploy@$app_name"; }
	systemctl is-enabled --quiet "deploy@$app_name" 2>/dev/null && systemctl disable "deploy@$app_name"
	[ -f "/etc/systemd/nspawn/deploy-$app_name.nspawn" ] && { rm "/etc/systemd/nspawn/deploy-$app_name.nspawn"; systemctl daemon-reload; }
	[ -f "$app_dir/caddy.conf" ] && { echo "  Removing from Caddy..."; caddy reload --config "$DEPLOY_ROOT/caddy/Caddyfile" 2>/dev/null || true; }
	echo "  Removing app files..." && rm -rf "$app_dir"
	echo "✅ Removed $app_name"
}

cmd_shell() {
	require_arg "$1" "Usage: deploy shell <app-name>"
	local container_root="$DEPLOY_ROOT/apps/$1/container"
	[ ! -d "$container_root" ] && { echo "❌ Container for $1 does not exist"; exit 1; }
	echo "🐚 Entering container for $1..."
	systemd-nspawn --directory="$container_root"
}

cmd__deploy-app() {
	require_arg "$1" "Internal error: app name required"
	local app_name=$1 app_dir="$DEPLOY_ROOT/apps/$app_name"
	local release_dir="$app_dir/releases/$(date +%Y%m%d-%H%M%S)"
	local current_link="$app_dir/current" container_root="$app_dir/container"

	echo "📦 Deploying $app_name..."
	mkdir -p "$release_dir"
	local repo_dir=$(pwd)
	unset GIT_DIR
	git --work-tree="$release_dir" --git-dir="$repo_dir" checkout HEAD -f
	cd "$release_dir"
	ln -sfn "$release_dir" "$current_link"
	echo "✅ Deployed to $current_link"

	local deployfile="$release_dir/deployfile"
	local start_cmd=$(get_conf "$deployfile" "start")
	local build_cmd=$(get_conf "$deployfile" "build")

	if [ -n "$start_cmd" ] && [ ! -d "$container_root" ]; then
		echo "🏗️  First deploy detected - creating container..."
		command -v debootstrap &>/dev/null || { echo "📦 Installing debootstrap..."; apt-get update && apt-get install -y debootstrap; }
		debootstrap --variant=minbase stable "$container_root" http://deb.debian.org/debian
		systemd-machine-id-setup --root="$container_root"
		echo "✅ Container created: $container_root"
	fi

	if [ -n "$start_cmd" ] && [ -n "$build_cmd" ]; then
		echo "🔧 Running build..."
		systemd-nspawn --directory="$container_root" --bind="$release_dir":/build --chdir=/build bash -c "$build_cmd"
	fi

	cmd__sync "$app_name"
	cd "$app_dir/releases" && ls -t | tail -n +6 | xargs -r rm -rf
	echo "🧹 Cleaned up old releases"
}

cmd__sync() {
	require_arg "$1" "Internal error: app name required"
	local app_name=$1 app_dir="$DEPLOY_ROOT/apps/$app_name" deployfile="$app_dir/current/deployfile"
	local start_cmd=$(get_conf "$deployfile" "start")
	local is_static=false; [ -z "$start_cmd" ] && is_static=true
	validate_deployfile "$deployfile" "$app_name"
	local port=$(get_conf "$deployfile" "port" "7890")

	echo "🔄 Syncing configuration for $app_name..."
	echo "  📝 Generating Caddy config..."
	> "$app_dir/caddy.conf"
	local domains=()
	while IFS= read -r domain; do domains+=("$domain"); done < <(get_conf_all "$deployfile" "domain")
	for domain in "${domains[@]}"; do
		if $is_static; then
			cat >> "$app_dir/caddy.conf" <<-CADDY
			$domain {
			    root * $app_dir/current
			    file_server
			    try_files {path} /index.html
			    encode gzip
			}
			CADDY
		else
			echo "$domain { reverse_proxy http://deploy-$app_name.nspawn:$port }" >> "$app_dir/caddy.conf"
		fi
	done
	[ ${#domains[@]} -gt 0 ] && echo "    Configured ${#domains[@]} domain(s): ${domains[*]}" || echo "    No domains configured"

	if ! $is_static; then
		echo "  📝 Generating .nspawn config..."
		local nspawn_file="/etc/systemd/nspawn/deploy-$app_name.nspawn"
		cat > "$nspawn_file" <<-NSPAWN
		[Exec]
		Boot=no

		[Files]
		Bind=$app_dir/current:/app
		BindReadOnly=$app_dir/start.sh:/app/start.sh
		BindReadOnly=/etc/resolv.conf

		NSPAWN

		local bind_count=0
		while IFS= read -r bind; do
			local host_path container_path readonly=""
			if [[ "$bind" =~ ^([^:]+):([^:]+):ro$ ]]; then
				host_path="${BASH_REMATCH[1]}" container_path="${BASH_REMATCH[2]}" readonly="ReadOnly"
			elif [[ "$bind" =~ ^([^:]+):([^:]+)$ ]]; then
				host_path="${BASH_REMATCH[1]}" container_path="${BASH_REMATCH[2]}"
			else
				echo "⚠️  Skipping invalid bind: $bind"; continue
			fi
			[ ! -e "$host_path" ] && { echo "⚠️  Host path does not exist: $host_path (creating directory)"; mkdir -p "$host_path"; }
			echo "Bind${readonly}=$host_path:$container_path" >> "$nspawn_file"
			((bind_count++))
		done < <(get_conf_all "$deployfile" "bind")

		echo -e "\n[Network]\nZone=deploy" >> "$nspawn_file"
		[ $bind_count -gt 0 ] && echo "    Added $bind_count custom bind mount(s)"

		cat > "$app_dir/start.sh" <<-STARTSH
		#!/bin/bash
		export PORT=$port
		exec $start_cmd
		STARTSH
		chmod +x "$app_dir/start.sh"
	fi

	echo "  🔄 Reloading services..."
	[ ${#domains[@]} -gt 0 ] && caddy reload --config "$DEPLOY_ROOT/caddy/Caddyfile" 2>/dev/null || true
	if ! $is_static; then
		systemctl daemon-reload
		systemctl is-enabled "deploy@$app_name.service" &>/dev/null || systemctl enable "deploy@$app_name.service"
		systemctl restart "deploy@$app_name"
	fi
	echo "✅ Configuration synced"
}

cmd_help() {
	cat <<-HELP
	🚀 deploy.sh

	Usage:
	  deploy init                        Initialize the deployment system
	  deploy create <name>               Create a new app
	  deploy list                        List all apps
	  deploy logs <name> [options...]    Show app logs (journalctl wrapper)
	  deploy shell <name>                Shell into container
	  deploy restart <name>              Restart an app
	  deploy remove <name>               Remove an app
	  deploy help                        Show this help

	deployfile:
	  Add a "deployfile" to your repo root to configure your app.

	  # For containers
	  start=npm start                # required: the long-running process command
	  build=npm ci && npm run build  # optional: runs before each deploy
	  port=3000                      # optional: container port (default: 7890)

	  # For all apps (static sites and containers)
	  domain=example.com             # optional: domain routing (multi-value)
	  domain=www.example.com         # can specify multiple domains

	  # Bind mounts (containers only, Docker-style syntax)
	  bind=/data/uploads:/app/uploads          # read-write mount
	  bind=/etc/secrets:/app/secrets:ro        # read-only mount (:ro)

	  The "start" command receives PORT as an environment variable.
	  Containers are accessible at: deploy-<app-name>.nspawn:<port>

	  Changes to deployfile take effect on next "git push".
	HELP
}

case "${1:-help}" in
	init)            cmd_init ;;
	create)          shift; cmd_create "$@" ;;
	list)            cmd_list ;;
	logs)            shift; cmd_logs "$@" ;;
	shell)           shift; cmd_shell "$@" ;;
	restart)         shift; cmd_restart "$@" ;;
	remove)          shift; cmd_remove "$@" ;;
	_deploy-app)     shift; cmd__deploy-app "$@" ;;
	_sync)           shift; cmd__sync "$@" ;;
	help|--help|-h)  cmd_help ;;
	*)               echo "Unknown command: $1"; echo "Run \"deploy help\" for usage"; exit 1 ;;
esac
