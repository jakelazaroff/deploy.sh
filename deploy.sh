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

set -euo pipefail

DEPLOY_ROOT=/srv/deploy
DEPLOY_USER=deploy
PLUGIN_DIR="$DEPLOY_ROOT/.plugins"
PORT_RANGE_START=49152   # first ephemeral port
PORT_WAIT_SECONDS=30     # how long to wait for a new container to start
MAX_RELEASES=5           # number of old releases to keep

# UTILITIES

red() { printf "\033[31m$1\033[0m"; }
green() { printf "\033[32m$1\033[0m"; }

# Print an error and exit
die() { error "$1" >&2; exit 1; }

log() { echo "$@" >&2; }
success() { echo "$(green "✓") $@" >&2; }
error() { echo "$(red "✗") $@" >&2; }

require_arg() { [ -n "${1:-}" ] || die "$2"; }

require_app() {
	require_arg "${1:-}" "Usage: deploy $PLUGIN_NAME <subcmd> <app-name>"
	[ -d "$DEPLOY_ROOT/$1" ] || die "App $1 does not exist"
	app_dir="$DEPLOY_ROOT/$1"
	server_conf="$app_dir/server.conf"
}

# Register a subcommand: name | usage | description
subcmd() { SUBCMDS_DATA="${SUBCMDS_DATA}${1}|${2}|${3}"$'\n'; }

# Validate subcmd, escalate, then call <plugin>:<subcmd> "$@"
dispatch() {
	local subcmd="${1:-}"
	if [[ "$subcmd" == --help || "$subcmd" == -h || "$subcmd" == help || -z "$subcmd" ]]; then
		plugin_help_default; return
	fi
	local valid; valid=$(printf '%s' "$SUBCMDS_DATA" | cut -d'|' -f1 | tr '\n' ' ')
	[[ " $valid " == *" $subcmd "* ]] || die "Unknown $PLUGIN_NAME command: $subcmd. Run \"deploy $PLUGIN_NAME --help\" for usage"
	escalate "$PLUGIN_NAME" "$@"
	"${PLUGIN_NAME}:${subcmd}" "$@"
}

# Auto-generate help from subcmd registrations
plugin_help_default() {
	printf 'Usage: deploy %s <command> [args...]\n\nCommands:\n' "$PLUGIN_NAME"
	while IFS='|' read -r name usage desc; do
		[ -z "$name" ] && continue
		printf '  %-10s  %-28s  %s\n' "$name" "$usage" "$desc"
	done <<< "$SUBCMDS_DATA"
}

# Privilege escalation: non-deploy users hop to the deploy user first (any user
# can via /etc/sudoers.d/deploy), then deploy escalates to root.
# exec replaces this process — the lines below never run if escalation happens.
escalate() {
	[ "$(id -u)" -eq 0 ] && return
	[ "$(id -un)" != "$DEPLOY_USER" ] && exec sudo -u "$DEPLOY_USER" "$0" "$@"
	exec sudo "$0" "$@"
}

# Deploy status tracking: cmd_deploy_app sets these globals so the EXIT trap
# can write a "failed" status if the deploy exits early (e.g. build failure).
_DEPLOY_STATUS_FILE=""
_DEPLOY_START_TIME=""
_deploy_exit_trap() {
	[ -z "$_DEPLOY_STATUS_FILE" ] && return
	local finish; finish=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	printf 'status=failed\nstarted=%s\nfinished=%s\n' "$_DEPLOY_START_TIME" "$finish" > "$_DEPLOY_STATUS_FILE"
}

