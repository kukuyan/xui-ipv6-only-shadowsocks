#!/usr/bin/env bash
set -euo pipefail

umask 077

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_PATH="/etc/x-ui/x-ui.db"
SERVICE_NAME="ss-ipv6-only-firewall.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
FIREWALL_SCRIPT="/usr/local/sbin/ss-ipv6-only-firewall"
FIREWALL_ENV="/etc/default/ss-ipv6-only-firewall"
INBOUND_REMARK="ss-ipv6-only"
SS_PORT="${SS_PORT:-39443}"
SS_METHOD="${SS_METHOD:-chacha20-ietf-poly1305}"
FORCE_CLEANUP=0
RESTART_OUTPUT_FILE=""
RESTART_COMMAND=""
DB_BACKUP=""
DB_MODIFIED=0
FIREWALL_INSTALLED=0

fatal() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: deploy-ipv6-ss-xui.sh [--force-cleanup]

Options:
  --force-cleanup  Remove a stale ss-ipv6-only inbound and this script's
                   firewall rules before deploying again.
  -h, --help       Show this help.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force-cleanup)
        FORCE_CLEANUP=1
        ;;
      --resume)
        fatal "--resume is not implemented yet; use rollback or --force-cleanup for a stale half-deploy"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fatal "unknown argument: $1"
        ;;
    esac
    shift
  done
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fatal "missing required command: $1"
}

validate_port() {
  [[ "$SS_PORT" =~ ^[0-9]+$ ]] || fatal "SS_PORT must be numeric"
  ((SS_PORT >= 1 && SS_PORT <= 65535)) || fatal "SS_PORT must be between 1 and 65535"
}

