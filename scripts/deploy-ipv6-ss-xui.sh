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

fatal() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
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
}

restart_xray() {
  x-ui restart-xray >/dev/null
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
  local listener_ok=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if has_ipv6_listener && ! has_ipv4_listener && ! has_wildcard_listener; then
      listener_ok=1
      break
    fi
    sleep 1
  done
  [[ "$listener_ok" -eq 1 ]] || fatal "listener verification failed for IPv6-only port ${SS_PORT}"
  systemctl is-active --quiet x-ui || fatal "x-ui service is not active after restart"
  systemctl is-active --quiet "$SERVICE_NAME" || fatal "${SERVICE_NAME} is not active"
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

check_prerequisites
backup_database
generate_password
insert_inbound
install_firewall_service
restart_xray
generate_import_files
verify_deployment
print_summary
