#!/usr/bin/env bash
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
ALPINE_VERSION=3.23.3
PORT_RANGE_START=49152 # first ephemeral port
PORT_WAIT_SECONDS=30 # how long to wait for a new container to start

# --- plugins ---

declare -A COMMANDS=()
POST_CONFIGURE_HOOKS=()

# --- utilities ---

red() { printf "\033[31m$1\033[0m"; }
green() { printf "\033[32m$1\033[0m"; }
dim() { printf "\033[2m$1\033[0m"; }

log() { echo "$@" >&2; }              # print to stderr
step() { log "$(dim "→") $@"; }      # print a progress step
success() { log "$(green "✓") $@"; } # print a success message
error() { log "$(red "✗") $@"; }     # print an error message
panic() { error "$1"; exit 1; }        # print an error and exit

require_arg() { [ -n "${1:-}" ] || panic "$2"; }

require_app() {
	require_arg "${1:-}" "Usage: deploy <command> <app>"
	[ -d "$DEPLOY_ROOT/$1" ] || panic "App $1 does not exist"
	app_name="$1"; app_dir="$DEPLOY_ROOT/$1"
}

# Privilege escalation: non-deploy users hop to the deploy user first (any user
# can via /etc/sudoers.d/deploy), then deploy escalates to root.
# exec replaces this process — the lines below never run if escalation happens.
escalate() {
	[ "$(id -u)" -eq 0 ] && return
	[ "$(id -un)" != "$DEPLOY_USER" ] && exec sudo -u "$DEPLOY_USER" "$0" "$@"
	exec sudo "$0" "$@"
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

check_domain_collision() {
	local domain=$1 exclude_app=${2:-}
	local domains_file
	for domains_file in "$DEPLOY_ROOT"/*/domains; do
		[ -f "$domains_file" ] || continue
		local app_name; app_name=$(basename "$(dirname "$domains_file")")
		[ "$app_name" = "$exclude_app" ] && continue
		grep -qx "$domain" "$domains_file" 2>/dev/null && panic "Domain $domain already used by $app_name"
	done
}

wait_for_port() {
	local port=$1 i=$((PORT_WAIT_SECONDS * 2))
	while ! ss -tln "sport = :$port" | grep -q LISTEN; do
		sleep 0.5; ((i--)) || return 1
	done
}

other_slot()  { [ "$1" = "blue" ] && echo "green" || echo "blue"; }
active_slot() { cat "$DEPLOY_ROOT/$1/active" 2>/dev/null || true; }

# systemd unit for an app slot
app_unit() { echo "deploy@$(systemd-escape -p "/${1}/${2}")"; }

# --- lifecycle ---

reload_caddy() { systemctl reload caddy 2>/dev/null || true; }

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

# zero-downtime slot swap: start new container, wait for it, teardown old, update active pointer.
activate_slot() {
	local app_name=$1 new_slot=$2
	local start_cmd; start_cmd=$(get_conf "$DEPLOY_ROOT/$app_name/$new_slot/deploy.conf" "start")
	if [ -n "$start_cmd" ]; then
		local port; port=$(assign_port "$app_name" "$new_slot")
		systemctl start "$(app_unit "$app_name" "$new_slot")"
		if ! wait_for_port "$port"; then
			teardown_slot "$app_name" "$new_slot"
			panic "Instance failed to start on port $port after ${PORT_WAIT_SECONDS}s"
		fi
		teardown_slot "$app_name" "$(other_slot "$new_slot")"
	fi
	echo "$new_slot" > "$DEPLOY_ROOT/$app_name/active"
	reload_caddy
}

teardown_slot() {
	local app_name=$1 slot=$2
	[ -n "$slot" ] || return 0
	systemctl stop "$(app_unit "$app_name" "$slot")" 2>/dev/null || true
	sed -i "/^${app_name}--${slot}=/d" "$DEPLOY_ROOT/.internal/ports"
}

# --- commands ---

# Re-configure and restart the active slot.
# No-op if app hasn't been deployed yet.
cmd:apply() {
	local app_name=$1
	local slot; slot=$(active_slot "$app_name"); [ -n "$slot" ] || return 0
	configure "$app_name" "$slot"
	local start_cmd; start_cmd=$(get_conf "$DEPLOY_ROOT/$app_name/$slot/deploy.conf" "start")
	if [ -n "$start_cmd" ]; then
		systemctl restart "$(app_unit "$app_name" "$slot")" || true
	fi
	reload_caddy
}

cmd:create() {
	require_arg "${1:-}" "Usage: deploy create <app>"
	local app_name=$1; local app_dir="$DEPLOY_ROOT/$app_name"
	if [[ "$app_name" == .* ]]; then panic "App name cannot start with '.'"; fi
	if [ -d "$app_dir" ]; then panic "App $app_name already exists"; fi

	step "Creating app: $app_name"
	mkdir -p "$app_dir"/repo.git
	git init --bare --initial-branch=main "$app_dir/repo.git"

	cat > "$app_dir/repo.git/hooks/post-receive" <<-HOOK
	#!/bin/bash
	sudo /usr/local/bin/deploy deploy $app_name
	HOOK
	chmod +x "$app_dir/repo.git/hooks/post-receive"
	chown -R "$DEPLOY_USER:$DEPLOY_USER" "$app_dir"
	chmod 2775 "$app_dir"
	touch "$app_dir/domains" "$app_dir/env"

	success "Created app: $app_name"
	log ""
	log "Next steps:"
	log "  git remote add deploy $DEPLOY_USER@$(hostname):$app_dir/repo.git"
	log "  git push deploy main"
	log ""
}

cmd:list() {
	for app_dir in "$DEPLOY_ROOT"/*/; do
		[ -d "$app_dir" ] || continue
		[[ "$(basename "$app_dir")" == .* ]] && continue
		printf '%s\n' "$(basename "$app_dir")"
	done
}

cmd:info() {
	require_app "${1:-}"; local app_name=$1
	local slot; slot=$(active_slot "$app_name")
	local deploy_conf="$app_dir/$slot/deploy.conf"

	local start_cmd="" status="" assets="" spa=""
	if [ -f "$deploy_conf" ]; then
		start_cmd=$(get_conf "$deploy_conf" "start")
		if [ -n "$start_cmd" ] && [ -n "$slot" ]; then
			status=$(systemctl is-active "$(app_unit "$app_name" "$slot")" 2>/dev/null || true)
		fi
		assets=$(get_conf "$deploy_conf" "assets")
		spa=$(get_conf "$deploy_conf" "spa")
	fi
	local domains_list; domains_list=$(cat "$app_dir/domains" 2>/dev/null || true)

	echo -e "\e[1m$app_name\e[0m"
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

cmd:restart() {
	require_app "${1:-}"; local app_name=$1
	local slot; slot=$(active_slot "$app_name"); [ -n "$slot" ] || panic "No active slot"
	step "Restarting $app_name"
	systemctl restart "$(app_unit "$app_name" "$slot")" || panic "Failed to restart $app_name"
	success "Restarted"
}

cmd:rollback() {
	require_app "${1:-}"; local app_name=$1
	local slot; slot=$(active_slot "$app_name"); [ -n "$slot" ] || panic "Nothing deployed"
	local prev_slot; prev_slot=$(other_slot "$slot")
	[ -d "$app_dir/$prev_slot" ] || panic "No previous release to roll back to"

	activate_slot "$app_name" "$prev_slot"
	success "Rolled back $app_name"
}

cmd:remove() {
	require_app "${1:-}"; local app_name=$1
	local force=false; [[ "${2:-}" == "-f" || "${2:-}" == "--force" ]] && force=true
	if ! $force; then
		read -rp "Remove $app_name? This will delete all app files. Type 'yes' to confirm: " confirm
		if [ "$confirm" != "yes" ]; then log "Aborted."; exit 1; fi
	fi
	step "Removing $app_name"
	teardown_slot "$app_name" "blue"
	teardown_slot "$app_name" "green"
	systemctl daemon-reload
	step "Removing app files"
	rm -rf "$app_dir"
	reload_caddy
	success "Removed $app_name"
}

# --- domains ---

cmd:domains() {
	local subcmd="${1:-list}"; shift || true
	case "$subcmd" in
		list)   cmd:domains:list "$@" ;;
		add)    cmd:domains:add "$@" ;;
		remove) cmd:domains:remove "$@" ;;
		*)      panic "Usage: deploy domains [list|add|remove] <app> [domain]" ;;
	esac
}