ss_port_in_use() {
  ss -H -lntup 2>/dev/null | awk -v port="$SS_PORT" '
    {
      local_addr = $5
      n = split(local_addr, parts, ":")
      if (parts[n] == port) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  '
}

has_ipv6_listener() {
  ss -H -lntup 2>/dev/null | awk -v port="$SS_PORT" -v ip="$IPV6_ADDR" '
    {
      local_addr = $5
      n = split(local_addr, parts, ":")
      if (parts[n] == port && index(local_addr, ip) > 0) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  '
}

has_wildcard_listener() {
  ss -H -lntup 2>/dev/null | awk -v port="$SS_PORT" '
    {
      local_addr = $5
      n = split(local_addr, parts, ":")
      if (parts[n] != port) {
        next
      }
      if (local_addr ~ /^\*:/ || local_addr ~ /^\[::\]:/ || local_addr ~ /^:::/) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  '
}

has_ipv4_listener() {
  ss -H -lntup 2>/dev/null | awk -v port="$SS_PORT" '
    {
      local_addr = $5
      n = split(local_addr, parts, ":")
      if (parts[n] != port) {
        next
      }
      if (local_addr ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}:/ || local_addr ~ /^\*:/ || local_addr ~ /^0\.0\.0\.0:/) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  '
}

config_contains_inbound() {
  [[ -f /usr/local/x-ui/bin/config.json ]] || return 1
  CONFIG_PATH="/usr/local/x-ui/bin/config.json" \
    SS_PORT="$SS_PORT" \
    IPV6_ADDR="$IPV6_ADDR" \
    INBOUND_REMARK="$INBOUND_REMARK" \
    python3 - <<'PY'
import json
import os
import sys

config_path = os.environ["CONFIG_PATH"]
port = int(os.environ["SS_PORT"])
ipv6_addr = os.environ["IPV6_ADDR"]
remark = os.environ["INBOUND_REMARK"]
tag = f"inbound-{port}"

try:
    with open(config_path, "r", encoding="utf-8") as handle:
        config = json.load(handle)
except Exception:
    raise SystemExit(1)

for inbound in config.get("inbounds", []):
    if not isinstance(inbound, dict):
        continue
    if inbound.get("protocol") != "shadowsocks":
        continue
    if int(inbound.get("port", -1)) != port:
        continue
    if inbound.get("listen") != ipv6_addr:
        continue
    if inbound.get("tag") not in (tag, remark):
        continue
    raise SystemExit(0)

raise SystemExit(1)
PY
}

delete_firewall_rules() {
  local proto comment
  for proto in tcp udp; do
    comment="ss-ipv6-only ${proto} ${SS_PORT}"
    while iptables -C INPUT -p "$proto" --dport "$SS_PORT" -m comment --comment "$comment" -j DROP 2>/dev/null; do
      iptables -D INPUT -p "$proto" --dport "$SS_PORT" -m comment --comment "$comment" -j DROP
    done
  done
}

remove_firewall_service() {
  if [[ -x "$FIREWALL_SCRIPT" ]]; then
    SS_PORT="$SS_PORT" "$FIREWALL_SCRIPT" remove || true
  else
    delete_firewall_rules
  fi
  if systemctl list-unit-files "$SERVICE_NAME" >/dev/null 2>&1 || [[ -f "$SERVICE_PATH" ]]; then
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
  delete_firewall_rules
  rm -f "$SERVICE_PATH" "$FIREWALL_SCRIPT" "$FIREWALL_ENV"
  systemctl daemon-reload
  systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
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
  local expect_config="${2:-none}"
  shift
  shift
  printf '$ %s\n' "$label" >>"$RESTART_OUTPUT_FILE"
  if "$@" >>"$RESTART_OUTPUT_FILE" 2>&1; then
    if [[ "$expect_config" == "present" ]] && ! config_contains_inbound; then
      printf 'command exited successfully, but config.json does not contain ss-ipv6-only yet; trying fallback\n' >>"$RESTART_OUTPUT_FILE"
      return 1
    fi
    RESTART_COMMAND="$label"
    return 0
  fi
  printf 'exit status: %s\n' "$?" >>"$RESTART_OUTPUT_FILE"
  return 1
}

restart_xray() {
  local expect_config="${1:-none}"
  RESTART_OUTPUT_FILE="$(mktemp)"
  : >"$RESTART_OUTPUT_FILE"

  if run_restart_candidate "x-ui restart-xray" "$expect_config" x-ui restart-xray; then
    return 0
  fi
  if run_restart_candidate "x-ui restart xray" "$expect_config" x-ui restart xray; then
    return 0
  fi
  if run_restart_candidate "x-ui restart" "$expect_config" x-ui restart; then
    return 0
  fi
  if run_restart_candidate "systemctl restart x-ui" "$expect_config" systemctl restart x-ui; then
    return 0
  fi

  print_restart_output
  return 1
}

restore_database_backup() {
  if [[ -n "$DB_BACKUP" && -f "$DB_BACKUP" ]]; then
    cp -a "$DB_BACKUP" "$DB_PATH"
    chmod 600 "$DB_PATH"
  fi
}

cleanup_failed_deploy() {
  printf 'Rolling back failed ss-ipv6-only deployment...\n' >&2
  if [[ "$DB_MODIFIED" -eq 1 ]]; then
    restore_database_backup
    printf 'Restored database backup: %s\n' "$DB_BACKUP" >&2
  fi
  if [[ "$FIREWALL_INSTALLED" -eq 1 || -f "$SERVICE_PATH" || -x "$FIREWALL_SCRIPT" ]]; then
    remove_firewall_service
    printf 'Removed firewall service and ss-ipv6-only IPv4 DROP rules.\n' >&2
  fi
  if [[ "$DB_MODIFIED" -eq 1 ]]; then
    restart_xray >/dev/null 2>&1 || true
  fi
}

fail_after_partial_deploy() {
  printf 'ERROR: %s\n' "$*" >&2
  print_restart_output
  cleanup_failed_deploy
  exit 1
}

inspect_existing_inbound() {
  DB_PATH="$DB_PATH" \
    SS_PORT="$SS_PORT" \
    INBOUND_REMARK="$INBOUND_REMARK" \
    python3 - <<'PY'
import os
import sqlite3

db_path = os.environ["DB_PATH"]
port = int(os.environ["SS_PORT"])
remark = os.environ["INBOUND_REMARK"]
tag = f"inbound-{port}"

conn = sqlite3.connect(db_path)
try:
    cur = conn.cursor()
    cur.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'inbounds'")
    if cur.fetchone() is None:
        raise SystemExit(0)
    cur.execute("PRAGMA table_info(inbounds)")
    column_names = {row[1] for row in cur.fetchall()}
    conditions = []
    params = []
    for column_name, value in (("remark", remark), ("tag", tag), ("port", port)):
        if column_name in column_names:
            conditions.append(f"{column_name} = ?")
            params.append(value)
    if not conditions:
        raise SystemExit(0)
    cur.execute(f"SELECT COUNT(*) FROM inbounds WHERE {' OR '.join(conditions)}", params)
    print(cur.fetchone()[0])
finally:
    conn.close()
PY
}

delete_existing_inbound() {
  DB_PATH="$DB_PATH" \
    SS_PORT="$SS_PORT" \
    INBOUND_REMARK="$INBOUND_REMARK" \
    python3 - <<'PY'
import os
import sqlite3

db_path = os.environ["DB_PATH"]
port = int(os.environ["SS_PORT"])
remark = os.environ["INBOUND_REMARK"]
tag = f"inbound-{port}"

conn = sqlite3.connect(db_path)
try:
    cur = conn.cursor()
    cur.execute("PRAGMA table_info(inbounds)")
    column_names = {row[1] for row in cur.fetchall()}
    conditions = []
    params = []
    for column_name, value in (("remark", remark), ("tag", tag), ("port", port)):
        if column_name in column_names:
            conditions.append(f"{column_name} = ?")
            params.append(value)
    if conditions:
        cur.execute(f"DELETE FROM inbounds WHERE {' OR '.join(conditions)}", params)
    conn.commit()
finally:
    conn.close()
PY
}

handle_existing_inbound() {
  local existing_count
  existing_count="$(inspect_existing_inbound)"
  [[ "${existing_count:-0}" -gt 0 ]] || return 0

  if has_ipv6_listener && ! has_ipv4_listener && ! has_wildcard_listener; then
    fatal "ss-ipv6-only already exists in the database and port ${SS_PORT} is already listening on IPv6; run rollback before redeploying"
  fi

  if [[ "$FORCE_CLEANUP" -ne 1 ]]; then
    fatal "database already contains ss-ipv6-only/inbound-${SS_PORT}, but port ${SS_PORT} is not listening. This looks like a stale half-deploy from a previous failed run. Run scripts/rollback-ipv6-ss-xui.sh first, or rerun this deploy script with --force-cleanup."
  fi

  backup_database
  delete_existing_inbound
  DB_MODIFIED=1
  remove_firewall_service
  restart_xray none || fatal "failed to restart x-ui after --force-cleanup"
}

check_prerequisites() {
  [[ "$(id -u)" -eq 0 ]] || fatal "run as root"
  [[ "$(uname -s)" == "Linux" ]] || fatal "this script only supports Linux"

  require_command python3
  require_command systemctl
  require_command iptables
  require_command ss
  require_command ip
  require_command x-ui
  validate_port

  [[ -f "$DB_PATH" ]] || fatal "missing $DB_PATH; install x-ui/3x-ui first, then rerun"
  systemctl is-active --quiet x-ui || fatal "x-ui service is not active"

  IPV6_ADDR="$(
    ip -6 addr show scope global |
      awk '/inet6 / && $0 !~ /(deprecated|tentative|dadfailed)/ { split($2, a, "/"); print a[1]; exit }'
  )"
  [[ -n "$IPV6_ADDR" ]] || fatal "no usable global IPv6 address found"

  handle_existing_inbound

  if ss_port_in_use; then
    fatal "port ${SS_PORT} is already listening"
  fi
}

backup_database() {
  local timestamp
  timestamp="$(date +%Y%m%d%H%M%S)"
  DB_BACKUP="/etc/x-ui/x-ui.db.bak-ss-ipv6-only-${timestamp}"
  cp -a "$DB_PATH" "$DB_BACKUP"
  chmod 600 "$DB_BACKUP"
}

generate_password() {
  SS_PASSWORD="$(
    python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
  )"
}

insert_inbound() {
  DB_PATH="$DB_PATH" \
    SS_PORT="$SS_PORT" \
    SS_METHOD="$SS_METHOD" \
    SS_PASSWORD="$SS_PASSWORD" \
    IPV6_ADDR="$IPV6_ADDR" \
    INBOUND_REMARK="$INBOUND_REMARK" \
    python3 - <<'PY'
import json
import os
import sqlite3
import sys
import time

db_path = os.environ["DB_PATH"]
port = int(os.environ["SS_PORT"])
method = os.environ["SS_METHOD"]
password = os.environ["SS_PASSWORD"]
ipv6_addr = os.environ["IPV6_ADDR"]
remark = os.environ["INBOUND_REMARK"]
tag = f"inbound-{port}"

settings = json.dumps(
    {
        "method": method,
        "password": password,
        "network": "tcp,udp",
    },
    separators=(",", ":"),
)
stream_settings = json.dumps(
    {
        "network": "tcp",
        "security": "none",
        "sockopt": {
            "v6only": True,
        },
    },
    separators=(",", ":"),
)
sniffing = json.dumps(
    {
        "enabled": False,
        "destOverride": ["http", "tls", "quic", "fakedns"],
        "metadataOnly": False,
        "routeOnly": False,
    },
    separators=(",", ":"),
)
allocate = json.dumps(
    {
        "strategy": "always",
        "refresh": 5,
        "concurrency": 3,
    },
    separators=(",", ":"),
)

conn = sqlite3.connect(db_path)
try:
    cur = conn.cursor()
    cur.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'inbounds'")
    if cur.fetchone() is None:
        raise SystemExit("x-ui database does not contain an inbounds table")

    cur.execute("PRAGMA table_info(inbounds)")
    columns = cur.fetchall()
    if not columns:
        raise SystemExit("x-ui inbounds table has no columns")

    column_names = {column[1] for column in columns}
    duplicate_conditions = []
    duplicate_params = []
    for column_name, value in (("remark", remark), ("tag", tag), ("port", port)):
        if column_name in column_names:
            duplicate_conditions.append(f"{column_name} = ?")
            duplicate_params.append(value)
    if duplicate_conditions:
        cur.execute(
            f"SELECT rowid FROM inbounds WHERE {' OR '.join(duplicate_conditions)} LIMIT 1",
            duplicate_params,
        )
        if cur.fetchone() is not None:
            raise SystemExit("refusing to overwrite an existing x-ui inbound")

    now = int(time.time())
    values = {
        "user_id": 0,
        "up": 0,
        "down": 0,
        "total": 0,
        "remark": remark,
        "enable": 1,
        "expiry_time": 0,
        "expiryTime": 0,
        "listen": ipv6_addr,
        "port": port,
        "protocol": "shadowsocks",
        "settings": settings,
        "stream_settings": stream_settings,
        "streamSettings": stream_settings,
        "tag": tag,
        "sniffing": sniffing,
        "allocate": allocate,
        "created_at": now,
        "updated_at": now,
    }

    insert_columns = []
    insert_values = []
    for _, name, column_type, notnull, default_value, pk in columns:
        if pk and name.lower() == "id":
            continue
        if name in values:
            insert_columns.append(name)
            insert_values.append(values[name])
            continue
        if default_value is not None or not notnull:
            continue
        normalized_type = (column_type or "").upper()
        insert_columns.append(name)
        if any(token in normalized_type for token in ("INT", "REAL", "NUM", "BOOL")):
            insert_values.append(0)
        else:
            insert_values.append("")

    placeholders = ",".join("?" for _ in insert_columns)
    quoted_columns = ",".join(f'"{name}"' for name in insert_columns)
    cur.execute(f"INSERT INTO inbounds ({quoted_columns}) VALUES ({placeholders})", insert_values)
    conn.commit()
except Exception as exc:
    conn.rollback()
    print(f"ERROR: {exc}", file=sys.stderr)
    raise SystemExit(1)
finally:
    conn.close()
PY
  DB_MODIFIED=1
}

install_firewall_service() {
  install -d -m 0755 /usr/local/sbin /etc/default /etc/systemd/system
  cat >"$FIREWALL_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SS_PORT="${SS_PORT:-39443}"

fatal() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$SS_PORT" =~ ^[0-9]+$ ]] || fatal "SS_PORT must be numeric"
((SS_PORT >= 1 && SS_PORT <= 65535)) || fatal "SS_PORT must be between 1 and 65535"
command -v iptables >/dev/null 2>&1 || fatal "missing required command: iptables"

delete_rule() {
  local proto="$1"
  local comment="ss-ipv6-only ${proto} ${SS_PORT}"
  while iptables -C INPUT -p "$proto" --dport "$SS_PORT" -m comment --comment "$comment" -j DROP 2>/dev/null; do
    iptables -D INPUT -p "$proto" --dport "$SS_PORT" -m comment --comment "$comment" -j DROP
  done
}

add_rule() {
  local proto="$1"
  local comment="ss-ipv6-only ${proto} ${SS_PORT}"
  delete_rule "$proto"
  iptables -I INPUT 1 -p "$proto" --dport "$SS_PORT" -m comment --comment "$comment" -j DROP
}

case "${1:-}" in
  apply)
    add_rule tcp
    add_rule udp
    ;;
  remove)
    delete_rule tcp
    delete_rule udp
    ;;
  *)
    fatal "usage: $0 apply|remove"
    ;;
