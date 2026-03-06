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

# Escape a string for embedding in JSON
json_str() {
	local s="$1"
	s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"
	printf '"%s"' "$s"
}

# Build a JSON array from arguments
json_arr() { local out='[' sep=''; for item in "$@"; do out+="$sep$(json_str "$item")"; sep=','; done; printf '%s]' "$out"; }

# Return a JSON string, or null if the argument is empty
json_nullable() { [ -n "$1" ] && json_str "$1" || printf 'null'; }

# Print an error and exit (JSON-aware)
die() {
	if $FMT_JSON; then printf '{"ok":false,"error":%s}\n' "$(json_str "$1")"
	else echo "⚠️ $1" >&2; fi
	exit 1
}

# Print a progress message to stderr; no-op in JSON mode
log() { $FMT_JSON || echo "$@" >&2; }

# Print a success result; emits {"ok":true} in JSON mode
ok() { $FMT_JSON && printf '{"ok":true}\n' || log "$1"; }

# Require an argument or exit with usage message
require_arg() {
	local arg=$1 usage=$2
	if [ -z "$arg" ]; then die "$usage"; fi
}

require_root() { if [ "$(id -u)" -ne 0 ]; then
	if $FMT_JSON; then exec sudo "$0" --json "$@"
	else exec sudo "$0" "$@"; fi
fi; }

check_domain_collision() {
	local domain=$1 exclude_app=${2:-}

	local deployfile
	for deployfile in "$DEPLOY_ROOT"/*/current/deploy.conf; do
		if [ ! -f "$deployfile" ]; then continue; fi
		local app_name=$(basename "$(dirname "$(dirname "$deployfile")")")
		if [ "$app_name" = "$exclude_app" ]; then continue; fi

		while IFS= read -r existing_domain; do
			if [ "$existing_domain" = "$domain" ]; then die "Domain $domain already used by $app_name"; fi
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
	if [ "$(id -u)" -ne 0 ]; then echo "⚠️ deploy init must be run as root" >&2; exit 1; fi
	log "🚀 Setting up deploy.sh at $DEPLOY_ROOT..."

	if ! command -v systemd-nspawn &>/dev/null; then
		log "📦 Installing systemd-container..."
		if command -v apt-get &>/dev/null; then
			apt-get install -y systemd-container
		elif command -v dnf &>/dev/null; then
			dnf install -y systemd-container
		else
			die "systemd-nspawn not found — install systemd-container manually"
		fi
	fi

	id "$DEPLOY_USER" &>/dev/null || { useradd -m -s /bin/bash "$DEPLOY_USER"; log "✅ Created user: $DEPLOY_USER"; }

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
		log "✅ Copied SSH authorized_keys from $src_keys"
	else
		log "⚠️  No authorized_keys found — add your public key manually to /home/$DEPLOY_USER/.ssh/authorized_keys"
	fi

	mkdir -p "$DEPLOY_ROOT/.internal"
	chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_ROOT"


	if [ ! -d "$DEPLOY_ROOT/.internal/machine" ]; then
		log "📦 Pulling Alpine base image..."
		local arch; arch=$(uname -m)
		local alpine_file; alpine_file=$(curl -fsSL "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$arch/latest-releases.yaml" | grep -oE "alpine-minirootfs-[0-9]+\.[0-9]+\.[0-9]+-${arch}\.tar\.gz" | head -1)
		if [ -z "$alpine_file" ]; then die "Could not find Alpine minirootfs for $arch"; fi
		mkdir -p "$DEPLOY_ROOT/.internal/machine"
		curl -fsSL "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$arch/$alpine_file" | tar -xz -C "$DEPLOY_ROOT/.internal/machine"
		log "🔧 Installing bash in base image..."
		systemd-nspawn -D "$DEPLOY_ROOT/.internal/machine" /bin/sh -c "apk update && apk add --no-cache bash"
		log "✅ Base image ready"
	fi

	command -v caddy &>/dev/null || { log "📦 Installing Caddy..."; curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=amd64" -o /usr/local/bin/caddy; chmod +x /usr/local/bin/caddy; }

	if [ ! -f "$DEPLOY_ROOT/.internal/Caddyfile" ]; then
		read -rp "📧 Email for Let's Encrypt certificates: " acme_email
		if [ -z "$acme_email" ]; then die "Email is required for HTTPS certificate provisioning"; fi
		cat > "$DEPLOY_ROOT/.internal/Caddyfile" <<-CADDY
		{
		    email $acme_email
		}

		import $DEPLOY_ROOT/*/caddy.conf
		CADDY
		log "📝 Created Caddyfile"
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
	log "📝 Created deploy@.service template"

	cat > /etc/sudoers.d/deploy <<-SUDOERS
	$DEPLOY_USER ALL=(root) NOPASSWD: /usr/local/bin/deploy *
	ALL ALL=(deploy) NOPASSWD: /usr/local/bin/deploy *
	SUDOERS
	chmod 0440 /etc/sudoers.d/deploy
	log "📝 Created /etc/sudoers.d/deploy"

	log -e "\n✅ System initialized!\n   Location: $DEPLOY_ROOT\n\nNext: deploy create <app-name>"
}

