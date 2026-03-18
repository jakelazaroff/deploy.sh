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

# --- utilities ---

red() { printf "\033[31m$1\033[0m"; }
green() { printf "\033[32m$1\033[0m"; }
dim() { printf "\033[2m$1\033[0m"; }

log() { echo "$@" >&2; }              # print to stderr
step() { log "$(dim "→") $@"; }      # print a progress step
success() { log "$(green "✓") $@"; } # print a success message
error() { log "$(red "✗") $@"; }     # print an error message
die() { error "$1"; exit 1; }        # print an error and exit

require_arg() { [ -n "${1:-}" ] || die "$2"; }

require_app() {
	require_arg "${1:-}" "Usage: deploy $PLUGIN_NAME <subcmd> <app>"
	[ -d "$DEPLOY_ROOT/$1" ] || die "App $1 does not exist"
	app_dir="$DEPLOY_ROOT/$1"
}

# register a subcommand: name | usage | description
subcmd() { SUBCMDS_DATA="${SUBCMDS_DATA}${1}|${2}|${3}"$'\n'; }

# validate subcmd, escalate, then call <plugin>:<subcmd> "$@"
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
	local domains_file
	for domains_file in "$DEPLOY_ROOT"/*/domains; do
		[ -f "$domains_file" ] || continue
		local app_name; app_name=$(basename "$(dirname "$domains_file")")
		[ "$app_name" = "$exclude_app" ] && continue
		grep -qx "$domain" "$domains_file" 2>/dev/null && die "Domain $domain already used by $app_name"
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
	local app_name=$1 slot=$2
	local key="${app_name}--${slot}"
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

# Re-configure and restart the active slot.
# Called by deploy-watch@.service when domains or env files change.
# Returns 0 (no-op) if app hasn't been deployed yet.
cmd_reconcile() {
	local app_name=$1
	local slot; slot=$(cat "$DEPLOY_ROOT/$app_name/active" 2>/dev/null) || return 0
	cmd_configure "$app_name" "$slot"
	local start_cmd; start_cmd=$(get_conf "$DEPLOY_ROOT/$app_name/$slot/deploy.conf" "start")
	if [ -n "$start_cmd" ]; then
		systemctl restart "deploy@deploy-${app_name}--${slot}" || true
	fi
	reload_caddy
}

teardown_slot() {
	local app_name=$1 slot=$2
	systemctl stop "deploy@deploy-${app_name}--${slot}" 2>/dev/null || true
	sed -i "/^${app_name}--${slot}=/d" "$DEPLOY_ROOT/.internal/ports"
}

wait_for_port() {
	local port=$1 i=$((PORT_WAIT_SECONDS * 2))
	while ! ss -tln "sport = :$port" | grep -q LISTEN; do
		sleep 0.5; ((i--)) || return 1
	done
}

other_slot() { [ "$1" = "blue" ] && echo "green" || echo "blue"; }

reload_caddy() { systemctl reload caddy 2>/dev/null || true; }

# Zero-downtime slot swap: start new container, wait for it, teardown old, update active pointer.
activate_slot() {
	local app_name=$1 new_slot=$2 old_slot=${3:-}
	local start_cmd; start_cmd=$(get_conf "$DEPLOY_ROOT/$app_name/$new_slot/deploy.conf" "start")
	if [ -n "$start_cmd" ]; then
		local port; port=$(assign_port "$app_name" "$new_slot")
		systemctl start "deploy@deploy-${app_name}--${new_slot}"
		if ! wait_for_port "$port"; then
			teardown_slot "$app_name" "$new_slot"
			die "Instance failed to start on port $port after ${PORT_WAIT_SECONDS}s"
		fi
		[ -n "$old_slot" ] && teardown_slot "$app_name" "$old_slot"
	fi
	echo "$new_slot" > "$DEPLOY_ROOT/$app_name/active"
	reload_caddy
}

load_plugin() {
	local cmd="$1"; shift
	PLUGIN_NAME="$cmd"
	SUBCMDS_DATA=""

	local plugin_file="$PLUGIN_DIR/$cmd"
	[ -f "$plugin_file" ] && source "$plugin_file"

	if declare -f "plugin:${cmd}" > /dev/null 2>&1; then
		"plugin:${cmd}" "$@"
	else
		die "Unknown command: $cmd. Run \"deploy help\" for usage"
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


write_app_caddy_conf() {
	local dest=$1 domains=$2 app_dir=$3 slot=$4 static_dir=$5 headers=$6 handler=$7
	cat > "$dest" <<-CADDY
	$domains {
	    root * $app_dir/$slot${static_dir:+/$static_dir}
	    $headers
	    $handler
	        import logging "$app_dir"
	}
	CADDY
	caddy fmt "$dest" --overwrite
}

# Initialize the deployment system (must be run as root)
cmd_init() {
	if [ "$(id -u)" -ne 0 ]; then die "deploy init must be run as root"; fi
	step "Setting up deploy.sh at $DEPLOY_ROOT..."

	# install system dependencies (including caddy from its official repo)
	if command -v apt-get &>/dev/null; then
		apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
		curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
			| gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
		curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
			| tee /etc/apt/sources.list.d/caddy-stable.list
		chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
		apt-get update -q
		apt-get install -y caddy systemd-container jq
	elif command -v dnf &>/dev/null; then
		dnf install -y dnf5-plugins
		dnf copr enable -y @caddy/caddy
		dnf install -y caddy systemd-container jq
	else
		die "Unsupported package manager — install caddy, systemd-container, and jq manually"
	fi

	# create deploy user
	id "$DEPLOY_USER" &>/dev/null || { useradd -m -s /bin/bash "$DEPLOY_USER"; success "Created $DEPLOY_USER user"; }

	# copy SSH keys
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
	fi

	# create deploy directory — group-writable so deploy group members can script against files directly
	mkdir -p "$DEPLOY_ROOT/.internal" "$PLUGIN_DIR"
	chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_ROOT"
	chmod 2775 "$DEPLOY_ROOT"

	# pull Alpine base image
	if [ ! -d "$DEPLOY_ROOT/.internal/machine" ]; then
		step "Pulling Alpine base image..."
		local arch; arch=$(uname -m)
		local alpine_file; alpine_file=$(curl -fsSL "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$arch/latest-releases.yaml" | grep -oE "alpine-minirootfs-[0-9]+\.[0-9]+\.[0-9]+-${arch}\.tar\.gz" | head -1)
		if [ -z "$alpine_file" ]; then die "Could not find Alpine minirootfs for $arch"; fi
		mkdir -p "$DEPLOY_ROOT/.internal/machine"
		curl -fsSL "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$arch/$alpine_file" | tar -xz -C "$DEPLOY_ROOT/.internal/machine"
		systemd-nspawn -D "$DEPLOY_ROOT/.internal/machine" /bin/sh -c "apk update && apk add --no-cache bash"
		success "Base image ready"
	fi

	# --- create Caddyfile ---
	if [ ! -f "$DEPLOY_ROOT/.internal/Caddyfile" ]; then
		read -rp "📧 Email for Let's Encrypt certificates: " acme_email
		if [ -z "$acme_email" ]; then die "Email is required for HTTPS certificate provisioning"; fi
		write_global_caddyfile "$DEPLOY_ROOT/.internal/Caddyfile" "$acme_email"
		success "Created Caddyfile"
	fi

	# override caddy's service to use our Caddyfile
	mkdir -p /etc/systemd/system/caddy.service.d
	cat > /etc/systemd/system/caddy.service.d/deploy.conf <<-OVERRIDE
	[Service]
	ExecStart=
	ExecStart=/usr/bin/caddy run --config $DEPLOY_ROOT/.internal/Caddyfile
	ExecReload=
	ExecReload=/usr/bin/caddy reload --config $DEPLOY_ROOT/.internal/Caddyfile
	OVERRIDE
	systemctl daemon-reload
	systemctl enable --now caddy

	# create deploy@ template service
	cat > "$DEPLOY_ROOT/.internal/deploy@.service" <<-SERVICE
	[Unit]
	Description=deploy.sh container %i
	After=network.target

	[Service]
	Type=simple
	ExecStart=/usr/local/bin/deploy _start %i
	Restart=on-failure
	KillMode=mixed
	SERVICE
	ln -sf "$DEPLOY_ROOT/.internal/deploy@.service" /etc/systemd/system/deploy@.service

	# create deploy-watch@ template units
	cat > "$DEPLOY_ROOT/.internal/deploy-watch@.path" <<-PATH
	[Unit]
	Description=Watch deploy.sh config for %i

	[Path]
	PathChanged=$DEPLOY_ROOT/%i/domains
	PathChanged=$DEPLOY_ROOT/%i/env
	PathChanged=$DEPLOY_ROOT/%i/mounts

	[Install]
	WantedBy=multi-user.target
	PATH
	ln -sf "$DEPLOY_ROOT/.internal/deploy-watch@.path" /etc/systemd/system/deploy-watch@.path

	cat > "$DEPLOY_ROOT/.internal/deploy-watch@.service" <<-SERVICE
	[Unit]
	Description=Reconcile deploy.sh config for %i

	[Service]
	Type=oneshot
	ExecStart=/usr/local/bin/deploy reconcile %i
	SERVICE
	ln -sf "$DEPLOY_ROOT/.internal/deploy-watch@.service" /etc/systemd/system/deploy-watch@.service

	systemctl daemon-reload

	# set up sudoers
	cat > /etc/sudoers.d/deploy <<-SUDOERS
	Defaults env_keep += "SSH_AUTH_SOCK"
	$DEPLOY_USER ALL=(root) NOPASSWD: /usr/local/bin/deploy *
	ALL ALL=(deploy) NOPASSWD: /usr/local/bin/deploy *
	SUDOERS
	chmod 0440 /etc/sudoers.d/deploy
	success "Created /etc/sudoers.d/deploy"

	success "deploy.sh initialized"
}

# Pipe to pager unless following output (-f) or user passed --no-pager
pager() {
	if [ "${1:-}" != "true" ] && [ "${2:-}" != "true" ] && [ -t 1 ]; then less -FRX; else cat; fi
}

# --- apps plugin ---

PLUGIN_SUMMARY_apps="Manage apps"

plugin:apps() {
	subcmd create   "<name>"       "Create a new app"
	subcmd list     ""             "List all apps"
	subcmd info     "<name>"       "Show app status and configuration"
	subcmd restart  "<name>"       "Restart an app's container"
	subcmd rollback "<name>"       "Roll back to a previous release"
	subcmd remove   "<name> [-f]"  "Remove an app and all its files"
	dispatch "$@"
}

apps:create() {
	require_arg "${2:-}" "Usage: deploy create <app>"
	local app_name=$2; local app_dir="$DEPLOY_ROOT/$app_name"
	if [[ "$app_name" == .* ]]; then die "App name cannot start with '.'"; fi
	if [ -d "$app_dir" ]; then die "App $app_name already exists"; fi

	step "Creating app: $app_name"
	mkdir -p "$app_dir"/repo.git
	git init --bare --initial-branch=main "$app_dir/repo.git"

	cat > "$app_dir/repo.git/hooks/post-receive" <<-HOOK
	#!/bin/bash
	sudo /usr/local/bin/deploy _deploy-app $app_name
	HOOK
	chmod +x "$app_dir/repo.git/hooks/post-receive"
	chown -R "$DEPLOY_USER:$DEPLOY_USER" "$app_dir"
	chmod 2775 "$app_dir"
	touch "$app_dir/domains" "$app_dir/env" "$app_dir/mounts"
	chmod 664 "$app_dir/domains" "$app_dir/env" "$app_dir/mounts"
	systemctl enable --now "deploy-watch@${app_name}.path"

	success "Created app: $app_name"
	log ""
	log "Next steps:"
	log "  git remote add deploy $DEPLOY_USER@$(hostname):$app_dir/repo.git"
	log "  git push deploy main"
	log ""
}

apps:list() {
	for app_dir in "$DEPLOY_ROOT"/*/; do
		[ -d "$app_dir" ] || continue
		[[ "$(basename "$app_dir")" == .* ]] && continue
		printf '%s\n' "$(basename "$app_dir")"
	done
}