check_domain_collision() {
	local domain=$1 exclude_app=${2:-}
	local conf
	for conf in "$DEPLOY_ROOT"/*/server.conf; do
		[ -f "$conf" ] || continue
		local app_name; app_name=$(basename "$(dirname "$conf")")
		[ "$app_name" = "$exclude_app" ] && continue
		grep -qx "domain=$domain" "$conf" 2>/dev/null && die "Domain $domain already used by $app_name"
	done
}

# get a value matching a given key from a config file, falling back to default
get_conf() {
	local file=$1 key=$2 default=${3:-}
	if [ ! -f "$file" ]; then echo "$default"; return; fi
	local value; value=$(grep "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-)
	echo "${value:-$default}"
}

# get all values matching a given key from a config file
get_conf_all() {
	local file=$1 key=$2
	if [ -f "$file" ]; then grep "^${key}=" "$file" 2>/dev/null | cut -d= -f2-; fi
}

assign_port() {
	local app_name=$1 release_id=$2
	local key="${app_name}--${release_id}"
	local ports_file="$DEPLOY_ROOT/.internal/ports"
	(
		flock -x 9
		local existing; existing=$(grep "^$key=" "$ports_file" 2>/dev/null | cut -d= -f2)
		if [ -n "$existing" ]; then echo "$existing"; exit 0; fi
		local port=$PORT_RANGE_START
		while grep -q "=$port$" "$ports_file" 2>/dev/null; do ((port++)); done
		echo "$key=$port" >> "$ports_file"
		echo "$port"
	) 9>>"$ports_file.lock"
}

get_active_release() {
	local target
	target=$(readlink "$DEPLOY_ROOT/$1/current" 2>/dev/null) || return 1
	basename "$target"
}

clone_release() {
	local app_name=$1 source_id=$2 new_id=$3
	local app_dir="$DEPLOY_ROOT/$app_name"
	local source_dir="$app_dir/releases/$source_id"
	local new_dir="$app_dir/releases/$new_id"

	cp -a "$source_dir" "$new_dir"
	rm -f "$new_dir"/deploy-*.service
}

# Clone the current release, re-configure, and activate.
# Used by domains/env/mounts add/remove to apply config changes.
reconfigure() {
	local app_name=$1
	local old_release; old_release=$(get_active_release "$app_name") || die "Not yet deployed"
	local new_release; new_release=$(date +%Y%m%d%H%M%S)
	clone_release "$app_name" "$old_release" "$new_release"
	cmd_configure "$app_name" "$new_release"
	activate_release "$app_name" "$new_release"
}

# Append key=value to a config file
conf_add() { echo "$2=$3" >> "$1"; }

_conf_remove() {
	local file=$1 pattern=$2
	local tmp; tmp=$(mktemp)
	grep -v "$pattern" "$file" > "$tmp" || true
	mv "$tmp" "$file"
}

# Remove the line matching exactly key=value
conf_remove_value() { _conf_remove "$1" "^${2}=${3}$"; }

# Remove all lines matching key=*
conf_remove_key() { _conf_remove "$1" "^${2}="; }

teardown_release() {
	local app_name=$1 release_id=$2
	local svc="deploy-${app_name}--${release_id}"
	systemctl stop "$svc" 2>/dev/null || true
	systemctl disable "$svc" 2>/dev/null || true
	sed -i "/^${app_name}--${release_id}=/d" "$DEPLOY_ROOT/.internal/ports"
}

wait_for_port() {
	local port=$1 i=$((PORT_WAIT_SECONDS * 2))
	while ! ss -tln "sport = :$port" | grep -q LISTEN; do
		sleep 0.5; ((i--)) || return 1
	done
}

activate_release() {
	local app_name=$1 release_id=$2
	local app_dir="$DEPLOY_ROOT/$app_name"
	local release_dir="$app_dir/releases/$release_id"
	local svc="deploy-${app_name}--${release_id}"

	local old_release; old_release=$(get_active_release "$app_name") || true
	local start_cmd; start_cmd=$(get_conf "$release_dir/deploy.conf" "start")

	if [ -n "$start_cmd" ]; then
		# Container app: zero-downtime activation
		systemctl link "$release_dir/${svc}.service"
		systemctl daemon-reload
		systemctl start "$svc"

		local port; port=$(assign_port "$app_name" "$release_id")
		if ! wait_for_port "$port"; then
			teardown_release "$app_name" "$release_id"
			die "New instance failed to start on port $port after ${PORT_WAIT_SECONDS}s"
		fi

		if [ -n "$old_release" ] && [ "$old_release" != "$release_id" ]; then
			teardown_release "$app_name" "$old_release"
		fi
	fi

	ln -sfn "releases/$release_id" "$app_dir/current"
	caddy reload --config "$DEPLOY_ROOT/.internal/Caddyfile" 2>/dev/null || true
}

load_plugin() {
	local cmd="$1"; shift
	PLUGIN_NAME="$cmd"
	SUBCMDS_DATA=""

	# try inline plugin first (name-suffixed functions)
	if declare -f "plugin_run_${cmd}" > /dev/null 2>&1; then
		"plugin_run_${cmd}" "$@"
		return
	fi

	# Then try external plugin file
	local plugin_file="$PLUGIN_DIR/$cmd"
	if [ ! -f "$plugin_file" ]; then
		die "Unknown command: $cmd. Run \"deploy help\" for usage"
	fi

	source "$plugin_file"

	if declare -f plugin_run > /dev/null 2>&1; then
		plugin_run "$@"
	else
		dispatch "$@"
	fi
}

# SUBCOMMANDS

# CONFIG GENERATORS

write_global_caddyfile() {
	local dest=$1 acme_email=$2
	cat > "$dest" <<-CADDY
	{
	    email $acme_email
	}

	(logging) {
	    log {
	        output file {args[0]}/access.log
	        format json
	    }
	}

	(static) {
	    file_server
	    encode gzip
	}

	(proxy) {
	    reverse_proxy localhost:{args[0]} {
	        header_up Host {http.request.host}
	    }
	}

	(spa) {
	    try_files {path} /index.html
	    import static
	}

	(assets) {
	    @static file
	    handle @static {
	        import static
	    }
	    handle {
	        import proxy {args[0]}
	    }
	}

	import $DEPLOY_ROOT/*/caddy.conf
	CADDY
}

write_caddy_service() {
	local dest=$1
	cat > "$dest" <<-SERVICE
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
}

write_app_caddy_conf() {
	local dest=$1 domains=$2 app_dir=$3 release_id=$4 static_dir=$5 headers=$6 handler=$7
	cat > "$dest" <<-CADDY
	$domains {
	    root * $app_dir/current${static_dir:+/$static_dir}
	    log_append release $release_id
	    $headers
	    $handler
	        import logging "$app_dir"
	}
	CADDY
	caddy fmt "$dest" --overwrite
}

