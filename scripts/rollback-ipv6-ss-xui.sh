#!/usr/bin/env bash
set -euo pipefail

DB_PATH="/etc/x-ui/x-ui.db"
SERVICE_NAME="ss-ipv6-only-firewall.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
FIREWALL_SCRIPT="/usr/local/sbin/ss-ipv6-only-firewall"
FIREWALL_ENV="/etc/default/ss-ipv6-only-firewall"
SS_PORT="${SS_PORT:-39443}"
RESTART_OUTPUT_FILE=""
RESTART_COMMAND=""

fatal() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fatal "missing required command: $1"
}

print_restart_output() {
  if [[ -n "$RESTART_OUTPUT_FILE" && -s "$RESTART_OUTPUT_FILE" ]]; then
    printf 'Restart command attempts/output:\n' >&2
    cat "$RESTART_OUTPUT_FILE" >&2
  elif [[ -n "$RESTART_COMMAND" ]]; then
    printf 'Restart command used: %s\n' "$RESTART_COMMAND" >&2
  fi
}

run_restart_candidate() {
  local label="$1"
  shift
  printf '$ %s\n' "$label" >>"$RESTART_OUTPUT_FILE"
  if "$@" >>"$RESTART_OUTPUT_FILE" 2>&1; then
    RESTART_COMMAND="$label"
    return 0
  fi
  printf 'exit status: %s\n' "$?" >>"$RESTART_OUTPUT_FILE"
  return 1
}

load_firewall_env() {
  if [[ -f "$FIREWALL_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$FIREWALL_ENV"
  fi
}

validate_port() {
  [[ "$SS_PORT" =~ ^[0-9]+$ ]] || fatal "SS_PORT must be numeric"
  ((SS_PORT >= 1 && SS_PORT <= 65535)) || fatal "SS_PORT must be between 1 and 65535"
}

latest_backup() {
  local backups=()
  shopt -s nullglob
  backups=(/etc/x-ui/x-ui.db.bak-ss-ipv6-only-*)
  shopt -u nullglob
  [[ "${#backups[@]}" -gt 0 ]] || fatal "no ss-ipv6-only database backup found"
  printf '%s\n' "${backups[-1]}"
}

remove_firewall_rules() {
  if [[ -x "$FIREWALL_SCRIPT" ]]; then
    SS_PORT="$SS_PORT" "$FIREWALL_SCRIPT" remove || true
  else
    for proto in tcp udp; do
      local comment="ss-ipv6-only ${proto} ${SS_PORT}"
      while iptables -C INPUT -p "$proto" --dport "$SS_PORT" -m comment --comment "$comment" -j DROP 2>/dev/null; do
        iptables -D INPUT -p "$proto" --dport "$SS_PORT" -m comment --comment "$comment" -j DROP
      done
    done
  fi
}

disable_firewall_service() {
  if systemctl list-unit-files "$SERVICE_NAME" >/dev/null 2>&1 || [[ -f "$SERVICE_PATH" ]]; then
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
  remove_firewall_rules
  rm -f "$SERVICE_PATH"
  rm -f "$FIREWALL_SCRIPT" "$FIREWALL_ENV"
  systemctl daemon-reload
  systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
}

restore_database() {
  local backup_path current_backup timestamp
  backup_path="$(latest_backup)"
  timestamp="$(date +%Y%m%d%H%M%S)"
  if [[ -f "$DB_PATH" ]]; then
    current_backup="/etc/x-ui/x-ui.db.pre-rollback-ss-ipv6-only-${timestamp}"
    cp -a "$DB_PATH" "$current_backup"
    chmod 600 "$current_backup"
  fi
  cp -a "$backup_path" "$DB_PATH"
  chmod 600 "$DB_PATH"
  RESTORED_BACKUP="$backup_path"
}

restart_xray() {
  RESTART_OUTPUT_FILE="$(mktemp)"
  : >"$RESTART_OUTPUT_FILE"
  if command -v x-ui >/dev/null 2>&1; then
    if run_restart_candidate "x-ui restart-xray" x-ui restart-xray; then
      return 0
    fi
    if run_restart_candidate "x-ui restart xray" x-ui restart xray; then
      return 0
    fi
    if run_restart_candidate "x-ui restart" x-ui restart; then
      return 0
    fi
  fi
  if run_restart_candidate "systemctl restart x-ui" systemctl restart x-ui; then
    return 0
  fi
  print_restart_output
  return 1
}

print_summary() {
  printf 'Restored database backup: %s\n' "$RESTORED_BACKUP"
  printf 'Removed service: %s\n' "$SERVICE_NAME"
  printf 'Retained config files:\n'
  printf '  /root/ss-ipv6-only-profile.txt\n'
  printf '  /root/ss-ipv6-only-uri.txt\n'
  printf '  /root/ss-ipv6-only-clash.yaml\n'
  printf '  /root/ss-ipv6-only-provider.yaml\n'
}

[[ "$(id -u)" -eq 0 ]] || fatal "run as root"
[[ "$(uname -s)" == "Linux" ]] || fatal "this script only supports Linux"
require_command systemctl
require_command iptables
load_firewall_env
validate_port
[[ -d /etc/x-ui ]] || fatal "missing /etc/x-ui"
disable_firewall_service
restore_database
restart_xray || fatal "failed to restart x-ui after rollback"
systemctl is-active --quiet x-ui || fatal "x-ui service is not active after rollback"
print_summary