cmd:domains:list() {
	require_app "${1:-}"
	cat "$app_dir/domains" 2>/dev/null || true
}

cmd:domains:add() {
	require_app "${1:-}"
	local domain=${2:-}
	require_arg "$domain" "Usage: deploy domains add <app> <domain>"
	check_domain_collision "$domain" "$app_name"
	echo "$domain" >> "$app_dir/domains"
	cmd:apply "$app_name"
	success "Added domain $domain"
}

cmd:domains:remove() {
	require_app "${1:-}"
	local domain=${2:-}
	require_arg "$domain" "Usage: deploy domains remove <app> <domain>"
	sed -i "/^${domain}$/d" "$app_dir/domains"
	cmd:apply "$app_name"
	success "Removed domain $domain"
}

cmd:env() {
	local subcmd="${1:-list}"; shift || true
	case "$subcmd" in
		list)   cmd:env:list "$@" ;;
		set)    cmd:env:set "$@" ;;
		remove) cmd:env:remove "$@" ;;
		*)      panic "Usage: deploy env [list|set|remove] <app> [KEY=value]" ;;
	esac
}

cmd:env:list() {
	require_app "${1:-}"
	cat "$app_dir/env" 2>/dev/null || true
}

cmd:env:set() {
	require_app "${1:-}"
	local kv=${2:-}
	require_arg "$kv" "Usage: deploy env set <app> KEY=value"
	[[ "$kv" == *=* ]] || panic "Expected KEY=value, got: $kv"
	local key="${kv%%=*}"
	sed -i "/^${key}=/d" "$app_dir/env"
	echo "$kv" >> "$app_dir/env"
	cmd:apply "$app_name"
	success "Set $key"
}

