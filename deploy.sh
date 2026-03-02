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

read_state() {
	local key=$1
	local default=$2
	local statefile="$DEPLOY_ROOT/state"

	if [ -f "$statefile" ]; then
		local value
		value=$(grep "^$key=" "$statefile" | cut -d= -f2-)
		if [ -n "$value" ]; then
			echo "$value"
			return
		fi
	fi

	echo "$default"
}

write_state() {
	local key=$1
	local value=$2
	local statefile="$DEPLOY_ROOT/state"

	if [ -f "$statefile" ] && grep -q "^$key=" "$statefile"; then
		sed -i "s/^$key=.*/$key=$value/" "$statefile"
	else
		echo "$key=$value" >> "$statefile"
	fi
}

check_domain_collision() {
	local domain=$1
	local exclude_app=${2:-}

	for deployfile in "$DEPLOY_ROOT"/apps/*/current/deployfile; do
		if [ ! -f "$deployfile" ]; then
			continue
		fi

		local app_name
		app_name=$(basename "$(dirname "$(dirname "$deployfile")")")

		# Skip the app we're configuring
		if [ "$app_name" = "$exclude_app" ]; then
			continue
		fi

		# Check all domains in this deployfile
		while IFS= read -r existing_domain; do
			if [ "$existing_domain" = "$domain" ]; then
				echo "❌ Domain $domain already used by $app_name"
				exit 1
			fi
		done < <(get_conf_all "$deployfile" "domain")
	done
}

# Get single value (last occurrence wins)
get_conf() {
	local file=$1 key=$2 default=${3:-}

	if [ ! -f "$file" ]; then
		echo "$default"
		return
	fi

	local value
	value=$(grep "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-)

	if [ -z "$value" ]; then
		echo "$default"
	else
		echo "$value"
	fi
}

# Get all values for a key (one per line)
get_conf_all() {
	local file=$1 key=$2

	if [ ! -f "$file" ]; then
		return
	fi

	grep "^${key}=" "$file" 2>/dev/null | cut -d= -f2-
}

# Validate deployfile has required fields
validate_deployfile() {
	local file=$1
	local app_name=$2

	if [ ! -f "$file" ]; then
		echo "❌ No deployfile found"
		exit 1
	fi

	# Check if at least one configuration exists (domain, start, etc.)
	local start_cmd=$(get_conf "$file" "start")
	local has_domains=$(get_conf_all "$file" "domain" | wc -l)

	if [ -z "$start_cmd" ] && [ "$has_domains" -eq 0 ]; then
		echo "❌ deployfile must have either 'start' (for containers) or 'domain' (for static sites)"
		exit 1
	fi

	# Validate bind mount syntax: /host:/container[:ro]
	while IFS= read -r bind; do
		if ! [[ "$bind" =~ ^/[^:]+:/[^:]+(:ro)?$ ]]; then
			echo "❌ Invalid bind mount syntax: $bind"
			echo "   Expected: bind=/host/path:/container/path[:ro]"
			exit 1
		fi
	done < <(get_conf_all "$file" "bind")

	# Validate domain uniqueness
	while IFS= read -r domain; do
		check_domain_collision "$domain" "$app_name"
	done < <(get_conf_all "$file" "domain")

	return 0
}

# ============================================================================
# SUBCOMMANDS
# ============================================================================

cmd_init() {
	echo "🚀 Setting up deploy.sh at $DEPLOY_ROOT..."

	# create deploy user
	if ! id "$DEPLOY_USER" &>/dev/null; then
		useradd -m -s /bin/bash "$DEPLOY_USER"
		echo "✅ Created user: $DEPLOY_USER"
	fi

	# set up SSH access for deploy user
	read -rp "🔑 Public key for SSH access (paste your ~/.ssh/id_*.pub): " public_key

	if [ -z "$public_key" ]; then
		echo "⚠️  No public key provided — add it manually to /home/$DEPLOY_USER/.ssh/authorized_keys"
	else
		mkdir -p "/home/$DEPLOY_USER/.ssh"
		echo "$public_key" >> "/home/$DEPLOY_USER/.ssh/authorized_keys"
		chown -R "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
		chmod 700 "/home/$DEPLOY_USER/.ssh"
		chmod 600 "/home/$DEPLOY_USER/.ssh/authorized_keys"
		echo "✅ Added public key for $DEPLOY_USER"
	fi

	# create directory structure
	mkdir -p "$DEPLOY_ROOT"/{apps,caddy}
	chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_ROOT"

	# configure nss-mymachines for container hostname resolution
	if ! grep -q "mymachines" /etc/nsswitch.conf 2>/dev/null; then
		echo "🔧 Configuring container hostname resolution..."

		# backup original
		cp /etc/nsswitch.conf /etc/nsswitch.conf.backup

		# add mymachines to hosts line
		sed -i 's/^hosts:.*/hosts: mymachines resolve [!UNAVAIL=return] files myhostname dns/' /etc/nsswitch.conf

		echo "✅ Configured /etc/nsswitch.conf for container resolution"
	fi

	# ensure systemd-machined is running
	systemctl enable systemd-machined 2>/dev/null || true

	# install caddy if needed
	if ! command -v caddy &> /dev/null; then
		echo "📦 Installing Caddy..."
		curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=amd64" -o /usr/local/bin/caddy
		chmod +x /usr/local/bin/caddy
	fi

	# create main caddyfile
	if [ ! -f "$DEPLOY_ROOT/caddy/Caddyfile" ]; then
		read -rp "📧 Email for Let's Encrypt certificates: " acme_email

		if [ -z "$acme_email" ]; then
			echo "❌ Email is required for HTTPS certificate provisioning"
			exit 1
		fi

		cat > "$DEPLOY_ROOT/caddy/Caddyfile" <<-CADDY
		{
		    email $acme_email
		}

		import /srv/deploy/apps/*/caddy.conf
		CADDY

		echo "📝 Created Caddyfile"
	fi

	# create caddy systemd service
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

	systemctl daemon-reload
	systemctl enable caddy
	systemctl start caddy

	# create deploy template service
	mkdir -p /etc/systemd/nspawn
	cat > /etc/systemd/system/deploy@.service <<-SERVICE
		[Unit]
		Description=%i container
		After=network.target

		[Service]
		Type=notify
		ExecStart=/usr/bin/systemd-nspawn \\
		    --quiet \\
		    --keep-unit \\
		    --settings=override \\
		    --machine=deploy-%i \\
		    --directory=$DEPLOY_ROOT/apps/%i/container

		Restart=always
		KillMode=mixed

		[Install]
		WantedBy=multi-user.target
		SERVICE

	echo "📝 Created deploy@.service template"

	echo
	echo "✅ System initialized!"
	echo "   Location: $DEPLOY_ROOT"
	echo
	echo "Next: deploy create <app-name>"
}

cmd_create() {
	if [ -z "$1" ]; then
		echo "Usage: deploy create <app-name>"
		exit 1
	fi

	local app_name=$1
	local app_dir="$DEPLOY_ROOT/apps/$app_name"

	# check for existing app with name
	if [ -d "$app_dir" ]; then
		echo "❌ App $app_name already exists"
		exit 1
	fi

	echo "📦 Creating app: $app_name"

	# create app structure
	mkdir -p "$app_dir"/{releases,repo.git}

	# initialize git repo
	cd "$app_dir/repo.git"
	git init --bare --initial-branch=main

	# create post-receive hook
	cat > hooks/post-receive <<-HOOK
		#!/bin/bash
		/usr/local/bin/deploy _deploy-app $app_name
		HOOK

	chmod +x hooks/post-receive

	# ensure deploy user owns the app directory
	chown -R "$DEPLOY_USER:$DEPLOY_USER" "$app_dir"

	echo "✅ Created app: $app_name"
	echo
	echo "Add a deployfile to your repo root:"
	echo
	echo "  For a container app:"
	echo "    start=npm start"
	echo "    build=npm ci && npm run build"
	echo "    port=3000"
	echo "    domain=yourdomain.com"
	echo "    bind=/data/uploads:/app/uploads"
	echo
	echo "  For a static site:"
	echo "    domain=yourdomain.com"
	echo
	echo "Next steps:"
	echo "  git remote add deploy $DEPLOY_USER@\$(hostname):$app_dir/repo.git"
	echo "  git push deploy main"
	echo
	echo "Container will be created automatically on first deploy if 'start=' is present."
}

cmd_list() {
	echo "📦 Deployed Apps:"
	echo

	if [ ! -d "$DEPLOY_ROOT/apps" ]; then
		echo "  (none)"
		return
	fi

	for app_dir in "$DEPLOY_ROOT"/apps/*; do
		if [ ! -d "$app_dir" ]; then
			continue
		fi

		local app_name=$(basename "$app_dir")

		echo "  $app_name"
		echo "    Location: $app_dir"

		# service status
		if systemctl list-unit-files | grep -q "^deploy@.service"; then
			local status
			status=$(systemctl is-active "deploy@$app_name" 2>/dev/null || true)
			echo "    Status: $status"
		fi

		# machine name
		if [ -d "$app_dir/container" ]; then
			echo "    Machine: deploy-$app_name.nspawn"
		fi

		# domains from deployfile
		if [ -f "$app_dir/current/deployfile" ]; then
			local domains=()
			while IFS= read -r domain; do
				domains+=("$domain")
			done < <(get_conf_all "$app_dir/current/deployfile" "domain")

			if [ ${#domains[@]} -gt 0 ]; then
				echo "    Domains: ${domains[*]}"
			fi

			# Show bind mount count
			local bind_count=$(get_conf_all "$app_dir/current/deployfile" "bind" | wc -l)
			if [ $bind_count -gt 0 ]; then
				echo "    Bind mounts: $bind_count"
			fi
		fi

		echo
	done
}

cmd_logs() {
	if [ -z "$1" ]; then
		echo "Usage: deploy logs <app-name> [journalctl-options...]"
		echo
		echo "Examples:"
		echo "  deploy logs myapi"
		echo "  deploy logs myapi -f"
		echo "  deploy logs myapi --since '1 hour ago'"
		exit 1
	fi

	local app_name=$1
	shift

	journalctl -u "deploy@$app_name" "$@"
}

cmd_restart() {
	if [ -z "$1" ]; then
		echo "Usage: deploy restart <app-name>"
		exit 1
	fi

	local app_name=$1

	echo "🔄 Restarting $app_name..."
	systemctl restart "deploy@$app_name"
	echo "✅ Restarted"
}

cmd_remove() {
	if [ -z "$1" ]; then
		echo "Usage: deploy remove <app-name>"
		exit 1
	fi

	local app_name=$1
	local app_dir="$DEPLOY_ROOT/apps/$app_name"

	if [ ! -d "$app_dir" ]; then
		echo "❌ App $app_name does not exist"
		exit 1
	fi

	echo "🗑️  Removing app: $app_name"

	# stop service
	if systemctl is-active --quiet "deploy@$app_name" 2>/dev/null; then
		echo "  Stopping service..."
		systemctl stop "deploy@$app_name"
	fi

	if systemctl is-enabled --quiet "deploy@$app_name" 2>/dev/null; then
		systemctl disable "deploy@$app_name"
	fi

	# remove .nspawn configuration file
	if [ -f "/etc/systemd/nspawn/deploy-$app_name.nspawn" ]; then
		rm "/etc/systemd/nspawn/deploy-$app_name.nspawn"
		systemctl daemon-reload
	fi

	# remove from Caddy
	if [ -f "$app_dir/caddy.conf" ]; then
		echo "  Removing from Caddy..."
		caddy reload --config "$DEPLOY_ROOT/caddy/Caddyfile" 2>/dev/null || true
	fi

	# remove app directory
	echo "  Removing app files..."
	rm -rf "$app_dir"

	echo "✅ Removed $app_name"
}

cmd_shell() {
	if [ -z "$1" ]; then
		echo "Usage: deploy shell <app-name>"
		exit 1
	fi

	local app_name=$1
	local container_root="$DEPLOY_ROOT/apps/$app_name/container"

	if [ ! -d "$container_root" ]; then
		echo "❌ Container for $app_name does not exist"
		exit 1
	fi

	echo "🐚 Entering container for $app_name..."
	systemd-nspawn --directory="$container_root"
}

# internal command called by git hook
cmd__deploy-app() {
	if [ -z "$1" ]; then
		echo "Internal error: app name required"
		exit 1
	fi

	local app_name=$1
	local app_dir="$DEPLOY_ROOT/apps/$app_name"
	local release_dir="$app_dir/releases/$(date +%Y%m%d-%H%M%S)"
	local current_link="$app_dir/current"
	local container_root="$app_dir/container"

	echo "📦 Deploying $app_name..."

	# extract code to new release
	mkdir -p "$release_dir"
	local repo_dir
	repo_dir=$(pwd)
	unset GIT_DIR  # git sets this in the hook environment; clear it to avoid conflicts
	git --work-tree="$release_dir" --git-dir="$repo_dir" checkout HEAD -f

	cd "$release_dir"

	# Atomic swap (do this BEFORE sync so deployfile is readable)
	ln -sfn "$release_dir" "$current_link"
	echo "✅ Deployed to $current_link"

	# Detect if container and run build if needed
	local deployfile="$release_dir/deployfile"
	local start_cmd=$(get_conf "$deployfile" "start")
	local build_cmd=$(get_conf "$deployfile" "build")

	# Create container on first deploy if this is a container app
	if [ -n "$start_cmd" ] && [ ! -d "$container_root" ]; then
		echo "🏗️  First deploy detected - creating container..."

		# install debootstrap if needed
		if ! command -v debootstrap &> /dev/null; then
			echo "📦 Installing debootstrap..."
			apt-get update && apt-get install -y debootstrap
		fi

		# create minimal debian container
		debootstrap --variant=minbase stable "$container_root" http://deb.debian.org/debian

		# setup machine ID
		systemd-machine-id-setup --root="$container_root"

		echo "✅ Container created: $container_root"
	fi

	# Only run build if this is a container (has start command) and has build command
	if [ -n "$start_cmd" ] && [ -n "$build_cmd" ]; then
		echo "🔧 Running build..."
		systemd-nspawn --directory="$container_root" \
			--bind="$release_dir":/build \
			--chdir=/build \
			bash -c "$build_cmd"
	fi

	# Sync derived configs and restart services
	cmd__sync "$app_name"

	# cleanup old releases (keep last 5)
	cd "$app_dir/releases"
	ls -t | tail -n +6 | xargs -r rm -rf
	echo "🧹 Cleaned up old releases"
}

# Internal command to sync derived files from deployfile
cmd__sync() {
	if [ -z "$1" ]; then
		echo "Internal error: app name required"
		exit 1
	fi

	local app_name=$1
	local app_dir="$DEPLOY_ROOT/apps/$app_name"
	local deployfile="$app_dir/current/deployfile"

	# Detect if static site (no start command)
	local start_cmd=$(get_conf "$deployfile" "start")
	local is_static="false"

	if [ -z "$start_cmd" ]; then
		is_static="true"
	fi

	# Validate deployfile
	validate_deployfile "$deployfile" "$app_name"

	# Read configuration
	local port=$(get_conf "$deployfile" "port" "7890")
	local build_cmd=$(get_conf "$deployfile" "build")

	echo "🔄 Syncing configuration for $app_name..."

	# ========================================
	# Generate Caddy configuration
	# ========================================

	echo "  📝 Generating Caddy config..."

	# Clear existing caddy.conf
	> "$app_dir/caddy.conf"

	# Get all domains
	local domains=()
	while IFS= read -r domain; do
		domains+=("$domain")
	done < <(get_conf_all "$deployfile" "domain")

	# Generate config for each domain
	if [ ${#domains[@]} -gt 0 ]; then
		for domain in "${domains[@]}"; do
			if [ "$is_static" = "true" ]; then
				# Static site config
				cat >> "$app_dir/caddy.conf" <<-CADDY
				$domain {
				    root * $app_dir/current
				    file_server
				    try_files {path} /index.html
				    encode gzip
				}
				CADDY
			else
				# Container reverse proxy
				cat >> "$app_dir/caddy.conf" <<-CADDY
				$domain {
				    reverse_proxy http://deploy-$app_name.nspawn:$port
				}
				CADDY
			fi
		done

		echo "    Configured ${#domains[@]} domain(s): ${domains[*]}"
	else
		echo "    No domains configured"
	fi

	# ========================================
	# Generate .nspawn configuration
	# ========================================

	if [ "$is_static" = "false" ]; then
		echo "  📝 Generating .nspawn config..."

		local nspawn_file="/etc/systemd/nspawn/deploy-$app_name.nspawn"
		local container_root="$app_dir/container"

		cat > "$nspawn_file" <<-NSPAWN
		[Exec]
		Boot=no

		[Files]
		# Default binds
		Bind=$app_dir/current:/app
		BindReadOnly=$app_dir/start.sh:/app/start.sh
		BindReadOnly=/etc/resolv.conf

		NSPAWN

		# Add custom bind mounts
		local bind_count=0
		while IFS= read -r bind; do
			# Parse bind syntax: /host:/container[:ro]
			local host_path container_path readonly=""

			if [[ "$bind" =~ ^([^:]+):([^:]+):ro$ ]]; then
				host_path="${BASH_REMATCH[1]}"
				container_path="${BASH_REMATCH[2]}"
				readonly="ReadOnly"
			elif [[ "$bind" =~ ^([^:]+):([^:]+)$ ]]; then
				host_path="${BASH_REMATCH[1]}"
				container_path="${BASH_REMATCH[2]}"
			else
				echo "⚠️  Skipping invalid bind: $bind"
				continue
			fi

			# Ensure host path exists
			if [ ! -e "$host_path" ]; then
				echo "⚠️  Host path does not exist: $host_path (creating directory)"
				mkdir -p "$host_path"
			fi

			# Write to nspawn file
			if [ -n "$readonly" ]; then
				echo "Bind${readonly}=$host_path:$container_path" >> "$nspawn_file"
			else
				echo "Bind=$host_path:$container_path" >> "$nspawn_file"
			fi

			((bind_count++))
		done < <(get_conf_all "$deployfile" "bind")

		# Add network zone
		cat >> "$nspawn_file" <<-NSPAWN

		[Network]
		Zone=deploy
		NSPAWN

		if [ $bind_count -gt 0 ]; then
			echo "    Added $bind_count custom bind mount(s)"
		fi

		# Generate start.sh wrapper
		cat > "$app_dir/start.sh" <<-STARTSH
		#!/bin/bash
		export PORT=$port
		exec $start_cmd
		STARTSH
		chmod +x "$app_dir/start.sh"
	fi

	# ========================================
	# Reload services
	# ========================================

	echo "  🔄 Reloading services..."

	# Reload Caddy if domains configured
	if [ ${#domains[@]} -gt 0 ]; then
		caddy reload --config "$DEPLOY_ROOT/caddy/Caddyfile" 2>/dev/null || true
	fi

	# Reload systemd and restart container
	if [ "$is_static" = "false" ]; then
		systemctl daemon-reload

		# Enable service if not already enabled
		if ! systemctl is-enabled "deploy@$app_name.service" &>/dev/null; then
			systemctl enable "deploy@$app_name.service"
		fi

		# Restart service
		systemctl restart "deploy@$app_name"
	fi

	echo "✅ Configuration synced"
}

# ============================================================================
# MAIN
# ============================================================================

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

# route to subcommands
case "${1:-help}" in
	init)       cmd_init ;;
	create)     shift; cmd_create "$@" ;;
	list)       cmd_list ;;
	logs)       shift; cmd_logs "$@" ;;
	shell)      shift; cmd_shell "$@" ;;
	restart)    shift; cmd_restart "$@" ;;
	remove)     shift; cmd_remove "$@" ;;
	_deploy-app) shift; cmd__deploy-app "$@" ;;  # internal
	_sync)      shift; cmd__sync "$@" ;;          # internal
	help|--help|-h) cmd_help ;;
	*)
		echo "Unknown command: $1"
		echo "Run \"deploy help\" for usage"
		exit 1
		;;
esac
