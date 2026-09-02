# net-config.sh — 网卡静态 IP 配置工具

> **版本**：1.1  
> **适用系统**：Linux（Ubuntu 18.04+ / Debian / 其他 systemd 发行版）  
> **依赖**：`bash` 4+，以下工具按需调用（均为可选降级）：`nmcli`、`ip`（iproute2）、`ifconfig`、`netplan`、`ifup`/`ifdown`

---

## 功能概述

`net-config.sh` 是一个交互式命令行工具，用于为 Linux 主机的指定网卡设置**静态 IPv4 地址**。

主要能力：

- 列出所有可用网卡及其连接状态
- 显示所选网卡的当前 IP、子网掩码、默认网关、MAC 地址
- 引导用户输入新的 IP、子网掩码、默认网关（网关可选）
- **自动判断持久化方式**，确保重启后配置依然生效
- 提供完整的参数校验与用户友好的交互提示

---

## 使用方法

```bash
# 以 root 身份运行（推荐）
sudo bash net-config.sh

# 或以普通用户运行（脚本内部调用 sudo）
bash net-config.sh
```

按屏幕提示依次完成以下步骤：

1. 从列表中选择要配置的网卡
2. 查看当前配置，确认是否需要修改
3. 输入新的 IP 地址、子网掩码、默认网关
4. 确认后自动应用并持久化

---

## 实现机制

### 总体流程

```
启动
 └─ 显示 Banner
 └─ 权限检查（非 root 则提示使用 sudo）
 └─ 步骤 1：枚举网卡 → 用户选择
 └─ 步骤 2：读取当前配置 → 用户确认是否修改
 └─ 步骤 3：收集新参数（IP / 子网掩码 / 网关）
 └─ 步骤 4：应用配置（即时生效 + 持久化）
 └─ 显示结果 → 退出
```

---

### 网卡枚举：`load_adapters()`

按优先级尝试以下方式枚举所有非环回网卡：

| 优先级 | 方式 | 条件 |
|---|---|---|
| 1 | 读取 `/sys/class/net/` 目录 | 目录存在（大多数 Linux） |
| 2 | `ip -br link show` | `ip` 命令可用 |
| 3 | `ifconfig -a` | `ifconfig` 可用 |

结果写入全局数组 `ADAPTER_NAMES`、`ADAPTER_STATES`、`ADAPTER_MACS`。

---

### 当前配置读取：`get_net_config(dev)`

按优先级查询指定网卡的 IP、掩码、网关、MAC：

| 信息 | 来源 |
|---|---|
| MAC 地址 | `/sys/class/net/<dev>/address` |
| IP / 掩码 | `ip -4 -o addr show dev <dev>`（优先）或 `ifconfig <dev>` |
| 默认网关 | `ip route show default dev <dev>`（优先）或 `route -n` |

---

### 参数校验

| 函数 | 用途 |
|---|---|
| `validate_ipv4(ip)` | 校验点分十进制 IPv4 格式（4 段，每段 0–255，无前导零） |
| `validate_subnet_mask(mask)` | 校验子网掩码（调用 `mask2cidr` 验证连续性） |
| `mask2cidr(mask)` | 点分十进制掩码 → CIDR 前缀长度 |
| `cidr2mask(cidr)` | CIDR 前缀长度 → 点分十进制掩码 |

---

### 配置应用与持久化：`apply_net_config(dev, ip, mask, gw)`

这是脚本的核心函数，分为**两条路径**：

#### 方式一：NetworkManager 管理（优先）

**触发条件**：`nmcli` 可用，且目标网卡状态不为 `unmanaged`。

```
nmcli -t -f DEVICE,STATE dev  → 检测网卡是否被 NM 管理
nmcli con show                → 查找已有连接名
nmcli con add                 → 若无连接则新建
nmcli con mod                 → 写入 IP / 掩码 / 网关 / ipv4.method=manual
nmcli con up                  → 激活连接
```

配置写入 `/etc/NetworkManager/system-connections/`，**重启后持久有效**。

---

#### 方式二：iproute2 即时生效 + 自动持久化

**触发条件**：`nmcli` 不可用，或网卡为 `unmanaged` 状态。

**Step 1 — 即时生效（运行时）**

```bash
ip -4 addr flush dev <dev>
ip addr add <ip>/<prefix> dev <dev>
ip link set dev <dev> up
ip route replace default via <gw> dev <dev>   # 仅在 gw 非空时执行
```

**Step 2 — 自动持久化**

调用 `detect_persist_backend()` 检测系统持久化后端，按结果选择策略：

```
detect_persist_backend()
 ├─ /etc/netplan/*.yaml 存在  → PERSIST_BACKEND=netplan
 ├─ /etc/network/interfaces 存在 → PERSIST_BACKEND=ifupdown
 └─ 否则                      → PERSIST_BACKEND=none
```

---

#### 持久化策略 A：Netplan（`persist_netplan`）

适用于 **Ubuntu 18.04+** 等使用 Netplan 的系统。

- 写入文件：`/etc/netplan/99-static-<dev>.yaml`（独立文件，不污染已有配置）
- 设置权限 `600`（Netplan 要求）
- 执行 `netplan apply` 使配置生效

生成的 YAML 示例：

```yaml
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      addresses:
        - 192.168.1.100/24
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses: []
```

---

#### 持久化策略 B：ifupdown（`persist_ifupdown`）

适用于使用传统 **ifupdown** 管理网络的系统（Debian 等）。

1. 自动备份原文件：`/etc/network/interfaces.bak.<timestamp>`
2. 从备份文件中移除目标网卡已有的 `iface <dev> inet` stanza
3. 追加新的 stanza：

```
auto eth0
iface eth0 inet static
    address 192.168.1.100
    netmask 255.255.255.0
    gateway 192.168.1.1
```

4. 执行 `ifdown <dev> && ifup <dev>` 重新激活网卡

---

#### 持久化策略 C：无已知后端（警告）

当 Netplan 和 ifupdown 均未检测到时，脚本：

- 打印明确警告：**此次配置仅在本次运行期间有效，重启后将失效**
- 给出两种手动持久化的操作指引（Netplan / ifupdown）

---

### 持久化结果输出

每次 `apply_net_config()` 执行后，全局变量 `PERSIST_RESULT_MSG` 会记录持久化结果，并在步骤 4 完成后打印：

| 场景 | 输出示例 |
|---|---|
| NM 管理 | `[持久化] 配置已通过 NetworkManager 写入连接 "eth0"（重启后依然有效）` |
| Netplan | `[持久化] 配置已写入 /etc/netplan/99-static-eth0.yaml 并通过 netplan apply 生效` |
| ifupdown | `[持久化] 配置已写入 /etc/network/interfaces（备份: ...，重启后依然有效）` |
| 无后端 | `[警告] 未检测到支持的持久化后端，此次配置仅在本次运行期间有效…` |

---

## 文件影响说明

| 场景 | 被修改的文件 |
|---|---|
| NM 管理 | `/etc/NetworkManager/system-connections/<连接名>` |
| Netplan | `/etc/netplan/99-static-<dev>.yaml`（新建） |
| ifupdown | `/etc/network/interfaces`（修改）+ `*.bak.<timestamp>`（备份） |
| 无后端 | 无文件修改 |

---

## 版本历史

| 版本 | 变更说明 |
|---|---|
| 1.0 | 初始版本：支持 nmcli 和 iproute2 即时配置 |
| 1.1 | 新增持久化支持：非 NM 场景自动写入 Netplan 或 ifupdown 配置；增加持久化结果反馈；Banner 补充注意事项 |

