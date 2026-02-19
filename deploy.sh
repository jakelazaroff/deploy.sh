#!/bin/bash
#
# deploy.sh - Minimal VPS deployment system
# Install: curl -fsSL https://raw.githubusercontent.com/you/deploy/main/deploy -o /usr/local/bin/deploy && chmod +x /usr/local/bin/deploy

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

increment_port() {
	local current
	current=$(read_state next_port 3000)
	write_state next_port $((current + 1))
	echo "$current"
}

check_domain_collision() {
	local domain=$1

	for caddy_conf in "$DEPLOY_ROOT"/apps/*/caddy.conf; do
		if [ -f "$caddy_conf" ]; then
			if grep -q "^$domain " "$caddy_conf"; then
				local app_name
				app_name=$(basename "$(dirname "$caddy_conf")")
				echo "❌ Domain $domain already used by $app_name"
				exit 1
			fi
		fi
	done
}

get_app_port() {
	local app_name=$1
	local port_file="$DEPLOY_ROOT/apps/$app_name/port"

	if [ -f "$port_file" ]; then
		cat "$port_file"
	fi
}

read_deployfile() {
	local deployfile=$1

	if [ ! -f "$deployfile" ]; then
		echo "❌ No deployfile found"
		exit 1
	fi

	DEPLOY_START=""
	DEPLOY_BUILD=""
	DEPLOY_PORT="7890"

	while IFS='=' read -r key value; do
		# skip blank lines and comments
		[[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
		# trim whitespace
		key=$(echo "$key" | xargs)
		value=$(echo "$value" | sed 's/^[[:space:]]*//')

		case "$key" in
			start) DEPLOY_START="$value" ;;
			build) DEPLOY_BUILD="$value" ;;
			port)  DEPLOY_PORT="$value" ;;
		esac
	done < "$deployfile"

	if [ -z "$DEPLOY_START" ]; then
		echo "❌ deployfile missing required \"start\" command"
		exit 1
	fi

	export DEPLOY_START DEPLOY_BUILD DEPLOY_PORT
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

	# create directory structure
	mkdir -p "$DEPLOY_ROOT"/{apps,caddy}
	chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_ROOT"

	# enable systemd-machined
	systemctl enable --now systemd-machined

	# install caddy if needed
	if ! command -v caddy &> /dev/null; then
		echo "📦 Installing Caddy..."
		curl -o /tmp/caddy.tar.gz -L "https://caddyserver.com/api/download?os=linux&arch=amd64"
		tar -xzf /tmp/caddy.tar.gz -C /usr/local/bin caddy
		chmod +x /usr/local/bin/caddy
		rm /tmp/caddy.tar.gz
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

	echo
	echo "✅ System initialized!"
	echo "   Location: $DEPLOY_ROOT"
	echo
	echo "Next: deploy create <app-name>"
}

