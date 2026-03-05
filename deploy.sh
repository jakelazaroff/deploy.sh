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

require_root() { if [ "$(id -u)" -ne 0 ]; then exec sudo "$0" "$@"; fi; }

check_domain_collision() {
	local domain=$1 exclude_app=${2:-}

	local deployfile
	for deployfile in "$DEPLOY_ROOT"/*/current/deploy.conf; do
		if [ ! -f "$deployfile" ]; then continue; fi
		local app_name=$(basename "$(dirname "$(dirname "$deployfile")")")
		if [ "$app_name" = "$exclude_app" ]; then continue; fi

		while IFS= read -r existing_domain; do
			if [ "$existing_domain" = "$domain" ]; then echo "⚠️ Domain $domain already used by $app_name"; exit 1; fi
		done < <(get_conf_all "$deployfile" "domain")
	done
}

# get a value matching a given key from a config file, falling back to default
get_conf() {
	local file=$1 key=$2 default=${3:-}
	if [ ! -f "$file" ]; then echo "$default"; return; fi
	local value=$(grep "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-)
	echo "${value:-$default}"
}

# get all values matching a given key from a config file
get_conf_all() {
	local file=$1 key=$2
	if [ -f "$file" ]; then grep "^${key}=" "$file" 2>/dev/null | cut -d= -f2-; fi
}

assign_port() {
	local app_name=$1
	local ports_file="$DEPLOY_ROOT/.internal/ports"
	local existing; existing=$(grep "^$app_name=" "$ports_file" 2>/dev/null | cut -d= -f2)
	if [ -n "$existing" ]; then echo "$existing"; return; fi
	local port=49152
	while grep -q "=$port$" "$ports_file" 2>/dev/null; do ((port++)); done
	echo "$app_name=$port" >> "$ports_file"
	echo "$port"
}

validate_deployconf() {
	local file=$1 app_name=$2
	if [ ! -f "$file" ]; then return 0; fi

	while IFS= read -r domain; do
		check_domain_collision "$domain" "$app_name"
	done < <(get_conf_all "$file" "domain")
}

# SUBCOMMANDS

cmd_init() {
	if [ "$(id -u)" -ne 0 ]; then echo "⚠️ deploy init must be run as root"; exit 1; fi
	echo "🚀 Setting up deploy.sh at $DEPLOY_ROOT..."

	if ! command -v systemd-nspawn &>/dev/null; then
		echo "📦 Installing systemd-container..."
		if command -v apt-get &>/dev/null; then
			apt-get install -y systemd-container
		elif command -v dnf &>/dev/null; then
			dnf install -y systemd-container
		else
			echo "⚠️ systemd-nspawn not found — install systemd-container manually"; exit 1
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

	mkdir -p "$DEPLOY_ROOT/.internal"
	chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_ROOT"


	if [ ! -d "$DEPLOY_ROOT/.internal/machine" ]; then
		echo "📦 Pulling Alpine base image..."
		local arch; arch=$(uname -m)
		local alpine_file; alpine_file=$(curl -fsSL "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$arch/latest-releases.yaml" | grep -oE "alpine-minirootfs-[0-9]+\.[0-9]+\.[0-9]+-${arch}\.tar\.gz" | head -1)
		if [ -z "$alpine_file" ]; then echo "⚠️ Could not find Alpine minirootfs for $arch"; exit 1; fi
		mkdir -p "$DEPLOY_ROOT/.internal/machine"
		curl -fsSL "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$arch/$alpine_file" | tar -xz -C "$DEPLOY_ROOT/.internal/machine"
		echo "🔧 Installing bash in base image..."
		systemd-nspawn -D "$DEPLOY_ROOT/.internal/machine" /bin/sh -c "apk update && apk add --no-cache bash"
		echo "✅ Base image ready"
	fi

	command -v caddy &>/dev/null || { echo "📦 Installing Caddy..."; curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=amd64" -o /usr/local/bin/caddy; chmod +x /usr/local/bin/caddy; }

	if [ ! -f "$DEPLOY_ROOT/.internal/Caddyfile" ]; then
		read -rp "📧 Email for Let's Encrypt certificates: " acme_email
		if [ -z "$acme_email" ]; then echo "⚠️ Email is required for HTTPS certificate provisioning"; exit 1; fi
		cat > "$DEPLOY_ROOT/.internal/Caddyfile" <<-CADDY
		{
		    email $acme_email
		}

		import $DEPLOY_ROOT/*/caddy.conf
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
	ExecStart=/usr/local/bin/caddy run --config $DEPLOY_ROOT/.internal/Caddyfile
	ExecReload=/usr/local/bin/caddy reload --config $DEPLOY_ROOT/.internal/Caddyfile
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
	ExecStart=/usr/bin/systemd-nspawn --quiet --keep-unit --settings=override -D $DEPLOY_ROOT/%i/machine --machine=deploy-%i /app/start.sh
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
	local app_name=$1; local app_dir="$DEPLOY_ROOT/$app_name"
	if [[ "$app_name" == .* ]]; then echo "⚠️ App name cannot start with '.'"; exit 1; fi
	if [ -d "$app_dir" ]; then echo "⚠️ App $app_name already exists"; exit 1; fi

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
	    domain=yourdomain.com
	    assets=public

	  For a static site:
	    domain=yourdomain.com
	    build=npm ci && npm run build
	    assets=dist
	    spa=true

	Next steps:
	  git remote add deploy $DEPLOY_USER@$(hostname):$app_dir/repo.git
	  git push deploy main

	To configure mounts or environment variables, create $app_dir/server.conf on the server:
	  mount=/data/uploads:/app/uploads    # read-write mount
	  mount=/etc/secrets:/app/secrets:ro  # read-only mount (:ro)
	  env=SECRET_KEY=...                  # environment variable (passed to container and build)
	MSG
}

