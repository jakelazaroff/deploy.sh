#!/usr/bin/env bash
#
# deploy.sh remote helper — run deploy commands on your server from a local repo.
#
# Usage: remote.sh <command> [args...]
#
# Requires a git remote named "deploy" pointing at your server, e.g.:
#   git remote add deploy deploy@myserver.com:/srv/deploy/myapp/repo.git

set -euo pipefail

# extract SSH host and app name from the "deploy" git remote.
# supports both SCP-style (user@host:path) and ssh:// URLs.
remote_url=$(git remote get-url deploy 2>/dev/null) \
  || { echo "No git remote named 'deploy' found" >&2; exit 1; }

if [[ "$remote_url" == ssh://* ]]; then
  without_scheme="${remote_url#ssh://}"
  ssh_target="${without_scheme%%/*}"
  remote_path="/${without_scheme#*/}"
else
  ssh_target="${remote_url%%:*}"
  remote_path="${remote_url##*:}"
fi

# /srv/deploy/myapp/repo.git -> myapp; overrideable with --app
app_name=$(basename "$(dirname "$remote_path")")

args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --app=*) app_name="${1#--app=}" ;;
    --app)   shift; app_name="${1:-}" ;;
    *)       args+=("$1") ;;
  esac
  shift
done
set -- "${args[@]+"${args[@]}"}"

ssh_opts=(-q); [ -t 0 ] && ssh_opts+=(-t)

# inject the app name into the right positional slot.
# subcommand groups (env, domains) expect <subcmd> <app> [args];
# everything else expects <app> [args].
# TODO: find a better way of doing this than a heuristic
cmd="${1:-help}"; shift || true
case "$cmd" in
	env|domains)
		subcmd="${1:-list}"; shift || true
		exec ssh "${ssh_opts[@]}" "$ssh_target" deploy "$cmd" "$subcmd" "$app_name" "$@"
		;;
	*)
		exec ssh "${ssh_opts[@]}" "$ssh_target" deploy "$cmd" "$app_name" "$@"
		;;
esac