apps:info() {
	require_app "${2:-}"; local app_name=$2
	local active_slot; active_slot=$(cat "$app_dir/active" 2>/dev/null || echo "")
	local deploy_conf="$app_dir/$active_slot/deploy.conf"

	local start_cmd="" status="" assets="" spa=""
	if [ -f "$deploy_conf" ]; then
		start_cmd=$(get_conf "$deploy_conf" "start")
		if [ -n "$start_cmd" ] && [ -n "$active_slot" ]; then
			status=$(systemctl is-active "deploy-${app_name}--${active_slot}" 2>/dev/null || true)
		fi
		assets=$(get_conf "$deploy_conf" "assets")
		spa=$(get_conf "$deploy_conf" "spa")
	fi
	local domains_list; domains_list=$(cat "$app_dir/domains" 2>/dev/null || true)

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
	[ -n "$active_slot" ] && echo "┆ Slot:    $active_slot"
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

apps:restart() {
	require_app "${2:-}"; local app_name=$2
	local slot; slot=$(cat "$app_dir/active" 2>/dev/null) || die "No active slot"
	step "Restarting $app_name..."
	systemctl restart "deploy@deploy-${app_name}--${slot}" || die "Failed to restart $app_name"
	success "Restarted"
}

apps:rollback() {
	require_app "${2:-}"; local app_name=$2
	local active_slot; active_slot=$(cat "$app_dir/active" 2>/dev/null) || die "Nothing deployed"
	local prev_slot; prev_slot=$(other_slot "$active_slot")
	[ -d "$app_dir/$prev_slot" ] || die "No previous release to roll back to"

	activate_slot "$app_name" "$prev_slot" "$active_slot"
	success "Rolled back $app_name"
}

apps:remove() {
	require_app "${2:-}"; local app_name=$2
	local force=false; [[ "${3:-}" == "-f" || "${3:-}" == "--force" ]] && force=true
	if ! $force; then
		read -rp "Remove $app_name? This will delete all app files. Type 'yes' to confirm: " confirm
		if [ "$confirm" != "yes" ]; then log "Aborted."; exit 1; fi
	fi
	step "Removing $app_name..."
	systemctl disable --now "deploy-watch@${app_name}.path" 2>/dev/null || true
	teardown_slot "$app_name" "blue"
	teardown_slot "$app_name" "green"
	systemctl daemon-reload
	local ports_file="$DEPLOY_ROOT/.internal/ports"
	if [ -f "$ports_file" ]; then sed -i "/^${app_name}--/d" "$ports_file"; fi
	step "Removing app files..."
	rm -rf "$app_dir"
	reload_caddy
	success "Removed $app_name"
}

# --- domains plugin ---

PLUGIN_SUMMARY_domains="Manage domains for an app"

plugin:domains() {
	subcmd list   "<app>"          "List domains for an app"
	subcmd add    "<app> <domain>" "Add a domain"
	subcmd remove "<app> <domain>" "Remove a domain"
	dispatch "$@"
}

domains:list() {
	require_app "${2:-}"
	cat "$app_dir/domains" 2>/dev/null || true
}

domains:add() {
	require_app "${2:-}"
	local domain=${3:-}
	require_arg "$domain" "Usage: deploy domains add <app> <domain>"
	check_domain_collision "$domain" "$app_name"
	echo "$domain" >> "$app_dir/domains"
	success "Added domain $domain to $app_name"
	systemctl start "deploy-watch@${app_name}.service" || die "Reconcile failed — run: journalctl -u deploy-watch@${app_name}.service"
}

domains:remove() {
	require_app "${2:-}"
	local domain=${3:-}
	require_arg "$domain" "Usage: deploy domains remove <app> <domain>"
	sed -i "/^${domain}$/d" "$app_dir/domains"
	success "Removed domain $domain from $app_name"
	systemctl start "deploy-watch@${app_name}.service" || die "Reconcile failed — run: journalctl -u deploy-watch@${app_name}.service"
}

# --- env plugin ---

PLUGIN_SUMMARY_env="Manage environment variables for an app"

plugin:env() {
	subcmd list   "<app>"           "List environment variables"
	subcmd set    "<app> KEY=value" "Set an environment variable"
	subcmd remove "<app> KEY"       "Remove an environment variable"
	dispatch "$@"
}

env:list() {
	require_app "${2:-}"
	cat "$app_dir/env" 2>/dev/null || true
}

env:set() {
	require_app "${2:-}"
	local kv=${3:-}
	require_arg "$kv" "Usage: deploy env set <app> KEY=value"
	[[ "$kv" == *=* ]] || die "Expected KEY=value, got: $kv"
	local key="${kv%%=*}"
	# replace semantics: remove existing key then append
	sed -i "/^${key}=/d" "$app_dir/env"
	echo "$kv" >> "$app_dir/env"
	success "Set $key for $app_name"
	systemctl start "deploy-watch@${app_name}.service" || die "Reconcile failed — run: journalctl -u deploy-watch@${app_name}.service"
}

env:remove() {
	require_app "${2:-}"
	local key=${3:-}
	require_arg "$key" "Usage: deploy env remove <app> KEY"
	sed -i "/^${key}=/d" "$app_dir/env"
	success "Removed $key from $app_name"
	systemctl start "deploy-watch@${app_name}.service" || die "Reconcile failed — run: journalctl -u deploy-watch@${app_name}.service"
}

# --- logs plugin ---

PLUGIN_SUMMARY_logs="View app, build, or access logs"

plugin:logs() {
	if [ -z "${1:-}" ] || [[ "${1:-}" == --help ]] || [[ "${1:-}" == -h ]]; then plugin_help_logs; return; fi
	escalate logs "$@"
	local app_name=$1; shift
	if [ ! -d "$DEPLOY_ROOT/$app_name" ]; then die "App $app_name does not exist"; fi

	local stream="app"
	case "${1:-}" in app|build|access) stream=$1; shift ;; esac

	# Options: -f and -n apply to all streams; --since/--before apply to app and access
	local follow=false no_pager=false num="" since="" before=""
	while [ $# -gt 0 ]; do
		case "$1" in
			-f|--follow) follow=true ;;
			-n)          shift; num=$1 ;;
			--since)     shift; since=$1 ;;
			--before)    shift; before=$1 ;;
			--no-pager)  no_pager=true ;;
			*)           die "Unknown option: $1" ;;
		esac
		shift
	done

	case "$stream" in
		# --- App logs: container stdout/stderr via journald ---
		app)
			local args=(--no-pager -u "deploy-${app_name}--*")
			$follow          && args+=(-f)
			[ -n "$num" ]    && args+=(-n "$num")
			[ -n "$since" ]  && args+=(--since "$since")
			[ -n "$before" ] && args+=(--before "$before")
			journalctl "${args[@]}" | pager "$follow" "$no_pager"
			;;
		# --- Build logs: saved output from the build step ---
		build)
			local slot; slot=$(cat "$DEPLOY_ROOT/$app_name/active" 2>/dev/null) || die "No active slot"
			local log_file="$DEPLOY_ROOT/$app_name/$slot/build.log"
			if [ ! -f "$log_file" ]; then die "No build log found for $app_name"; fi
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
				(if $before != "" then .ts <= ($before | tonumber) else true end)
			) | [(.ts | strftime("%Y/%m/%d %H:%M:%S")), .request.method, .request.uri,
			      (.status | tostring), (.size | tostring), "-", (((.duration * 1000) | floor | tostring) + " ms")] | join(" ")'
			{
				if $follow; then tail -f ${num:+-n "$num"} "$log_file"
				else cat "$log_file"
				fi \
				| jq -r --arg since "$since_ts" --arg before "$before_ts" "$jq_filter" \
				| { [ -n "$num" ] && ! $follow && tail -n "$num" || cat; }
			} | pager "$follow" "$no_pager"
			;;
	esac
}

