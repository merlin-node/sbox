# sbox

一个简洁的 sing-box 管理脚本，支持多种入站/出站协议、分流规则、流量统计。

- **入站协议**：Shadowsocks（含 2022）、VLESS + Reality、AnyTLS（自签 / ACME 真实证书）
- **出站协议**：SS / VLESS-Reality / VLESS-WS-TLS / Hysteria2 / TUIC / Trojan / AnyTLS / Socks5
- **系统**：Debian 12 / 13（root 运行）
- **命令**：`sb`

## 一键安装

```bash
wget -O sb.sh https://raw.githubusercontent.com/merlin-node/sbox/main/sb.sh && bash sb.sh
```

或用 curl：

```bash
curl -fsSL https://raw.githubusercontent.com/merlin-node/sbox/main/sb.sh -o sb.sh && bash sb.sh
```

首次运行会自动安装依赖、下载 sing-box、配置 systemd 服务，并将脚本复制到 `/usr/local/bin/sb`。
之后任何位置输入 `sb` 即可呼出菜单。

## 更新

脚本菜单内：`9 脚本管理 → 1 更新脚本`

或手动：

```bash
wget -O /usr/local/bin/sb https://raw.githubusercontent.com/merlin-node/sbox/main/sb.sh && chmod +x /usr/local/bin/sb
```

## 卸载

脚本菜单内：`9 脚本管理 → 2 一键卸载`

会移除 sing-box 二进制、配置目录、systemd 服务、日志、`sb` 命令。

## 功能菜单

```
1. 添加配置           # 创建入站节点（IPv4/IPv6 → SS / Reality / AnyTLS）
2. 更改配置           # 改备注、改端口
3. 查看配置           # 列出所有节点与分享链接
4. 删除配置
5. 分流规则管理        # 出站节点、域名规则、屏蔽大陆
6. IPv4/IPv6 优先级与策略
7. 配置流量使用情况     # vnstat 统计
8. sing-box 管理       # 启停、日志、版本切换、时间同步
9. 脚本管理            # 更新、卸载
0. 退出
```

## 注意事项

- **时间同步**：SS-2022 / Reality 等协议要求服务器与客户端时间偏差 < 30 秒，否则客户端连不上。首次安装会自动检测，菜单 `8 → t` 可随时一键修复。
- **IPv6**：节点会根据创建时选择的 IPv4 / IPv6 自动绑定监听地址，禁用 IPv6 的机器只创建 IPv4 节点即可。
- **AnyTLS**：建议选择 ACME 真实证书（需要域名解析到本机 + 80 端口可访问），更安全。

## 作者

Merlin