esac
EOF
  chmod 0755 "$FIREWALL_SCRIPT"

  cat >"$FIREWALL_ENV" <<EOF
SS_PORT=${SS_PORT}
EOF
  chmod 0600 "$FIREWALL_ENV"

  install -m 0644 "${PROJECT_ROOT}/systemd/${SERVICE_NAME}" "$SERVICE_PATH"
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME" >/dev/null
  FIREWALL_INSTALLED=1
}

generate_import_files() {
  SS_PASSWORD="$SS_PASSWORD" python3 "${PROJECT_ROOT}/scripts/generate-import-configs.py" \
    --server "$IPV6_ADDR" \
    --port "$SS_PORT" \
    --method "$SS_METHOD" \
    --name "$INBOUND_REMARK" \
    --out-dir /root >/dev/null
}

verify_deployment() {
  local listener_ok=0 config_ok=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if config_contains_inbound; then
      config_ok=1
    fi
    if [[ "$config_ok" -eq 1 ]] && has_ipv6_listener && ! has_ipv4_listener && ! has_wildcard_listener; then
      listener_ok=1
      break
    fi
    sleep 1
  done
  [[ "$config_ok" -eq 1 ]] || fail_after_partial_deploy "/usr/local/x-ui/bin/config.json does not contain the ss-ipv6-only inbound after restart"
  [[ "$listener_ok" -eq 1 ]] || fail_after_partial_deploy "listener verification failed for IPv6-only port ${SS_PORT}"
  systemctl is-active --quiet x-ui || fail_after_partial_deploy "x-ui service is not active after restart"
  systemctl is-active --quiet "$SERVICE_NAME" || fail_after_partial_deploy "${SERVICE_NAME} is not active"
}

print_summary() {
  printf 'Inbound: %s\n' "$INBOUND_REMARK"
  printf 'IPv6: %s\n' "$IPV6_ADDR"
  printf 'Port: %s\n' "$SS_PORT"
  printf 'Config files:\n'
  printf '  /root/ss-ipv6-only-profile.txt\n'
  printf '  /root/ss-ipv6-only-uri.txt\n'
  printf '  /root/ss-ipv6-only-clash.yaml\n'
  printf '  /root/ss-ipv6-only-provider.yaml\n'
  printf 'Database backup: %s\n' "$DB_BACKUP"
}

parse_args "$@"
check_prerequisites
backup_database
generate_password
insert_inbound
install_firewall_service
restart_xray present || fail_after_partial_deploy "failed to restart x-ui/Xray or regenerate config.json"
verify_deployment
generate_import_files
print_summary
