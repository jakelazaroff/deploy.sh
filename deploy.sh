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

DEPLOY_ROOT=/srv/deploy
DEPLOY_USER=deploy

# UTILITIES

# Require an argument or exit with usage message
require_arg() {
	local arg=$1 usage=$2
	if [ -z "$arg" ]; then echo "$usage"; exit 1; fi
}

check_domain_collision() {
	local domain=$1 exclude_app=${2:-}

	for deployfile in "$DEPLOY_ROOT"/apps/*/current/deploy.conf; do
		if [ ! -f "$deployfile" ]; then continue; fi
		local app_name=$(basename "$(dirname "$(dirname "$deployfile")")")
		if [ "$app_name" = "$exclude_app" ]; then continue; fi

		while IFS= read -r existing_domain; do
			if [ "$existing_domain" = "$domain" ]; then echo "❌ Domain $domain already used by $app_name"; exit 1; fi
		done < <(get_conf_all "$deployfile" "domain")
	done
}

get_conf() {
	local file=$1 key=$2 default=${3:-}
	if [ ! -f "$file" ]; then echo "$default"; return; fi
	local value=$(grep "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-)
	echo "${value:-$default}"
}

get_conf_all() {
	local file=$1 key=$2
	if [ -f "$file" ]; then grep "^${key}=" "$file" 2>/dev/null | cut -d= -f2-; fi
}

validate_deployconf() {
	local file=$1 app_name=$2
	if [ ! -f "$file" ]; then echo "❌ No deploy.conf found"; exit 1; fi

	local start_cmd=$(get_conf "$file" "start")
	local has_domains=$(get_conf_all "$file" "domain" | wc -l)
	if [ -z "$start_cmd" ] && [ "$has_domains" -eq 0 ]; then echo "❌ deploy.conf must have either 'start' (for containers) or 'domain' (for static sites)"; exit 1; fi

	while IFS= read -r domain; do
		check_domain_collision "$domain" "$app_name"
	done < <(get_conf_all "$file" "domain")
}

# SUBCOMMANDS

cmd_init() {
	if [ "$(id -u)" -ne 0 ]; then echo "❌ deploy init must be run as root"; exit 1; fi
	echo "🚀 Setting up deploy.sh at $DEPLOY_ROOT..."

	if ! command -v systemd-nspawn &>/dev/null; then
		echo "📦 Installing systemd-container..."
		if command -v apt-get &>/dev/null; then
			apt-get install -y systemd-container
		elif command -v dnf &>/dev/null; then
			dnf install -y systemd-container
		else
			echo "❌ systemd-nspawn not found — install systemd-container manually"; exit 1
		fi
	fi

	id "$DEPLOY_USER" &>/dev/null || { useradd -m -s /bin/bash "$DEPLOY_USER"; echo "✅ Created user: $DEPLOY_USER"; }

	local src_keys=""
	if [ -n "$SUDO_USER" ]; then
		local src_home; src_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
		if [ -f "$src_home/.ssh/authorized_keys" ]; then src_keys="$src_home/.ssh/authorized_keys"; fi
	fi
	if [ -z "$src_keys" ] && [ -f /root/.ssh/authorized_keys ]; then src_keys=/root/.ssh/authorized_keys; fi

	if [ -n "$src_keys" ]; then
		mkdir -p "/home/$DEPLOY_USER/.ssh"
		cp "$src_keys" "/home/$DEPLOY_USER/.ssh/authorized_keys"
		chown -R "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
		chmod 700 "/home/$DEPLOY_USER/.ssh" && chmod 600 "/home/$DEPLOY_USER/.ssh/authorized_keys"
		echo "✅ Copied SSH authorized_keys from $src_keys"
	else
		echo "⚠️  No authorized_keys found — add your public key manually to /home/$DEPLOY_USER/.ssh/authorized_keys"
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

	if [ ! -d /var/lib/machines/deploy-base ]; then
		echo "📦 Pulling Alpine base image..."
		local arch; arch=$(uname -m)
		local alpine_file; alpine_file=$(curl -fsSL "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$arch/latest-releases.yaml" | grep -oE "alpine-minirootfs-[0-9]+\.[0-9]+\.[0-9]+-${arch}\.tar\.gz" | head -1)
		if [ -z "$alpine_file" ]; then echo "❌ Could not find Alpine minirootfs for $arch"; exit 1; fi
		machinectl pull-tar --verify=no "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$arch/$alpine_file" deploy-base
		echo "🔧 Installing bash in base image..."
		systemd-nspawn --machine=deploy-base /bin/sh -c "apk update && apk add --no-cache bash"
		echo "✅ Base image ready"
	fi

	command -v caddy &>/dev/null || { echo "📦 Installing Caddy..."; curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=amd64" -o /usr/local/bin/caddy; chmod +x /usr/local/bin/caddy; }

	if [ ! -f "$DEPLOY_ROOT/caddy/Caddyfile" ]; then
		read -rp "📧 Email for Let's Encrypt certificates: " acme_email
		if [ -z "$acme_email" ]; then echo "❌ Email is required for HTTPS certificate provisioning"; exit 1; fi
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
	ExecStart=/usr/bin/systemd-nspawn --quiet --keep-unit --settings=override --machine=deploy-%i
	Restart=always
	KillMode=mixed

	[Install]
	WantedBy=multi-user.target
	SERVICE
	echo "📝 Created deploy@.service template"

	cat > /etc/sudoers.d/deploy <<-SUDOERS
	$DEPLOY_USER ALL=(root) NOPASSWD: /usr/local/bin/deploy *
	ALL ALL=(deploy) NOPASSWD: /usr/local/bin/deploy *
	SUDOERS
	chmod 0440 /etc/sudoers.d/deploy
	echo "📝 Created /etc/sudoers.d/deploy"

	echo -e "\n✅ System initialized!\n   Location: $DEPLOY_ROOT\n\nNext: deploy create <app-name>"
}

cmd_create() {
	require_arg "$1" "Usage: deploy create <app-name>"
	local app_name=$1; local app_dir="$DEPLOY_ROOT/apps/$app_name"
	if [ -d "$app_dir" ]; then echo "❌ App $app_name already exists"; exit 1; fi

	echo "📦 Creating app: $app_name"
	mkdir -p "$app_dir"/{releases,repo.git}
	cd "$app_dir/repo.git" && git init --bare --initial-branch=main

	cat > hooks/post-receive <<-HOOK
	#!/bin/bash
	sudo /usr/local/bin/deploy _deploy-app $app_name
	HOOK
	chmod +x hooks/post-receive
	chown -R "$DEPLOY_USER:$DEPLOY_USER" "$app_dir"

	cat <<-MSG
	✅ Created app: $app_name

	Add a deploy.conf to your repo root:

	  For a container app:
	    start=npm start
	    build=npm ci && npm run build
	    port=3000
	    domain=yourdomain.com
	    assets=public

	  For a static site:
	    domain=yourdomain.com
	    build=npm ci && npm run build
	    assets=dist
	    spa=true

	Next steps:
	  git remote add deploy $DEPLOY_USER@\$(hostname):$app_dir/repo.git
	  git push deploy main

	To configure mounts or environment variables, create $app_dir/server.conf on the server:
	  mount=/data/uploads:/app/uploads    # read-write mount
	  mount=/etc/secrets:/app/secrets:ro  # read-only mount (:ro)
	  env=SECRET_KEY=...                  # environment variable (passed to container and build)
	MSG
}

cmd_list() {
	echo -e "📦 Deployed Apps:\n"
	if [ ! -d "$DEPLOY_ROOT/apps" ]; then echo "  (none)"; return; fi

	for app_dir in "$DEPLOY_ROOT"/apps/*; do
		if [ ! -d "$app_dir" ]; then continue; fi
		local app_name=$(basename "$app_dir")
		echo "  $app_name"
		echo "    Location: $app_dir"
		if systemctl list-unit-files | grep -q "^deploy@.service"; then echo "    Status: $(systemctl is-active "deploy@$app_name" 2>/dev/null || true)"; fi
		if [ -d "$app_dir/container" ]; then echo "    Machine: deploy-$app_name.nspawn"; fi
		if [ -f "$app_dir/current/deploy.conf" ]; then
			local domains=$(get_conf_all "$app_dir/current/deploy.conf" "domain" | tr '\n' ' ')
			if [ -n "$domains" ]; then echo "    Domains: $domains"; fi
		fi
		local mount_count=$(get_conf_all "$app_dir/server.conf" "mount" | wc -l)
		if [ "$mount_count" -gt 0 ]; then echo "    Mounts: $mount_count"; fi
		echo
	done
}

cmd_logs() {
	require_arg "$1" "Usage: deploy logs <app-name> [journalctl-options...]

Examples:
  deploy logs myapi
  deploy logs myapi -f
  deploy logs myapi --since '1 hour ago'"
	sudo "$0" _logs "$@"
}

cmd__logs() {
	require_arg "$1" "Internal error: app name required"
	local app_name=$1; shift
	journalctl -u "deploy@$app_name" "$@"
}

cmd_restart() {
	require_arg "$1" "Usage: deploy restart <app-name>"
	sudo "$0" _restart "$1"
}

cmd__restart() {
	require_arg "$1" "Internal error: app name required"
	echo "🔄 Restarting $1..."
	systemctl restart "deploy@$1"
	echo "✅ Restarted"
}

cmd_remove() {
	require_arg "$1" "Usage: deploy remove <app-name>"
	local app_name=$1; local app_dir="$DEPLOY_ROOT/apps/$app_name"
	if [ ! -d "$app_dir" ]; then echo "❌ App $app_name does not exist"; exit 1; fi
	sudo "$0" _remove "$app_name"
}

cmd__remove() {
	require_arg "$1" "Internal error: app name required"
	local app_name=$1; local app_dir="$DEPLOY_ROOT/apps/$app_name"
	echo "🗑️  Removing app: $app_name"
	if systemctl is-active --quiet "deploy@$app_name" 2>/dev/null; then echo "  Stopping service..."; systemctl stop "deploy@$app_name"; fi
	if systemctl is-enabled --quiet "deploy@$app_name" 2>/dev/null; then systemctl disable "deploy@$app_name"; fi
	if [ -f "/etc/systemd/nspawn/deploy-$app_name.nspawn" ]; then rm "/etc/systemd/nspawn/deploy-$app_name.nspawn"; systemctl daemon-reload; fi
	if [ -d "/var/lib/machines/deploy-$app_name" ]; then echo "  Removing container image..."; machinectl remove "deploy-$app_name"; fi
	if [ -f "$app_dir/caddy.conf" ]; then echo "  Removing from Caddy..."; caddy reload --config "$DEPLOY_ROOT/caddy/Caddyfile" 2>/dev/null || true; fi
	echo "  Removing app files..." && rm -rf "$app_dir"
	echo "✅ Removed $app_name"
}

cmd_shell() {
	require_arg "$1" "Usage: deploy shell <app-name>"
	if [ ! -d "/var/lib/machines/deploy-$1" ]; then echo "❌ Container for $1 does not exist"; exit 1; fi
	sudo "$0" _shell "$1"
}

cmd__shell() {
	require_arg "$1" "Internal error: app name required"
	echo "🐚 Entering container for $1..."
	systemd-nspawn --machine="deploy-$1"
}

cmd__deploy-app() {
	require_arg "$1" "Internal error: app name required"
	local app_name=$1; local app_dir="$DEPLOY_ROOT/apps/$app_name"
	local release_dir="$app_dir/releases/$(date +%Y%m%d-%H%M%S)"
	local current_link="$app_dir/current"

	echo "📦 Deploying $app_name..."
	mkdir -p "$release_dir"
	local repo_dir=$(pwd)
	unset GIT_DIR
	git --work-tree="$release_dir" --git-dir="$repo_dir" checkout HEAD -f
	cd "$release_dir"
	ln -sfn "$release_dir" "$current_link"
	echo "✅ Deployed to $current_link"

	local deployfile="$release_dir/deploy.conf"
	local start_cmd=$(get_conf "$deployfile" "start")
	local build_cmd=$(get_conf "$deployfile" "build")

	if [ -n "$start_cmd" ] && [ ! -d "/var/lib/machines/deploy-$app_name" ]; then
		echo "🏗️  First deploy detected - cloning base image..."
		machinectl clone deploy-base "deploy-$app_name"
		rm -f "/var/lib/machines/deploy-$app_name/etc/machine-id"
		systemd-machine-id-setup --root="/var/lib/machines/deploy-$app_name"
		echo "✅ Container created"
	fi

	local app_conf="$app_dir/server.conf"
	local setenv_args=()
	while IFS= read -r env_var; do
		setenv_args+=(--setenv="$env_var")
	done < <(get_conf_all "$app_conf" "env")

	if [ -n "$start_cmd" ] && [ -n "$build_cmd" ]; then
		echo "🔧 Running build..."
		systemd-nspawn --machine="deploy-$app_name" "${setenv_args[@]}" --bind="$release_dir":/build --chdir=/build bash -c "$build_cmd"
	elif [ -z "$start_cmd" ] && [ -n "$build_cmd" ]; then
		echo "🔧 Running static site build in ephemeral container..."
		local build_machine="deploy-${app_name}-build"
		machinectl clone deploy-base "$build_machine"
		systemd-nspawn --machine="$build_machine" "${setenv_args[@]}" --bind="$release_dir":/build --chdir=/build bash -c "$build_cmd"
		machinectl remove "$build_machine"
		echo "✅ Build complete"
	fi

	cmd__sync "$app_name"
	cd "$app_dir/releases" && ls -t | tail -n +6 | xargs -r rm -rf
	echo "🧹 Cleaned up old releases"
}

cmd__sync() {
	require_arg "$1" "Internal error: app name required"
	local app_name=$1; local app_dir="$DEPLOY_ROOT/apps/$app_name"
	local deployfile="$app_dir/current/deploy.conf" app_conf="$app_dir/server.conf"
	local start_cmd=$(get_conf "$deployfile" "start")
	local is_static=false; if [ -z "$start_cmd" ]; then is_static=true; fi
	validate_deployconf "$deployfile" "$app_name"
	local port=$(get_conf "$deployfile" "port" "7890")

	echo "🔄 Syncing configuration for $app_name..."
	echo "  📝 Generating Caddy config..."
	> "$app_dir/caddy.conf"
	local domains=()
	while IFS= read -r domain; do domains+=("$domain"); done < <(get_conf_all "$deployfile" "domain")
	local static_dir=$(get_conf "$deployfile" "assets")
	local spa_mode=$(get_conf "$deployfile" "spa")

	for domain in "${domains[@]}"; do
		if $is_static; then
			local root_path="$app_dir/current"
			if [ -n "$static_dir" ]; then root_path="$app_dir/current/$static_dir"; fi

			if [ "$spa_mode" = "true" ]; then
				cat >> "$app_dir/caddy.conf" <<-CADDY
				$domain {
				    root * $root_path
				    try_files {path} /index.html
				    file_server
				    encode gzip
				}
				CADDY
			else
				cat >> "$app_dir/caddy.conf" <<-CADDY
				$domain {
				    root * $root_path
				    file_server
				    encode gzip
				}
				CADDY
			fi
		else
			if [ -n "$static_dir" ]; then
				cat >> "$app_dir/caddy.conf" <<-CADDY
				$domain {
				    root * $app_dir/current/$static_dir

				    @static file
				    handle @static {
				        file_server
				        encode gzip
				    }

				    handle {
				        reverse_proxy http://deploy-$app_name.nspawn:$port
				    }
				}
				CADDY
			else
				echo "$domain { reverse_proxy http://deploy-$app_name.nspawn:$port }" >> "$app_dir/caddy.conf"
			fi
		fi
	done
	[ ${#domains[@]} -gt 0 ] && echo "    Configured ${#domains[@]} domain(s): ${domains[*]}" || echo "    No domains configured"
	if [ -n "$static_dir" ]; then echo "    Assets directory: $static_dir"; fi
	if [ "$spa_mode" = "true" ]; then echo "    SPA mode: enabled"; fi

	if ! $is_static; then
		echo "  📝 Generating .nspawn config..."
		local nspawn_file="/etc/systemd/nspawn/deploy-$app_name.nspawn"
		printf '[Exec]\nBoot=no\n' > "$nspawn_file"

		local env_count=0
		while IFS= read -r env_var; do
			echo "Environment=\"$env_var\"" >> "$nspawn_file"
			((env_count++))
		done < <(get_conf_all "$app_conf" "env")

		cat >> "$nspawn_file" <<-NSPAWN

		[Files]
		Bind=$app_dir/current:/app
		BindReadOnly=$app_dir/start.sh:/app/start.sh
		BindReadOnly=/etc/resolv.conf

		NSPAWN

		local mount_count=0
		while IFS= read -r mount; do
			local host_path container_path readonly=""
			if [[ "$mount" =~ ^([^:]+):([^:]+):ro$ ]]; then
				host_path="${BASH_REMATCH[1]}" container_path="${BASH_REMATCH[2]}" readonly="ReadOnly"
			elif [[ "$mount" =~ ^([^:]+):([^:]+)$ ]]; then
				host_path="${BASH_REMATCH[1]}" container_path="${BASH_REMATCH[2]}"
			else
				echo "⚠️  Skipping invalid mount: $mount"; continue
			fi
			if [ ! -e "$host_path" ]; then echo "⚠️  Host path does not exist: $host_path (creating directory)"; mkdir -p "$host_path"; fi
			echo "Bind${readonly}=$host_path:$container_path" >> "$nspawn_file"
			((mount_count++))
		done < <(get_conf_all "$app_conf" "mount")

		echo -e "\n[Network]\nZone=deploy" >> "$nspawn_file"
		if [ "$mount_count" -gt 0 ]; then echo "    Added $mount_count custom mount(s)"; fi
		if [ "$env_count" -gt 0 ]; then echo "    Added $env_count environment variable(s)"; fi

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

cmd_uninstall() {
	if [ "$(id -u)" -ne 0 ]; then echo "❌ deploy uninstall must be run as root"; exit 1; fi
	echo "⚠️  This will remove all deploy.sh system changes, including all apps and containers."
	read -rp "Type 'yes' to confirm: " confirm
	if [ "$confirm" != "yes" ]; then echo "Aborted."; exit 1; fi

	echo "🗑️  Uninstalling deploy.sh..."

	for app_dir in "$DEPLOY_ROOT"/apps/*/; do
		if [ ! -d "$app_dir" ]; then continue; fi
		local app_name=$(basename "$app_dir")
		if systemctl is-active --quiet "deploy@$app_name" 2>/dev/null; then echo "  Stopping deploy@$app_name..."; systemctl stop "deploy@$app_name"; fi
		if systemctl is-enabled --quiet "deploy@$app_name" 2>/dev/null; then systemctl disable "deploy@$app_name"; fi
		if [ -d "/var/lib/machines/deploy-$app_name" ]; then rm -rf "/var/lib/machines/deploy-$app_name"; fi
	done
	rm -f /etc/systemd/nspawn/deploy-*.nspawn

	if [ -d /var/lib/machines/deploy-base ]; then rm -rf /var/lib/machines/deploy-base; fi

	if systemctl is-active --quiet caddy 2>/dev/null; then echo "  Stopping caddy..."; systemctl stop caddy; fi
	if systemctl is-enabled --quiet caddy 2>/dev/null; then systemctl disable caddy; fi
	rm -f /etc/systemd/system/caddy.service /usr/local/bin/caddy

	rm -f /etc/systemd/system/deploy@.service
	rm -f /etc/sudoers.d/deploy
	systemctl daemon-reload

	if [ -f /etc/nsswitch.conf.backup ]; then
		mv /etc/nsswitch.conf.backup /etc/nsswitch.conf
		echo "  Restored /etc/nsswitch.conf"
	fi

	rm -rf "$DEPLOY_ROOT"
	if id "$DEPLOY_USER" &>/dev/null; then userdel -r "$DEPLOY_USER"; fi

	echo "✅ Uninstalled"
}

