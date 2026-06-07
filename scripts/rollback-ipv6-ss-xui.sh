#!/usr/bin/env bash
set -euo pipefail

DB_PATH="/etc/x-ui/x-ui.db"
SERVICE_NAME="ss-ipv6-only-firewall.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
FIREWALL_SCRIPT="/usr/local/sbin/ss-ipv6-only-firewall"
FIREWALL_ENV="/etc/default/ss-ipv6-only-firewall"
SS_PORT="${SS_PORT:-39443}"

fatal() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fatal "missing required command: $1"
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
  if command -v x-ui >/dev/null 2>&1; then
    x-ui restart-xray >/dev/null
  else
    systemctl restart x-ui
  fi
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
restart_xray
systemctl is-active --quiet x-ui || fatal "x-ui service is not active after rollback"
print_summary