cmd_create() {
	if [ -z "$1" ]; then
		echo "Usage: deploy create <app-name> [--static]"
		exit 1
	fi

	local app_name=$1
	local static_mode=false

	# check for --static flag
	for arg in "$@"; do
		if [ "$arg" = "--static" ]; then
			static_mode=true
		fi
	done

	local app_dir="$DEPLOY_ROOT/apps/$app_name"

	# check for existing app with name
	if [ -d "$app_dir" ]; then
		echo "❌ App $app_name already exists"
		exit 1
	fi

	# allocate port
	local port=$(increment_port)

	echo "📦 Creating app: $app_name"
	echo "   Port: $port"

	# create app structure
	mkdir -p "$app_dir"/{releases,repo.git}

	# initialize git repo
	cd "$app_dir/repo.git"
	git init --bare

	# create post-receive hook
	cat > hooks/post-receive <<-HOOK
		#!/bin/bash
		/usr/local/bin/deploy _deploy-app $app_name
		HOOK

	chmod +x hooks/post-receive

	if [ "$static_mode" = true ]; then
		# static site - no container needed

		# create dummy service that does nothing (for consistency)
		cat > "$app_dir/service.conf" <<-SERVICE
			[Unit]
			Description=$app_name (static site)
			After=network.target

			[Service]
			Type=oneshot
			ExecStart=/bin/true
			RemainAfterExit=yes

			[Install]
			WantedBy=multi-user.target
			SERVICE

		ln -sf "$app_dir/service.conf" "/etc/systemd/system/deploy-$app_name.service"
		systemctl daemon-reload

		echo "✅ Created static site: $app_name"
		echo
		echo "Next steps:"
		echo "  git remote add deploy $DEPLOY_USER@\$(hostname):$app_dir/repo.git"
		echo "  git push deploy main"
		echo "  deploy route $app_name yourdomain.com"

	else
		# create container
		echo "🏗️  Creating container..."

		local container_root="$app_dir/container"

		# install debootstrap if needed
		if ! command -v debootstrap &> /dev/null; then
			echo "📦 Installing debootstrap..."
			apt-get update && apt-get install -y debootstrap
		fi

		# create minimal debian container
		debootstrap --variant=minbase stable "$container_root" http://deb.debian.org/debian

		# setup machine ID
		systemd-machine-id-setup --root="$container_root"

		# store host port for later use
		echo "$port" > "$app_dir/port"

		echo "✅ Created app: $app_name"
		echo "   Container: $container_root"
		echo "   Host port: $port"
		echo
		echo "Add a deployfile to your repo root:"
		echo "  start=npm start"
		echo "  build=npm ci && npm run build"
		echo "  port=3000"
		echo
		echo "Next steps:"
		echo "  git remote add production $DEPLOY_USER@\$(hostname):$app_dir/repo.git"
		echo "  git push production main"
		echo "  deploy route $app_name yourdomain.com"
	fi
}

cmd_route() {
	if [ -z "$1" ] || [ -z "$2" ]; then
		echo "Usage: deploy route <app-name> <domain>"
		exit 1
	fi

	local app_name=$1
	local domain=$2
	local app_dir="$DEPLOY_ROOT/apps/$app_name"

	if [ ! -d "$app_dir" ]; then
		echo "❌ App $app_name does not exist"
		exit 1
	fi

	# check for domain collision (including within this app)
	check_domain_collision "$domain"

	# detect static vs container based on whether a container was created
	if [ ! -d "$app_dir/container" ]; then
		local root_dir="$app_dir/current"

		cat >> "$app_dir/caddy.conf" <<-CADDY
			$domain {
			    root * $root_dir
			    file_server
			    try_files {path} /index.html
			    encode gzip
			}
			CADDY

		echo "✅ Caddy configured for static site"
		echo "   $domain -> $root_dir"

	else
		# get port from service.conf
		local port=$(get_app_port "$app_name")

		if [ -z "$port" ]; then
			echo "❌ Could not determine port for $app_name"
			exit 1
		fi

		cat >> "$app_dir/caddy.conf" <<-CADDY
			$domain {
			    reverse_proxy localhost:$port
			}
			CADDY

		echo "✅ Caddy configured for $app_name"
		echo "   $domain -> localhost:$port"
	fi

	# reload caddy
	caddy reload --config "$DEPLOY_ROOT/caddy/Caddyfile"

	echo "🔒 HTTPS will be automatically provisioned!"
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
		if systemctl list-unit-files | grep -q "^deploy-$app_name.service"; then
			local status
			status=$(systemctl is-active "deploy-$app_name" 2>/dev/null || echo "inactive")
			echo "    Status: $status"
		fi

		# port
		local port=$(get_app_port "$app_name")
		if [ -n "$port" ]; then
			echo "    Port: $port"
		fi

		# domain
		if [ -f "$app_dir/caddy.conf" ]; then
			local domain=$(head -1 "$app_dir/caddy.conf" | awk '{print $1}')
			echo "    Domain: $domain"
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

	journalctl -u "deploy-$app_name" "$@"
}