cmd:env:remove() {
	require_app "${1:-}"
	local key=${2:-}
	require_arg "$key" "Usage: deploy env remove <app> KEY"
	sed -i "/^${key}=/d" "$app_dir/env"
	cmd:apply "$app_name"
	success "Removed $key"
}

cmd:logs() {
	require_arg "${1:-}" "Usage: deploy logs <app> [-f] [-n N]"
	local app_name=$1; shift
	if [ ! -d "$DEPLOY_ROOT/$app_name" ]; then panic "App $app_name does not exist"; fi

	local follow=false num=""
	while [ $# -gt 0 ]; do
		case "$1" in
			-f|--follow) follow=true ;;
			-n)          shift; num=$1 ;;
			*)           panic "Unknown option: $1" ;;
		esac
		shift
	done

	local args=(--no-pager -u "deploy@$(systemd-escape -p "/${app_name}")-*")
	$follow       && args+=(-f)
	[ -n "$num" ] && args+=(-n "$num")
	journalctl "${args[@]}"
}

# initialize the deployment system
cmd:init() {
	if [ "$(id -u)" -ne 0 ]; then panic "deploy init must be run as root"; fi
	log "Setting up deploy.sh at $DEPLOY_ROOT"


	# install system dependencies
	step "Installing system dependencies"
	if command -v apt-get &>/dev/null; then
		apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
		curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
			| gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
		curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
			| tee /etc/apt/sources.list.d/caddy-stable.list
		chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
		apt-get update -q
		apt-get install -y caddy systemd-container
	elif command -v dnf &>/dev/null; then
		dnf install -y dnf5-plugins
		dnf copr enable -y @caddy/caddy
		dnf install -y caddy systemd-container
	else
		panic "Unsupported package manager — install caddy and systemd-container manually"
	fi

	# create deploy user; add caddy to the deploy group so it can write access logs
	id "$DEPLOY_USER" &>/dev/null || { step "Creating $DEPLOY_USER user"; useradd -m -s /bin/bash "$DEPLOY_USER"; }
	id caddy &>/dev/null && usermod -aG "$DEPLOY_USER" caddy

	# copy SSH keys
	step "Copying SSH authorized_keys"
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
	fi

	# create deploy directory
	mkdir -p "$DEPLOY_ROOT/.internal" "$DEPLOY_ROOT/.plugins"
	chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_ROOT"
	chmod 2775 "$DEPLOY_ROOT"

	# pull Alpine base image
	if [ ! -d "$DEPLOY_ROOT/.internal/machine" ]; then
		step "Pulling Alpine base image"
		local arch; arch=$(uname -m)
		mkdir -p "$DEPLOY_ROOT/.internal/machine"
		curl -fsSL "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$arch/alpine-minirootfs-${ALPINE_VERSION}-${arch}.tar.gz" | tar -xz -C "$DEPLOY_ROOT/.internal/machine"
		systemd-nspawn -D "$DEPLOY_ROOT/.internal/machine" /bin/sh -c "apk update && apk add --no-cache bash"
	fi

	# create Caddyfile
	if [ ! -f "$DEPLOY_ROOT/.internal/Caddyfile" ]; then
		read -rp "📧 Email for Let's Encrypt certificates: " acme_email
		if [ -z "$acme_email" ]; then panic "Email is required for HTTPS certificate provisioning"; fi
		step "Configuring Caddy"
		cat > "$DEPLOY_ROOT/.internal/Caddyfile" <<-CADDY
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
	ExecStart=/usr/bin/systemd-nspawn --quiet --settings=trusted --machine=%i -D $DEPLOY_ROOT%f/machine bash /app/start.sh
	Restart=on-failure
	KillMode=mixed
	SERVICE
	ln -sf "$DEPLOY_ROOT/.internal/deploy@.service" /etc/systemd/system/deploy@.service

	systemctl daemon-reload

	# set up sudoers
	step "Setting up sudoers"
	cat > /etc/sudoers.d/deploy <<-SUDOERS
	Defaults env_keep += "SSH_AUTH_SOCK"
	$DEPLOY_USER ALL=(root) NOPASSWD: /usr/local/bin/deploy *
	ALL ALL=(deploy) NOPASSWD: /usr/local/bin/deploy *
	SUDOERS
	chmod 0440 /etc/sudoers.d/deploy

	success "deploy.sh initialized"
}