cmd_help() {
	cat <<-HELP
	🚀 deploy.sh

	Usage:
	  deploy init                        Initialize the deployment system
	  deploy create <name>               Create a new app
	  deploy list                        List all apps
	  deploy logs <name> [options...]    Show app logs
	  deploy shell <name>                Shell into container
	  deploy restart <name>              Restart an app
	  deploy remove <name>               Remove an app
	  deploy uninstall                   Remove all deploy.sh system changes
	  deploy help                        Show this help
	HELP
}

case "${1:-}" in
	init|uninstall|_*|help|--help|-h|"") ;;
	*)
		if [ "$(id -un)" != "$DEPLOY_USER" ] && [ "$(id -u)" -ne 0 ]; then
			exec sudo -u "$DEPLOY_USER" "$0" "$@"
		fi
		;;
esac

case "${1:-help}" in
	init)            cmd_init ;;
	create)          shift; cmd_create "$@" ;;
	list)            cmd_list ;;
	logs)            shift; cmd_logs "$@" ;;
	shell)           shift; cmd_shell "$@" ;;
	restart)         shift; cmd_restart "$@" ;;
	remove)          shift; cmd_remove "$@" ;;
	uninstall)       cmd_uninstall ;;
	_deploy-app)     shift; cmd__deploy-app "$@" ;;
	_sync)           shift; cmd__sync "$@" ;;
	_logs)           shift; cmd__logs "$@" ;;
	_restart)        shift; cmd__restart "$@" ;;
	_remove)         shift; cmd__remove "$@" ;;
	_shell)          shift; cmd__shell "$@" ;;
	help|--help|-h)  cmd_help ;;
	*)               echo "Unknown command: $1"; echo "Run \"deploy help\" for usage"; exit 1 ;;
esac
