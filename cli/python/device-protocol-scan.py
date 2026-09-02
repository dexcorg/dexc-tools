#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""device-protocol-scan.py：设备协议检测工具（跨平台）。

自动识别本机网卡，扫描存活主机，按用户选择的 1 种内置协议检测目标端口，
并通过协议握手 / banner 复核确认服务类型，最终输出每台设备的 IP、MAC 与服务信息。
每次运行仅检测 1 种协议。为 cli/windows/device-protocol-scan.ps1 的 Python 移植版。

内置协议：HTTP HTTPS SSH FTP SMTP RTSP Telnet RDP SMB SIP MQTT Redis
额外原始端口：通过 -Ports 追加，仅做 TCP 端口开放检测（TCP-only）。
仅使用 Python 标准库，无需额外安装依赖。
"""

import argparse
import csv
import errno
import ipaddress
import os
import platform
import re
import select
import socket
import ssl
import struct
import subprocess
import sys
import time

try:
    for _stream in (sys.stdout, sys.stdin):
        try:
            _stream.reconfigure(encoding="utf-8")
        except Exception:
            pass
except Exception:
    pass

interactive = sys.stdin.isatty()


def run_cli(cmd):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        return p.stdout or ""
    except Exception:
        return ""


# ==================== 网段 / IP 工具 ====================

def ip_to_uint(ip):
    return int(ipaddress.IPv4Address(ip))


def uint_to_ip(u):
    return str(ipaddress.IPv4Address(u))


def netmask_prefix(nm):
    try:
        if nm.lower().startswith("0x"):
            v = int(nm, 16)
        else:
            v = int(ipaddress.IPv4Address(nm))
        return bin(v).count("1")
    except Exception:
        return 24


def is_linklocal(ip):
    return ip.startswith("169.254.") or ip.startswith("127.")


def get_subnet_hosts(ip, prefix):
    if prefix < 1 or prefix > 32:
        return []
    net = ipaddress.ip_network("{}/{}".format(ip, prefix), strict=False)
    total = net.num_addresses - 2
    if total < 1 or total > 65534:
        return []
    return [str(h) for h in net.hosts()]


def list_active_ipv4():
    """返回全部可用候选网卡，每项为 dict {iface, ip, prefix, state}。

    仅保留已连接/up、非 loopback、非 linklocal 的 IPv4；按平台枚举所有接口。
    """
    system = platform.system()
    found = []

    def add(iface, ip, prefix, state):
        if iface is None or ip is None or prefix is None:
            return
        if iface == "lo" or is_linklocal(ip):
            return
        found.append({"iface": str(iface), "ip": ip,
                      "prefix": int(prefix), "state": bool(state)})

    if system == "Darwin":
        relist = run_cli(["ifconfig", "-l"]).split()
        for ifname in relist:
            if ifname == "lo0":
                continue
            ifo = run_cli(["ifconfig", ifname])
            up = re.search(r"^%s:\s+flags=[0-9]+<([^>]*)>" % re.escape(ifname), ifo, re.M)
            if not up or "UP" not in up.group(1):
                continue
            ip = run_cli(["ipconfig", "getifaddr", ifname]).strip()
            if not ip or is_linklocal(ip):
                continue
            prefix = 24
            nm = re.search(r"inet\s+\S+\s+netmask\s+(0x[0-9a-fA-F]+)", ifo)
            if nm:
                prefix = netmask_prefix(nm.group(1))
            add(ifname, ip, prefix, True)

    elif system == "Linux":
        out = run_cli(["ip", "-4", "-o", "addr", "show"])
        for m in re.finditer(
            r"^\d+:\s+(\S+)\s+inet\s+(\d+\.\d+\.\d+\.\d+)/(\d+)",
            out, re.M
        ):
            ifname = m.group(1)
            if ifname == "lo":
                continue
            state = "UP" in run_cli(["ip", "link", "show", ifname])
            add(ifname, m.group(2), m.group(3), state)

    elif system == "Windows":
        try:
            import netifaces  # pragma: no cover - 若存在则优先使用
        except Exception:
            netifaces = None
        if netifaces is not None:  # pragma: no cover
            for iface in netifaces.interfaces():
                addrs = netifaces.ifaddresses(iface)
                addrs4 = addrs.get(netifaces.AF_INET, [])
                for a in addrs4:
                    ip = a.get("addr", "")
                    if ip and not is_linklocal(ip):
                        add(iface, ip, netmask_prefix(a.get("netmask", "255.255.255.0")), True)
        else:
            out = run_cli(["ipconfig", "/all"])
            blocks = re.split(r"\n(?=\S)", out)
            for blk in blocks:
                name_m = re.search(r"^(?:以太网|Ethernet|无线局域网|Wireless|本地连接|Ethernet adapter|Wireless LAN adapter)[^\r\n]*", blk, re.M)
                if not name_m:
                    name_m = re.search(r"\b(?:adapter|适配器)[^\r\n]*\S+", blk, re.I)
                iface = name_m.group(0).strip() if name_m else "?"
                ip_m = re.search(r"IPv4[^\r\n]*?(\d{1,3}(?:\.\d{1,3}){3})", blk)
                if not ip_m:
                    continue
                ip = ip_m.group(1)
                if is_linklocal(ip):
                    continue
                prefix = 24
                sm = re.search(r"[^\r\n]*?(?:子网掩码|Subnet Mask|サブネット マスク)[^\r\n]*?(\d{1,3}(?:\.\d{1,3}){3})", blk)
                if sm:
                    prefix = netmask_prefix(sm.group(1))
                state = (re.search(r"(?i)媒体断开|Media disconnected|メディア", blk) is None)
                add(iface, ip, prefix, state)

    if found:
        return found

    # 通用回退：ifconfig 解析
    out = run_cli(["ifconfig"])
    for m in re.finditer(
        r"^(\S+):\s+flags=[0-9]+<([^>]*)>.*?\n(?:.*\n)*?\s+inet\s+(\d+\.\d+\.\d+\.\d+)\s+netmask\s+(0x[0-9a-fA-F]+|\d+\.\d+\.\d+\.\d+)",
        out, re.M | re.S,
    ):
        ifname = m.group(1)
        if "UP" not in m.group(2):
            continue
        ip = m.group(3)
        if is_linklocal(ip):
            continue
        add(ifname, ip, netmask_prefix(m.group(4)), True)

    return found


def get_active_ipv4():
    """返回 (ip, prefix)（取首个候选），无法识别返回 (None, 0)。"""
    lst = list_active_ipv4()
    if lst:
        return lst[0]["ip"], lst[0]["prefix"]
    system = platform.system()

    if system == "Darwin":
        out = run_cli(["route", "-n", "get", "default"])
        m = re.search(r"interface:\s*(\S+)", out)
        if m:
            ifname = m.group(1).strip()
            ip = run_cli(["ipconfig", "getifaddr", ifname]).strip()
            if ip and not is_linklocal(ip):
                prefix = 24
                ifo = run_cli(["ifconfig", ifname])
                nm = re.search(r"inet\s+\S+\s+netmask\s+(0x[0-9a-fA-F]+)", ifo)
                if nm:
                    prefix = netmask_prefix(nm.group(1))
                return ip, prefix

    elif system == "Linux":
        out = run_cli(["ip", "-4", "route", "show", "default"])
        m = re.search(r"default\b.*\bdev\s+(\S+)", out) or re.search(r"dev\s+(\S+)", out)
        if m:
            ifname = m.group(1).strip()
            out2 = run_cli(["ip", "-4", "addr", "show", ifname])
            mm = re.search(r"inet\s+(\d+\.\d+\.\d+\.\d+)/(\d+)", out2)
            if mm:
                ip, prefix = mm.group(1), int(mm.group(2))
                if not is_linklocal(ip):
                    return ip, prefix

    elif system == "Windows":
        out = run_cli(["ipconfig"])
        m = re.search(r"IPv4[^\r\n]*?(\d{1,3}(?:\.\d{1,3}){3})", out)
        if m:
            ip = m.group(1)
            prefix = 24
            sm = re.search(r"[^\r\n]*?(\d{1,3}(?:\.\d{1,3}){3})\s*$", out, re.M)
            return ip, prefix

    # 通用回退：ifconfig 解析
    out = run_cli(["ifconfig"])
    for m in re.finditer(
        r"inet\s+(\d+\.\d+\.\d+\.\d+)\s+netmask\s+(0x[0-9a-fA-F]+|\d+\.\d+\.\d+\.\d+)", out
    ):
        ip = m.group(1)
        if is_linklocal(ip):
            continue
        return ip, netmask_prefix(m.group(2))

    # 纯 Python 回退：探测出站 IP（无前缀时按 /24）
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
        finally:
            s.close()
        if ip and not is_linklocal(ip):
            return ip, 24
    except OSError:
        pass

    return None, 0


# ==================== Ping 存活扫描 ====================

def ping_cmd(ip, timeout_ms):
    system = platform.system()
    if system == "Darwin":
        return ["ping", "-c", "1", "-t", "1", "-W", str(timeout_ms), ip]
    if system == "Linux":
        secs = max(1, timeout_ms // 1000)
        return ["ping", "-c", "1", "-W", str(secs), ip]
    if system == "Windows":
        return ["ping", "-n", "1", "-w", str(timeout_ms), ip]
    return None


def ping_sweep(hosts, timeout_ms):
    alive = []
    batch_size = 128
    total_batches = (len(hosts) + batch_size - 1) // batch_size
    sw = time.monotonic()
    for i in range(0, len(hosts), batch_size):
        batch_index = i // batch_size + 1
        batch = hosts[i:i + batch_size]
        procs = []
        for ip in batch:
            cmd = ping_cmd(ip, timeout_ms)
            if not cmd:
                continue
            try:
                p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                procs.append((ip, p))
            except Exception:
                pass
        for ip, p in procs:
            try:
                rc = p.wait(timeout=timeout_ms / 1000 + 15)
            except subprocess.TimeoutExpired:
                try:
                    p.kill()
                except Exception:
                    pass
                rc = 1
            if rc == 0:
                alive.append(ip)
        print("  Ping 批次 {}/{}，已用 {:.1f}s".format(batch_index, total_batches, time.monotonic() - sw), flush=True)
    return alive


# ==================== TCP 端口扫描 ====================

def test_tcp_ports(ips, ports, timeout_ms):
    pairs = [(h, p) for h in ips for p in ports]
    results = []
    batch_size = 128
    total_batches = (len(pairs) + batch_size - 1) // batch_size
    sw = time.monotonic()
    for i in range(0, len(pairs), batch_size):
        batch_index = i // batch_size + 1
        batch = pairs[i:i + batch_size]
        socks = []
        for ip, port in batch:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setblocking(False)
            try:
                s.connect_ex((ip, port))
            except OSError:
                pass
            socks.append(s)
        done = [False] * len(batch)
        deadline = time.monotonic() + timeout_ms / 1000.0
        while True:
            pending = [idx for idx, s in enumerate(socks) if not done[idx]]
            if not pending:
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            relist = [socks[idx] for idx in pending]
            try:
                _, wlist, xlist = select.select([], relist, relist, remaining)
            except (OSError, ValueError):
                break
            ready = set(wlist) | set(xlist)
            for idx in pending:
                s = socks[idx]
                if s in ready and not done[idx]:
                    try:
                        err = s.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
                    except OSError:
                        err = 1
                    if err == 0:
                        results.append(batch[idx])
                    done[idx] = True
                    try:
                        s.close()
                    except OSError:
                        pass
        for idx, s in enumerate(socks):
            if not done[idx]:
                try:
                    s.close()
                except OSError:
                    pass
        print("  端口批次 {}/{}，已用 {:.1f}s".format(
            batch_index, total_batches, time.monotonic() - sw), flush=True)
    return results


# ==================== 协议握手复核 ====================

def connect_timeout(ip, port, timeout_ms):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setblocking(False)
    err = s.connect_ex((ip, port))
    try:
        if err in (0, errno.EINPROGRESS, errno.EALREADY, errno.EINTR):
            _, w, _ = select.select([], [s], [], timeout_ms / 1000.0)
            if w:
                e = s.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
                if e == 0:
                    s.setblocking(True)
                    s.settimeout(timeout_ms / 1000.0 + 5)
                    return s
    except (OSError, ValueError):
        pass
    try:
        s.close()
    except OSError:
        pass
    return None


def read_bytes_timeout(stream, timeout_ms, max_bytes=4096):
    data = bytearray()
    try:
        deadline = time.monotonic() + timeout_ms / 1000.0
        got = False
        while time.monotonic() < deadline and len(data) < max_bytes:
            try:
                r, _, _ = select.select([stream], [], [], max(0.0, deadline - time.monotonic()))
            except (OSError, ValueError):
                break
            if not r:
                break
            chunk = stream.recv(1024)
            if not chunk:
                break
            data += chunk
            if not got:
                got = True
                deadline = time.monotonic() + min(200, timeout_ms) / 1000.0
    except (OSError, ssl.SSLError):
        pass
    return bytes(data)


def ascii_text(raw):
    return raw.decode("ascii", "replace")


def test_http(ip, port, timeout_ms, use_tls):
    sock = None
    stream = None
    try:
        sock = connect_timeout(ip, port, timeout_ms)
        if not sock:
            return None
        stream = sock
        if use_tls:
            ctx = ssl._create_unverified_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            try:
                ctx.minimum_version = ssl.TLSVersion.TLSv1_2
            except Exception:
                pass
            stream = ctx.wrap_socket(sock, server_hostname=ip)
        req = "GET / HTTP/1.0\r\nHost: {}\r\nUser-Agent: Device-Scanner\r\nConnection: close\r\n\r\n".format(ip).encode("ascii")
        stream.sendall(req)
        raw = read_bytes_timeout(stream, timeout_ms)
        if not raw:
            return None
        resp = ascii_text(raw)
        m = re.search(r"(?im)^HTTP/\d\.\d\s+(\d+)", resp)
        if m:
            code = int(m.group(1))
            server = ""
            sm = re.search(r"(?im)^Server:\s*(.+)$", resp)
            if sm:
                server = sm.group(1).strip()
            return {"Valid": True, "Code": code, "Server": server}
    except Exception:
        return None
    finally:
        try:
            if stream and stream is not sock:
                stream.close()
        except Exception:
            pass
        try:
            if sock:
                sock.close()
        except Exception:
            pass
    return None


def test_ssh(ip, port, timeout_ms):
    sock = None
    try:
        sock = connect_timeout(ip, port, timeout_ms)
        if not sock:
            return None
        raw = read_bytes_timeout(sock, timeout_ms)
        if not raw:
            return None
        banner = ascii_text(raw)
        if re.search(r"(?m)^SSH-\d\.\d", banner):
            first = next((ln.strip() for ln in banner.splitlines() if ln.strip()), "").strip()
            return {"Valid": True, "Code": 0, "Server": first}
    except Exception:
        pass
    finally:
        try:
            if sock:
                sock.close()
        except Exception:
            pass
    return None


def test_banner220(ip, port, timeout_ms):
    sock = None
    try:
        sock = connect_timeout(ip, port, timeout_ms)
        if not sock:
            return None
        raw = read_bytes_timeout(sock, timeout_ms)
        if not raw:
            return None
        first = next((ln.strip() for ln in ascii_text(raw).splitlines() if ln.strip()), "").strip()
        if first and re.match(r"^220[\s-]", first):
            return {"Valid": True, "Code": 0, "Server": first}
    except Exception:
        pass
    finally:
        try:
            if sock:
                sock.close()
        except Exception:
            pass
    return None


def test_rtsp(ip, port, timeout_ms):
    sock = None
    try:
        sock = connect_timeout(ip, port, timeout_ms)
        if not sock:
            return None
        req = "OPTIONS rtsp://{}:{}/ RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: Device-Scanner\r\n\r\n".format(ip, port).encode("ascii")
        sock.sendall(req)
        raw = read_bytes_timeout(sock, timeout_ms)
        if not raw:
            return None
        resp = ascii_text(raw)
        m = re.search(r"(?im)^RTSP/1\.0\s+(\d+)", resp)
        if m:
            code = int(m.group(1))
            server = ""
            sm = re.search(r"(?im)^Server:\s*(.+)$", resp)
            if sm:
                server = sm.group(1).strip()
            return {"Valid": True, "Code": code, "Server": server}
    except Exception:
        pass
    finally:
        try:
            if sock:
                sock.close()
        except Exception:
            pass
    return None


def test_telnet(ip, port, timeout_ms):
    sock = None
    try:
        sock = connect_timeout(ip, port, timeout_ms)
        if not sock:
            return None
        raw = read_bytes_timeout(sock, timeout_ms)
        if not raw:
            return None
        sb = []
        for b in raw:
            if 32 <= b < 127 or b == 9:
                sb.append(chr(b))
            elif b in (10, 13):
                sb.append(" ")
        text = re.sub(r"\s+", " ", "".join(sb)).strip()
        if not text:
            text = "Telnet"
        return {"Valid": True, "Code": 0, "Server": text}
    except Exception:
        pass
    finally:
        try:
            if sock:
                sock.close()
        except Exception:
            pass
    return None


def test_rdp(ip, port, timeout_ms):
    sock = None
    try:
        sock = connect_timeout(ip, port, timeout_ms)
        if not sock:
            return None
        req = bytes([0x03, 0x00, 0x00, 0x13, 0x0E, 0xE0, 0x00, 0x00,
                     0x00, 0x01, 0x00, 0x08, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00])
        sock.sendall(req)
        raw = read_bytes_timeout(sock, timeout_ms)
        if len(raw) < 4:
            return None
        if raw[0] == 0x03 and raw[1] == 0x00:
            return {"Valid": True, "Code": 0, "Server": "RDP"}
    except Exception:
        pass
    finally:
        try:
            if sock:
                sock.close()
        except Exception:
            pass
    return None


def smb2_negotiate_request():
    b = bytearray()
    b += struct.pack(">I", 0x68)
    b += b"\xfeSMB"
    b += struct.pack("<H", 0x0040)
    b += struct.pack("<H", 0)
    b += struct.pack("<I", 0)
    b += struct.pack("<H", 0)
    b += struct.pack("<H", 1)
    b += struct.pack("<I", 0)
    b += struct.pack("<Q", 0)
    b += struct.pack("<Q", 1)
    b += struct.pack("<I", 0)
    b += struct.pack("<I", 0)
    b += struct.pack("<Q", 0)
    b += bytes(16)
    b += struct.pack("<H", 36)
    b += struct.pack("<H", 2)
    b += struct.pack("<H", 1)
    b += struct.pack("<H", 0)
    b += struct.pack("<I", 0)
    b += bytes(16)
    b += struct.pack("<I", 0)
    b += struct.pack("<H", 0)
    b += struct.pack("<H", 0)
    b += struct.pack("<H", 0x0202)
    b += struct.pack("<H", 0x0210)
    return bytes(b)


def test_smb(ip, port, timeout_ms):
    sock = None
    try:
        sock = connect_timeout(ip, port, timeout_ms)
        if not sock:
            return None
        sock.sendall(smb2_negotiate_request())
        raw = read_bytes_timeout(sock, timeout_ms, 4096)
        if len(raw) < 20:
            return None
        if raw[4:8] == b"\xfeSMB":
            dialect = ""
            if len(raw) >= 74:
                dialect = "SMB 0x{:04X}".format(struct.unpack("<H", raw[72:74])[0])
            return {"Valid": True, "Code": 0, "Server": dialect}
    except Exception:
        pass
    finally:
        try:
            if sock:
                sock.close()
        except Exception:
            pass
    return None


def test_sip(ip, port, timeout_ms):
    sock = None
    try:
        sock = connect_timeout(ip, port, timeout_ms)
        if not sock:
            return None
        req = (
            "OPTIONS sip:scanner@{} SIP/2.0\r\n"
            "Via: SIP/2.0/TCP 192.0.2.1:5060;branch=z9hG4bK7766\r\n"
            "Max-Forwards: 70\r\n"
            "To: <sip:scanner@{}>\r\n"
            "From: <sip:scanner@{}>;tag=8877\r\n"
            "Call-ID: 1a2b3c@{}\r\n"
            "CSeq: 1 OPTIONS\r\n"
            "Content-Length: 0\r\n\r\n"
        ).format(ip, ip, ip, ip).encode("ascii")
        sock.sendall(req)
        raw = read_bytes_timeout(sock, timeout_ms)
        if not raw:
            return None
        resp = ascii_text(raw)
        m = re.search(r"(?im)^SIP/2\.0\s+(\d+)", resp)
        if m:
            code = int(m.group(1))
            server = ""
            sm = re.search(r"(?im)^Server:\s*(.+)$", resp)
            if sm:
                server = sm.group(1).strip()
            return {"Valid": True, "Code": code, "Server": server}
    except Exception:
        pass
    finally:
        try:
            if sock:
                sock.close()
        except Exception:
            pass
    return None


def test_mqtt(ip, port, timeout_ms):
    sock = None
    try:
        sock = connect_timeout(ip, port, timeout_ms)
        if not sock:
            return None
        req = bytes([0x10, 0x0C, 0x00, 0x04, 0x4D, 0x51, 0x54, 0x54,
                     0x04, 0x02, 0x00, 0x3C, 0x00, 0x00])
        sock.sendall(req)
        raw = read_bytes_timeout(sock, timeout_ms)
        if len(raw) < 4:
            return None
        if raw[0] == 0x20 and raw[3] == 0x00:
            return {"Valid": True, "Code": 0, "Server": "MQTT"}
    except Exception:
        pass
    finally:
        try:
            if sock:
                sock.close()
        except Exception:
            pass
    return None


def test_redis(ip, port, timeout_ms):
    sock = None
    try:
        sock = connect_timeout(ip, port, timeout_ms)
        if not sock:
            return None
        sock.sendall(b"PING\r\n")
        raw = read_bytes_timeout(sock, timeout_ms)
        if not raw:
            return None
        if ascii_text(raw).startswith("+PONG"):
            return {"Valid": True, "Code": 0, "Server": "Redis"}
    except Exception:
        pass
    finally:
        try:
            if sock:
                sock.close()
        except Exception:
            pass
    return None


# ==================== MAC 查询 ====================

_MAC_RE = re.compile(
    r"([0-9a-fA-F]{2}[-:][0-9a-fA-F]{2}[-:][0-9a-fA-F]{2}"
    r"[-:][0-9a-fA-F]{2}[-:][0-9a-fA-F]{2}[-:][0-9a-fA-F]{2})"
)
_MAC_RE_LOOSE = re.compile(r"((?:[0-9a-fA-F]{1,2}[:-]){5}[0-9a-fA-F]{1,2})")


def _pad_mac(m):
    groups = re.split(r"[:-]", m)
    return "-".join(g.upper().zfill(2) for g in groups)


def get_mac(ip):
    system = platform.system()

    def norm(m):
        m = m.replace(":", "-").upper()
        return m

    def valid(mac):
        return mac not in ("00-00-00-00-00-00", "FF-FF-FF-FF-FF-FF")

    if system == "Darwin":
        out = run_cli(["arp", "-n", ip])
        m = _MAC_RE_LOOSE.search(out)
        if m and valid(_pad_mac(m.group(1))):
            return _pad_mac(m.group(1))
    elif system == "Linux":
        out = run_cli(["ip", "neigh", "show", ip])
        m = _MAC_RE.search(out)
        if m and valid(norm(m.group(1))):
            return norm(m.group(1))
        try:
            with open("/proc/net/arp", encoding="ascii", errors="replace") as f:
                for line in f:
                    parts = line.split()
                    if len(parts) >= 4 and parts[0] == ip and len(parts[3]) == 17:
                        mac = norm(parts[3])
                        if valid(mac):
                            return mac
        except OSError:
            pass
    elif system == "Windows":
        out = run_cli(["arp", "-a"])
        for m in re.finditer(r"\b{}\s+[0-9a-fA-F\-]{17}".format(re.escape(ip)), out):
            mm = _MAC_RE.search(out[m.start():m.start() + 80])
            if mm and valid(norm(mm.group(1))):
                return norm(mm.group(1))
    return "N/A"


# ==================== 协议注册表 ====================

PROTOCOL_TABLE = [
    {"Name": "HTTP", "Ports": [80], "Verify": lambda ip, pt, tm: test_http(ip, pt, tm, False)},
    {"Name": "HTTPS", "Ports": [443], "Verify": lambda ip, pt, tm: test_http(ip, pt, tm, True)},
    {"Name": "SSH", "Ports": [22], "Verify": test_ssh},
    {"Name": "FTP", "Ports": [21], "Verify": test_banner220},
    {"Name": "SMTP", "Ports": [25], "Verify": test_banner220},
    {"Name": "RTSP", "Ports": [554, 8554], "Verify": test_rtsp},
    {"Name": "Telnet", "Ports": [23], "Verify": test_telnet},
    {"Name": "RDP", "Ports": [3389], "Verify": test_rdp},
    {"Name": "SMB", "Ports": [445], "Verify": test_smb},
    {"Name": "SIP", "Ports": [5060], "Verify": test_sip},
    {"Name": "MQTT", "Ports": [1883], "Verify": test_mqtt},
    {"Name": "Redis", "Ports": [6379], "Verify": test_redis},
]


def get_selected_protocol(name):
    if not name:
        return None
    t = name.strip().upper()
    for item in PROTOCOL_TABLE:
        if item["Name"].upper() == t:
            return item
    return None


def show_protocol_menu(registry):
    while True:
        print("[输入] 请选择要检测的协议（每次只能选择 1 种）：", flush=True)
        for i, item in enumerate(registry):
            print("  {:>2}. {:<8} 端口: {}".format(i + 1, item["Name"], ",".join(str(p) for p in item["Ports"])))
        print("")
        choice = input("[输入] 请输入选项数字 [1 - {} / q 取消] 然后按回车: ".format(len(registry))).strip()
        if re.match(r"^[qQ]$", choice):
            return None
        try:
            n = int(choice)
        except ValueError:
            n = 0
        if n >= 1 and n <= len(registry):
            return registry[n - 1]
        print("[错误] 无效输入，请输入 1 - {} 或 q。".format(len(registry)))
        print("")


def state_label(state):
    return "已连接" if state else "未连接"


def resolve_interface(iface_arg, candidates):
    """按接口名或 IP 匹配候选网卡，返回匹配项，找不到返回 None。"""
    if not iface_arg:
        return None
    key = iface_arg.strip()
    for c in candidates:
        if c["iface"] == key or c["ip"] == key:
            return c
    return None


def show_nic_menu(candidates):
    if not candidates:
        return None
    while True:
        print("[输入] 请选择要检测的网卡 [1 - {} / q 取消]:".format(len(candidates)), flush=True)
        for i, c in enumerate(candidates):
            print("  {}. {}  {}/{}  [{}]".format(
                i + 1, c["iface"], c["ip"], c["prefix"], state_label(c["state"])))
        print("")
        choice = input("[输入] 请输入选项数字 [1 - {} / q 取消] 然后按回车: ".format(len(candidates))).strip()
        if re.match(r"^[qQ]$", choice):
            return None
        try:
            n = int(choice)
        except ValueError:
            n = 0
        if n >= 1 and n <= len(candidates):
            return candidates[n - 1]
        print("[错误] 无效输入，请输入 1 - {} 或 q。".format(len(candidates)))
        print("")


def confirm_or_exit(cancel_msg):
    if interactive:
        print(cancel_msg)
        print("")
        input("[结束] 按回车键退出...")
    return 1


# ==================== 主流程 ====================

def main():
    parser = argparse.ArgumentParser(description="设备协议检测工具")
    parser.add_argument("-Subnet", "-subnet", "--subnet", dest="subnet", default=None,
                        help="手动指定 CIDR 网段，例如 192.168.1.0/24")
    parser.add_argument("-Interface", "-interface", "--interface", dest="interface", default=None,
                        help="指定要检测的网卡（接口名或 IP），例如 eth0")
    parser.add_argument("-Protocol", "-protocol", "--protocol", dest="protocol", default=None,
                        help="要检测的协议名（每次 1 种），例如 SSH")
    parser.add_argument("-Ports", "-ports", "--ports", dest="ports", default="",
                        help="额外要检测的原始端口（TCP-only），例如 8080,8443")
    parser.add_argument("-TimeoutMs", "-timeoutms", "-timeout", "--timeout",
                        dest="timeout_ms", type=int, default=1500, help="TCP 超时（毫秒），默认 1500")
    parser.add_argument("-PingTimeoutMs", "-pingtimeoutms", "-pingtimeout", "--pingtimeout",
                        dest="ping_timeout_ms", type=int, default=500, help="Ping 超时（毫秒），默认 500")
    parser.add_argument("-OutFile", "-outfile", "--outfile", dest="out_file", default=None,
                        help="将全部结果导出为 CSV 文件（可选）")
    args = parser.parse_args()

    timeout_ms = args.timeout_ms
    ping_timeout_ms = args.ping_timeout_ms
    if timeout_ms < 0 or ping_timeout_ms < 0:
        print("[错误] TimeoutMs 与 PingTimeoutMs 必须为非负数。")
        sys.exit(confirm_or_exit("[提示] 已取消，未开始扫描。"))

    extra_ports = []
    if args.ports:
        for part in args.ports.split(","):
            part = part.strip()
            if not re.match(r"^\d+$", part):
                print("[错误] Ports 格式错误，应为逗号分隔的端口号，例如 8080,8443。")
                sys.exit(confirm_or_exit("[提示] 已取消，未开始扫描。"))
            extra_ports.append(int(part))

    print("=========================================")
    print("  设备协议检测工具")
    print("  版本 1.1")
    print("=========================================")
    print("[适用场景]")
    print("需要识别局域网内设备开放的端口与协议服务（HTTP、SSH、FTP、RTSP、RDP 等）时使用。")
    print("")
    print("[功能说明]")
    print("自动识别本机网卡（多网卡时可选择需要检测的网卡），扫描存活主机，并按所选协议做端口检测与握手复核，输出每台设备的 IP、MAC 与服务信息。")
    print("")
    print("[操作方式]")
    print("输入选项数字选择 1 种协议后按回车，输入 q 取消；多网卡时需再选择检测网卡；随后确认扫描参数后自动执行。")
    print("")
    print("[执行步骤]")
    print("1. 识别网段与待扫描主机")
    print("2. Ping 扫描存活主机")
    print("3. 检测开放端口")
    print("4. 协议握手复核")
    print("")
    print("[注意事项]")
    print("- 每次运行仅检测 1 种协议；可用 -Ports 附加原始端口（仅做 TCP 开放检测）。")
    print("- 多网卡环境可用 -Interface <接口名或IP> 指定网卡，或用 -Subnet 直接指定网段。")
    print("- 扫描整个网段耗时较长，请耐心等待。")
    print("- 需在可访问目标网段的网络环境下运行。")
    print("- 无 Python 环境时请使用 cli/windows/device-protocol-scan.ps1。")
    print("=========================================")

    sw_total = time.monotonic()

    # ---- 收集参数：协议 ----
    selected_protocol = get_selected_protocol(args.protocol)
    if not selected_protocol and args.protocol:
        print("")
        print("[错误] 未知协议: {}（可用: {}）。".format(args.protocol, ", ".join(i["Name"] for i in PROTOCOL_TABLE)))
    if not selected_protocol:
        if not interactive:
            print("[错误] 未指定有效协议，且非交互模式下无法弹出菜单，请使用 -Protocol 指定。")
            sys.exit(1)
        print("")
        selected_protocol = show_protocol_menu(PROTOCOL_TABLE)
        if not selected_protocol:
            print("[提示] 已取消，未开始扫描。")
            print("")
            input("[结束] 按回车键退出...")
            sys.exit(0)

    # ---- 收集参数：网段 / 网卡 ----
    if args.subnet:
        m = re.match(r"^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$", args.subnet)
        if not m:
            print("")
            print("[错误] Subnet 格式错误，应为 CIDR 格式，例如 192.168.1.0/24。")
            sys.exit(confirm_or_exit("[提示] 已取消，未开始扫描。"))
        local_ip = m.group(1)
        prefix = int(m.group(2))
        nic_state = None
    else:
        candidates = list_active_ipv4()
        if not candidates:
            print("")
            print("[错误] 无法自动识别网段，请使用 -Subnet 手动指定，例如 -Subnet 192.168.1.0/24。")
            sys.exit(confirm_or_exit("[提示] 已取消，未开始扫描。"))
        chosen = None
        if args.interface:
            chosen = resolve_interface(args.interface, candidates)
            if not chosen:
                print("")
                print("[错误] 未找到匹配的网卡: {}（接口名或 IP）。".format(args.interface))
                print("[提示] 可用网卡：{}。".format(
                    ", ".join("{} ({})".format(c["iface"], c["ip"]) for c in candidates)))
                sys.exit(confirm_or_exit("[提示] 已取消，未开始扫描。"))
        elif interactive:
            print("")
            chosen = show_nic_menu(candidates)
            if not chosen:
                print("[提示] 已取消，未开始扫描。")
                print("")
                input("[结束] 按回车键退出...")
                sys.exit(0)
        else:
            chosen = candidates[0]
        local_ip = chosen["ip"]
        prefix = chosen["prefix"]
        nic_state = state_label(chosen["state"])

    scan_ports = sorted(set([int(p) for p in selected_protocol["Ports"]] + extra_ports))

    # ---- 参数回显确认 ----
    print("")
    print("[提示] 扫描参数确认：")
    print("  检测协议: {}（端口: {}）".format(selected_protocol["Name"], ",".join(str(p) for p in selected_protocol["Ports"])))
    if nic_state is not None:
        print("  检测网卡: {}  [{}]".format(chosen["iface"], nic_state))
    print("  扫描网段: {}/{}".format(local_ip, prefix))
    print("  检测端口: {}".format(",".join(str(p) for p in scan_ports)))
    if extra_ports:
        print("  附加原始端口: {}".format(",".join(str(p) for p in extra_ports)))
    print("  TCP 超时: {}ms，Ping 超时: {}ms".format(timeout_ms, ping_timeout_ms))
    if args.out_file:
        if os.path.exists(args.out_file):
            print("[提示] 输出文件已存在，确认后将被覆盖。")
    if interactive:
        while True:
            ok = input("[输入] 确认开始扫描？[y 开始 / q 取消] ").strip()
            if re.match(r"^[yY]$", ok):
                break
            if re.match(r"^[qQ]$", ok):
                print("[提示] 已取消，未开始扫描。")
                print("")
                input("[结束] 按回车键退出...")
                sys.exit(0)
            print("[错误] 无效输入，请输入 y 或 q。")

    # ---- 步骤 1/4：识别网段与待扫描主机 ----
    print("")
    print("[进度] 步骤 1/4：识别网段与待扫描主机 ...")
    hosts = get_subnet_hosts(local_ip, prefix)
    self_u = ip_to_uint(local_ip)
    hosts = [h for h in hosts if ip_to_uint(h) != self_u]
    print("[完成] 扫描网段 {}/{}，待扫描主机 {} 台（已排除本机）。".format(local_ip, prefix, len(hosts)))

    # ---- 步骤 2/4：Ping 扫描存活主机 ----
    alive = []
    if hosts:
        print("")
        print("[进度] 步骤 2/4：Ping 扫描存活主机 ...")
        alive = ping_sweep(hosts, ping_timeout_ms)
        print("[完成] 存活主机 {} 台。".format(len(alive)))
    else:
        print("[提示] 网段内无可扫描主机，扫描中止。")

    # ---- 步骤 3/4：检测开放端口 ----
    open_pairs = []
    if alive:
        print("")
        print("[进度] 步骤 3/4：检测开放端口 ...")
        open_pairs = test_tcp_ports(alive, scan_ports, timeout_ms)
        print("[完成] 开放端口对 {} 个。".format(len(open_pairs)))
    else:
        print("[提示] 未发现存活主机，跳过端口检测与协议复核。")

    # ---- 步骤 4/4：协议握手复核 ----
    row_list = []
    if open_pairs:
        print("")
        print("[进度] 步骤 4/4：协议握手复核 ...")
        count = 0
        total = len(open_pairs)
        for pair in sorted(open_pairs, key=lambda x: (x[0], x[1])):
            count += 1
            if count % 50 == 0 or count == total:
                print("  复核进度 {}/{}".format(count, total), flush=True)
            ip, port = pair
            matched = False
            if port in selected_protocol["Ports"]:
                info = selected_protocol["Verify"](ip, port, timeout_ms)
                if info:
                    matched = True
                    row_list.append({
                        "Protocol": selected_protocol["Name"],
                        "IP": ip,
                        "MAC": get_mac(ip),
                        "Port": port,
                        "Code": info["Code"],
                        "Server": info["Server"],
                    })
            if not matched and port in extra_ports:
                row_list.append({
                    "Protocol": "TCP",
                    "IP": ip,
                    "MAC": get_mac(ip),
                    "Port": port,
                    "Code": 0,
                    "Server": "(port open)",
                })
        print("[完成] 协议握手复核完成。")
    elif alive:
        print("[提示] 未发现开放端口，跳过协议复核。")

    # ---- 结果汇总 ----
    total_devices = len(set(r["IP"] for r in row_list))
    if row_list:
        for name in sorted(set(r["Protocol"] for r in row_list)):
            rows = [r for r in row_list if r["Protocol"] == name]
            ips = sorted(set(r["IP"] for r in rows))
            print("")
            print("=== {} 设备 ({}) ===".format(name, len(ips)))
            display = sorted(rows, key=lambda r: (r["IP"], r["Port"]))
            headers = ["IP", "MAC", "Port", "Code", "Server"]
            widths = {
                "IP": max(15, max(len(str(r["IP"])) for r in display)),
                "MAC": max(17, max(len(str(r["MAC"])) for r in display)),
                "Port": max(6, max(len(str(r["Port"])) for r in display)),
                "Code": max(6, max(len(str(r["Code"])) for r in display)),
            }
            header_line = (
                "{:<{}}  {:<{}}  {:<{}}  {:<{}}  {}".format(
                    "IP", widths["IP"], "MAC", widths["MAC"],
                    "Port", widths["Port"], "Code", widths["Code"], "Server")
            )
            print(header_line)
            print("-" * len(header_line))
            for r in display:
                print("{:<{}}  {:<{}}  {:<{}}  {:<{}}  {}".format(
                    r["IP"], widths["IP"], r["MAC"], widths["MAC"],
                    r["Port"], widths["Port"], r["Code"], widths["Code"], r["Server"]))
        print("[结果] 发现设备总数: {} 台。".format(total_devices))
        if args.out_file:
            with open(args.out_file, "w", newline="", encoding="utf-8-sig") as f:
                writer = csv.writer(f)
                writer.writerow(["Protocol", "IP", "MAC", "Port", "Code", "Server"])
                for r in sorted(row_list, key=lambda r: (r["Protocol"], r["IP"], r["Port"])):
                    writer.writerow([r["Protocol"], r["IP"], r["MAC"], r["Port"], r["Code"], r["Server"]])
            print("[完成] 结果已导出: {}".format(args.out_file))
    else:
        print("[提示] 有端口开放，但未通过任何协议复核。")

    print("")
    print("[结果] 扫描完成。")
    print("  检测协议: {}".format(selected_protocol["Name"]))
    print("  扫描网段: {}/{}".format(local_ip, prefix))
    print("  存活主机: {}".format(len(alive)))
    print("  开放端口对: {}".format(len(open_pairs)))
    print("  识别设备: {} 台".format(total_devices))
    print("  共耗时: {:.1f}s".format(time.monotonic() - sw_total))
    print("")
    print("扫描结束。")
    print("")
    if interactive:
        input("[结束] 按回车键退出...")
    sys.exit(0)


if __name__ == "__main__":
    main()