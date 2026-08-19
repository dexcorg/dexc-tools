#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""llm-dir-handle.py：将指定目录中指定后缀的文件按自定义提示词，通过 LLM API 批量处理后输出到另一目录。"""

import argparse
import codecs
import os
import re
import sys
import time
from pathlib import Path

import requests

import charset_normalizer

VERSION = "1.2"

REQUEST_TIMEOUT = int(os.environ.get("LLM_TIMEOUT", "1800"))
RETRIES = int(os.environ.get("LLM_RETRIES", "3"))
TEMPERATURE = float(os.environ.get("LLM_TEMPERATURE", "0.1"))
MAX_TOKENS = int(os.environ.get("LLM_MAX_TOKENS", "8192"))

SYSTEM_PROMPT = (
    "You are a helpful assistant. Process the given file content according to the user's "
    "instruction. Output ONLY the processed result text itself: do not add explanations, "
    "remarks, or markdown code fences unless the result content itself requires them."
)

PLACEHOLDER = "[[CONTENT]]"
PLACEHOLDER_RE = re.compile(r"\[\[(?:content|c)\]\]", re.IGNORECASE)
QUIT_TOKENS = {"[[q]]", "[[quit]]"}


def log(msg):
    print(msg, flush=True)


def print_banner():
    print("=========================================")
    print("  目录文件批量 LLM 处理")
    print(f"  版本 {VERSION}")
    print("=========================================")
    print("[适用场景]")
    print("需要按自定义提示词批量处理目录中的文本文件（如摘要、改写、格式转换、内容审查等）时使用。")
    print()
    print("[功能说明]")
    print("递归扫描来源目录中指定后缀的文件，将提示词中的 [[CONTENT]] 占位符替换为文件内容，调用 LLM API（OpenAI 兼容）处理后，以原始文件名输出到目标目录并镜像目录结构，输出扩展名可另行指定。")
    print()
    print("[操作方式]")
    print("可直接拖放文件夹到终端，或手动输入路径；按提示依次输入各项参数，确认后执行。也可通过命令行参数非交互运行。")
    print()
    print("[执行步骤]")
    print("1. 收集参数（来源目录、输出目录、目标后缀、输出扩展名、处理提示词、API 地址）")
    print("2. 回显并确认参数")
    print("3. 逐文件读取并调用 LLM 处理")
    print("4. 汇总执行结果")
    print()
    print("[注意事项]")
    print("- 处理提示词必须包含内容占位符 [[C]]/[[CONTENT]]，会被替换为每个文件的完整内容。")
    print("- 输出扩展名可选（仅单个值），留空则保留原扩展名；输入统一转为小写。")
    print("- 输出目录不能等于或位于来源目录之内。")
    print("- 输出目录中已存在的同名文件将被覆盖（可用 --skip-existing 跳过）。")
    print("- 首次使用需安装依赖：.venv/bin/pip install -r requirements.txt")
    print("=========================================")


def clean_path(s):
    s = (s or "").strip()
    while s and s[0] in "\"'":
        s = s[1:]
    while s and s[-1] in "\"'":
        s = s[:-1]
    s = s.replace("\\ ", " ")
    return s.strip()


def decode_bytes(raw):
    if raw.startswith(codecs.BOM_UTF8):
        return raw.decode("utf-8-sig")
    if raw.startswith(codecs.BOM_UTF16_LE):
        return raw.decode("utf-16-le")
    if raw.startswith(codecs.BOM_UTF16_BE):
        return raw.decode("utf-16-be")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        best = charset_normalizer.from_bytes(raw).best()
        if best is not None:
            return str(best)
        return raw.decode("utf-8", errors="replace")


def normalize_base(url):
    url = (url or "").strip().strip("\"'")
    url = url.rstrip("/")
    url = re.sub(r"/chat/completions$", "", url)
    if url and not re.search(r"/v\d+$", url):
        url += "/v1"
    return url


