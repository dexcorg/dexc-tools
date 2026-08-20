#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""llm-dir-translate.py：将指定目录中的文件按类型提取文本，通过 LLM API 批量翻译后输出到另一目录。"""

import argparse
import codecs
import csv
import html as html_mod
import io
import json
import os
import re
import sys
import time
from pathlib import Path
from html.parser import HTMLParser

import requests

try:
    import tiktoken
except ImportError:  # pragma: no cover
    tiktoken = None

import charset_normalizer
from ruamel.yaml import YAML

VERSION = "1.1"

BATCH_ITEMS = int(os.environ.get("BATCH_ITEMS", "8"))
BATCH_CHARS = int(os.environ.get("BATCH_CHARS", "400"))
BATCH_MAX_ITEMS = int(os.environ.get("BATCH_MAX_ITEMS", "64"))
REQUEST_TIMEOUT = int(os.environ.get("LLM_TIMEOUT", "1800"))
RETRIES = int(os.environ.get("LLM_RETRIES", "3"))
TEMPERATURE = float(os.environ.get("LLM_TEMPERATURE", "0.1"))
MAX_TOKENS = int(os.environ.get("LLM_MAX_TOKENS", "1024"))
CONTEXT_TOKENS = int(os.environ.get("LLM_CONTEXT_TOKENS", "0"))
BUDGET_DIVISOR = 4
OUTPUT_RATIO = 1.5

LANGUAGES = {
    "1": ("zh-CN", "简体中文"),
    "2": ("ja", "日本語"),
    "3": ("en", "English"),
}

FILE_TYPES = {
    "1": {"exts": {".txt", ".md"}, "kind": "text", "all": False},
    "2": {"exts": {".html", ".htm"}, "kind": "html", "all": False},
    "3": {"exts": {".json"}, "kind": "json", "all": False},
    "4": {"exts": {".json"}, "kind": "json", "all": True},
    "5": {"exts": {".yaml", ".yml"}, "kind": "yaml", "all": False},
    "6": {"exts": {".yaml", ".yml"}, "kind": "yaml", "all": True},
    "7": {"exts": {".csv"}, "kind": "csv", "all": False},
    "8": {"exts": {".csv"}, "kind": "csv", "all": True},
}

FILE_TYPE_LABELS = {
    "1": "TEXT .......... 翻译文本全文（扫描 .txt/.md 文件）",
    "2": "HTML .......... 翻译 HTML 可显示文本及 JS 字符串（扫描 .html 文件）",
    "3": "JSON_VALUE..... 翻译 JSON 叶子节点值（扫描 .json 文件）",
    "4": "JSON_TOTAL .... 翻译 JSON 全部节点（键与值，扫描 .json 文件）",
    "5": "YAML_VALUE .... 翻译 YAML 叶子节点值（扫描 .yaml 文件）",
    "6": "YAML_TOTAL .... 翻译 YAML 全部节点（键与值，扫描 .yaml 文件）",
    "7": "CSV_TITLE ..... 翻译 CSV 标题行（扫描 .csv 文件）",
    "8": "CSV_TOTAL ..... 翻译 CSV 全部单元格（扫描 .csv 文件）",
}

SEG_TOKEN_RE = re.compile(r"\u27e6SEG(\d+)\u27e7")
JS_STR_RE = re.compile(r"""('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")""")
TRANSLATABLE_ATTRS = {"title", "placeholder", "alt", "aria-label"}
LETTER_RE = re.compile(r"[A-Za-z\u00c0-\u024f\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]")
CJK_RE = re.compile(r"[\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]")

CONTEXT_FIELDS = ("context_length", "max_context_length", "max_model_len", "context_window", "context_size")

MODEL_CONTEXT_MAP = (
    ("llama4", 1_048_576),
    ("llama3.1", 131_072),
    ("llama3", 8_192),
    ("llama-2", 4_096),
    ("gpt-4o", 128_000),
    ("gpt-4-turbo", 128_000),
    ("gpt-4", 8_192),
    ("gpt-3.5", 16_385),
    ("deepseek", 65_536),
    ("glm-4", 128_000),
    ("chatglm", 32_768),
    ("qwen", 32_768),
    ("mistral", 32_768),
    ("mixtral", 32_768),
    ("command-r", 128_000),
    ("gemma", 8_192),
    ("phi", 8_192),
    ("yi", 4_096),
)

