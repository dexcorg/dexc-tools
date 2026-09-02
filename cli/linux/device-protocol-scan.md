# device-protocol-scan.sh — 设备协议检测工具（Linux）

> **版本**：1.1  
> **适用系统**：Linux（Ubuntu 18.04+ / Debian / CentOS 等主流发行版）  
> **依赖**：`bash` 4+、`timeout`（coreutils，macOS 可用 `gtimeout`）、`ping`、`od`、`dd`、`mktemp`；`ip`（iproute2）或 `ifconfig`（二选一）；`openssl`（可选，缺失时 HTTPS 协议降级为仅 TCP 开放检测）

---

## 功能概述

`device-protocol-scan.sh` 是 `cli/windows/device-protocol-scan.ps1` 的 **Linux Bash 移植版**，用于扫描局域网设备并检测其开放的端口与协议服务。

主要能力：

- 自动识别本机网卡（多网卡时可选择要检测的网卡），或通过 `-Subnet` 手动指定网段
- Ping 扫描网段内存活主机
- 并发检测各主机上目标协议端口是否开放
- 对开放端口做**协议握手复核**（HTTP/HTTPS/SSH/FTP/SMTP/RTSP/Telnet/RDP/SMB/SIP/MQTT/Redis 共 12 种）
- 输出每台设备的 IP、MAC、端口、协议状态码与服务 banner
- 支持导出带 UTF-8 BOM 的 CSV 结果文件

---

## 使用方法

```bash
# 交互模式（推荐）
bash device-protocol-scan.sh

# 非交互模式：指定网段与协议，并导出 CSV
bash device-protocol-scan.sh -Subnet 192.168.1.0/24 -Protocol HTTP -OutFile result.csv
```

交互模式下按屏幕提示完成：

1. 选择要检测的协议（输入数字后回车，输入 `q` 取消）
2. 多网卡时选择要检测的网卡（输入数字后回车，输入 `q` 取消）
3. 确认扫描参数（网段 / 端口 / 超时时间）
4. 自动执行 4 步扫描并展示结果

---

## 参数说明

| 参数 | 说明 | 默认值 |
|---|---|---|
| `-Subnet <CIDR>` | 指定扫描网段，如 `192.168.1.0/24`；优先于网卡选择 | 自动识别并选择网卡 |
| `-Interface <接口名或IP>` | 指定要检测的网卡（接口名或 IP），跳过网卡菜单 | 多网卡时交互选择 |
| `-Protocol <名称>` | 指定要检测的协议（见协议清单） | 交互菜单选择 |
| `-Ports <列表>` | 附加原始端口，仅做 TCP 开放检测（不作协议复核），逗号分隔 | 无 |
| `-TimeoutMs <毫秒>` | TCP 连接超时 | `1500` |
| `-PingTimeoutMs <毫秒>` | Ping 超时 | `500` |
| `-OutFile <路径>` | 导出 CSV 结果文件 | 无 |

> 说明：无论指定与否，每次**只检测同一种协议**；附加的 `-Ports` 端口只报告「端口开放」。
> 网卡选择优先级：`-Subnet`（显式网段）＞ `-Interface`（锁定网卡）＞ 交互菜单 ＞ 非交互取首个候选。

---

## 协议清单

| 序号 | 协议 | 默认端口 | 判定方式 |
|---|---|---|---|
| 1 | HTTP | 80 | `GET / HTTP/1.0`，解析 `HTTP/1.x <code>` 与 `Server` 头 |
| 2 | HTTPS | 443 | openssl `s_client` 发起 TLS 握手后发送 HTTP 请求 |
| 3 | SSH | 22 | 读取 banner，匹配 `^SSH-\d` |
| 4 | FTP | 21 | 读取 banner，匹配 `^220[ -]` |
| 5 | SMTP | 25 | 读取 banner，匹配 `^220[ -]` |
| 6 | RTSP | 554 / 8554 | `OPTIONS RTSP/1.0`，解析 `RTSP/1.0 <code>` |
| 7 | Telnet | 23 | 读取 banner 并清洗为可打印文本 |
| 8 | RDP | 3389 | 发送 RDP 握手报文，响应以 `03 00` 开头 |
| 9 | SMB | 445 | 发送 SMB2 Negociate 报文，验证 `FE 53 4D 42` 签名并提取方言（Dialect） |
| 10 | SIP | 5060 | `OPTIONS SIP/2.0`，解析 `SIP/2.0 <code>` |
| 11 | MQTT | 1883 | 发送 CONNECT 报文，响应为 `20 xx xx 00 00` |
| 12 | Redis | 6379 | 发送 `PING`，响应为 `+PONG` |

---

## 实现机制

### 总体流程

```
启动
 └─ 参数解析与工具检查
 └─ 显示 Banner
 └─ 收集参数：协议 → 网卡（多网卡时选择） → 端口 → 回显确认
 └─ 步骤 1/4：识别网卡与待扫描主机（排除本机）
 └─ 步骤 2/4：Ping 扫描存活主机
 └─ 步骤 3/4：检测开放端口（TCP connect）
 └─ 步骤 4/4：协议握手复核
 └─ 结果汇总（分协议表格 / CSV 导出）→ 退出
```