def parse_extensions(s):
    s = (s or "").strip()
    parts = re.split(r"[/,;\s\u3000，；]+", s)
    exts = set()
    for p in parts:
        p = p.strip().strip(".").lower()
        if p:
            exts.add("." + p)
    return exts


def parse_output_ext(s):
    s = (s or "").strip().strip(".").lower()
    if re.search(r"[/,;\s\u3000，；]", s):
        return None
    return s


def strip_fences(s):
    if not isinstance(s, str):
        return s
    lines = s.split("\n")
    if lines and lines[0].strip().startswith("```"):
        lines = lines[1:]
    if lines and lines[-1].strip() == "```":
        lines = lines[:-1]
    return "\n".join(lines)


class LlamaClient:
    def __init__(self, base_url, model=None, timeout=REQUEST_TIMEOUT):
        self.base = normalize_base(base_url)
        self.model = model
        self.timeout = timeout

    def fetch_model(self):
        try:
            r = requests.get(self.base + "/models", timeout=15)
            r.raise_for_status()
            j = r.json()
            data = j.get("data") or j.get("models") or []
            if data:
                return data[0].get("id") or data[0].get("name")
        except Exception:
            pass
        return None

    def chat(self, system, user, max_tokens=MAX_TOKENS):
        body = {
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "temperature": TEMPERATURE,
            "max_tokens": max_tokens,
            "stream": False,
        }
        if self.model:
            body["model"] = self.model
        r = requests.post(self.base + "/chat/completions", json=body, timeout=self.timeout)
        r.raise_for_status()
        return r.json()["choices"][0]["message"]["content"]


def call_llm(client, prompt, content):
    if not PLACEHOLDER_RE.search(prompt):
        raise ValueError("处理提示词缺少内容占位符（[[C]]/[[CONTENT]]）")
    user = PLACEHOLDER_RE.sub(lambda m: content, prompt)
    last = None
    for attempt in range(RETRIES):
        try:
            result = client.chat(SYSTEM_PROMPT, user)
            return strip_fences(result)
        except Exception as e:
            last = f"API 错误: {e}"
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"调用失败（重试 {RETRIES} 次）：{last}")


def scan_files(src, exts):
    out = []
    for p in sorted(src.rglob("*")):
        if p.is_file() and p.suffix.lower() in exts:
            out.append(p)
    return out


def output_path(dst, src, f, out_ext):
    rel = f.relative_to(src)
    return dst / (rel.with_suffix("." + out_ext) if out_ext else rel)


def run(args, src, dst, exts, out_ext, prompt, client):
    files = scan_files(src, exts)
    if not files:
        log(f"[提示] 未在 {src} 中找到扩展名为 {sorted(exts)} 的文件。")
        return
    log(f"[提示] 发现 {len(files)} 个文件")
    failures = []
    for i, f in enumerate(files, 1):
        rel = f.relative_to(src)
        out = output_path(dst, src, f, out_ext)
        if args.skip_existing and out.exists():
            log(f"[提示] 步骤 {i}/{len(files)}：{rel} 输出已存在，跳过")
            continue
        log(f"[进度] 步骤 {i}/{len(files)}：{rel} ...")
        try:
            raw = decode_bytes(f.read_bytes())
            if args.dry:
                log(f"[完成] 读取 {rel}: {len(raw)} 字符")
                continue
            new_text = call_llm(client, prompt, raw)
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(new_text, encoding="utf-8")
            log(f"[完成] {rel} -> {out}")
        except Exception as e:
            failures.append(str(rel))
            log(f"[失败] {rel}: {e}")
    log("[结果] 执行完成。")
    log(f"  成功：{len(files) - len(failures)}/{len(files)}")
    log(f"  失败：{len(failures)}/{len(files)}")
    if failures:
        for x in failures:
            log(f"  - {x}")


def ask_path(prompt, must_exist):
    while True:
        s = clean_path(input(prompt))
        if not s:
            print("[错误] 输入不能为空。")
            continue
        p = Path(s).expanduser().resolve()
        if must_exist and not p.is_dir():
            print(f"[错误] 目录不存在：{p}")
            continue
        return p


