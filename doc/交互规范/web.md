# DEXC Tools｜Web 工具统一交互规范

本规范用于约束 `web` 目录下所有单页工具（纯前端 HTML 应用）的交互风格与实现约定，以 `web/gitignore-maker/index.html` 为参考模板，确保不同工具间的操作体验一致。

## 核心原则

1. **启动即展示**：进入页面立即展示工具用途与使用方式说明，不依赖用户猜测。
2. **纯前端实现**：无后端请求，逻辑与数据在单页内完成，支持静态部署。
3. **明确的状态反馈**：加载中 / 成功 / 失败等状态必须通过统一反馈组件（Toast）体现。
4. **关键操作需确认**：生成 / 下载等对结果有实际影响的操作为部分失败提供确认流程。
5. **可回退**：用户已选内容（选项、条目等）可逐个移除，避免误操作不可逆。

## 页面布局与目录约定

### 目录结构

每个工具使用独立目录，仅包含一个 HTML 入口与多语言资源：

```
web/<工具名>/
  index.html
  i18n/
    zh-CN.json
    en.json
```

### 页面组成

自上而下由五个区块构成：

1. **头部**：左侧标题（含图标），右侧语言切换下拉。
2. **主工作区**：承载核心交互（常用左右分栏）。
3. **说明区块**：数据来源、使用方法等辅助说明。
4. **全局组件**：Toast 容器、确认 Modal，位于页面层，复用同一套实例。

### 主工作区布局

- 常用左右分栏：左列为数据 / 选项树，右列为「已选集 + 主操作按钮」。
- 左右列卡片可设置 `h-100` 等高与固定 `max-height` 的内滚动区域，保持视觉对齐。

## 版本号

- 版本号格式：`主版本.次版本`。
- 版本号是头部与标题平级展示的一个「标签」，与其它功能标签平等排布，全体置于同一 `d-flex align-items-center gap-2` 容器内，便于后续扩展新的功能标签（以 Badge 平级追加即可）。
- 外观：使用 Bootstrap Badge（`badge bg-dark`）并搭配 `fa-tag` 图标作为版本标签的辨识样式；字号与其它标签一致，不包裹 `<small>` 缩小，显示形如 `1.0`，用户可见。
- 版本标签不属于文案，不携带 `data-i18n`、不进入 i18n 资源、不随语言切换变化；其余功能标签的文案如需翻译使用 `data-i18n`。
- 变更须递增版本号，并同步更新 README 工具表；版本升级遵循 `主版本`（不兼容/重大变更）与 `次版本`（功能变更/修复）约定。

## 多语言与国际化

1. 所有界面文案使用 `data-i18n` 属性；需跟随语言切换的 HTML 属性（如 `aria-label`、`title`）使用 `data-i18n-attr`。
2. 翻译资源存放在 `i18n/zh-CN.json` 与 `i18n/en.json`，key 集合必须一致。
3. 语言选择下拉固定在头部右上角；切换时同步更新 `document.documentElement.lang` 与 `document.title`。
4. 缺失的翻译回显为 key 本身，避免空白；翻译资源加载失败时保留上次语言，不崩溃、不闪退。
5. 切换语言后须重新渲染所有动态列表（树、已选集等），保证文案一致。

## 状态与反馈（Toast）规范

对应命令行工具的「统一信息前缀」，Web 侧统一使用 Toast 反馈，禁止自由发挥。

| 类型 | 图标 | 颜色 | 语义 | 停留 |
| ---- | ---- | ---- | ---- | ---- |
| `info` | `fa-info-circle` | primary | 加载中 / 普通提示 | 不自动关闭（含进度型） |
| `success` | `fa-check-circle` | success | 成功 | 较短自动关闭（约 3s） |
| `danger` | `fa-exclamation-triangle` | danger | 失败 / 异常 | 较长自动关闭（约 5s） |

- Toast 容器固定在页面底部居中：`toast-container position-fixed bottom-0 start-50 translate-middle-x`。
- 提示文案必须使用翻译资源（`t(key)`），不提写死的中英文。

## 加载与空状态

- **加载中**：顶部 `info` Toast「加载中…」，可设定为不自动关闭，结束后关闭。
- **结束反馈**：成功 / 失败均须有明确结束提示；失败时给出重试指引。
- **空状态**：数据为空时显示居中占位（图标 + 文案，如 `fa-inbox` + 暂无数据），禁止呈现空白页面。