# deploy an app (called by git post-receive hook)
cmd:deploy() {
	require_arg "${1:-}" "Internal error: app name required"
	local app_name=$1; local app_dir="$DEPLOY_ROOT/$app_name"

	# build into whichever slot isn't currently active
	local next_slot; next_slot=$(other_slot "$(active_slot "$app_name")")
	local release_dir="$app_dir/$next_slot"
	local build_log="$release_dir/build.log"

	log "Deploying $app_name"
	rm -rf "$release_dir"
	unset GIT_DIR
	# Clone rather than checkout so that .git lives inside the release dir. This
	# keeps all git metadata (gitdir pointers, core.worktree, submodule configs)
	# self-relative to the release dir, which means they resolve correctly when
	# the dir is mounted at /build inside the build container.
	git clone --local --quiet "$app_dir/repo.git" "$release_dir"
	if [ -f "$release_dir/.gitmodules" ]; then
		step "Initializing submodules"
		GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" git -C "$release_dir" submodule update --init --recursive
	fi

	local deploy_conf="$release_dir/deploy.conf"
	local start_cmd; start_cmd=$(get_conf "$deploy_conf" "start")
	local build_cmd; build_cmd=$(get_conf "$deploy_conf" "build")

	local setenv_args=()
	while IFS= read -r env_var; do
		setenv_args+=(--setenv="$env_var")
	done < <(cat "$app_dir/env" 2>/dev/null || true)

	# container setup has three paths:
	# 1. build + start: build in ephemeral container, which becomes the runtime container
	# 2. build only:    build in ephemeral container, then discard it (static site)
	# 3. start only:    clone base image as runtime container (no build step)
	if [ -n "$build_cmd" ]; then
		local build_dir="$app_dir/machine-build"
		rm -rf "$build_dir"
		cp -a "$DEPLOY_ROOT/.internal/machine" "$build_dir"
		step "Running build"
		systemd-nspawn -D "$build_dir" "${setenv_args[@]}" --bind="$release_dir":/build --chdir=/build bash -c "$build_cmd" 2>&1 | tee "$build_log"
		[ -n "$start_cmd" ] && mv "$build_dir" "$release_dir/machine" || rm -rf "$build_dir"
	elif [ -n "$start_cmd" ]; then
		step "Cloning base image"
		cp -a "$DEPLOY_ROOT/.internal/machine" "$release_dir/machine"
	fi

	if [ -n "$start_cmd" ]; then
		rm -f "$release_dir/machine/etc/machine-id"
		systemd-machine-id-setup --root="$release_dir/machine"
	fi

	configure "$app_name" "$next_slot"

	activate_slot "$app_name" "$next_slot"
	success "Deployed $app_name"
}