def ask_extensions(prompt):
    while True:
        s = input(prompt)
        exts = parse_extensions(s)
        if exts:
            return exts
        print("[错误] 无法解析后缀，请输入如 txt/md 或 txt,md。")


def ask_output_ext(prompt):
    while True:
        s = input(prompt)
        ext = parse_output_ext(s)
        if ext is None:
            print("[错误] 输出扩展名只允许单个值（如 md）。")
            continue
        return ext


def ask_prompt(prompt):
    print(prompt)
    print(f"[输入] 支持多行（含空行），单独一行输入 [[Q]]/[[QUIT]] 结束并发送；首行输入 [[Q]]/[[QUIT]] 取消；提示词需包含内容占位符 [[C]]/[[CONTENT]]：")
    while True:
        lines = []
        while True:
            line = input()
            if line.strip().lower() in QUIT_TOKENS:
                if not lines:
                    return None
                break
            lines.append(line)
        if not lines:
            print("[错误] 提示词不能为空，请重新输入。")
            continue
        prompt = "\n".join(lines)
        if PLACEHOLDER_RE.search(prompt):
            return prompt
        print("[错误] 处理提示词必须包含内容占位符（[[C]]/[[CONTENT]]），请重新输入。")


def ask_api():
    while True:
        s = clean_path(input("[输入] 请输入 LLM API 地址（OpenAI 兼容，如 http://127.0.0.1:8080）："))
        if not s:
            print("[错误] 地址不能为空。")
            continue
        return s


def is_inside(path, base):
    try:
        path.relative_to(base)
        return True
    except ValueError:
        return False


def confirm_params(src, dst, exts, out_ext, prompt, api, model, overwrite):
    print("[提示] 即将执行，请确认以下参数：")
    print(f"  - 来源目录：{src}")
    print(f"  - 输出目录：{dst}")
    print(f"  - 目标后缀：{' '.join(sorted(exts))}")
    print(f"  - 输出扩展名：{('.' + out_ext) if out_ext else '保持原样'}")
    if prompt:
        preview = prompt.replace("\n", " ")
        print(f"  - 处理提示词：{preview[:80]}{'...' if len(preview) > 80 else ''}")
    else:
        print("  - 处理提示词：（dry 模式不发送）")
    if api:
        print(f"  - API 地址：{api}")
    print(f"  - 模型：{model or '自动探测'}")
    if overwrite:
        print("[提示] 注意：输出目录中已存在的同名文件将被覆盖。")
    while True:
        c = input("[输入] 确认执行？[y / n / q 取消]：").strip().lower()
        if c in ("y", "yes"):
            return True
        if c in ("n", "q", "no"):
            return False
        print("[错误] 无效输入，请输入 y、n 或 q。")