# Internal: deploy an app (called by git post-receive hook)
cmd_deploy_app() {
	require_arg "${1:-}" "Internal error: app name required"
	local app_name=$1; local app_dir="$DEPLOY_ROOT/$app_name"

	# build into whichever slot isn't currently active
	local active_slot; active_slot=$(cat "$app_dir/active" 2>/dev/null || echo "")
	local next_slot; next_slot=$(other_slot "$active_slot")
	local release_dir="$app_dir/$next_slot"

	local status_file="$app_dir/deploy.status"
	local build_log="$release_dir/build.log"
	local start_time; start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	printf 'status=running\nstarted=%s\npid=%s\n' "$start_time" "$$" > "$status_file"
	_DEPLOY_STATUS_FILE="$status_file"; _DEPLOY_START_TIME="$start_time"
	trap '_deploy_exit_trap' EXIT

	step "Deploying $app_name..."
	rm -rf "$release_dir"
	local repo_dir; repo_dir=$(pwd)
	unset GIT_DIR
	# Clone rather than checkout so that .git lives inside the release dir. This
	# keeps all git metadata (gitdir pointers, core.worktree, submodule configs)
	# self-relative to the release dir, which means they resolve correctly when
	# the dir is mounted at /build inside the build container.
	git clone --local --quiet "$repo_dir" "$release_dir"
	if [ -f "$release_dir/.gitmodules" ]; then
		step "Initializing submodules..."
		GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" git -C "$release_dir" submodule update --init --recursive
	fi

	local deploy_conf="$release_dir/deploy.conf"
	local start_cmd; start_cmd=$(get_conf "$deploy_conf" "start")
	local build_cmd; build_cmd=$(get_conf "$deploy_conf" "build")

	local setenv_args=()
	while IFS= read -r env_var; do
		setenv_args+=(--setenv="$env_var")
	done < <(cat "$app_dir/env" 2>/dev/null || true)

	# Container setup has three paths:
	# 1. build + start: build in ephemeral container, which becomes the runtime container
	# 2. build only:    build in ephemeral container, then discard it (static site)
	# 3. start only:    clone base image as runtime container (no build step)
	if [ -n "$build_cmd" ]; then
		local build_dir="$app_dir/machine-build"
		rm -rf "$build_dir"
		cp -a "$DEPLOY_ROOT/.internal/machine" "$build_dir"
		step "Running build..."
		systemd-nspawn -D "$build_dir" "${setenv_args[@]}" --bind="$release_dir":/build --chdir=/build bash -c "$build_cmd" 2>&1 | tee "$build_log"
		[ -n "$start_cmd" ] && mv "$build_dir" "$release_dir/machine" || rm -rf "$build_dir"
	elif [ -n "$start_cmd" ]; then
		step "Cloning base image..."
		cp -a "$DEPLOY_ROOT/.internal/machine" "$release_dir/machine"
	fi

	if [ -n "$start_cmd" ]; then
		rm -f "$release_dir/machine/etc/machine-id"
		systemd-machine-id-setup --root="$release_dir/machine"
	fi

	cmd_configure "$app_name" "$next_slot"

	activate_slot "$app_name" "$next_slot" "$active_slot"
	success "Deployed $app_name"

	trap - EXIT
	local finish_time; finish_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	printf 'status=success\nstarted=%s\nfinished=%s\n' "$start_time" "$finish_time" > "$status_file"
	_DEPLOY_STATUS_FILE=""
}