cmd_create() {
	require_arg "$1" "Usage: deploy create <app-name>"
	local app_name=$1; local app_dir="$DEPLOY_ROOT/$app_name"
	if [[ "$app_name" == .* ]]; then echo "⚠️ App name cannot start with '.'" >&2; exit 1; fi
	if [ -d "$app_dir" ]; then echo "⚠️ App $app_name already exists" >&2; exit 1; fi

	log "📦 Creating app: $app_name"
	mkdir -p "$app_dir"/{releases,repo.git}
	cd "$app_dir/repo.git" && git init --bare --initial-branch=main

	cat > hooks/post-receive <<-HOOK
	#!/bin/bash
	sudo /usr/local/bin/deploy _deploy-app $app_name
	HOOK
	chmod +x hooks/post-receive
	chown -R "$DEPLOY_USER:$DEPLOY_USER" "$app_dir"

	cat >&2 <<-MSG
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
	local names=()
	for app_dir in "$DEPLOY_ROOT"/*/; do
		[ -d "$app_dir" ] && names+=("$(basename "$app_dir")")
	done
	if $FMT_JSON; then
		printf '%s\n' "$(json_arr "${names[@]}")"
	else
		printf '%s\n' "${names[@]}"
	fi
}

cmd_info() {
	require_arg "$1" "Usage: deploy info <app-name>"
	local app_name=$1 app_dir="$DEPLOY_ROOT/$1"
	if [ ! -d "$app_dir" ]; then die "App $app_name does not exist"; fi

	local deployfile="$app_dir/current/deploy.conf"
	local release_name; release_name=$(basename "$(readlink "$app_dir/current" 2>/dev/null)" 2>/dev/null)

	if ! $FMT_JSON; then
		echo -e "\e[1m$app_name\e[0m"

		if [ -n "$release_name" ]; then
			local deployed_at="${release_name:0:4}-${release_name:4:2}-${release_name:6:2} ${release_name:9:2}:${release_name:11:2}"
			echo "┆ Last deployed: $deployed_at"
		fi

		if [ ! -f "$deployfile" ]; then echo "┆ Not yet deployed"; return; fi

		local start_cmd; start_cmd=$(get_conf "$deployfile" "start")
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

		local assets; assets=$(get_conf "$deployfile" "assets")
		if [ -n "$assets" ]; then echo "┆ Assets:  $assets"; fi

		local spa; spa=$(get_conf "$deployfile" "spa")
		if [ "$spa" = "true" ]; then echo "┆ SPA:     yes"; fi
		return
	fi

	local deployed_at=""
	[ -n "$release_name" ] && deployed_at="${release_name:0:4}-${release_name:4:2}-${release_name:6:2} ${release_name:9:2}:${release_name:11:2}"

	local type="null" status="null" command="null" domains_json="null" assets_json="null" spa_json="false"
	local last_deployed; last_deployed=$(json_nullable "$deployed_at")

	if [ -f "$deployfile" ]; then
		local start_cmd; start_cmd=$(get_conf "$deployfile" "start")
		if [ -n "$start_cmd" ]; then
			local svc_status; svc_status=$(systemctl is-active "deploy@$app_name" 2>/dev/null || true)
			type=$(json_str "container")
			status=$(json_str "$svc_status")
			command=$(json_str "$start_cmd")
		else
			type=$(json_str "static")
		fi

		local domains=()
		while IFS= read -r d; do domains+=("$d"); done < <(get_conf_all "$deployfile" "domain")
		[ ${#domains[@]} -gt 0 ] && domains_json=$(json_arr "${domains[@]}")

		local assets; assets=$(get_conf "$deployfile" "assets")
		assets_json=$(json_nullable "$assets")

		local spa; spa=$(get_conf "$deployfile" "spa")
		[ "$spa" = "true" ] && spa_json="true"
	fi

	printf '{"name":%s,"type":%s,"status":%s,"command":%s,"last_deployed":%s,"domains":%s,"assets":%s,"spa":%s}\n' \
		"$(json_str "$app_name")" "$type" "$status" "$command" "$last_deployed" "$domains_json" "$assets_json" "$spa_json"
}

cmd_logs() {
	require_arg "$1" "Usage: deploy logs <app-name> [journalctl-options...]

Examples:
  deploy logs myapi
  deploy logs myapi -f
  deploy logs myapi --since '1 hour ago'"
	require_root logs "$@"
	local app_name=$1; shift
	if $FMT_JSON; then
		journalctl --no-pager -u "deploy@$app_name" -o json "$@"
	else
		journalctl --no-pager -u "deploy@$app_name" "$@"
	fi
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
			--since) shift; since_ts=$(date -d "$1" +%s 2>/dev/null) || die "Invalid --since date: $1" ;;
			--before) shift; before_ts=$(date -d "$1" +%s 2>/dev/null) || die "Invalid --before date: $1" ;;
		esac
		shift
	done

	if [ ! -f "$log_file" ]; then die "No access log found at $log_file"; fi

	local domains=()
	while IFS= read -r domain; do domains+=("$domain"); done < <(get_conf_all "$deployfile" "domain")
	if [ ${#domains[@]} -eq 0 ]; then die "No domains configured for $app_name"; fi

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
	log "🔄 Restarting $1..."
	if systemctl restart "deploy@$1"; then
		ok "✅ Restarted"
	else
		die "Failed to restart $1"
	fi
}

cmd_remove() {
	require_arg "$1" "Usage: deploy remove <app-name>"
	local app_name=$1; local app_dir="$DEPLOY_ROOT/$app_name"
	if [ ! -d "$app_dir" ]; then die "App $app_name does not exist"; fi
	require_root remove "$@"
	log "🗑️  Removing app: $app_name"
	if systemctl is-active --quiet "deploy@$app_name" 2>/dev/null; then
		log "  Stopping service..."
		systemctl stop "deploy@$app_name"
	fi
	if systemctl is-enabled --quiet "deploy@$app_name" 2>/dev/null; then systemctl disable "deploy@$app_name"; fi
	if [ -f "/etc/systemd/nspawn/deploy-$app_name.nspawn" ]; then rm "/etc/systemd/nspawn/deploy-$app_name.nspawn"; systemctl daemon-reload; fi
	if [ -f "$app_dir/caddy.conf" ]; then
		log "  Removing from Caddy..."
		caddy reload --config "$DEPLOY_ROOT/.internal/Caddyfile" 2>/dev/null || true
	fi
	log "  Removing app files..."
	rm -rf "$app_dir"
	local ports_file="$DEPLOY_ROOT/.internal/ports"
	if [ -f "$ports_file" ]; then sed -i "/^$app_name=/d" "$ports_file"; fi
	ok "✅ Removed $app_name"
}

cmd_internal_deploy-app() {
	require_arg "$1" "Internal error: app name required"
	local app_name=$1; local app_dir="$DEPLOY_ROOT/$app_name"
	local release_dir="$app_dir/releases/$(date +%Y%m%d-%H%M%S)"
	local current_link="$app_dir/current"

	log "📦 Deploying $app_name..."
	mkdir -p "$release_dir"
	local repo_dir=$(pwd)
	unset GIT_DIR
	git --work-tree="$release_dir" --git-dir="$repo_dir" checkout HEAD -f
	cd "$release_dir"
	ln -sfn "$release_dir" "$current_link"
	log "✅ Deployed to $current_link"

	local deployfile="$release_dir/deploy.conf"
	local start_cmd=$(get_conf "$deployfile" "start")
	local build_cmd=$(get_conf "$deployfile" "build")

	if [ -n "$start_cmd" ] && [ ! -d "$app_dir/machine" ]; then
		log "🏗️  First deploy detected - cloning base image..."
		cp -a "$DEPLOY_ROOT/.internal/machine" "$app_dir/machine"
		rm -f "$app_dir/machine/etc/machine-id"
		systemd-machine-id-setup --root="$app_dir/machine"
		log "✅ Container created"
	fi

	local app_conf="$app_dir/server.conf"
	local setenv_args=()
	while IFS= read -r env_var; do
		setenv_args+=(--setenv="$env_var")
	done < <(get_conf_all "$app_conf" "env")

	if [ -n "$start_cmd" ] && [ -n "$build_cmd" ]; then
		log "🔧 Running build..."
		local build_dir="$app_dir/machine-build"
		if [ -d "$build_dir" ]; then rm -rf "$build_dir"; fi
		cp -a "$DEPLOY_ROOT/.internal/machine" "$build_dir"
		systemd-nspawn -D "$build_dir" "${setenv_args[@]}" --bind="$release_dir":/build --chdir=/build bash -c "$build_cmd"
		log "🔄 Swapping container..."
		systemctl stop "deploy@$app_name" 2>/dev/null || true
		rm -rf "$app_dir/machine"
		mv "$build_dir" "$app_dir/machine"
	elif [ -z "$start_cmd" ] && [ -n "$build_cmd" ]; then
		log "🔧 Running static site build in ephemeral container..."
		local build_dir="$app_dir/machine-build"
		if [ -d "$build_dir" ]; then rm -rf "$build_dir"; fi
		cp -a "$DEPLOY_ROOT/.internal/machine" "$build_dir"
		systemd-nspawn -D "$build_dir" "${setenv_args[@]}" --bind="$release_dir":/build --chdir=/build bash -c "$build_cmd"
		rm -rf "$build_dir"
		log "✅ Build complete"
	fi

	cmd_internal_sync "$app_name"
	cd "$app_dir/releases" && ls -t | tail -n +6 | xargs -r rm -rf
	log "🧹 Cleaned up old releases"
}

cmd_internal_sync() {
	require_arg "$1" "Internal error: app name required"
	local app_name=$1; local app_dir="$DEPLOY_ROOT/$app_name"
	local deployfile="$app_dir/current/deploy.conf" app_conf="$app_dir/server.conf"
	local start_cmd=$(get_conf "$deployfile" "start")
	local is_static=false; if [ -z "$start_cmd" ]; then is_static=true; fi
	validate_deployconf "$deployfile" "$app_name"
	local port; port=$(assign_port "$app_name")

	log "🔄 Syncing configuration for $app_name..."

	local domains; domains=$(get_conf_all "$deployfile" "domain")
	local static_dir=$(get_conf "$deployfile" "assets")
	local spa_mode=$(get_conf "$deployfile" "spa")
	local host="${domains//$'\n'/, }"

	if [ -n "$domains" ]; then
		cat > "$app_dir/caddy.conf" <<-CADDY
		$host {
		    root * $app_dir/current${static_dir:+/$static_dir}
		$(if $is_static; then
			[ "$spa_mode" = "true" ] && echo "    try_files {path} /index.html"
			cat <<-'HANDLER'
			    file_server
			    encode gzip
			HANDLER
		elif [ -n "$static_dir" ]; then
			cat <<-HANDLER
			    @static file
			    handle @static { file_server; encode gzip }
			    handle { reverse_proxy localhost:$port }
			HANDLER
		else
			echo "    reverse_proxy localhost:$port"
		fi)
		    log { output file $DEPLOY_ROOT/.internal/access.log }
		}
		CADDY
	else
		> "$app_dir/caddy.conf"
	fi

	if ! $is_static; then
		local env_lines; env_lines=$(
			while IFS= read -r env_var; do
				printf 'Environment="%s"\n' "$env_var"
			done < <(get_conf_all "$app_conf" "env")
		)

		local mount_lines; mount_lines=$(
			while IFS= read -r mount; do
				if [[ "$mount" =~ ^([^:]+):([^:]+):ro$ ]]; then
					host_path="${BASH_REMATCH[1]}" container_path="${BASH_REMATCH[2]}" readonly="ReadOnly"
				elif [[ "$mount" =~ ^([^:]+):([^:]+)$ ]]; then
					host_path="${BASH_REMATCH[1]}" container_path="${BASH_REMATCH[2]}" readonly=""
				else
					log "⚠️  Skipping invalid mount: $mount"; continue
				fi
				[ ! -e "$host_path" ] && { log "⚠️  Host path does not exist: $host_path (creating directory)"; mkdir -p "$host_path"; }
				printf 'Bind%s=%s:%s\n' "$readonly" "$host_path" "$container_path"
			done < <(get_conf_all "$app_conf" "mount")
		)

		local nspawn_file="/etc/systemd/nspawn/deploy-$app_name.nspawn"
		cat > "$nspawn_file" <<-NSPAWN
		[Exec]
		Boot=no
		Parameters=/app/start.sh
		$env_lines

		[Files]
		Bind=$app_dir/current:/app
		BindReadOnly=$app_dir/start.sh:/app/start.sh
		BindReadOnly=/etc/resolv.conf
		$mount_lines

		[Network]
		Private=no
		NSPAWN

		cat > "$app_dir/start.sh" <<-STARTSH
		#!/bin/bash
		export PORT=$port
		cd /app
		exec $start_cmd
		STARTSH
		chmod +x "$app_dir/start.sh"
	fi

	[ -n "$domains" ] && caddy reload --config "$DEPLOY_ROOT/.internal/Caddyfile" 2>/dev/null || true
	if ! $is_static; then
		systemctl daemon-reload
		systemctl is-enabled "deploy@$app_name.service" &>/dev/null || systemctl enable "deploy@$app_name.service"
		systemctl restart "deploy@$app_name"
	fi
	log "✅ Configuration synced"
}

cmd_uninstall() {
	if [ "$(id -u)" -ne 0 ]; then echo "⚠️ deploy uninstall must be run as root" >&2; exit 1; fi
	log "⚠️  This will remove all deploy.sh system changes, including all apps and containers."
	read -rp "Type 'yes' to confirm: " confirm
	if [ "$confirm" != "yes" ]; then log "Aborted."; exit 1; fi

	log "🗑️  Uninstalling deploy.sh..."

	for app_dir in "$DEPLOY_ROOT"/*/; do
		if [ ! -d "$app_dir" ]; then continue; fi
		local app_name=$(basename "$app_dir")
		if systemctl is-active --quiet "deploy@$app_name" 2>/dev/null; then log "  Stopping deploy@$app_name..."; systemctl stop "deploy@$app_name"; fi
		if systemctl is-enabled --quiet "deploy@$app_name" 2>/dev/null; then systemctl disable "deploy@$app_name"; fi
	done
	rm -f /etc/systemd/nspawn/deploy-*.nspawn

	if systemctl is-active --quiet caddy 2>/dev/null; then log "  Stopping caddy..."; systemctl stop caddy; fi
	if systemctl is-enabled --quiet caddy 2>/dev/null; then systemctl disable caddy; fi
	rm -f /etc/systemd/system/caddy.service /usr/local/bin/caddy

	rm -f /etc/systemd/system/deploy@.service
	rm -f /etc/sudoers.d/deploy
	systemctl daemon-reload

	if [ -f /etc/nsswitch.conf.backup ]; then
		mv /etc/nsswitch.conf.backup /etc/nsswitch.conf
		log "  Restored /etc/nsswitch.conf"
	fi

	rm -rf "$DEPLOY_ROOT"
	if id "$DEPLOY_USER" &>/dev/null; then userdel -r "$DEPLOY_USER"; fi

	log "✅ Uninstalled"
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

FMT_JSON=false
_args=()
for _arg in "$@"; do
	[ "$_arg" = "--json" ] && FMT_JSON=true || _args+=("$_arg")
done
set -- "${_args[@]+"${_args[@]}"}"
unset _args _arg

case "${1:-}" in
	init|uninstall|_*|help|--help|-h|"") ;;
	*)
		if [ "$(id -un)" != "$DEPLOY_USER" ] && [ "$(id -u)" -ne 0 ]; then
			if $FMT_JSON; then exec sudo -u "$DEPLOY_USER" "$0" --json "$@"
			else exec sudo -u "$DEPLOY_USER" "$0" "$@"; fi
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
	_deploy-app)     shift; cmd_internal_deploy-app "$@" ;;
	_sync)           shift; cmd_internal_sync "$@" ;;
	help|--help|-h)  cmd_help ;;
	*)               die "Unknown command: $1. Run \"deploy help\" for usage" ;;
esac