# internal: generate Caddy config and systemd service for a slot
configure() {
	require_arg "${1:-}" "Internal error: app name required"
	require_arg "${2:-}" "Internal error: slot required"
	local app_name=$1 slot=$2; local app_dir="$DEPLOY_ROOT/$app_name"
	local release_dir="$app_dir/$slot"
	local deploy_conf="$release_dir/deploy.conf"
	local start_cmd; start_cmd=$(get_conf "$deploy_conf" "start")
	local domains; domains=$(tr '\n' ' ' < "$app_dir/domains" 2>/dev/null); domains="${domains% }"
	local d; for d in $domains; do check_domain_collision "$d" "$app_name"; done
	local port; port=$(assign_port "$app_name" "$slot")

	step "Configuring $app_name"

	local static_dir; static_dir=$(get_conf "$deploy_conf" "assets")
	local spa_mode; spa_mode=$(get_conf "$deploy_conf" "spa")

	# generate Caddy config
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

		cat > "$app_dir/caddy.conf" <<-CADDY
		$domains {
		    root * $app_dir/$slot${static_dir:+/$static_dir}
		    $headers
		    $handler
		        import logging "$app_dir"
		}
		CADDY
		caddy fmt "$app_dir/caddy.conf" --overwrite
	else
		true > "$app_dir/caddy.conf"
	fi

	# generate .nspawn config and start.sh
	if [ -n "$start_cmd" ]; then
		mkdir -p "$app_dir/data"
		printf '#!/bin/sh\n%s\n' "$start_cmd" > "$release_dir/start.sh"

		# build up the Environment= lines from the env file
		local env_lines=""
		while IFS= read -r env_var; do
			env_lines+="Environment=${env_var}"$'\n'
		done < <(cat "$app_dir/env" 2>/dev/null || true)

		cat > "$release_dir/machine.nspawn" <<-NSPAWN
		[Exec]
		WorkingDirectory=/app
		Environment=PORT=$port
		${env_lines}
		[Files]
		Bind=$release_dir:/app
		Bind=$app_dir/data:/data
		BindReadOnly=/etc/resolv.conf
		NSPAWN
	fi

	for hook in "${POST_CONFIGURE_HOOKS[@]}"; do "$hook" "$app_name" "$release_dir"; done

	success "Configured"
}

cmd:help() {
	cat <<-HELP
	deploy.sh — minimal VPS deployment system

	Usage: deploy <command> [args...]

	Apps:
	  create <app>                    Create a new app
	  list                            List all apps
	  info <app>                      Show app status and configuration
	  restart <app>                   Restart an app's container
	  rollback <app>                  Roll back to a previous release
	  remove <app> [-f]              Remove an app and all its files

	Config:
	  domains [list|add|remove] <app> [domain]    Manage domains
	  env [list|set|remove] <app> [KEY=value]     Manage environment variables
	  apply <app>                                 Apply config changes

	Logs:
	  logs <app> [-f] [-n N]

	System:
	  init                            Initialize the deployment system

	deploy.conf (in repo root):
	  start=<cmd>                     Start command (receives \$PORT; omit for static sites)
	  build=<cmd>                     Build command
	  assets=<dir>                    Static assets directory (default: repo root)
	  spa=true                        Single-page app mode
	  header=<path> <name>: <value>   Response header (repeatable)
	HELP
}

# source plugins from $DEPLOY_ROOT/.plugins/
for _plugin in "$DEPLOY_ROOT/.plugins/"*; do [ -f "$_plugin" ] && source "$_plugin"; done

cmd="${1:-help}"; shift || true
case "$cmd" in help|--help|-h) ;; *) escalate "$cmd" "$@" ;; esac
case $cmd in
	help|--help|-h) cmd:help "$@" ;;
	init)           cmd:init "$@" ;;
	apply)          cmd:apply "$@" ;;
	deploy)         cmd:deploy "$@" ;;
	create)         cmd:create "$@" ;;
	list)           cmd:list "$@" ;;
	info)           cmd:info "$@" ;;
	restart)        cmd:restart "$@" ;;
	rollback)       cmd:rollback "$@" ;;
	remove)         cmd:remove "$@" ;;
	domains)        cmd:domains "$@" ;;
	env)            cmd:env "$@" ;;
	logs)           cmd:logs "$@" ;;
	*)
		fn="${COMMANDS[$cmd]:-}"
		[ -n "$fn" ] && "$fn" "$@" \
			|| panic "Unknown command: $cmd. Run \"deploy help\" for usage"
		;;
esac