cmd_list() {
	for app_dir in "$DEPLOY_ROOT"/*/; do
		if [ ! -d "$app_dir" ]; then continue; fi
		echo $(basename "$app_dir")
	done
}

cmd_info() {
	require_arg "$1" "Usage: deploy info <app-name>"
	local app_name=$1 app_dir="$DEPLOY_ROOT/$1"
	if [ ! -d "$app_dir" ]; then echo "⚠️ App $app_name does not exist"; exit 1; fi

	local deployfile="$app_dir/current/deploy.conf"
	local release_name; release_name=$(basename "$(readlink "$app_dir/current" 2>/dev/null)" 2>/dev/null)

	echo -e "\e[1m$app_name\e[0m"

	if [ -n "$release_name" ]; then
		local deployed_at="${release_name:0:4}-${release_name:4:2}-${release_name:6:2} ${release_name:9:2}:${release_name:11:2}"
		echo "┆ Last deployed: $deployed_at"
	fi

	if [ ! -f "$deployfile" ]; then echo "┆ Not yet deployed"; return; fi

	local start_cmd=$(get_conf "$deployfile" "start")
	if [ -n "$start_cmd" ]; then
		local status; status=$(systemctl is-active "deploy@$app_name" 2>/dev/null || true)
		echo "┆ Type:    container ($status)"
		echo "┆ Command: $start_cmd"
	else
		echo "┆ Type:    static"
	fi

	local domains=()
	while IFS= read -r d; do domains+=("$d"); done < <(get_conf_all "$deployfile" "domain")
	if [ ${#domains[@]} -gt 0 ]; then
		echo "┆ Domains:"
		for d in "${domains[@]}"; do echo "┆   $d"; done
	fi

	local assets=$(get_conf "$deployfile" "assets")
	if [ -n "$assets" ]; then echo "┆ Assets:  $assets"; fi

	local spa=$(get_conf "$deployfile" "spa")
	if [ "$spa" = "true" ]; then echo "┆ SPA:     yes"; fi
}

cmd_logs() {
	require_arg "$1" "Usage: deploy logs <app-name> [journalctl-options...]

Examples:
  deploy logs myapi
  deploy logs myapi -f
  deploy logs myapi --since '1 hour ago'"
	require_root logs "$@"
	local app_name=$1; shift
	journalctl --no-pager -u "deploy@$app_name" "$@"
}

cmd_requests() {
	require_arg "$1" "Usage: deploy requests <app-name> [options...]

Options:
  -f                  Follow log output
  --since <date>      Show requests since date
  --before <date>     Show requests before date

Examples:
  deploy requests myapp
  deploy requests myapp -f
  deploy requests myapp --since '1 hour ago'
  deploy requests myapp --since '2026-03-01 10:00' --before '2026-03-01 11:00'"
	require_root requests "$@"
	local app_name=$1; shift
	local log_file="$DEPLOY_ROOT/.internal/access.log"
	local deployfile="$DEPLOY_ROOT/$app_name/current/deploy.conf"
	local follow=false since_ts="" before_ts=""

	while [ $# -gt 0 ]; do
		case "$1" in
			-f) follow=true ;;
			--since) shift; since_ts=$(date -d "$1" +%s 2>/dev/null) || { echo "⚠️ Invalid --since date: $1"; exit 1; } ;;
			--before) shift; before_ts=$(date -d "$1" +%s 2>/dev/null) || { echo "⚠️ Invalid --before date: $1"; exit 1; } ;;
		esac
		shift
	done

	if [ ! -f "$log_file" ]; then echo "No access log found at $log_file"; exit 1; fi

	local domains=()
	while IFS= read -r domain; do domains+=("$domain"); done < <(get_conf_all "$deployfile" "domain")
	if [ ${#domains[@]} -eq 0 ]; then echo "No domains configured for $app_name"; exit 1; fi

	local pattern; pattern=$(printf '%s\n' "${domains[@]}" | paste -sd '|')

	if $follow; then tail -f "$log_file"; else cat "$log_file"; fi \
	| awk -v p="$pattern" -v since="$since_ts" -v before="$before_ts" '
		$0 ~ p {
			if (since != "" || before != "") {
				if (match($0, /"ts":[0-9]+/))
					ts = substr($0, RSTART+5, RLENGTH-5) + 0
				if (since  != "" && ts < since+0)  next
				if (before != "" && ts > before+0) next
			}
			print
		}
	'
}

cmd_restart() {
	require_arg "$1" "Usage: deploy restart <app-name>"
	require_root restart "$@"
	echo "🔄 Restarting $1..."
	systemctl restart "deploy@$1"
	echo "✅ Restarted"
}

cmd_remove() {
	require_arg "$1" "Usage: deploy remove <app-name>"
	local app_name=$1; local app_dir="$DEPLOY_ROOT/$app_name"
	if [ ! -d "$app_dir" ]; then echo "⚠️ App $app_name does not exist"; exit 1; fi
	require_root remove "$@"
	echo "🗑️  Removing app: $app_name"
	if systemctl is-active --quiet "deploy@$app_name" 2>/dev/null; then echo "  Stopping service..."; systemctl stop "deploy@$app_name"; fi
	if systemctl is-enabled --quiet "deploy@$app_name" 2>/dev/null; then systemctl disable "deploy@$app_name"; fi
	if [ -f "/etc/systemd/nspawn/deploy-$app_name.nspawn" ]; then rm "/etc/systemd/nspawn/deploy-$app_name.nspawn"; systemctl daemon-reload; fi
	if [ -f "$app_dir/caddy.conf" ]; then echo "  Removing from Caddy..."; caddy reload --config "$DEPLOY_ROOT/.internal/Caddyfile" 2>/dev/null || true; fi
	echo "  Removing app files..." && rm -rf "$app_dir"
	local ports_file="$DEPLOY_ROOT/.internal/ports"
	if [ -f "$ports_file" ]; then sed -i "/^$app_name=/d" "$ports_file"; fi
	echo "✅ Removed $app_name"
}

cmd__deploy-app() {
	require_arg "$1" "Internal error: app name required"
	local app_name=$1; local app_dir="$DEPLOY_ROOT/$app_name"
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

	if [ -n "$start_cmd" ] && [ ! -d "$app_dir/machine" ]; then
		echo "🏗️  First deploy detected - cloning base image..."
		cp -a "$DEPLOY_ROOT/.internal/machine" "$app_dir/machine"
		rm -f "$app_dir/machine/etc/machine-id"
		systemd-machine-id-setup --root="$app_dir/machine"
		echo "✅ Container created"
	fi

	local app_conf="$app_dir/server.conf"
	local setenv_args=()
	while IFS= read -r env_var; do
		setenv_args+=(--setenv="$env_var")
	done < <(get_conf_all "$app_conf" "env")

	if [ -n "$start_cmd" ] && [ -n "$build_cmd" ]; then
		echo "🔧 Running build..."
		local build_dir="$app_dir/machine-build"
		if [ -d "$build_dir" ]; then rm -rf "$build_dir"; fi
		cp -a "$DEPLOY_ROOT/.internal/machine" "$build_dir"
		systemd-nspawn -D "$build_dir" "${setenv_args[@]}" --bind="$release_dir":/build --chdir=/build bash -c "$build_cmd"
		echo "🔄 Swapping container..."
		systemctl stop "deploy@$app_name" 2>/dev/null || true
		rm -rf "$app_dir/machine"
		mv "$build_dir" "$app_dir/machine"
	elif [ -z "$start_cmd" ] && [ -n "$build_cmd" ]; then
		echo "🔧 Running static site build in ephemeral container..."
		local build_dir="$app_dir/machine-build"
		if [ -d "$build_dir" ]; then rm -rf "$build_dir"; fi
		cp -a "$DEPLOY_ROOT/.internal/machine" "$build_dir"
		systemd-nspawn -D "$build_dir" "${setenv_args[@]}" --bind="$release_dir":/build --chdir=/build bash -c "$build_cmd"
		rm -rf "$build_dir"
		echo "✅ Build complete"
	fi

	cmd__sync "$app_name"
	cd "$app_dir/releases" && ls -t | tail -n +6 | xargs -r rm -rf
	echo "🧹 Cleaned up old releases"
}

cmd__sync() {
	require_arg "$1" "Internal error: app name required"
	local app_name=$1; local app_dir="$DEPLOY_ROOT/$app_name"
	local deployfile="$app_dir/current/deploy.conf" app_conf="$app_dir/server.conf"
	local start_cmd=$(get_conf "$deployfile" "start")
	local is_static=false; if [ -z "$start_cmd" ]; then is_static=true; fi
	validate_deployconf "$deployfile" "$app_name"
	local port; port=$(assign_port "$app_name")

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
				    log {
				        output file $DEPLOY_ROOT/.internal/access.log
				    }
				}
				CADDY
			else
				cat >> "$app_dir/caddy.conf" <<-CADDY
				$domain {
				    root * $root_path
				    file_server
				    encode gzip
				    log {
				        output file $DEPLOY_ROOT/.internal/access.log
				    }
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
				        reverse_proxy localhost:$port
				    }

				    log {
				        output file $DEPLOY_ROOT/.internal/access.log
				    }
				}
				CADDY
			else
				cat >> "$app_dir/caddy.conf" <<-CADDY
				$domain {
				    reverse_proxy localhost:$port
				    log {
				        output file $DEPLOY_ROOT/.internal/access.log
				    }
				}
				CADDY
			fi
		fi
	done
	[ ${#domains[@]} -gt 0 ] && echo "    Configured ${#domains[@]} domain(s): ${domains[*]}" || echo "    No domains configured"
	if [ -n "$static_dir" ]; then echo "    Assets directory: $static_dir"; fi
	if [ "$spa_mode" = "true" ]; then echo "    SPA mode: enabled"; fi

	if ! $is_static; then
		echo "  📝 Generating .nspawn config..."
		local nspawn_file="/etc/systemd/nspawn/deploy-$app_name.nspawn"
		printf '[Exec]\nBoot=no\nParameters=/app/start.sh\n' > "$nspawn_file"

		local env_count=0
		while IFS= read -r env_var; do
			echo "Environment=\"$env_var\"" >> "$nspawn_file"
			((++env_count))
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
			((++mount_count))
		done < <(get_conf_all "$app_conf" "mount")

		echo -e "\n[Network]\nPrivate=no" >> "$nspawn_file"
		if [ "$mount_count" -gt 0 ]; then echo "    Added $mount_count custom mount(s)"; fi
		if [ "$env_count" -gt 0 ]; then echo "    Added $env_count environment variable(s)"; fi

		cat > "$app_dir/start.sh" <<-STARTSH
		#!/bin/bash
		export PORT=$port
		cd /app
		exec $start_cmd
		STARTSH
		chmod +x "$app_dir/start.sh"
	fi

	echo "  🔄 Reloading services..."
	[ ${#domains[@]} -gt 0 ] && caddy reload --config "$DEPLOY_ROOT/.internal/Caddyfile" 2>/dev/null || true
	if ! $is_static; then
		systemctl daemon-reload
		systemctl is-enabled "deploy@$app_name.service" &>/dev/null || systemctl enable "deploy@$app_name.service"
		systemctl restart "deploy@$app_name"
	fi
	echo "✅ Configuration synced"
}

cmd_uninstall() {
	if [ "$(id -u)" -ne 0 ]; then echo "⚠️ deploy uninstall must be run as root"; exit 1; fi
	echo "⚠️  This will remove all deploy.sh system changes, including all apps and containers."
	read -rp "Type 'yes' to confirm: " confirm
	if [ "$confirm" != "yes" ]; then echo "Aborted."; exit 1; fi

	echo "🗑️  Uninstalling deploy.sh..."

	for app_dir in "$DEPLOY_ROOT"/*/; do
		if [ ! -d "$app_dir" ]; then continue; fi
		local app_name=$(basename "$app_dir")
		if systemctl is-active --quiet "deploy@$app_name" 2>/dev/null; then echo "  Stopping deploy@$app_name..."; systemctl stop "deploy@$app_name"; fi
		if systemctl is-enabled --quiet "deploy@$app_name" 2>/dev/null; then systemctl disable "deploy@$app_name"; fi
	done
	rm -f /etc/systemd/nspawn/deploy-*.nspawn

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
	📦 deploy.sh

	Usage:
	  deploy init                         Initialize the deployment system
	  deploy create <name>                Create a new app
	  deploy list                         List all apps
	  deploy info <name>                  Show app info
	  deploy logs <name> [options...]     Show app logs
	  deploy requests <name> [options...] Show app requests
	  deploy restart <name>               Restart an app
	  deploy remove <name>                Remove an app
	  deploy uninstall                    Remove all deploy.sh system changes
	  deploy help                         Show this help
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
	info)            shift; cmd_info "$@" ;;
	logs)            shift; cmd_logs "$@" ;;
	requests)        shift; cmd_requests "$@" ;;
	restart)         shift; cmd_restart "$@" ;;
	remove)          shift; cmd_remove "$@" ;;
	uninstall)       cmd_uninstall ;;
	_deploy-app)     shift; cmd__deploy-app "$@" ;;
	_sync)           shift; cmd__sync "$@" ;;
	help|--help|-h)  cmd_help ;;
	*)               echo "Unknown command: $1"; echo "Run \"deploy help\" for usage"; exit 1 ;;
esac