# Internal: generate Caddy config and systemd service for a slot
cmd_configure() {
	require_arg "${1:-}" "Internal error: app name required"
	require_arg "${2:-}" "Internal error: slot required"
	local app_name=$1 slot=$2; local app_dir="$DEPLOY_ROOT/$app_name"
	local release_dir="$app_dir/$slot"
	local deploy_conf="$release_dir/deploy.conf"
	local start_cmd; start_cmd=$(get_conf "$deploy_conf" "start")
	local domains; domains=$(tr '\n' ' ' < "$app_dir/domains" 2>/dev/null); domains="${domains% }"
	local d; for d in $domains; do check_domain_collision "$d" "$app_name"; done
	local port; port=$(assign_port "$app_name" "$slot")

	step "Configuring $app_name..."

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

		write_app_caddy_conf "$app_dir/caddy.conf" "$domains" "$app_dir" "$slot" "$static_dir" "$headers" "$handler"
	else
		true > "$app_dir/caddy.conf"
	fi

	# --- Generate .nspawn config and start.sh ---
	if [ -n "$start_cmd" ]; then
		mkdir -p "$app_dir/data"
		printf '#!/bin/sh\n%s\n' "$start_cmd" > "$release_dir/start.sh"

		# build up the Environment= lines from the env file
		local env_lines=""
		local env_lines=""
		while IFS= read -r env_var; do
			env_lines+="Environment=${env_var}"$'\n'
		done < <(cat "$app_dir/env" 2>/dev/null || true)

		local mount_lines=""
		while IFS= read -r mount; do
			mount_lines+="Bind=${mount}"$'\n'
		done < <(cat "$app_dir/mounts" 2>/dev/null || true)

		cat > "$release_dir/machine.nspawn" <<-NSPAWN
		[Exec]
		WorkingDirectory=/app
		Parameters=bash /app/start.sh
		Environment=PORT=$port
		${env_lines}
		[Files]
		Bind=$release_dir:/app
		Bind=$app_dir/data:/data
		BindReadOnly=/etc/resolv.conf
		${mount_lines}
		NSPAWN
	fi

	success "Configured"
}

