# DEXC Tools｜星辰工具集

道而星辰工具集合。

## 目录结构

| 目录 | 内容 |
| ---- | ---- |
| `pack/` | 针对具体场景的工具集合（含安装脚本、配置工具等） |
| `cli/` | 命令行工具，按系统归档分类 |
| `web/` | 纯前端工具，无需构建、无需后端 |
| `python/` | Python 命令行工具，独立 venv 运行 |
| `doc/` | 文档（含交互规范） |

---

## 命令行工具（`cli/`）

按系统类型归档，新增工具直接放入对应目录，无需修改本文档：

- `cli/macos/`：macOS 工具（`.command`，需 `chmod +x`）
- `cli/linux/`：Linux 工具（`.sh`，需 `chmod +x`）
- `cli/windows/`：Windows 工具（`.ps1`，经 `PSRunner.cmd` 启动）

> Windows 侧工具统一经 `PSRunner.cmd` 拖拽或输入路径运行，详见交互规范。

---

## 场景工具包（`pack/`）

针对具体部署场景的工具集合，每个子目录包含该场景所需的全部脚本与工具。

---

## Python 工具（`python/`）

Python 命令行工具，统一在 `python/.venv` 独立虚拟环境中运行，依赖见 `python/requirements.txt`，运行前先安装依赖：

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

每个工具的直接说明文档为与工具同名的 `.md` 文件（如 `python/llm-dir-translate.md`）。

---

## 纯前端工具（`web/`）

无需构建、无需后端；部分工具通过只读公开接口访问第三方数据。每个工具使用一个独立目录（`web/<工具名>/`），通用样式遵循 `doc/web/common.css` 并在各工具 `style/common.css` 放置副本。新增工具直接创建目录即可，无需修改本文档。

---

## 交互规范与通用资源（`doc/`）

按工具类型归档交互规范与通用样式资源：

- `doc/cli/standard.md`：命令行工具统一交互规范（启动横幅、统一信息前缀、参数收集、BOM 处理等）
- `doc/python/standard.md`：Python 工具统一交互规范（虚拟环境、交互/非交互模式、路径规整等）
- `doc/web/standard.md`：Web 工具统一交互规范（页面布局、Toast 反馈、多语言、CDN 引用等）
- `doc/web/common.css`：Web 工具通用样式源文件（各 Web 工具在 `style/common.css` 放置副本）

各规范均包含工具版本号标注的相关约定。

---

## 许可

本项目基于 [MIT 许可](LICENSE) 发布。版权所有 © 2026 道而星辰。