_TIKTOKEN_ENC = None


def get_tiktoken():
    global _TIKTOKEN_ENC
    if _TIKTOKEN_ENC is None:
        try:
            _TIKTOKEN_ENC = tiktoken.get_encoding("cl100k_base") if tiktoken else False
        except Exception:
            _TIKTOKEN_ENC = False
    return _TIKTOKEN_ENC or None


def estimate_tokens(text):
    if not text:
        return 0
    enc = get_tiktoken()
    if enc is not None:
        try:
            return len(enc.encode(text))
        except Exception:
            pass
    cjk = len(CJK_RE.findall(text))
    rest = len(text) - cjk
    return cjk + (rest + 3) // 4


def resolve_token_budget(context_limit):
    if context_limit and context_limit > 0:
        return max(1, context_limit // BUDGET_DIVISOR)
    return BATCH_CHARS


def resolve_item_cap(context_limit):
    if not context_limit or context_limit <= 0:
        return BATCH_ITEMS
    budget = context_limit // BUDGET_DIVISOR
    return max(BATCH_ITEMS, min(BATCH_MAX_ITEMS, budget // 16))


def log(msg):
    print(msg, flush=True)


def print_banner():
    print("=========================================")
    print("  目录文件批量 LLM 翻译")
    print(f"  版本 {VERSION}")
    print("=========================================")
    print("[适用场景]")
    print("需要批量将目录中的文本类文件（TXT/MD/HTML/JSON/YAML/CSV）翻译为指定语言时使用。")
    print()
    print("[功能说明]")
    print("递归扫描来源目录，按文件类型提取可翻译文本，经 LLM API（OpenAI 兼容）翻译后输出到另一目录，保持原目录结构与文件格式。")
    print("翻译分段按模型上下文 Token 上限的 1/4 动态分批，Token 上限可手动指定（直接回车则自动探测）。")
    print()
    print("[操作方式]")
    print("可直接拖放文件夹到终端，或手动输入路径；按提示依次输入各项参数，确认后执行。也可通过命令行参数非交互运行。")
    print()
    print("[执行步骤]")
    print("1. 收集参数（来源目录、输出目录、文件种类、目标语言、API 地址）")
    print("2. 回显并确认参数")
    print("3. 逐文件提取与翻译")
    print("4. 汇总执行结果")
    print()
    print("[注意事项]")
    print("- 输出目录不能等于或位于来源目录之内。")
    print("- 输出目录中已存在的同名文件将被覆盖（可用 --skip-existing 跳过）。")
    print("- 首次使用需安装依赖：.venv/bin/pip install -r requirements.txt")
    print("=========================================")


def is_translatable(s):
    if not isinstance(s, str):
        return False
    s2 = s.strip()
    if not s2:
        return False
    if not LETTER_RE.search(s2):
        return False
    if re.match(r"^(https?://|ftps?://|mailto:|tel:|data:|www\.|/|\w:[/\\])", s2, re.I):
        return False
    if re.match(r"^[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}$", s2):
        return False
    if re.match(r"^\d{2,4}[-/.]\d{1,2}[-/.]\d{1,4}$", s2):
        return False
    if re.match(r"^#?[0-9a-fA-F]{6}$", s2):
        return False
    if re.match(
        r"^[\w\-. /\\]+\.(json|txt|md|yaml|yml|html?|css|js|png|jpe?g|gif|svg|zip|tar|gz|exe|pdf|docx?|xlsx?|pptx?)$",
        s2,
        re.I,
    ):
        return False
    return True


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


def parse_json_array(s):
    if not isinstance(s, str):
        return None
    s = s.strip()
    m = re.search(r"```(?:json)?\s*(.*?)```", s, re.S)
    if m:
        s = m.group(1).strip()
    try:
        v = json.loads(s)
        if isinstance(v, list):
            return v
    except Exception:
        pass
    m = re.search(r"\[.*\]", s, re.S)
    if m:
        try:
            v = json.loads(m.group(0))
            if isinstance(v, list):
                return v
        except Exception:
            pass
    return None


class LlamaClient:
    def __init__(self, base_url, model=None, timeout=REQUEST_TIMEOUT, context_limit=0):
        self.base = normalize_base(base_url)
        self.model = model
        self.timeout = timeout
        self.context_limit = context_limit

    def fetch_model_meta(self):
        try:
            r = requests.get(self.base + "/models", timeout=15)
            r.raise_for_status()
            j = r.json()
            data = j.get("data") or j.get("models") or []
            return data if isinstance(data, list) else []
        except Exception:
            return []

    def fetch_model(self):
        try:
            for info in self.fetch_model_meta():
                if isinstance(info, dict):
                    mid = info.get("id") or info.get("name")
                    if mid:
                        return mid
        except Exception:
            pass
        return None

    def auto_detect_context(self, model=None):
        try:
            for info in self.fetch_model_meta():
                if isinstance(info, dict):
                    for f in CONTEXT_FIELDS:
                        v = info.get(f)
                        if isinstance(v, int) and v > 0:
                            return v
        except Exception:
            pass
        name = model or self.model
        if name:
            mname = str(name).lower()
            for key, ctx in MODEL_CONTEXT_MAP:
                if key in mname:
                    return ctx
        return 0

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

    def translate_batch(self, texts, lang_code, lang_name):
        n = len(texts)
        sys_prompt = (
            "You are a professional translator. Translate the given text(s) into "
            f"{lang_name} ({lang_code}). Detect the source language yourself.\n"
            "Rules:\n"
            f"1. Output ONLY a valid JSON array with exactly {n} strings, in the same order as input.\n"
            "2. No markdown fences, no explanations, no extra text.\n"
            "3. Preserve numbers, URLs, emails, placeholders, tags, and formatting exactly.\n"
            "4. If an input string has nothing to translate, output an empty string for it."
        )
        payload = json.dumps(texts, ensure_ascii=False)
        in_tokens = estimate_tokens(sys_prompt) + estimate_tokens(payload)
        max_tokens = max(MAX_TOKENS, int(in_tokens * OUTPUT_RATIO))
        last = None
        for attempt in range(RETRIES):
            try:
                content = self.chat(sys_prompt, payload, max_tokens=max_tokens)
            except requests.exceptions.HTTPError as e:
                resp = e.response
                code = getattr(resp, "status_code", None)
                msg = (str(e) + (resp.text if resp is not None else "")).lower()
                if code == 400 and any(w in msg for w in ("context", "prompt", "token", "length")):
                    log("[回退] 批次超出模型上下文长度，将拆分批次重试")
                    return None
                last = f"API 错误: {e}"
                time.sleep(2 * (attempt + 1))
                continue
            except Exception as e:
                last = f"API 错误: {e}"
                time.sleep(2 * (attempt + 1))
                continue
            parsed = parse_json_array(content)
            if parsed is not None and len(parsed) == n and all(isinstance(x, str) for x in parsed):
                return parsed
            if isinstance(parsed, list) and len(parsed) == 0 and n == 1:
                log("[提示] 模型返回空数组，视为无需翻译，保留原文")
                return list(texts)
            got = len(parsed) if isinstance(parsed, list) else "N/A"
            last = f"输出无法解析（长度 {got}，期望 {n}）: {content[:120]!r}"
            if attempt + 1 < RETRIES:
                sys_prompt += f"\nIMPORTANT: previous attempt failed. Return exactly {n} strings as one JSON array, nothing else."
                time.sleep(1)
        log(f"[失败] 批次重试 {RETRIES} 次仍失败：{last}")
        return None


def chunk_indexed(segments, token_budget=None, item_cap=None):
    if token_budget is None:
        token_budget = BATCH_CHARS
    if item_cap is None:
        item_cap = BATCH_ITEMS
    counts = [estimate_tokens(t) for t in segments]
    batches = []
    cur = []
    clen = 0
    for i, t in enumerate(segments):
        if cur and (len(cur) >= item_cap or clen + counts[i] > token_budget):
            batches.append(cur)
            cur = []
            clen = 0
        cur.append(i)
        clen += counts[i]
    if cur:
        batches.append(cur)
    return batches


def translate_batches(client, segments, lang_code, lang_name, token_budget=None):
    if not segments:
        return list(segments)
    translated = list(segments)
    item_cap = resolve_item_cap(client.context_limit if client is not None else 0)
    idx_batches = chunk_indexed(segments, token_budget=token_budget, item_cap=item_cap)

    def run(idxs):
        texts = [segments[i] for i in idxs]
        result = client.translate_batch(texts, lang_code, lang_name)
        if result is not None and len(result) == len(idxs):
            for j, idx in enumerate(idxs):
                translated[idx] = result[j]
            return True
        return False

    total = len(idx_batches)
    done = 0
    for bidx, idxs in enumerate(idx_batches, 1):
        log(f"[进度] 批次 {bidx}/{total}（{len(idxs)} 段）")
        if run(idxs):
            log(f"[完成] 批次 {bidx}/{total} 翻译完成")
        else:
            stack = [idxs]
            good = 0
            bad = 0
            while stack:
                cur = stack.pop()
                if run(cur):
                    good += 1
                elif len(cur) > 1:
                    mid = len(cur) // 2
                    stack.append(cur[:mid])
                    stack.append(cur[mid:])
                else:
                    bad += 1
            if good:
                log(f"[修复] 批次 {bidx}/{total} 拆分重试部分成功（成功 {good} / 失败 {bad}）")
            else:
                log(f"[失败] 批次 {bidx}/{total}（保留原文）")
        done += len(idxs)
    return translated


def rebuild_parts(parts, translated):
    out = []
    for p in parts:
        if p[0] == "raw":
            s = p[1]
            if "\u27e6SEG" in s:
                s = SEG_TOKEN_RE.sub(
                    lambda m: html_mod.escape(translated[int(m.group(1))], quote=True), s
                )
            out.append(s)
        elif p[0] == "seg":
            out.append(translated[p[1]])
        elif p[0] == "jseg":
            out.append(p[2] + translated[p[1]] + p[2])
    return "".join(out)


def extract_text_segments(text):
    parts = []
    segments = []
    lines = text.splitlines(keepends=True)
    i, n = 0, len(lines)
    buf = []

    def flush():
        if buf:
            chunk = "".join(buf)
            if is_translatable(chunk):
                segments.append(chunk)
                parts.append(("seg", len(segments) - 1))
            else:
                parts.append(("raw", chunk))
            buf.clear()

    while i < n:
        line = lines[i]
        st = line.strip()
        if st.startswith("```") or st.startswith("~~~"):
            flush()
            fence = st[:3]
            parts.append(("raw", line))
            i += 1
            while i < n and not lines[i].strip().startswith(fence):
                parts.append(("raw", lines[i]))
                i += 1
            if i < n:
                parts.append(("raw", lines[i]))
                i += 1
            continue
        if st == "":
            flush()
            parts.append(("raw", line))
            i += 1
            continue
        buf.append(line)
        i += 1
    flush()
    return parts, segments


class HTMLTextExtractor(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.parts = []
        self.segments = []
        self._tags = []
        self._script_json = []

    def _container(self):
        for t in reversed(self._tags):
            if t in ("script", "style", "textarea"):
                return t
        return None

    def _add_text(self, text):
        if is_translatable(text):
            self.segments.append(text)
            self.parts.append(("seg", len(self.segments) - 1))
        else:
            self.parts.append(("raw", text))

    def _add_script_text(self, text):
        pos = 0
        for m in JS_STR_RE.finditer(text):
            if m.start() > pos:
                self.parts.append(("raw", text[pos:m.start()]))
            lit = m.group(1)
            inner = lit[1:-1]
            if is_translatable(inner):
                self.segments.append(inner)
                self.parts.append(("jseg", len(self.segments) - 1, lit[0]))
            else:
                self.parts.append(("raw", lit))
            pos = m.end()
        if pos < len(text):
            self.parts.append(("raw", text[pos:]))

    @staticmethod
    def _build_tag(tag, attrs, self_closing):
        s = "<" + tag
        for name, value in attrs:
            if value is None:
                s += f" {name}"
            elif isinstance(value, tuple):
                s += f' {name}="\u27e6SEG{value[1]}\u27e7"'
            else:
                s += f' {name}="{html_mod.escape(str(value), quote=True)}"'
        s += " />" if self_closing else ">"
        return s

    def _handle_attrs(self, attrs):
        out = []
        for name, value in attrs:
            name = name.lower()
            if name in TRANSLATABLE_ATTRS and isinstance(value, str) and is_translatable(value):
                self.segments.append(value)
                out.append((name, ("SEG", len(self.segments) - 1)))
            else:
                out.append((name, value))
        return out

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        self._tags.append(tag)
        if tag == "script":
            is_json = any(
                name.lower() == "type" and value and "json" in value.lower()
                for name, value in attrs
            )
            self._script_json.append(is_json)
        self.parts.append(("raw", self._build_tag(tag, self._handle_attrs(attrs), False)))

    def handle_startendtag(self, tag, attrs):
        tag = tag.lower()
        self.parts.append(("raw", self._build_tag(tag, self._handle_attrs(attrs), True)))

    def handle_endtag(self, tag):
        tag = tag.lower()
        while self._tags:
            t = self._tags.pop()
            if t == tag:
                break
        if tag == "script" and self._script_json:
            self._script_json.pop()
        self.parts.append(("raw", f"</{tag}>"))

    def handle_data(self, data):
        if not data:
            return
        c = self._container()
        if c == "script":
            if self._script_json and self._script_json[-1]:
                self.parts.append(("raw", data))
            else:
                self._add_script_text(data)
        elif c == "style":
            self.parts.append(("raw", data))
        else:
            self._add_text(data)

    def handle_comment(self, data):
        self.parts.append(("raw", f"<!--{data}-->"))

    def handle_decl(self, decl):
        self.parts.append(("raw", f"<!{decl}>"))

    def handle_entityref(self, name):
        self.parts.append(("raw", f"&{name};"))

    def handle_charref(self, name):
        self.parts.append(("raw", f"&#{name};"))

    def handle_pi(self, data):
        self.parts.append(("raw", f"<?{data}>"))


def collect(node, translate_keys, out):
    if isinstance(node, dict):
        for k, v in node.items():
            collect(v, translate_keys, out)
            if translate_keys and isinstance(k, str) and is_translatable(k):
                out.append(k)
    elif isinstance(node, list):
        for v in node:
            collect(v, translate_keys, out)
    elif isinstance(node, str) and is_translatable(node):
        out.append(node)


def transform_new(node, translate_keys, table, start):
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            nv, start = transform_new(v, translate_keys, table, start)
            nk = k
            if translate_keys and isinstance(k, str) and is_translatable(k):
                nk = table[start]
                start += 1
            out[nk] = nv
        return out, start
    if isinstance(node, list):
        out = []
        for v in node:
            nv, start = transform_new(v, translate_keys, table, start)
            out.append(nv)
        return out, start
    if isinstance(node, str) and is_translatable(node):
        return table[start], start + 1
    return node, start


def transform_yaml(node, translate_keys, table, start):
    if isinstance(node, dict):
        renames = []
        for i, (k, v) in enumerate(node.items()):
            start, v2 = transform_yaml(v, translate_keys, table, start)
            if v2 is not v:
                node[k] = v2
            if translate_keys and isinstance(k, str) and is_translatable(k):
                nk = table[start]
                start += 1
                if nk != k:
                    renames.append((i, k, nk))
        for i, ok, nk in reversed(renames):
            val = node.pop(ok)
            node.insert(i, nk, val)
        return start, node
    if isinstance(node, list):
        for i in range(len(node)):
            start, v2 = transform_yaml(node[i], translate_keys, table, start)
            node[i] = v2
        return start, node
    if isinstance(node, str) and is_translatable(node):
        return start + 1, table[start]
    return start, node


def get_yaml():
    y = YAML()
    y.preserve_quotes = True
    y.width = 4096
    return y


def read_csv_rows(text):
    try:
        dialect = csv.Sniffer().sniff(text[:4096], delimiters=",;\t")
    except Exception:
        dialect = csv.excel
    return [list(r) for r in csv.reader(io.StringIO(text), dialect)]


def process_text(raw_text, client, lang_code, lang_name, token_budget=None):
    parts, segments = extract_text_segments(raw_text)
    translated = translate_batches(client, segments, lang_code, lang_name, token_budget=token_budget)
    return rebuild_parts(parts, translated)


def process_html(raw_text, client, lang_code, lang_name, token_budget=None):
    ex = HTMLTextExtractor()
    ex.feed(raw_text)
    ex.close()
    translated = translate_batches(client, ex.segments, lang_code, lang_name, token_budget=token_budget)
    return rebuild_parts(ex.parts, translated)


def process_json(raw_text, all_nodes, client, lang_code, lang_name, token_budget=None):
    data = json.loads(raw_text)
    segments = []
    collect(data, all_nodes, segments)
    translated = translate_batches(client, segments, lang_code, lang_name, token_budget=token_budget)
    new_data, _ = transform_new(data, all_nodes, translated, 0)
    return json.dumps(new_data, ensure_ascii=False, indent=2) + "\n"


def process_yaml(raw_text, all_nodes, client, lang_code, lang_name, token_budget=None):
    yaml = get_yaml()
    data = yaml.load(raw_text)
    segments = []
    collect(data, all_nodes, segments)
    translated = translate_batches(client, segments, lang_code, lang_name, token_budget=token_budget)
    transform_yaml(data, all_nodes, translated, 0)
    buf = io.StringIO()
    yaml.dump(data, buf)
    return buf.getvalue()


def process_csv(raw_text, all_nodes, client, lang_code, lang_name, token_budget=None):
    rows = read_csv_rows(raw_text)
    out_rows = []
    cells = []
    for ri, row in enumerate(rows):
        out_row = []
        for cell in row:
            if (all_nodes or ri == 0) and is_translatable(cell):
                cells.append(cell)
                out_row.append(("SEG", len(cells) - 1))
            else:
                out_row.append(cell)
        out_rows.append(out_row)
    translated = translate_batches(client, cells, lang_code, lang_name, token_budget=token_budget)
    buf = io.StringIO()
    writer = csv.writer(buf, lineterminator="\n")
    for row in out_rows:
        writer.writerow([translated[c[1]] if isinstance(c, tuple) else c for c in row])
    return buf.getvalue()


def dispatch(kind, all_nodes, raw_text, client, lang_code, lang_name, token_budget=None):
    if kind == "text":
        return process_text(raw_text, client, lang_code, lang_name, token_budget)
    if kind == "html":
        return process_html(raw_text, client, lang_code, lang_name, token_budget)
    if kind == "json":
        return process_json(raw_text, all_nodes, client, lang_code, lang_name, token_budget)
    if kind == "yaml":
        return process_yaml(raw_text, all_nodes, client, lang_code, lang_name, token_budget)
    if kind == "csv":
        return process_csv(raw_text, all_nodes, client, lang_code, lang_name, token_budget)
    raise ValueError(kind)


def dry_stats(kind, all_nodes, raw_text):
    segs = []
    if kind == "text":
        _, segs = extract_text_segments(raw_text)
    elif kind == "html":
        ex = HTMLTextExtractor()
        ex.feed(raw_text)
        ex.close()
        segs = ex.segments
    elif kind == "json":
        collect(json.loads(raw_text), all_nodes, segs)
    elif kind == "yaml":
        collect(get_yaml().load(raw_text), all_nodes, segs)
    elif kind == "csv":
        for ri, row in enumerate(read_csv_rows(raw_text)):
            for cell in row:
                if (all_nodes or ri == 0) and is_translatable(cell):
                    segs.append(cell)
    return segs


def scan_files(src, exts):
    out = []
    for p in sorted(src.rglob("*")):
        if p.is_file() and p.suffix.lower() in exts:
            out.append(p)
    return out


def run(args, src, dst, cfg, lang_code, lang_name, client, context_limit=0):
    token_budget = resolve_token_budget(context_limit)
    files = scan_files(src, cfg["exts"])
    if not files:
        log(f"[提示] 未在 {src} 中找到扩展名为 {cfg['exts']} 的文件。")
        return
    log(f"[提示] 发现 {len(files)} 个文件")
    failures = []
    for i, f in enumerate(files, 1):
        rel = f.relative_to(src)
        out = dst / rel
        if args.skip_existing and out.exists():
            log(f"[提示] 步骤 {i}/{len(files)}：{rel} 输出已存在，跳过")
            continue
        log(f"[进度] 步骤 {i}/{len(files)}：{rel} ...")
        try:
            raw_text = decode_bytes(f.read_bytes())
            if args.dry:
                segs = dry_stats(cfg["kind"], cfg["all"], raw_text)
                nb = len(chunk_indexed(segs, token_budget=token_budget,
                                       item_cap=resolve_item_cap(context_limit))) if segs else 0
                log(f"[完成] 提取 {rel}: {len(segs)} 段 / 预计 {nb} 批")
                for s in segs[:3]:
                    log(f"      - {s[:60]!r}")
                continue
            out.parent.mkdir(parents=True, exist_ok=True)
            new_text = dispatch(cfg["kind"], cfg["all"], raw_text, client, lang_code, lang_name, token_budget)
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


def ask_api():
    while True:
        s = clean_path(input("[输入] 请输入 LLM API 地址（OpenAI 兼容，如 http://127.0.0.1:8080）："))
        if not s:
            print("[错误] 地址不能为空。")
            continue
        return s


def ask_token_limit():
    print("[输入] 请输入模型上下文 Token 上限（如 4096 / 32768 / 128000），直接回车将自动探测：")
    while True:
        s = input("[输入] Token 上限 [回车=自动探测 / q 取消]: ").strip().lower()
        if not s:
            return 0
        if s == "q":
            return None
        try:
            v = int(s)
            if v > 0:
                return v
        except ValueError:
            pass
        print("[错误] 请输入正整数或直接回车。")


def ask_file_type():
    print("[输入] 请选择文件种类：")
    for k in sorted(FILE_TYPES, key=int):
        print(f"  [{k}] {FILE_TYPE_LABELS[k]}")
    while True:
        c = input("[输入] 请输入选项数字 [1-8 / q 取消] 然后按回车: ").strip().lower()
        if c in FILE_TYPES:
            return c
        if c == "q":
            return None
        print("[错误] 无效序号，请输入 1-8 或 q。")


def ask_language():
    print("[输入] 请选择目标语言（也可直接输入语言代码或名称，如 fr / Français）：")
    for k, (code, name) in LANGUAGES.items():
        print(f"  [{k}] {name} ({code})")
    while True:
        s = input("[输入] 请输入序号或语言代码 [1-3 / q 取消] 然后按回车: ").strip().lower()
        if s in LANGUAGES:
            return LANGUAGES[s]
        if s == "q":
            return None
        if s:
            return (s, s)
        print("[错误] 目标语言不能为空。")


def is_inside(path, base):
    try:
        path.relative_to(base)
        return True
    except ValueError:
        return False


def confirm_params(src, dst, type_key, lang_name, lang_code, api, model, overwrite, context_desc):
    mode = FILE_TYPE_LABELS[type_key].split("  ")[0]
    print("[提示] 即将执行，请确认以下参数：")
    print(f"  - 来源目录：{src}")
    print(f"  - 输出目录：{dst}")
    print(f"  - 文件种类：{mode}")
    print(f"  - 目标语言：{lang_name} ({lang_code})")
    if api:
        print(f"  - API 地址：{api}")
    print(f"  - 模型：{model or '自动探测'}")
    print(f"  - Token 上限：{context_desc}")
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
    parser = argparse.ArgumentParser(description="目录文件批量 LLM 翻译")
    parser.add_argument("--src", help="来源目录")
    parser.add_argument("--dst", help="输出目录")
    parser.add_argument("--type", help="文件种类序号 1-8")
    parser.add_argument("--lang", help="目标语言序号或代码")
    parser.add_argument("--api", help="LLM API 地址（OpenAI 兼容，必填）")
    parser.add_argument("--model", help="模型名称（默认自动探测）")
    parser.add_argument("--token-limit", help="模型上下文 Token 上限（默认自动探测）")
    parser.add_argument("--skip-existing", action="store_true", help="跳过已存在的输出文件")
    parser.add_argument("--dry", action="store_true", help="仅提取统计，不调用模型不写文件")
    args = parser.parse_args()

    interactive = sys.stdin.isatty()

    def fatal(msg):
        print(f"[错误] {msg}")
        if interactive:
            input("[结束] 按回车键退出...")
        sys.exit(1)

    missing = []
    for name in ("src", "dst", "type", "lang"):
        if not getattr(args, name):
            missing.append(name)
    if not args.dry and not args.api:
        missing.append("api")
    if missing and not interactive:
        fatal(f"非交互模式缺少必需参数：{', '.join('--' + m for m in missing)}。")

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

    if "type" in missing:
        type_key = ask_file_type()
        if type_key is None:
            print("[提示] 已取消，未做任何操作。")
            if interactive:
                input("[结束] 按回车键退出...")
            sys.exit(0)
    else:
        type_key = args.type.strip()
    cfg = FILE_TYPES.get(type_key)
    if not cfg:
        fatal(f"无效文件种类：{type_key}")

    if "lang" in missing:
        lang = ask_language()
        if lang is None:
            print("[提示] 已取消，未做任何操作。")
            if interactive:
                input("[结束] 按回车键退出...")
            sys.exit(0)
        lang_code, lang_name = lang
    else:
        lang_code, lang_name = LANGUAGES.get(args.lang.strip(), (args.lang.strip(), args.lang.strip()))

    api = args.api
    if "api" in missing:
        api = ask_api()

    context_limit = 0
    if args.token_limit:
        try:
            context_limit = int(args.token_limit)
            if context_limit <= 0:
                raise ValueError
        except ValueError:
            fatal(f"无效 --token-limit：{args.token_limit!r}")
    if not context_limit:
        context_limit = CONTEXT_TOKENS
    if interactive and not args.token_limit and not CONTEXT_TOKENS:
        tl = ask_token_limit()
        if tl is None:
            print("[提示] 已取消，未做任何操作。")
            if interactive:
                input("[结束] 按回车键退出...")
            sys.exit(0)
        context_limit = tl
    context_desc = f"{context_limit}（手动）" if context_limit else "自动探测"

    overwrite = False
    if not args.dry and not args.skip_existing:
        files = scan_files(src, cfg["exts"])
        overwrite = any((dst / f.relative_to(src)).exists() for f in files)

    if interactive and missing:
        if not confirm_params(src, dst, type_key, lang_name, lang_code, api, args.model, overwrite, context_desc):
            print("[提示] 已取消，未做任何操作。")
            if interactive:
                input("[结束] 按回车键退出...")
            sys.exit(0)

    client = None
    if not args.dry:
        client = LlamaClient(api, model=args.model or None, context_limit=context_limit)
        model = client.model or client.fetch_model()
        if model:
            client.model = model
            print(f"[提示] 使用模型：{model}")
        else:
            print("[提示] 无法自动探测模型名称，将省略 model 字段。")

        if not client.context_limit:
            resolved = client.auto_detect_context(model)
            if resolved:
                client.context_limit = resolved
                print(f"[提示] 自动探测上下文 Token 上限：{resolved}")
            else:
                print("[提示] 无法探测 Token 上限，将使用保守默认分段。")
        else:
            print(f"[提示] 上下文 Token 上限：{client.context_limit}（批次预算 = {resolve_token_budget(client.context_limit)}）")

        try:
            client.chat("You are a translator.", "ping", max_tokens=8)
        except Exception as e:
            print(f"[提示] LLM 连接测试失败：{e}")
            if interactive:
                if input("[输入] 是否继续？[y/N]：").strip().lower() != "y":
                    print("[提示] 已取消。")
                    input("[结束] 按回车键退出...")
                    sys.exit(0)

    run(args, src, dst, cfg, lang_code, lang_name, client, context_limit)
    if interactive:
        input("[结束] 按回车键退出...")


if __name__ == "__main__":
    main()