---

### 并发批处理

Ping 与 TCP 端口扫描均采用 **每批 128 个后台作业并发**、`wait` 后汇总的方式，避免拉起过多进程同时保证整网段扫描足够快。每个后台作业的绝对超时由 `timeout`（缺失时降级为 `gtimeout`，两者皆无则报缺失）兜底，防止死等。

---

### 网段计算：`gen_subnet_hosts(ip, prefix)`

按 CIDR 前缀计算掩码，枚举 `网络地址+1 ~ 广播地址-1` 的全部主机 IP（支持 `/1`~`/30`，上限 65534 台），结果写入全局数组 `HOSTS`。

---

### 网卡识别：`list_active_ipv4`

遍历本机全部网卡（仅保留 **up 连接 / 非 loopback / 非 linklocal** 的 IPv4），将候选写入全局并行数组 `NIC_NAMES` / `NIC_IPS` / `NIC_PREFIXES` / `NIC_STATES`，供交互菜单展示（接口名 + IP/前缀 + 连接状态）：

```
[输入] 请选择要检测的网卡 [1 - N / q 取消]:
  1. eth0       192.168.1.100/24  [已连接]
  2. wlan0      10.0.0.5/16       [未连接]
```

- 数据来源优先级：`ip -4 -o addr show`（iproute2）＞ `/sys/class/net` 遍历 ＞ `ifconfig` 逐接口解析。
- 与 `-Subnet` 的关系：`-Subnet` 显式指定网段时跳过网卡选择；`-Interface`（接口名或 IP）可锁定网卡。
- 非交互模式（stdin 非 TTY）未指定网卡时，自动取首个候选（兼容旧行为）。

---

### TCP 端口探测

```
timeout X bash -c "exec 3<>/dev/tcp/$ip/$port"
```

依赖 bash 内建 `/dev/tcp`，成功即视为端口开放，无需额外工具。

---

### 协议握手复核

- **文本协议**（HTTP/SSH/FTP/SMTP/RTSP/SIP/Telnet/Redis）：`read_text` 通过 `/dev/tcp` 连接，`printf '%b'` 发送报文，`cat <&3 | head -c <n>` 读回响应文本。
- **二进制协议**（RDP/MQTT/SMB）：`read_hex` 用 `dd bs=1 count=<n> <&3` 读取后经 `od -An -v -tx1` 输出十六进制（`-v` 防止 BSD `od` 将重复行折叠为 `*`），再做字节级比对：

| 协议 | 判定条件 | 输出信息 |
|---|---|---|
| RDP | 响应以 `03 00` 开头 | 协议名 |
| MQTT | 第 1 字节 `20` 且第 4 字节 `00` | 协议名 |
| SMB | 偏移 8–15 为 `FE 53 4D 42` | 提取偏移 72 处 Dialect（如 `SMB 0x0202`） |

RDP / MQTT / SMB 报文定义（`RDP_REQ` / `MQTT_REQ` / `SMB_REQ`）与 PowerShell 版**逐字节一致**。

---

### HTTPS 复核

HTTPS 探测通过管道将 HTTP 请求写入 `openssl s_client` 的标准输入，输出同样经 `parse_http_resp` 解析。若本机未安装 `openssl`，HTTPS 探测返回「仅 TCP 开放」降级结果（`TCP|ip|mac|port|0|(port open)`），并在 Banner 中提示安装命令。

---

### MAC 地址解析：`get_mac(ip)`

按以下顺序尝试获取主机 MAC：

| 优先级 | 方式 |
|---|---|
| 1 | `ip neigh show <ip>`（iproute2 邻居表） |
| 2 | 解析 `/proc/net/arp`（内核 ARP 表） |
| 3 | 均无结果时显示 `N/A` |

MAC 会过滤掉全零（`00-00-00-00-00-00`）与广播（`FF-FF-FF-FF-FF-FF`）地址。

---

### 结果表与 CSV 导出

结果统一以 `协议|IP|MAC|端口|状态码|服务信息` 六字段存储。

- 控制台按协议分组打印对齐表格；
- `export_csv` 将结果按协议/IP/端口排序后写入 CSV，**首行带 UTF-8 BOM**（`\xef\xbb\xbf`），并用标准 CSV 引号转义含空格、逗号、引号的字段，可直接用 Excel 打开。

---

## 文件影响说明

| 项目 | 说明 |
|---|---|
| 持久化文件 | 无（仅读取网络配置与 ARP 表） |
| 临时文件 | 扫描期间在 `mktemp -d` 临时目录中按批次记录存活主机与开放端口，结束后自动清理 |

---

## 版本历史

| 版本 | 变更说明 |
|---|---|
| 1.1 | 新增多网卡支持：自动枚举本机全部网卡并展示连接状态，交互时可选择要检测的网卡；新增 `-Interface`（接口名或 IP）参数锁定网卡；`-Subnet` 优先于网卡选择；非交互未指定网卡时自动取首个候选 |
| 1.0 | 初始版本：与 `device-protocol-scan.ps1` 功能等价的纯 Bash 移植；支持 12 种协议握手复核、128 并发批处理、CSV 导出、非交互模式 |