cmd_help() {
	cat <<-HELP
	📦 deploy.sh — minimal VPS deployment system

	Usage: deploy <command> [args...]

	Commands:
	HELP

	# inline plugins
	local fn
	for fn in $(declare -F | awk '/^plugin:/{print $3}' | sort); do
		local name="${fn#plugin:}"
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
			declare -f "plugin:${name}" > /dev/null 2>&1 && continue
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
	  reconcile <app>     Re-apply config from domains/env files

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
	Usage: deploy logs <app> [app|build|access] [options...]

	Streams:
	  app (default)       Container stdout/stderr (journald)
	  build               Build step output
	  access              HTTP access logs (Caddy)

	Options:
	  -f, --follow        Follow log output
	  -n N                Show last N lines
	  --since DATE        Show logs since date (app/access only)
	  --before DATE       Show logs before date (app/access only)
	  --no-pager          Disable pager
	HELP
}

cmd_start() {
	# called by deploy@.service template: parse "deploy-<app>--<slot>" → machine dir
	local machine=$1
	local rest="${machine#deploy-}" app="${rest%--*}" slot="${rest##*--}"
	exec systemd-nspawn --quiet --machine="$machine" -D "$DEPLOY_ROOT/$app/$slot/machine"
}

case "${1:-help}" in
	help|--help|-h) cmd_help ;;
	init)           cmd_init ;;
# shortcuts → delegate to apps plugin
	create|list|info|restart|rollback|remove) load_plugin apps "$@" ;;

	# internal (git hooks, systemd units, other commands)
	_deploy-app)    shift; cmd_deploy_app "$@" ;;
	reconcile)      shift; escalate reconcile "$@"; cmd_reconcile "$@" ;;
	_start)         shift; cmd_start "$@" ;;

	# try as plugin
	*)              load_plugin "$@" ;;
esac
