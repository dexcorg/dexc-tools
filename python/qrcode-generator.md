# 二维码生成器

> 当前版本：`1.0`

根据用户选择的二维码类型和输入的内容，生成对应的二维码图片并保存到指定路径。支持文本、URL、WIFI、电话、邮件、短信、日历事件、地理位置、vCard 共 9 种类型。

## 功能特性

- **支持 9 种二维码类型**：文本、URL、WIFI、电话、邮件、短信、日历事件、地理位置、vCard
- **交互式命令行**：菜单选择类型，逐项收集参数，回显确认
- **命令行参数**：支持非交互模式批量生成
- **自定义输出路径**：默认输出到脚本所在目录，可指定任意路径
- **纠错级别可选**：支持 L(7%)、M(15%)、Q(25%)、H(30%) 四级纠错
- **路径拖拽支持**：接受终端拖拽文件/目录，自动规整引号与转义

## 环境要求

- Python 3.9+
- qrcode[pil] 依赖

## 安装

首次使用需在 `python` 目录下安装依赖（独立 venv，不污染全局环境）：

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

依赖项：`qrcode[pil]`

## 使用方式

### 交互式运行

```bash
.venv/bin/python qrcode-generator.py
```

启动后先展示工具说明横幅，再按提示操作：

1. **选择二维码类型**（输入数字 1-9，`q` 取消）
2. **输入类型参数**（根据类型不同，逐项收集）
3. **设置输出路径**（可拖放文件至终端，回车使用默认路径）
4. **选择纠错级别**（L/M/Q/H，回车使用默认 M）
5. **确认参数**（回显所有参数，`y` 确认 / `n` 取消）
6. **生成二维码**

### 命令行参数（非交互）

```bash
.venv/bin/python qrcode-generator.py --type text --content "Hello World"
```

| 参数 | 说明 |
| --- | --- |
| `--type` | 二维码类型：text/url/wifi/phone/email/sms/calendar/geo/vcard |
| `--content` | 二维码内容（text/url 类型） |
| `--output` | 输出文件路径（默认：脚本目录/qrcode.png） |
| `--error-correction` | 纠错级别：L/M/Q/H（默认：M） |
| `--ssid` | WiFi 网络名称（wifi 类型） |
| `--password` | WiFi 密码（wifi 类型） |
| `--encryption` | WiFi 加密类型：WPA/WEP/nopass（wifi 类型） |
| `--phone` | 电话号码（phone/sms/vcard 类型） |
| `--email` | 邮件地址（email/vcard 类型） |
| `--message` | 短信内容（sms 类型） |
| `--summary` | 日历事件标题（calendar 类型） |
| `--dtstart` | 事件开始时间（calendar 类型） |
| `--dtend` | 事件结束时间（calendar 类型） |
| `--location` | 事件地点（calendar 类型） |
| `--description` | 事件描述（calendar 类型） |
| `--lat` | 纬度（geo 类型） |
| `--lon` | 经度（geo 类型） |
| `--name` | 联系人姓名（vcard 类型） |
| `--org` | 组织/公司（vcard 类型） |
| `--title` | 职位（vcard 类型） |

> 全部参数由命令行指定时以非交互模式运行：不再回显确认、结束后不等待回车。

## 支持的二维码类型

| 类型 | 说明 | 必需参数 |
| --- | --- | --- |
| 文本 (text) | 纯文本内容 | `--content` |
| URL (url) | 网站链接 | `--content` |
| WIFI (wifi) | WiFi 连接信息 | `--ssid`, `--password`, `--encryption` |
| 电话 (phone) | 电话号码 | `--phone` |
| 邮件 (email) | 邮件地址 | `--email` |
| 短信 (sms) | 短信内容 | `--phone`, `--message` |
| 日历事件 (calendar) | 事件信息 | `--summary`, `--dtstart`, `--dtend` |
| 地理位置 (geo) | 经纬度坐标 | `--lat`, `--lon` |
| vCard (vcard) | 联系人信息 | `--name` |

## 说明与限制

- 输出目录不存在时会自动创建
- 已存在的同名文件会提示覆盖确认
- WIFI 二维码格式：`WIFI:T:加密类型;S:网络名;P:密码;;`
- 日历事件时间格式：`YYYY-MM-DD HH:MM:SS` 或 `YYYYMMDDTHHMMSS`
- vCard 版本：3.0