## 列表 / 搜索 / 多选交互

### 目录树
- 目录节点支持折叠（Bootstrap Collapse），箭头（chevron）随展开/收起旋转指示。
- 文件节点采用点击 toggle：再点一次取消选择。

### 多选与联动
- 选中节点高亮（`active`）并显示对勾图标。
- 左列选中态、右列已选列表、数量角标三处实时同步。
- 已选集为空时主操作按钮置灰（`disabled`）。

### 搜索定位
- 输入即搜：随输入实时过滤定位。
- 回车跳转：循环跳转上一 / 下一个匹配（`Shift+Enter` 反向）。
- Esc 清除搜索并复位。
- 匹配项高亮（如 `search-hit`），自动展开其祖先目录并 `scrollIntoView`。

## 主操作（生成 / 下载）流程与确认

1. 逐项获取数据（如 fetch 各资源），用 `Promise.allSettled` 分类成功与失败。
2. 结果处理：
   - **全部成功**：直接产出并触发下载。
   - **部分失败**：弹出 Modal 列出失败项，用户「确认生成」后跳过失败项继续。
   - **全部失败**：仅报错（danger Toast），不产出空结果。
3. 下载文件名及后续需用户手动处理的内容（如重命名）须在成功提示中明确说明。

## 错误处理与用户提示

- 单项失败不拖垮整体：按成功 / 失败分类汇总，最终反馈数量。
- 明确区分「加载失败」与「单项失败」，给出各自适当的提示与重试引导。

## 响应式（移动端适配）

- 基于 Bootstrap 栅格（如 `col-md-*`、`col-lg-*`）实现响应式。
- 桌面宽度：主工作区左右分栏并排。
- 移动端（如小于 `768px`）：主工作区上下堆叠，操作区随屏宽自适应。
- 数据列表区域设置固定 `max-height` + `overflow-y:auto`，避免撑破布局；卡片使用 `h-100` 等高对齐。

## 可访问性

- 纯图标按钮（语言切换、搜索上 / 下 / 清除等）必须提供 `aria-label` / `title`，并通过 `data-i18n-attr` 跟随语言切换。
- 主操作按钮使用原生 `button` 并声明 `type`；不可用状态以 `disabled` 表达。
- 模态框使用 Bootstrap Modal（内建 `aria-hidden` 与焦点管理）；图标仅作视觉装饰，关键语义依赖文字文本。
- 语义化标签优先（`header`、`h1`…`h6`、`list` 等），减少无意义的 `div` 层级。

## CDN 统一使用

统一采用 **jsdelivr** 单一 CDN，固定版本号，禁止浮动版本（如 `@latest`）。

| 资源 | 版本 | 链接 |
| ---- | ---- | ---- |
| Bootstrap CSS | 5.3.0 | `https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css` |
| Bootstrap JS Bundle | 5.3.0 | `https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js` |
| Font Awesome CSS | 6.4.0 | `https://cdn.jsdelivr.net/npm/@fortawesome/fontawesome-free@6.4.0/css/all.min.css` |

约定：
- 统一版本组合 `bootstrap@5.3.0` + `fontawesome-free@6.4.0`。
- Font Awesome 使用 jsdelivr 的 npm 路径（包名 `@fortawesome/fontawesome-free`），类名前缀与用法不变。
- 升级依赖须全仓一致，避免不同工具各自用不同版本。

## 编码与文件规范

| 文件类型 | 编码 | 换行 | 其它 |
| -------- | ---- | ---- | ---- |
| `index.html` | UTF-8 | LF | `<meta charset="UTF-8">`；CSS/JS 内联单文件；框架/图标经 CDN 引入 |
| `i18n/*.json` | UTF-8 无 BOM | LF | `zh-CN.json` 与 `en.json` 的 key 集合必须一致 |

## 无后端约定

- 所有工具保持纯前端、可静态部署（如 GitHub Pages / 本地直接打开）。
- 外部数据经只读公开 API（如 GitHub raw / git trees）直接 `fetch`，不携带鉴权、不要求服务端跨域配置。
- 若某工具确实需要后端能力，须在文档中单独说明并评审，禁止未经批准引入后端服务。