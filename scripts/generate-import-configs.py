#!/usr/bin/env python3
"""Generate root-only Shadowsocks import files for Clash/Mihomo/Nikki."""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
from urllib.parse import quote


def yaml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def ss_uri(method: str, password: str, server: str, port: int, name: str) -> str:
    userinfo = f"{method}:{password}".encode("utf-8")
    encoded_userinfo = base64.urlsafe_b64encode(userinfo).decode("ascii").rstrip("=")
    return f"ss://{encoded_userinfo}@[{server}]:{port}#{quote(name)}"


def proxy_yaml(name: str, server: str, port: int, method: str, password: str, indent: str = "") -> str:
    return "\n".join(
        [
            f"{indent}- name: {yaml_string(name)}",
            f"{indent}  type: ss",
            f"{indent}  server: {yaml_string(server)}",
            f"{indent}  port: {port}",
            f"{indent}  cipher: {yaml_string(method)}",
            f"{indent}  password: {yaml_string(password)}",
            f"{indent}  udp: true",
            f"{indent}  ip-version: ipv6",
        ]
    )


def write_secret(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(content)
    os.chmod(path, 0o600)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate root-only Shadowsocks import files.")
    parser.add_argument("--server", required=True, help="Global IPv6 address without brackets.")
    parser.add_argument("--port", required=True, type=int, help="Shadowsocks port.")
    parser.add_argument("--method", required=True, help="Shadowsocks cipher.")
    parser.add_argument("--name", default="ss-ipv6-only", help="Proxy name.")
    parser.add_argument("--out-dir", default="/root", help="Output directory.")
    parser.add_argument(
        "--password-env",
        default="SS_PASSWORD",
        help="Environment variable containing the Shadowsocks password.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    password = os.environ.get(args.password_env)
    if not password:
        raise SystemExit(f"missing password environment variable: {args.password_env}")

    out_dir = Path(args.out_dir)
    uri = ss_uri(args.method, password, args.server, args.port, args.name)

    profile = "\n".join(
        [
            f"name={args.name}",
            f"server={args.server}",
            f"port={args.port}",
            f"method={args.method}",
            f"password={password}",
            "udp=true",
            "ip-version=ipv6",
            "",
        ]
    )

    clash = "\n".join(
        [
            "proxies:",
            proxy_yaml(args.name, args.server, args.port, args.method, password, indent="  "),
            "proxy-groups:",
            f"  - name: {yaml_string('Proxy')}",
            "    type: select",
            "    proxies:",
            f"      - {yaml_string(args.name)}",
            "rules:",
            "  - MATCH,Proxy",
            "",
        ]
    )

    provider = "\n".join(
        [
            "proxies:",
            proxy_yaml(args.name, args.server, args.port, args.method, password, indent="  "),
            "",
        ]
    )

    paths = {
        "profile": out_dir / "ss-ipv6-only-profile.txt",
        "uri": out_dir / "ss-ipv6-only-uri.txt",
        "clash": out_dir / "ss-ipv6-only-clash.yaml",
        "provider": out_dir / "ss-ipv6-only-provider.yaml",
    }

    write_secret(paths["profile"], profile)
    write_secret(paths["uri"], uri + "\n")
    write_secret(paths["clash"], clash)
    write_secret(paths["provider"], provider)

    for key in ("profile", "uri", "clash", "provider"):
        print(f"{key}={paths[key]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