cmd_restart() {
	if [ -z "$1" ]; then
		echo "Usage: deploy restart <app-name>"
		exit 1
	fi

	local app_name=$1

	echo "🔄 Restarting $app_name..."
	systemctl restart "deploy-$app_name"
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
	if systemctl is-active --quiet "deploy-$app_name" 2>/dev/null; then
		echo "  Stopping service..."
		systemctl stop "deploy-$app_name"
	fi

	if systemctl is-enabled --quiet "deploy-$app_name" 2>/dev/null; then
		systemctl disable "deploy-$app_name"
	fi

	# remove service symlink
	if [ -L "/etc/systemd/system/deploy-$app_name.service" ]; then
		rm "/etc/systemd/system/deploy-$app_name.service"
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
	GIT_DIR=$(pwd)
	git --work-tree="$release_dir" --git-dir="$GIT_DIR" checkout -f

	cd "$release_dir"

	# read deployfile
	read_deployfile "$release_dir/deployfile"

	# read host port
	local host_port=$(cat "$app_dir/port")
	local container_port="$DEPLOY_PORT"

	# run build command if present
	if [ -n "$DEPLOY_BUILD" ]; then
		echo "🔧 Running build..."

		if [ -d "$container_root" ]; then
			systemd-nspawn --directory="$container_root" \
				--bind="$release_dir":/build \
				--chdir=/build \
				bash -c "$DEPLOY_BUILD"
		else
			bash -c "$DEPLOY_BUILD"
		fi
	fi

	# atomic swap
	ln -sfn "$release_dir" "$current_link"
	echo "✅ Deployed to $current_link"

	# generate start.sh wrapper
	cat > "$app_dir/start.sh" <<-STARTSH
	#!/bin/bash
	export PORT=$container_port
	exec $DEPLOY_START
	STARTSH
	chmod +x "$app_dir/start.sh"

	# generate/update systemd service
	cat > "$app_dir/service.conf" <<-SERVICE
		[Unit]
		Description=$app_name container
		After=network.target

		[Service]
		Type=notify
		ExecStart=/usr/bin/systemd-nspawn \\
		    --directory=$container_root \\
		    --bind=$app_dir/current:/app \\
		    --bind-ro=$app_dir/start.sh:/app/start.sh \\
		    --bind-ro=/etc/resolv.conf \\
		    --network-veth \\
		    --port=$host_port:$container_port \\
		    --chdir=/app \\
		    bash /app/start.sh

		Restart=always
		KillMode=mixed

		[Install]
		WantedBy=multi-user.target
		SERVICE

	# symlink service file + reload
	ln -sf "$app_dir/service.conf" "/etc/systemd/system/deploy-$app_name.service"
	systemctl daemon-reload

	# start/restart service
	echo "🔄 Restarting $app_name..."
	systemctl restart "deploy-$app_name"

	# cleanup old releases (keep last 5)
	cd "$app_dir/releases"
	ls -t | tail -n +6 | xargs -r rm -rf
	echo "🧹 Cleaned up old releases"
}

# ============================================================================
# MAIN
# ============================================================================

cmd_help() {
	cat <<-HELP
		🚀 deploy.sh

		Usage:
		  deploy init                        Initialize the deployment system
		  deploy create <name> [--static]    Create a new app
		  deploy route <name> <domain>       Route domain to app
		  deploy list                        List all apps
		  deploy logs <name> [options...]    Show app logs (journalctl wrapper)
		  deploy restart <name>              Restart an app
		  deploy remove <name>               Remove an app
		  deploy shell <name>                Shell into container
		  deploy help                        Show this help

		deployfile:
		  Add a "deployfile" to your repo root to configure builds and runtime.

		  start=npm start                # required: the long-running process command
		  build=npm ci && npm run build  # optional: runs before each deploy
		  port=7890                      # optional: container port

		  The "start" command receives PORT as an environment variable.
		HELP
}

# route to subcommands
case "${1:-help}" in
	init)       cmd_init ;;
	create)     shift; cmd_create "$@" ;;
	route)      shift; cmd_route "$@" ;;
	list)       cmd_list ;;
	logs)       shift; cmd_logs "$@" ;;
	restart)    shift; cmd_restart "$@" ;;
	remove)     shift; cmd_remove "$@" ;;
	shell)      shift; cmd_shell "$@" ;;
	_deploy-app) shift; cmd__deploy-app "$@" ;;  # internal
	help|--help|-h) cmd_help ;;
	*)
		echo "Unknown command: $1"
		echo "Run \"deploy help\" for usage"
		exit 1
		;;
esac