write_app_service() {
	local dest=$1 app_name=$2 release_id=$3; shift 3
	{
		cat <<-SERVICE
		[Unit]
		Description=deploy $app_name $release_id
		After=network.target

		[Service]
		Type=simple
		SERVICE
		printf 'ExecStart=/usr/bin/systemd-nspawn \\\n'
		local args=("$@") i
		for ((i = 0; i < ${#args[@]} - 1; i++)); do
			printf '    %s \\\n' "${args[i]}"
		done
		printf '    %s\n' "${args[-1]}"
		cat <<-SERVICE
		Restart=on-failure
		KillMode=mixed
		SERVICE
	} > "$dest"
}


# Initialize the deployment system (must be run as root)
cmd_init() {
	if [ "$(id -u)" -ne 0 ]; then die "deploy init must be run as root"; fi
	log "🚀 Setting up deploy.sh at $DEPLOY_ROOT..."

	# --- Install dependencies ---

	# install system dependencies
	local to_install=()
	command -v systemd-nspawn &>/dev/null || to_install+=(systemd-container)
	command -v jq &>/dev/null || to_install+=(jq)
	if [ ${#to_install[@]} -gt 0 ]; then
		log "📦 Installing ${to_install[*]}..."
		if command -v apt-get &>/dev/null; then
			apt-get install -y "${to_install[@]}"
		elif command -v dnf &>/dev/null; then
			dnf install -y "${to_install[@]}"
		else
			die "Missing ${to_install[*]} — install manually"
		fi
	fi

	# install caddy
	if ! command -v caddy &>/dev/null; then
		local caddy_arch; case "$(uname -m)" in
			x86_64)  caddy_arch=amd64 ;;
			aarch64) caddy_arch=arm64 ;;
			armv7l)  caddy_arch=armv7 ;;
			*)       die "Unsupported architecture for Caddy: $(uname -m)" ;;
		esac
		curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=$caddy_arch" -o /usr/local/bin/caddy
		chmod +x /usr/local/bin/caddy
	fi

	# --- Create deploy user ---
	id "$DEPLOY_USER" &>/dev/null || { useradd -m -s /bin/bash "$DEPLOY_USER"; success "Created user: $DEPLOY_USER"; }

	# --- Copy SSH keys ---
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
		success "Copied SSH authorized_keys from $src_keys"
	else
		error "No authorized_keys found — add your public key manually to /home/$DEPLOY_USER/.ssh/authorized_keys"
	fi

	# --- Create deploy directory ---
	mkdir -p "$DEPLOY_ROOT/.internal" "$PLUGIN_DIR"
	chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_ROOT"

	# --- Pull Alpine base image ---
	if [ ! -d "$DEPLOY_ROOT/.internal/machine" ]; then
		log "📦 Pulling Alpine base image..."
		local arch; arch=$(uname -m)
		local alpine_file; alpine_file=$(curl -fsSL "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$arch/latest-releases.yaml" | grep -oE "alpine-minirootfs-[0-9]+\.[0-9]+\.[0-9]+-${arch}\.tar\.gz" | head -1)
		if [ -z "$alpine_file" ]; then die "Could not find Alpine minirootfs for $arch"; fi
		mkdir -p "$DEPLOY_ROOT/.internal/machine"
		curl -fsSL "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$arch/$alpine_file" | tar -xz -C "$DEPLOY_ROOT/.internal/machine"
		systemd-nspawn -D "$DEPLOY_ROOT/.internal/machine" /bin/sh -c "apk update && apk add --no-cache bash"
		success "Base image ready"
	fi

	# --- Create Caddyfile ---
	if [ ! -f "$DEPLOY_ROOT/.internal/Caddyfile" ]; then
		read -rp "📧 Email for Let's Encrypt certificates: " acme_email
		if [ -z "$acme_email" ]; then die "Email is required for HTTPS certificate provisioning"; fi
		write_global_caddyfile "$DEPLOY_ROOT/.internal/Caddyfile" "$acme_email"
		log "📝 Created Caddyfile"
	fi

	# --- Create Caddy systemd service ---
	write_caddy_service "$DEPLOY_ROOT/.internal/caddy.service"

	systemctl enable "$DEPLOY_ROOT/.internal/caddy.service" && systemctl start caddy

	# --- Set up sudoers ---
	cat > /etc/sudoers.d/deploy <<-SUDOERS
	Defaults env_keep += "SSH_AUTH_SOCK"
	$DEPLOY_USER ALL=(root) NOPASSWD: /usr/local/bin/deploy *
	ALL ALL=(deploy) NOPASSWD: /usr/local/bin/deploy *
	SUDOERS
	chmod 0440 /etc/sudoers.d/deploy
	log "📝 Created /etc/sudoers.d/deploy"

	log ""
	success "System initialized!"
	log "   Location: $DEPLOY_ROOT"
	log ""
	log "Next: deploy create <app-name>"
}

# Create a new app and its bare git repo
apps:create() {
	require_arg "${2:-}" "Usage: deploy create <app-name>"
	local app_name=$2; local app_dir="$DEPLOY_ROOT/$app_name"
	if [[ "$app_name" == .* ]]; then die "App name cannot start with '.'"; fi
	if [ -d "$app_dir" ]; then die "App $app_name already exists"; fi

	log "📦 Creating app: $app_name"
	mkdir -p "$app_dir"/{releases,repo.git}
	git init --bare --initial-branch=main "$app_dir/repo.git"

	cat > "$app_dir/repo.git/hooks/post-receive" <<-HOOK
	#!/bin/bash
	sudo /usr/local/bin/deploy _deploy-app $app_name
	HOOK
	chmod +x "$app_dir/repo.git/hooks/post-receive"
	chown -R "$DEPLOY_USER:$DEPLOY_USER" "$app_dir"

	success "Created app: $app_name"
	log ""
	log "Next steps:"
	log "  git remote add deploy $DEPLOY_USER@$(hostname):$app_dir/repo.git"
	log "  git push deploy main"
	log ""
	log "See 'deploy help' for deploy.conf format."
}

apps:list() {
	for app_dir in "$DEPLOY_ROOT"/*/; do
		[ -d "$app_dir" ] || continue
		[[ "$(basename "$app_dir")" == .* ]] && continue
		printf '%s\n' "$(basename "$app_dir")"
	done
}

apps:info() {
	require_arg "${2:-}" "Usage: deploy info <app-name>"
	local app_name=$2; local app_dir="$DEPLOY_ROOT/$app_name"
	if [ ! -d "$app_dir" ]; then die "App $app_name does not exist"; fi

	local deploy_conf="$app_dir/current/deploy.conf"
	local server_conf="$app_dir/server.conf"
	local release_name; release_name=$(basename "$(readlink "$app_dir/current" 2>/dev/null)" 2>/dev/null)
	local deployed_at=""
	[ -n "$release_name" ] && deployed_at="${release_name:0:4}-${release_name:4:2}-${release_name:6:2} ${release_name:8:2}:${release_name:10:2}"

	local start_cmd="" status="" assets="" spa=""
	if [ -f "$deploy_conf" ]; then
		start_cmd=$(get_conf "$deploy_conf" "start")
		if [ -n "$start_cmd" ] && [ -n "$release_name" ]; then
			status=$(systemctl is-active "deploy-${app_name}--${release_name}" 2>/dev/null || true)
		fi
		assets=$(get_conf "$deploy_conf" "assets")
		spa=$(get_conf "$deploy_conf" "spa")
	fi
	local domains_list; domains_list=$(get_conf_all "$server_conf" "domain")

	local status_file="$app_dir/deploy.status"
	local deploy_status="" deploy_started="" deploy_finished="" deploy_pid=""
	if [ -f "$status_file" ]; then
		deploy_status=$(get_conf "$status_file" "status")
		deploy_started=$(get_conf "$status_file" "started")
		deploy_finished=$(get_conf "$status_file" "finished")
		deploy_pid=$(get_conf "$status_file" "pid")
		if [ "$deploy_status" = "running" ] && [ -n "$deploy_pid" ] && ! kill -0 "$deploy_pid" 2>/dev/null; then
			deploy_status="interrupted"
		fi
	fi

	echo -e "\e[1m$app_name\e[0m"
	[ -n "$deployed_at" ] && echo "┆ Last deployed: $deployed_at"
	if [ -n "$deploy_status" ]; then
		local deploy_time=""
		if [ "$deploy_status" = "running" ] && [ -n "$deploy_started" ]; then
			deploy_time=" (since ${deploy_started:0:10} ${deploy_started:11:5})"
		elif [ -n "$deploy_finished" ]; then
			deploy_time=" (${deploy_finished:0:10} ${deploy_finished:11:5})"
		fi
		echo "┆ Deploy:  $deploy_status$deploy_time"
	fi
	if [ ! -f "$deploy_conf" ]; then echo "┆ Not yet deployed"; return; fi
	if [ -n "$start_cmd" ]; then
		echo "┆ Type:    container ($status)"
		echo "┆ Command: $start_cmd"
	else
		echo "┆ Type:    static"
	fi
	[ -n "$domains_list" ] && echo "┆ Domain:  $(echo "$domains_list" | tr '\n' ' ')"
	[ -n "$assets" ] && echo "┆ Assets:  $assets"
	[ "$spa" = "true" ] && echo "┆ SPA:     yes"
}

# Pipe to pager unless following output (-f) or user passed --no-pager
pager() {
	if [ "${1:-}" != "true" ] && [ "${2:-}" != "true" ] && [ -t 1 ]; then less -FRX; else cat; fi
}


PLUGIN_SUMMARY_logs="View app, build, or access logs"

# View app logs (journald), build output, or HTTP access logs
plugin_run_logs() {
	if [ -z "${1:-}" ] || [[ "${1:-}" == --help ]] || [[ "${1:-}" == -h ]]; then plugin_help_logs; return; fi
	escalate logs "$@"
	local app_name=$1; shift
	if [ ! -d "$DEPLOY_ROOT/$app_name" ]; then die "App $app_name does not exist"; fi

	local stream="app"
	case "${1:-}" in app|build|access) stream=$1; shift ;; esac

	# Options: -f and -n apply to all streams; --since/--before apply to app and access
	local follow=false no_pager=false num="" since="" before="" release=""
	while [ $# -gt 0 ]; do
		case "$1" in
			-f|--follow) follow=true ;;
			-n)          shift; num=$1 ;;
			--since)     shift; since=$1 ;;
			--before)    shift; before=$1 ;;
			--no-pager)  no_pager=true ;;
			--release)   shift; release=$1 ;;
			*)           die "Unknown option: $1" ;;
		esac
		shift
	done

	case "$stream" in
		# --- App logs: container stdout/stderr via journald ---
		app)
			local unit
			if [ -n "$release" ]; then
				unit="deploy-${app_name}--${release}"
			else
				unit="deploy-${app_name}--*"
			fi
			local args=(--no-pager -u "$unit")
			$follow          && args+=(-f)
			[ -n "$num" ]    && args+=(-n "$num")
			[ -n "$since" ]  && args+=(--since "$since")
			[ -n "$before" ] && args+=(--before "$before")
			journalctl "${args[@]}" | pager "$follow" "$no_pager"
			;;
		# --- Build logs: saved output from the build step ---
		build)
			local rid="${release:-$(get_active_release "$app_name")}" || die "No active release"
			local log_file="$DEPLOY_ROOT/$app_name/releases/$rid/build.log"
			if [ ! -f "$log_file" ]; then die "No build log found${release:+ for release $release}"; fi
			{ if $follow; then tail -f ${num:+-n "$num"} "$log_file"
			  else { cat "$log_file"; } | { [ -n "$num" ] && tail -n "$num" || cat; }
			  fi } | pager "$follow" "$no_pager"
			;;
		# --- Access logs: Caddy JSON logs, parsed into human-readable format ---
		access)
			local log_file="$DEPLOY_ROOT/$app_name/access.log"
			if [ ! -f "$log_file" ]; then die "No access log found for $app_name"; fi
			local since_ts="" before_ts=""
			[ -n "$since" ]  && { since_ts=$(date -d "$since" +%s 2>/dev/null)  || die "Invalid --since date: $since"; }
			[ -n "$before" ] && { before_ts=$(date -d "$before" +%s 2>/dev/null) || die "Invalid --before date: $before"; }
			# Parse Caddy JSON log lines into human-readable format
			local jq_filter='select(
				(if $since  != "" then .ts >= ($since  | tonumber) else true end) and
				(if $before != "" then .ts <= ($before | tonumber) else true end) and
				(if $release != "" then .release == $release else true end)
			) | [(.ts | strftime("%Y/%m/%d %H:%M:%S")), .request.method, .request.uri,
			      (.status | tostring), (.size | tostring), "-", (((.duration * 1000) | floor | tostring) + " ms")] | join(" ")'
			{
				if $follow; then tail -f ${num:+-n "$num"} "$log_file"
				else cat "$log_file"
				fi \
				| jq -r --arg since "$since_ts" --arg before "$before_ts" --arg release "$release" "$jq_filter" \
				| { [ -n "$num" ] && ! $follow && tail -n "$num" || cat; }
			} | pager "$follow" "$no_pager"
			;;
	esac
}

PLUGIN_SUMMARY_domains="Manage domains for an app"

# Manage domains for an app
plugin_run_domains() {
	subcmd list   "<app-name>"          "List domains for an app"
	subcmd add    "<app-name> <domain>" "Add a domain"
	subcmd remove "<app-name> <domain>" "Remove a domain"
	dispatch "$@"
}

domains:list() {
	require_app "${2:-}"
	get_conf_all "$server_conf" "domain"
}

domains:add() {
	require_app "${2:-}"
	local domain=${3:-}
	require_arg "$domain" "Usage: deploy domains add <app-name> <domain>"
	check_domain_collision "$domain" "$app_name"
	touch "$server_conf"
	conf_add "$server_conf" "domain" "$domain"
	success "Added domain $domain to $app_name"
	reconfigure "$app_name"
}

domains:remove() {
	require_app "${2:-}"
	local domain=${3:-}
	require_arg "$domain" "Usage: deploy domains remove <app-name> <domain>"
	if ! grep -q "^domain=${domain}$" "$server_conf" 2>/dev/null; then
		die "Domain $domain not found for $app_name"
	fi
	conf_remove_value "$server_conf" "domain" "$domain"
	success "Removed domain $domain from $app_name"
	reconfigure "$app_name"
}

PLUGIN_SUMMARY_env="Manage environment variables for an app"

# Manage environment variables for an app
plugin_run_env() {
	subcmd list   "<app-name>"           "List environment variables"
	subcmd set    "<app-name> KEY=value" "Set an environment variable"
	subcmd remove "<app-name> KEY"       "Remove an environment variable"
	dispatch "$@"
}

env:list() {
	require_app "${2:-}"
	get_conf_all "$server_conf" "env"
}
env:set() {
	require_app "${2:-}"
	local kv=${3:-}
	require_arg "$kv" "Usage: deploy env set <app-name> KEY=value"
	[[ "$kv" == *=* ]] || die "Expected KEY=value, got: $kv"
	local key="${kv%%=*}"
	touch "$server_conf"
	conf_remove_key "$server_conf" "env=${key}"  # replace semantics
	conf_add "$server_conf" "env" "$kv"
	success "Set $key for $app_name"
	reconfigure "$app_name"
}
env:remove() {
	require_app "${2:-}"
	local key=${3:-}
	require_arg "$key" "Usage: deploy env remove <app-name> KEY"
	if ! grep -q "^env=${key}=" "$server_conf" 2>/dev/null; then
		die "Environment variable $key not found for $app_name"
	fi
	conf_remove_key "$server_conf" "env=${key}"
	success "Removed $key from $app_name"
	reconfigure "$app_name"
}


PLUGIN_SUMMARY_apps="Manage apps (create, list, info, restart, rollback, remove)"

# App management namespace
plugin_run_apps() {
	subcmd list     ""             "List all apps"
	subcmd create   "<name>"       "Create a new app"
	subcmd info     "<name>"       "Show app status and configuration"
	subcmd restart  "<name>"       "Restart an app's container"
	subcmd rollback "<name>"       "Roll back to a previous release"
	subcmd remove   "<name> [-f]"  "Remove an app and all its files"
	dispatch "$@"
}

apps:restart() {
	require_arg "${2:-}" "Usage: deploy restart <app-name>"
	local app_name=$2
	local release_id; release_id=$(get_active_release "$app_name") || die "No active release"
	log "🔄 Restarting $app_name..."
	systemctl restart "deploy-${app_name}--${release_id}" || die "Failed to restart $app_name"
	success "Restarted"
}

apps:rollback() {
	require_arg "${2:-}" "Usage: deploy rollback <app-name> [--release <id>]"
	local app_name=$2; shift 2; local app_dir="$DEPLOY_ROOT/$app_name"
	if [ ! -d "$app_dir" ]; then die "App $app_name does not exist"; fi

	local current_release; current_release=$(readlink "$app_dir/current" 2>/dev/null)
	if [ -z "$current_release" ]; then die "No current release for $app_name"; fi

	# Parse --release option
	local target_id=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--release) shift; target_id=$1 ;;
			*) die "Unknown option: $1" ;;
		esac
		shift
	done

	local target=""
	if [ -n "$target_id" ]; then
		target="$app_dir/releases/$target_id"
		if [ ! -d "$target" ]; then die "Release $target_id not found"; fi
	else
		for dir in "$app_dir/releases"/*/; do
			dir="${dir%/}"
			[[ "$dir" == */"$(basename "$current_release")" ]] && continue
			[[ "$dir" > "$target" ]] && target="$dir"
		done
		if [ -z "$target" ]; then die "No previous release to roll back to"; fi
	fi

	log "⏪ Rolling back $app_name from $(basename "$current_release") to $(basename "$target")..."

	local new_release; new_release=$(date +%Y%m%d%H%M%S)
	clone_release "$app_name" "$(basename "$target")" "$new_release"

	cmd_configure "$app_name" "$new_release"
	activate_release "$app_name" "$new_release"
}

apps:remove() {
	require_arg "${2:-}" "Usage: deploy remove <app-name> [-f]"
	local force=false; [[ "${3:-}" == "-f" || "${3:-}" == "--force" ]] && force=true
	local app_name=$2; local app_dir="$DEPLOY_ROOT/$app_name"
	if [ ! -d "$app_dir" ]; then die "App $app_name does not exist"; fi
	if ! $force; then
		read -rp "Remove $app_name? This will delete all app files. Type 'yes' to confirm: " confirm
		if [ "$confirm" != "yes" ]; then log "Aborted."; exit 1; fi
	fi
	log "🗑️  Removing app: $app_name"
	for dir in "$app_dir/releases"/*/; do
		[ -d "$dir" ] || continue
		teardown_release "$app_name" "$(basename "$dir")"
	done
	systemctl daemon-reload
	local ports_file="$DEPLOY_ROOT/.internal/ports"
	if [ -f "$ports_file" ]; then sed -i "/^${app_name}--/d" "$ports_file"; fi
	log "  Removing app files..."
	rm -rf "$app_dir"
	log "  Reloading Caddy..."
	caddy reload --config "$DEPLOY_ROOT/.internal/Caddyfile" 2>/dev/null || true
	success "Removed $app_name"
}

# Internal: deploy an app (called by git post-receive hook)
cmd_deploy_app() {
	require_arg "${1:-}" "Internal error: app name required"
	local app_name=$1; local app_dir="$DEPLOY_ROOT/$app_name"
	local release_id; release_id=$(date +%Y%m%d%H%M%S)
	local release_dir="$app_dir/releases/$release_id"

	local status_file="$app_dir/deploy.status"
	local build_log="$release_dir/build.log"
	local start_time; start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	printf 'status=running\nstarted=%s\npid=%s\n' "$start_time" "$$" > "$status_file"
	_DEPLOY_STATUS_FILE="$status_file"; _DEPLOY_START_TIME="$start_time"
	trap '_deploy_exit_trap' EXIT

	log "📦 Deploying $app_name..."
	local repo_dir; repo_dir=$(pwd)
	unset GIT_DIR
	# Clone rather than checkout so that .git lives inside the release dir. This
	# keeps all git metadata (gitdir pointers, core.worktree, submodule configs)
	# self-relative to the release dir, which means they resolve correctly when
	# the dir is mounted at /build inside the build container.
	git clone --local --quiet "$repo_dir" "$release_dir"
	if [ -f "$release_dir/.gitmodules" ]; then
		log "📦 Initializing submodules..."
		GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" git -C "$release_dir" submodule update --init --recursive
	fi

	local deploy_conf="$release_dir/deploy.conf"
	local start_cmd; start_cmd=$(get_conf "$deploy_conf" "start")
	local build_cmd; build_cmd=$(get_conf "$deploy_conf" "build")

	local server_conf="$app_dir/server.conf"
	local setenv_args=()
	while IFS= read -r env_var; do
		setenv_args+=(--setenv="$env_var")
	done < <(get_conf_all "$server_conf" "env")

	# Container setup has three paths:
	# 1. build + start: build in ephemeral container, which becomes the runtime container
	# 2. build only:    build in ephemeral container, then discard it (static site)
	# 3. start only:    clone base image as runtime container (no build step)
	if [ -n "$build_cmd" ]; then
		local build_dir="$app_dir/machine-build"
		rm -rf "$build_dir"
		cp -a "$DEPLOY_ROOT/.internal/machine" "$build_dir"
		log "🔧 Running build..."
		systemd-nspawn -D "$build_dir" "${setenv_args[@]}" --bind="$release_dir":/build --chdir=/build bash -c "$build_cmd" 2>&1 | tee "$build_log"
		if [ -n "$start_cmd" ]; then
			mv "$build_dir" "$release_dir/machine"
		else
			rm -rf "$build_dir"
		fi
	elif [ -n "$start_cmd" ]; then
		# First container deploy or non-build container: clone base image
		log "🏗️  Cloning base image..."
		cp -a "$DEPLOY_ROOT/.internal/machine" "$release_dir/machine"
	fi

	if [ -n "$start_cmd" ]; then
		rm -f "$release_dir/machine/etc/machine-id"
		systemd-machine-id-setup --root="$release_dir/machine"
	fi

	cmd_configure "$app_name" "$release_id"
	activate_release "$app_name" "$release_id"

	# Prune old releases (subshell so cd doesn't affect the caller)
	(
		cd "$app_dir/releases" && ls -t | tail -n +$((MAX_RELEASES + 1)) | while read -r old; do
			teardown_release "$app_name" "$old"
			rm -rf "$old"
		done
	)
	systemctl daemon-reload
	log "🧹 Cleaned up old releases"
	success "Deployed $app_name ($release_id)"

	trap - EXIT
	local finish_time; finish_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	printf 'status=success\nstarted=%s\nfinished=%s\n' "$start_time" "$finish_time" > "$status_file"
	_DEPLOY_STATUS_FILE=""
}

# Internal: generate Caddy config and systemd service for a release
cmd_configure() {
	require_arg "${1:-}" "Internal error: app name required"
	require_arg "${2:-}" "Internal error: release id required"
	local app_name=$1 release_id=$2; local app_dir="$DEPLOY_ROOT/$app_name"
	local release_dir="$app_dir/releases/$release_id"
	local deploy_conf="$release_dir/deploy.conf" server_conf="$app_dir/server.conf"
	local start_cmd; start_cmd=$(get_conf "$deploy_conf" "start")
	local domains; domains=$(get_conf_all "$server_conf" "domain" | tr '\n' ' '); domains="${domains% }"
	local d; for d in $domains; do check_domain_collision "$d" "$app_name"; done
	local port; port=$(assign_port "$app_name" "$release_id")

	log "🔄 Configuring $app_name..."

	local static_dir; static_dir=$(get_conf "$deploy_conf" "assets")
	local spa_mode; spa_mode=$(get_conf "$deploy_conf" "spa")

	# --- Generate Caddy config ---
	if [ -n "$domains" ]; then
		local handler
		if [ -z "$start_cmd" ] && [ "$spa_mode" = "true" ]; then
			handler="import spa"
		elif [ -z "$start_cmd" ]; then
			handler="import static"
		elif [ -n "$static_dir" ]; then
			handler="import assets $port"
		else
			handler="import proxy $port"
		fi

		local headers=""
		while IFS= read -r h; do
			local path="${h%% *}" rest="${h#* }" name value
			name="${rest%%:*}"
			value="${rest#*: }"
			[[ "$value" == *" "* ]] && value="\"$value\""
			headers+="    header $path $name $value"$'\n'
		done < <(get_conf_all "$deploy_conf" "header")

		write_app_caddy_conf "$app_dir/caddy.conf" "$domains" "$app_dir" "$release_id" "$static_dir" "$headers" "$handler"
	else
		true > "$app_dir/caddy.conf"
	fi

	# --- Generate systemd service unit ---
	if [ -n "$start_cmd" ]; then
		local svc="deploy-${app_name}--${release_id}"

		local nspawn_args=(
			--quiet
			"--machine=$svc"
			-D "$release_dir/machine"
			--chdir=/app
			"--setenv=PORT=$port"
		)

		while IFS= read -r env_var; do
			nspawn_args+=("--setenv=$env_var")
		done < <(get_conf_all "$server_conf" "env")

		nspawn_args+=(
			"--bind=$release_dir:/app"
			"--bind=$app_dir/data:/data"
			--bind-ro=/etc/resolv.conf
		)

		while IFS= read -r mount; do
			if [[ "$mount" =~ ^([^:]+):([^:]+)(:ro)?$ ]]; then
				local host_path="${BASH_REMATCH[1]}" container_path="${BASH_REMATCH[2]}"
				local flag="--bind${BASH_REMATCH[3]:+-ro}"
				nspawn_args+=("$flag=$host_path:$container_path")
			else
				error "Skipping invalid mount: $mount"; continue
			fi
			[ ! -e "$host_path" ] && { error "Host path does not exist: $host_path (creating directory)"; mkdir -p "$host_path"; }
		done < <(get_conf_all "$server_conf" "mount")

		nspawn_args+=(bash -c "$start_cmd")

		mkdir -p "$app_dir/data"
		write_app_service "$release_dir/${svc}.service" "$app_name" "$release_id" "${nspawn_args[@]}"
	fi

	success "Configured"
}

# Remove all deploy.sh system changes (must be run as root)
cmd_uninstall() {
	if [ "$(id -u)" -ne 0 ]; then die "deploy uninstall must be run as root"; fi
	local force=false; [[ "${1:-}" == "-f" || "${1:-}" == "--force" ]] && force=true
	if ! $force; then
		error "This will remove all deploy.sh system changes, including all apps and containers."
		read -rp "Type 'yes' to confirm: " confirm
		if [ "$confirm" != "yes" ]; then log "Aborted."; exit 1; fi
	fi

	log "🗑️  Uninstalling deploy.sh..."

	for svc_file in /etc/systemd/system/deploy-*.service; do
		[ -f "$svc_file" ] || continue
		local svc; svc=$(basename "$svc_file" .service)
		systemctl stop "$svc" 2>/dev/null || true
		systemctl disable "$svc" 2>/dev/null || true
	done
	if systemctl is-active --quiet caddy 2>/dev/null; then log "  Stopping caddy..."; systemctl stop caddy; fi
	if systemctl is-enabled --quiet caddy 2>/dev/null; then systemctl disable caddy; fi
	rm -f /usr/local/bin/caddy

	rm -f /etc/sudoers.d/deploy
	systemctl daemon-reload

	rm -rf "$DEPLOY_ROOT"
	if id "$DEPLOY_USER" &>/dev/null; then userdel -r "$DEPLOY_USER"; fi

	success "Uninstalled"
}

cmd_help() {
	cat <<-HELP
	📦 deploy.sh — minimal VPS deployment system

	Usage: deploy <command> [args...]

	Commands:
	HELP

	# inline plugins
	local fn
	for fn in $(declare -F | awk '/plugin_run_/{print $3}' | sort); do
		local name="${fn#plugin_run_}"
		local summary_var="PLUGIN_SUMMARY_${name}"
		printf "  %-20s %s\n" "$name" "${!summary_var:-}"
	done

	# External plugins
	if [ -d "$PLUGIN_DIR" ]; then
		local plugin_file
		for plugin_file in "$PLUGIN_DIR"/*; do
			[ -f "$plugin_file" ] || continue
			local name; name=$(basename "$plugin_file")
			# skip if inline version exists
			declare -f "plugin_run_${name}" > /dev/null 2>&1 && continue
			local PLUGIN_SUMMARY=""
			source "$plugin_file"
			printf "  %-20s %s\n" "$name" "$PLUGIN_SUMMARY"
		done
	fi

	cat <<-HELP

	Shortcuts:
	  create, list, info, restart, rollback, remove → deploy apps <cmd>

	System:
	  init                Initialize the deployment system
	  uninstall [-f]      Remove all deploy.sh system changes

	Run "deploy <command> --help" for details on any command.

	deploy.conf (in repo root):
	  start=<cmd>         Start command (receives \$PORT; omit for static sites)
	  build=<cmd>         Build command (runs in ephemeral container)
	  assets=<dir>        Static assets directory (default: repo root)
	  spa=true            Single-page app mode
	  header=<path> <Name>: <value>   Response header (repeatable)
	HELP
}

plugin_help_logs() {
	cat <<-HELP
	Usage: deploy logs <app-name> [app|build|access] [options...]

	Streams:
	  app (default)       Container stdout/stderr (journald)
	  build               Build step output
	  access              HTTP access logs (Caddy)

	Options:
	  -f, --follow        Follow log output
	  -n N                Show last N lines
	  --since DATE        Show logs since date (app/access only)
	  --before DATE       Show logs before date (app/access only)
	  --release ID        Filter by release
	  --no-pager          Disable pager
	HELP
}

case "${1:-help}" in
	help|--help|-h) cmd_help ;;
	init)           cmd_init ;;
	uninstall)      shift; cmd_uninstall "$@" ;;

	# shortcuts → delegate to apps plugin
	create|list|info|restart|rollback|remove) load_plugin apps "$@" ;;

	# internal (git hooks, other commands)
	_deploy-app)    shift; cmd_deploy_app "$@" ;;
	_configure)     shift; cmd_configure "$@" ;;

	# try as plugin
	*)              load_plugin "$@" ;;
esac
