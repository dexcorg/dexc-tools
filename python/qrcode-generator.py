#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""qrcode-generator.py：多功能二维码生成器。

支持多种二维码类型：文本、URL、WIFI、电话、邮件、短信、日历事件、地理位置、vCard。
用户可通过命令行参数或交互式菜单选择类型并输入内容，生成二维码图片。
"""

import argparse
import os
import sys
import re
from pathlib import Path
from datetime import datetime

try:
    for _stream in (sys.stdout, sys.stdin):
        try:
            _stream.reconfigure(encoding="utf-8")
        except Exception:
            pass
except Exception:
    pass

interactive = sys.stdin.isatty()

VERSION = "1.0"
SCRIPT_DIR = Path(__file__).parent.resolve()
DEFAULT_OUTPUT = SCRIPT_DIR / "qrcode.png"

QR_TYPES = {
    "1": "文本",
    "2": "URL",
    "3": "WIFI",
    "4": "电话",
    "5": "邮件",
    "6": "短信",
    "7": "日历事件",
    "8": "地理位置",
    "9": "vCard",
}

ERROR_CORRECTION_LEVELS = {
    "L": "L (7%)",
    "M": "M (15%)",
    "Q": "Q (25%)",
    "H": "H (30%)",
}


def log(msg=""):
    print(msg, flush=True)


def clean_path(s):
    s = (s or "").strip()
    while s and s[0] in "\"'":
        s = s[1:]
    while s and s[-1] in "\"'":
        s = s[:-1]
    s = s.replace("\\ ", " ")
    return s.strip()


def print_banner():
    log("=========================================")
    log("  二维码生成器")
    log(f"  版本 {VERSION}")
    log("=========================================")
    log("[适用场景]")
    log("需要生成各类二维码图片时使用，支持文本、URL、WiFi、联系方式等多种类型。")
    log()
    log("[功能说明]")
    log("根据用户选择的二维码类型和输入的内容，生成对应的二维码图片并保存到指定路径。")
    log()
    log("[操作方式]")
    log("1. 选择二维码类型")
    log("2. 根据类型输入相应参数")
    log("3. 设置输出路径和纠错级别")
    log("4. 确认参数后生成二维码")
    log()
    log("[执行步骤]")
    log("1. 选择二维码类型")
    log("2. 收集类型所需参数")
    log("3. 设置输出路径")
    log("4. 选择纠错级别")
    log("5. 确认参数并生成二维码")
    log()
    log("[注意事项]")
    log("- 输出目录不存在时会自动创建")
    log("- 已存在的同名文件会提示覆盖")
    log("- 首次使用需安装依赖：.venv/bin/pip install -r requirements.txt")
    log("=========================================")


def validate_url(url):
    url_pattern = re.compile(
        r"^https?://"
        r"(?:(?:[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?\.)+[A-Z]{2,6}\.?|"
        r"localhost|"
        r"\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})"
        r"(?::\d+)?"
        r"(?:/?|[/?]\S+)$",
        re.IGNORECASE,
    )
    return bool(url_pattern.match(url))


def validate_email(email):
    email_pattern = re.compile(r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$")
    return bool(email_pattern.match(email))


def validate_phone(phone):
    phone_pattern = re.compile(r"^\+?[\d\s\-\(\)]{7,20}$")
    return bool(phone_pattern.match(phone))


def validate_wifi_encryption(enc):
    return enc.upper() in ("WPA", "WEP", "nopass")


def format_wifi_content(ssid, password, encryption):
    return f"WIFI:T:{encryption};S:{ssid};P:{password};;"


def format_phone_content(phone):
    return f"tel:{phone}"


def format_email_content(email):
    return f"mailto:{email}"


def format_sms_content(phone, message):
    return f"SMSTO:{phone}:{message}"


def format_calendar_content(summary, dtstart, dtend, location="", description=""):
    lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "BEGIN:VEVENT",
        f"SUMMARY:{summary}",
        f"DTSTART:{dtstart}",
        f"DTEND:{dtend}",
    ]
    if location:
        lines.append(f"LOCATION:{location}")
    if description:
        lines.append(f"DESCRIPTION:{description}")
    lines.extend(["END:VEVENT", "END:VCALENDAR"])
    return "\n".join(lines)


def format_geo_content(lat, lon):
    return f"geo:{lat},{lon}"


def format_vcard_content(name, phone="", email="", org="", title=""):
    lines = [
        "BEGIN:VCARD",
        "VERSION:3.0",
        f"FN:{name}",
        f"N:{name};;;;",
    ]
    if phone:
        lines.append(f"TEL:{phone}")
    if email:
        lines.append(f"EMAIL:{email}")
    if org:
        lines.append(f"ORG:{org}")
    if title:
        lines.append(f"TITLE:{title}")
    lines.append("END:VCARD")
    return "\n".join(lines)


def format_datetime_input(dt_str):
    dt_str = dt_str.strip()
    formats = [
        "%Y%m%dT%H%M%S",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M:%S",
        "%Y%m%d%H%M%S",
    ]
    for fmt in formats:
        try:
            dt = datetime.strptime(dt_str, fmt)
            return dt.strftime("%Y%m%dT%H%M%S")
        except ValueError:
            continue
    return None


def get_input(prompt, default=None, required=True):
    while True:
        suffix = f" [回车使用默认值: {default}]" if default is not None else ""
        user_input = input(f"[输入] {prompt}{suffix}: ").strip()
        if not user_input:
            if default is not None:
                return str(default)
            if not required:
                return ""
            print("[错误] 输入不能为空，请重新输入。")
            continue
        return user_input


def get_path_input(prompt, must_exist=False, default=None):
    while True:
        path_str = get_input(prompt, default=default, required=False)
        if not path_str and default is not None:
            return Path(str(default))
        path = Path(clean_path(path_str)).expanduser().resolve()
        if must_exist and not path.exists():
            print(f"[错误] 路径不存在：{path}")
            continue
        return path


def get_menu_choice(prompt, options, allow_quit=True):
    while True:
        log(f"[输入] {prompt}")
        for key, label in options.items():
            log(f"  {key}. {label}")
        if allow_quit:
            log("  q. 取消")
        choice = input("请输入选项数字然后按回车: ").strip().lower()
        if allow_quit and choice == "q":
            return None
        if choice in options:
            return choice
        print("[错误] 无效选项，请重新输入。")


def collect_text_params():
    content = get_input("请输入文本内容")
    return {"content": content}


def collect_url_params():
    while True:
        url = get_input("请输入URL地址（如 https://example.com）")
        if validate_url(url):
            return {"url": url}
        print("[错误] 无效的URL格式，请输入完整的URL（包含 http:// 或 https://）")


def collect_wifi_params():
    ssid = get_input("请输入WiFi网络名称（SSID）")
    while True:
        encryption = get_input("请输入加密类型（WPA/WEP/nopass）", default="WPA").upper()
        if validate_wifi_encryption(encryption):
            break
        print("[错误] 无效的加密类型，请输入 WPA、WEP 或 nopass")

    password = ""
    if encryption != "nopass":
        password = get_input("请输入WiFi密码")
    return {"ssid": ssid, "password": password, "encryption": encryption}


def collect_phone_params():
    while True:
        phone = get_input("请输入电话号码（如 +8613800138000）")
        if validate_phone(phone):
            return {"phone": phone}
        print("[错误] 无效的电话号码格式")


def collect_email_params():
    while True:
        email = get_input("请输入邮件地址")
        if validate_email(email):
            return {"email": email}
        print("[错误] 无效的邮件地址格式")


def collect_sms_params():
    while True:
        phone = get_input("请输入接收手机号码")
        if validate_phone(phone):
            break
        print("[错误] 无效的手机号码格式")
    message = get_input("请输入短信内容")
    return {"phone": phone, "message": message}


def collect_calendar_params():
    summary = get_input("请输入事件标题")

    while True:
        dtstart = get_input("请输入开始时间（格式：YYYY-MM-DD HH:MM:SS 或 YYYYMMDDTHHMMSS）")
        formatted_start = format_datetime_input(dtstart)
        if formatted_start:
            break
        print("[错误] 无效的时间格式")

    while True:
        dtend = get_input("请输入结束时间（格式：YYYY-MM-DD HH:MM:SS 或 YYYYMMDDTHHMMSS）")
        formatted_end = format_datetime_input(dtend)
        if formatted_end:
            break
        print("[错误] 无效的时间格式")

    location = get_input("请输入地点（可选）", required=False)
    description = get_input("请输入事件描述（可选）", required=False)

    return {
        "summary": summary,
        "dtstart": formatted_start,
        "dtend": formatted_end,
        "location": location,
        "description": description,
    }


def collect_geo_params():
    while True:
        lat_str = get_input("请输入纬度（-90 到 90）")
        try:
            lat = float(lat_str)
            if -90 <= lat <= 90:
                break
        except ValueError:
            pass
        print("[错误] 无效的纬度值")

    while True:
        lon_str = get_input("请输入经度（-180 到 180）")
        try:
            lon = float(lon_str)
            if -180 <= lon <= 180:
                break
        except ValueError:
            pass
        print("[错误] 无效的经度值")

    return {"lat": lat, "lon": lon}


def collect_vcard_params():
    name = get_input("请输入姓名")
    phone = get_input("请输入电话号码（可选）", required=False)
    email = get_input("请输入邮件地址（可选）", required=False)
    org = get_input("请输入组织/公司（可选）", required=False)
    title = get_input("请输入职位（可选）", required=False)
    return {
        "name": name,
        "phone": phone,
        "email": email,
        "org": org,
        "title": title,
    }


def collect_output_path():
    default_path = str(DEFAULT_OUTPUT)
    path_str = get_input("请输入输出文件路径", default=default_path)
    return Path(clean_path(path_str)).expanduser().resolve()


def collect_error_correction():
    options = {
        "L": "L (7%) - 低",
        "M": "M (15%) - 中（推荐）",
        "Q": "Q (25%) - 较高",
        "H": "H (30%) - 高",
    }
    log("[输入] 请选择纠错级别：")
    for key, label in options.items():
        log(f"  {key}. {label}")
    while True:
        choice = input("请输入选项字母然后按回车 [默认 M]: ").strip().upper()
        if not choice:
            return "M"
        if choice in options:
            return choice
        print("[错误] 无效选项，请输入 L、M、Q 或 H。")


def build_content(qr_type, params):
    if qr_type == "1":
        return params["content"]
    elif qr_type == "2":
        return params["url"]
    elif qr_type == "3":
        return format_wifi_content(params["ssid"], params["password"], params["encryption"])
    elif qr_type == "4":
        return format_phone_content(params["phone"])
    elif qr_type == "5":
        return format_email_content(params["email"])
    elif qr_type == "6":
        return format_sms_content(params["phone"], params["message"])
    elif qr_type == "7":
        return format_calendar_content(
            params["summary"],
            params["dtstart"],
            params["dtend"],
            params.get("location", ""),
            params.get("description", ""),
        )
    elif qr_type == "8":
        return format_geo_content(params["lat"], params["lon"])
    elif qr_type == "9":
        return format_vcard_content(
            params["name"],
            params.get("phone", ""),
            params.get("email", ""),
            params.get("org", ""),
            params.get("title", ""),
        )
    return params.get("content", "")


def confirm_params(qr_type, params, content, output_path, error_correction):
    log("[提示] 即将执行，请确认以下参数：")
    log(f"  - 二维码类型：{QR_TYPES[qr_type]}")
    log(f"  - 内容预览：{content[:80]}{'...' if len(content) > 80 else ''}")
    log(f"  - 输出路径：{output_path}")
    log(f"  - 纠错级别：{ERROR_CORRECTION_LEVELS[error_correction]}")
    if output_path.exists():
        log("[提示] 注意：输出目录中已存在的同名文件将被覆盖。")
    while True:
        c = input("[输入] 确认执行？[y / n / q 取消]：").strip().lower()
        if c in ("y", "yes"):
            return True
        if c in ("n", "q", "no"):
            return False
        print("[错误] 无效输入，请输入 y、n 或 q。")


def generate_qr(content, output_path, error_correction):
    try:
        import qrcode
        from qrcode.constants import ERROR_CORRECT_L, ERROR_CORRECT_M, ERROR_CORRECT_Q, ERROR_CORRECT_H
    except ImportError:
        print("[错误] qrcode 库未安装，请先运行：.venv/bin/pip install -r requirements.txt")
        return False

    ec_map = {
        "L": ERROR_CORRECT_L,
        "M": ERROR_CORRECT_M,
        "Q": ERROR_CORRECT_Q,
        "H": ERROR_CORRECT_H,
    }

    try:
        qr = qrcode.QRCode(
            version=1,
            error_correction=ec_map.get(error_correction, ERROR_CORRECT_M),
            box_size=10,
            border=4,
        )
        qr.add_data(content)
        qr.make(fit=True)

        img = qr.make_image(fill_color="black", back_color="white")
        output_path.parent.mkdir(parents=True, exist_ok=True)
        img.save(str(output_path))
        return True
    except Exception as e:
        print(f"[错误] 生成二维码失败：{e}")
        return False


def main():
    print_banner()

    parser = argparse.ArgumentParser(description="多功能二维码生成器")
    parser.add_argument("--type", choices=["text", "url", "wifi", "phone", "email", "sms", "calendar", "geo", "vcard"],
                        help="二维码类型")
    parser.add_argument("--content", help="二维码内容（文本/URL类型）")
    parser.add_argument("--output", help=f"输出文件路径（默认：脚本目录/qrcode.png）")
    parser.add_argument("--error-correction", choices=["L", "M", "Q", "H"], default="M",
                        help="纠错级别（默认：M）")
    parser.add_argument("--ssid", help="WiFi网络名称")
    parser.add_argument("--password", help="WiFi密码")
    parser.add_argument("--encryption", help="WiFi加密类型（WPA/WEP/nopass）")
    parser.add_argument("--phone", help="电话号码")
    parser.add_argument("--email", help="邮件地址")
    parser.add_argument("--message", help="短信内容")
    parser.add_argument("--summary", help="日历事件标题")
    parser.add_argument("--dtstart", help="事件开始时间")
    parser.add_argument("--dtend", help="事件结束时间")
    parser.add_argument("--location", help="事件地点")
    parser.add_argument("--description", help="事件描述")
    parser.add_argument("--lat", type=float, help="纬度")
    parser.add_argument("--lon", type=float, help="经度")
    parser.add_argument("--name", help="联系人姓名")
    parser.add_argument("--org", help="组织/公司")
    parser.add_argument("--title", help="职位")
    args = parser.parse_args()

    type_map = {
        "text": "1",
        "url": "2",
        "wifi": "3",
        "phone": "4",
        "email": "5",
        "sms": "6",
        "calendar": "7",
        "geo": "8",
        "vcard": "9",
    }

    qr_type = None
    if args.type:
        qr_type = type_map.get(args.type)

    if qr_type is None:
        if not interactive:
            print("[错误] 非交互模式必须指定 --type 参数。")
            sys.exit(1)
        qr_type = get_menu_choice("请选择二维码类型：", QR_TYPES)
        if qr_type is None:
            log("[提示] 已取消，未做任何操作。")
            sys.exit(0)

    params = {}

    if qr_type == "1":
        if args.content:
            params = {"content": args.content}
        elif interactive:
            params = collect_text_params()
        else:
            print("[错误] 非交互模式必须指定 --content 参数。")
            sys.exit(1)

    elif qr_type == "2":
        if args.content:
            if validate_url(args.content):
                params = {"url": args.content}
            else:
                print("[错误] 无效的URL格式。")
                sys.exit(1)
        elif interactive:
            params = collect_url_params()
        else:
            print("[错误] 非交互模式必须指定 --content 参数（URL）。")
            sys.exit(1)

    elif qr_type == "3":
        if args.ssid:
            encryption = (args.encryption or "WPA").upper()
            if not validate_wifi_encryption(encryption):
                print("[错误] 无效的加密类型。")
                sys.exit(1)
            password = args.password or ""
            if encryption != "nopass" and not password:
                print("[错误] WPA/WEP 加密需要提供密码。")
                sys.exit(1)
            params = {"ssid": args.ssid, "password": password, "encryption": encryption}
        elif interactive:
            params = collect_wifi_params()
        else:
            print("[错误] 非交互模式必须指定 --ssid 参数。")
            sys.exit(1)

    elif qr_type == "4":
        if args.phone:
            if validate_phone(args.phone):
                params = {"phone": args.phone}
            else:
                print("[错误] 无效的电话号码格式。")
                sys.exit(1)
        elif interactive:
            params = collect_phone_params()
        else:
            print("[错误] 非交互模式必须指定 --phone 参数。")
            sys.exit(1)

    elif qr_type == "5":
        if args.email:
            if validate_email(args.email):
                params = {"email": args.email}
            else:
                print("[错误] 无效的邮件地址格式。")
                sys.exit(1)
        elif interactive:
            params = collect_email_params()
        else:
            print("[错误] 非交互模式必须指定 --email 参数。")
            sys.exit(1)

    elif qr_type == "6":
        if args.phone and args.message:
            if validate_phone(args.phone):
                params = {"phone": args.phone, "message": args.message}
            else:
                print("[错误] 无效的手机号码格式。")
                sys.exit(1)
        elif interactive:
            params = collect_sms_params()
        else:
            print("[错误] 非交互模式必须指定 --phone 和 --message 参数。")
            sys.exit(1)

    elif qr_type == "7":
        if args.summary and args.dtstart and args.dtend:
            formatted_start = format_datetime_input(args.dtstart)
            formatted_end = format_datetime_input(args.dtend)
            if not formatted_start or not formatted_end:
                print("[错误] 无效的时间格式。")
                sys.exit(1)
            params = {
                "summary": args.summary,
                "dtstart": formatted_start,
                "dtend": formatted_end,
                "location": args.location or "",
                "description": args.description or "",
            }
        elif interactive:
            params = collect_calendar_params()
        else:
            print("[错误] 非交互模式必须指定 --summary、--dtstart 和 --dtend 参数。")
            sys.exit(1)

    elif qr_type == "8":
        if args.lat is not None and args.lon is not None:
            if -90 <= args.lat <= 90 and -180 <= args.lon <= 180:
                params = {"lat": args.lat, "lon": args.lon}
            else:
                print("[错误] 无效的经纬度值。")
                sys.exit(1)
        elif interactive:
            params = collect_geo_params()
        else:
            print("[错误] 非交互模式必须指定 --lat 和 --lon 参数。")
            sys.exit(1)

    elif qr_type == "9":
        if args.name:
            params = {
                "name": args.name,
                "phone": args.phone or "",
                "email": args.email or "",
                "org": args.org or "",
                "title": args.title or "",
            }
        elif interactive:
            params = collect_vcard_params()
        else:
            print("[错误] 非交互模式必须指定 --name 参数。")
            sys.exit(1)

    content = build_content(qr_type, params)

    if interactive:
        output_path = collect_output_path()
    elif args.output:
        output_path = Path(clean_path(args.output)).expanduser().resolve()
    else:
        output_path = DEFAULT_OUTPUT

    if interactive:
        error_correction = collect_error_correction()
    else:
        error_correction = args.error_correction.upper()
        if error_correction not in ERROR_CORRECTION_LEVELS:
            print("[错误] 无效的纠错级别。")
            sys.exit(1)

    if interactive:
        if not confirm_params(qr_type, params, content, output_path, error_correction):
            log("[提示] 已取消，未做任何操作。")
            sys.exit(0)

    log(f"[进度] 步骤 5/5：生成二维码 ...")
    if generate_qr(content, output_path, error_correction):
        log(f"[完成] 二维码已生成：{output_path}")
    else:
        print("[失败] 二维码生成失败。")
        sys.exit(1)

    log("[结果] 执行完成。")
    log(f"  成功：1/1")


if __name__ == "__main__":
    main()