def main():
    for stream in (sys.stdout, sys.stdin):
        try:
            stream.reconfigure(encoding="utf-8")
        except Exception:
            pass
    print_banner()
    parser = argparse.ArgumentParser(description="目录文件批量 LLM 处理")
    parser.add_argument("--src", help="来源目录")
    parser.add_argument("--dst", help="输出目录")
    parser.add_argument("--ext", help="目标文件后缀，如 txt/md 或 txt,md（大小写不敏感）")
    parser.add_argument("--out-ext", help="输出文件扩展名（可选，留空保持原扩展名；仅单个值，自动转小写）")
    parser.add_argument("--prompt", help="处理提示词（需包含内容占位符 [[C]]/[[CONTENT]]）")
    parser.add_argument("--prompt-file", help="从文件读取处理提示词")
    parser.add_argument("--api", help="LLM API 地址（OpenAI 兼容，必填）")
    parser.add_argument("--model", help="模型名称（默认自动探测）")
    parser.add_argument("--skip-existing", action="store_true", help="跳过已存在的输出文件")
    parser.add_argument("--dry", action="store_true", help="仅扫描统计，不调用模型不写文件")
    args = parser.parse_args()

    interactive = sys.stdin.isatty()

    def fatal(msg):
        print(f"[错误] {msg}")
        if interactive:
            input("[结束] 按回车键退出...")
        sys.exit(1)

    if args.prompt and args.prompt_file:
        fatal("--prompt 与 --prompt-file 不能同时使用。")

    has_prompt = bool(args.prompt or args.prompt_file)
    missing = []
    for name in ("src", "dst", "ext"):
        if not getattr(args, name):
            missing.append(name)
    if not args.out_ext:
        missing.append("out_ext")
    if not args.dry and not has_prompt:
        missing.append("prompt")
    if not args.dry and not args.api:
        missing.append("api")
    required_missing = [m for m in missing if m != "out_ext"]
    if required_missing and not interactive:
        fatal(f"非交互模式缺少必需参数：{', '.join('--' + m for m in required_missing)}。")

    step = 0

    def label(prompt):
        nonlocal step
        step += 1
        return f"[输入] (参数 {step}/{len(missing)}) {prompt}"

    if "src" in missing:
        src = ask_path(label("请输入来源目录（可拖放）："), must_exist=True)
    else:
        src = Path(args.src).expanduser().resolve()

    if "dst" in missing:
        dst = ask_path(label("请输入输出目录（可拖放）："), must_exist=False)
    else:
        dst = Path(args.dst).expanduser().resolve()

    if dst == src or is_inside(dst, src):
        fatal("输出目录不能等于或位于来源目录之内。")

    if "ext" in missing:
        exts = ask_extensions(label("请输入目标处理文件后缀（如 txt/md，可多后缀）："))
    else:
        exts = parse_extensions(args.ext)
        if not exts:
            fatal("无法解析 --ext 后缀。")

    out_ext = ""
    if "out_ext" in missing:
        if interactive:
            out_ext = ask_output_ext(label("请输入输出文件扩展名 [回车使用默认值: 保持原扩展名]（如 md）："))
    else:
        out_ext = parse_output_ext(args.out_ext)
        if out_ext is None:
            fatal("--out-ext 只允许单个值。")

    prompt = None
    if "prompt" not in missing:
        prompt = args.prompt
        if prompt is None and args.prompt_file:
            prompt = Path(args.prompt_file).expanduser().read_text(encoding="utf-8")
        if not args.dry and not PLACEHOLDER_RE.search(prompt):
            fatal("处理提示词必须包含内容占位符（[[C]]/[[CONTENT]]）。")
    elif not args.dry:
        prompt = ask_prompt(label("请输入处理提示词："))
        if prompt is None:
            print("[提示] 已取消，未做任何操作。")
            if interactive:
                input("[结束] 按回车键退出...")
            sys.exit(0)

    api = args.api
    if "api" in missing:
        api = ask_api()

    overwrite = False
    if not args.dry and not args.skip_existing:
        files = scan_files(src, exts)
        overwrite = any(output_path(dst, src, f, out_ext).exists() for f in files)

    if interactive and missing:
        if not confirm_params(src, dst, exts, out_ext, prompt, api, args.model, overwrite):
            print("[提示] 已取消，未做任何操作。")
            if interactive:
                input("[结束] 按回车键退出...")
            sys.exit(0)

    client = None
    if not args.dry:
        client = LlamaClient(api, model=args.model or None)
        model = client.model or client.fetch_model()
        if model:
            client.model = model
            print(f"[提示] 使用模型：{model}")
        else:
            print("[提示] 无法自动探测模型名称，将省略 model 字段。")

        try:
            client.chat("You are a helper.", "ping", max_tokens=8)
        except Exception as e:
            print(f"[提示] LLM 连接测试失败：{e}")
            if interactive:
                if input("[输入] 是否继续？[y/N]：").strip().lower() != "y":
                    print("[提示] 已取消。")
                    input("[结束] 按回车键退出...")
                    sys.exit(0)

    run(args, src, dst, exts, out_ext, prompt, client)
    if interactive:
        input("[结束] 按回车键退出...")


if __name__ == "__main__":
    main()
