# 设备协议检测工具（Python）

> 当前版本：`1.0`

自动识别本机所在网段，扫描存活主机，按用户选择的 1 种内置协议检测目标端口，并通过协议握手 / banner 复核确认服务类型，最终输出每台设备的 IP、MAC 与服务信息。每次运行仅检测 1 种协议。

本工具为 `cli/windows/device-protocol-scan.ps1` 的跨平台移植版（macOS / Linux），仅使用 Python 标准库实现。无 Python 环境时仍可使用 Windows 版 `cli/windows/device-protocol-scan.ps1`。

## 功能特性

- **跨平台**：macOS / Linux 自动适配网段识别、Ping 参数、ARP/MAC 查询方式
- **自动识别网段**：默认自动探测本机所在网段，也可 `-Subnet` 手动指定
- **并行扫描**：Ping 存活与 TCP 端口检测按批次（128）并发执行
- **协议握手复核**：12 种内置协议通过握手 / banner 判定，降低误报
- **额外原始端口**：`-Ports` 附加端口仅做 TCP 开放检测（TCP-only）
- **CSV 导出**：`-OutFile` 导出全部结果（UTF-8 带 BOM，兼容 Excel）
- **交互 / 非交互自动切换**：参数齐全且标准输入非 TTY 时不等待输入，避免阻塞管道

## 环境要求

- Python 3.9+
- 无需第三方依赖（仅标准库）
- 需在可访问目标网段的网络环境下运行

## 安装

首次使用需在 `python` 目录下创建独立虚拟环境（不污染全局环境）。本工具无需额外依赖，但仍按规范在 venv 中运行：

```bash
python3 -m venv .venv
```

## 使用方式

### 交互式运行

```bash
.venv/bin/python device-protocol-scan.py
```

启动后先展示工具说明横幅，再按提示选择要检测的 1 种协议（输入数字后按回车，`q` 取消），随后回显扫描参数确认（`y` 开始 / `q` 取消）后自动执行。

执行流程：

1. 识别网段与待扫描主机
2. Ping 扫描存活主机
3. 检测开放端口
4. 协议握手复核

结束后输出结果汇总，按回车退出。

### 命令行参数（非交互）

```bash
.venv/bin/python device-protocol-scan.py -Protocol SSH -Subnet 192.168.1.0/24
```

| 参数 | 说明 |
| --- | --- |
| `-Subnet` / `--subnet` | 手动指定 CIDR 网段，例如 `192.168.1.0/24`；缺省自动识别本机网段 |
| `-Protocol` / `--protocol` | 要检测的协议名（每次 1 种），例如 `SSH`；缺省进入交互菜单选择 |
| `-Ports` / `--ports` | 额外要检测的原始端口（TCP-only），例如 `8080,8443` |
| `-TimeoutMs` / `--timeout` | TCP 连接 / 读取超时（毫秒），默认 `1500` |
| `-PingTimeoutMs` / `--pingtimeout` | Ping 超时（毫秒），默认 `500` |
| `-OutFile` / `--outfile` | 将全部结果导出为 CSV 文件（可选） |

> 全部参数由命令行指定且标准输入非 TTY 时以非交互模式运行：不再回显确认、结束后不等待回车；若协议缺失且标准输入非 TTY，则报错退出，不会挂起等待输入。

## 内置协议

| 协议 | 默认端口 | 判定方式 |
| --- | --- | --- |
| HTTP | 80 | GET 请求，响应 `HTTP/x.x` |
| HTTPS | 443 | TLS 握手后 GET 请求，响应 `HTTP/x.x` |
| SSH | 22 | banner 以 `SSH-` 开头 |
| FTP | 21 | banner 以 `220 ` 或 `220-` 开头 |
| SMTP | 25 | banner 以 `220 ` 或 `220-` 开头 |
| RTSP | 554, 8554 | OPTIONS 请求，响应 `RTSP/1.0` |
| Telnet | 23 | banner 文本（过滤控制字节） |
| RDP | 3389 | 发送 X.224 连接请求后响应头 `03 00` |
| SMB | 445 | SMB2 Negotiate，响应签名 `FE 53 4D 42` |
| SIP | 5060 | OPTIONS 请求，响应 `SIP/2.0` |
| MQTT | 1883 | CONNECT 报文，响应 `CONNACK (0x20)` |
| Redis | 6379 | PING，响应 `+PONG` |

## 说明与限制

- 每次运行仅检测 1 种协议；可用 `-Ports` 附加原始端口（仅做 TCP 开放检测）
- HTTPS 判定不校验证书（与 Windows 版行为一致），可识别自签名证书设备
- 扫描整个网段耗时较长，请耐心等待
- MAC 查询依赖系统 ARP 表（`arp -n` / `ip neigh` / `/proc/net/arp`），未命中时记 `N/A`
- 依赖主机应答 ICMP for Ping 存活扫描；主机防火墙屏蔽 Ping 时可能漏检
- 本工具为 Windows 版 `cli/windows/device-protocol-scan.ps1` 的跨平台移植，二者功能与输出格式保持一致
- 无 Python 环境的使用者请使用 `cli/windows/device-protocol-scan.ps1`（配合 `PSRunner.cmd` 运行）