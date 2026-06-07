# x-ui / 3x-ui IPv6-only Shadowsocks inbound

在已经安装并运行 x-ui / 3x-ui 的 Debian/Ubuntu VPS 上，新增一个只监听全局 IPv6 地址的 Shadowsocks 入站，并生成 Nikki / Clash / Mihomo 可直接导入的配置文件。

脚本使用现有 x-ui / 3x-ui 的 Xray，不会默认重装 x-ui，不会清空 iptables/nftables，不会覆盖已有入站，不会删除 Docker volume、系统数据目录或重装系统。

## 前置条件

- Debian/Ubuntu VPS。
- 已安装并运行 x-ui / 3x-ui，且存在 `/etc/x-ui/x-ui.db`。
- VPS 有可用的全局 IPv6 地址。
- 系统存在 `python3`、`systemctl`、`iptables`、`ss`、`ip`、`x-ui`。

如果没有全局 IPv6 地址，或找不到 `/etc/x-ui/x-ui.db`，部署脚本会直接退出，不会自动安装 x-ui。

## 一键部署

```bash
git clone <GITHUB_REPO_URL>
cd xui-ipv6-only-shadowsocks
sudo bash scripts/deploy-ipv6-ss-xui.sh
```

默认端口是 `39443`，默认加密方式是 `chacha20-ietf-poly1305`。

环境变量示例：

```bash
sudo SS_PORT=39443 SS_METHOD=chacha20-ietf-poly1305 bash scripts/deploy-ipv6-ss-xui.sh
```

部署成功后，终端只会显示入站名称、IPv6 地址、端口、配置文件路径和数据库备份路径，不会输出 Shadowsocks 密码、`ss://` 链接或订阅链接。

## 生成的文件

部署脚本会生成以下 root-only 文件，权限为 `600`：

```text
/root/ss-ipv6-only-profile.txt
/root/ss-ipv6-only-uri.txt
/root/ss-ipv6-only-clash.yaml
/root/ss-ipv6-only-provider.yaml
```

查看导入文件。下面命令会显示真实节点信息，只应在可信终端中执行：

```bash
sudo ls -l /root/ss-ipv6-only-*
sudo cat /root/ss-ipv6-only-clash.yaml
sudo cat /root/ss-ipv6-only-provider.yaml
sudo cat /root/ss-ipv6-only-uri.txt
```

不要公开 `/root/ss-ipv6-only-uri.txt`、`/root/ss-ipv6-only-clash.yaml`、`/root/ss-ipv6-only-provider.yaml` 或 `/root/ss-ipv6-only-profile.txt`。这些文件包含真实 Shadowsocks 密码。

## 导入 Nikki / Clash / Mihomo

- Nikki：导入 `/root/ss-ipv6-only-clash.yaml`，或把 `/root/ss-ipv6-only-provider.yaml` 作为 proxy provider 使用。
- Clash：导入 `/root/ss-ipv6-only-clash.yaml`。
- Mihomo：导入 `/root/ss-ipv6-only-clash.yaml`，或在已有配置中引用 `/root/ss-ipv6-only-provider.yaml`。

生成的 YAML 节点包含：

```yaml
type: ss
server: "2001:db8::1"
port: 39443
cipher: "chacha20-ietf-poly1305"
password: "<stored in root-only generated files>"
udp: true
ip-version: ipv6
```

其中 `server` 会写入带引号的全局 IPv6 字符串。

## IPv6-only 验证

在 VPS 上检查监听：

```bash
sudo ss -lntup | grep 39443
```

预期结果应只看到 `[IPv6]:39443` 形式的监听，不应看到 `0.0.0.0:39443`。

从有 IPv6 出口的客户端测试：

```bash
nc -6 -vz <ipv6> 39443
```

IPv4 连接应该超时或失败，这是预期行为：

```bash
nc -4 -vz <ipv4> 39443
```

服务状态检查：

```bash
sudo systemctl is-active x-ui
sudo systemctl is-active ss-ipv6-only-firewall.service
```

## 回滚

回滚脚本会：

- 使用最新的 `/etc/x-ui/x-ui.db.bak-ss-ipv6-only-<timestamp>` 恢复 `/etc/x-ui/x-ui.db`。
- 停用并删除 `ss-ipv6-only-firewall.service`。
- 只删除本脚本创建的 IPv4 `tcp/$SS_PORT` 和 `udp/$SS_PORT` DROP 规则。
- 重启 x-ui Xray。
- 保留 `/root/ss-ipv6-only-*` 配置文件，不会在未确认的情况下删除它们。

执行：

```bash
sudo bash scripts/rollback-ipv6-ss-xui.sh
```

如果部署时使用了自定义端口，回滚脚本会优先读取 `/etc/default/ss-ipv6-only-firewall` 中的端口。该文件不存在时，可以手动指定：

```bash
sudo SS_PORT=39443 bash scripts/rollback-ipv6-ss-xui.sh
```

## 常见故障

客户端没有 IPv6 出口：这个入站只监听 VPS 的全局 IPv6 地址。客户端网络没有 IPv6 时，节点会连接失败。

Docker / Sub-Store 容器没有 IPv6：容器内可能无法访问 IPv6-only 节点。需要检查 Docker 网络、容器 DNS、IPv6 转发和宿主机 IPv6 连通性。

Clash / Mihomo 配置被 Sub-Store 改坏：检查生成后的节点是否仍保留 `type: ss`、带引号 IPv6 `server`、`udp: true` 和 `ip-version: ipv6`。

VPS 只监听 IPv6，IPv4 超时是预期行为：脚本会把 Xray 入站 `listen` 设置为具体全局 IPv6 地址，并额外安装 IPv4 DROP 兜底规则。IPv4 连接失败不代表部署失败。

找不到 `/etc/x-ui/x-ui.db`：脚本不会自动安装 x-ui / 3x-ui。请先安装并确认 x-ui 正常运行。

端口已被占用：换一个端口重新部署，例如：

```bash
sudo SS_PORT=40443 bash scripts/deploy-ipv6-ss-xui.sh
```

## 安全说明

- 修改 `/etc/x-ui/x-ui.db` 前，脚本会备份到 `/etc/x-ui/x-ui.db.bak-ss-ipv6-only-<timestamp>`。
- Shadowsocks 密码随机生成，只写入 `/root/ss-ipv6-only-*` 文件，权限为 `600`。
- 脚本不会在日志、README 示例或终端输出中回显真实密码、`ss://` 链接或订阅链接。
- 防火墙只添加带 `ss-ipv6-only` comment 的 IPv4 DROP 规则，不清空、不重置现有 iptables/nftables 规则。
- 回滚只删除本脚本创建的端口规则，不删除用户数据和未确认的配置文件。
