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

## 通用样式规范 (common.css)

所有 Web 工具**必须**遵循 `doc/web/common.css`（当前版本 `1.0`）定义的统一样式。为保证工具可独立运行与静态部署友好，采用**外链 CSS + 复制分发**方式：每个工具在 `style/common.css` 放置副本，HTML 通过 `<link>` 引用。

### 版本管理

- 统一维护 `doc/web/common.css`，版本格式 `主版本.次版本`，当前 `1.0`。
- CSS 文件首行标注 `/* common.css v1.0 */`。
- 升级 CSS 版本时：
  1. 更新源文件版本号与内容
  2. 复制到各工具 `style/common.css`
  3. 同步更新 HTML 中的缓存破坏参数 `?v=X.Y`

### 目录结构

每个工具目录结构为：

```
web/<工具名>/
  index.html
  style/
    common.css     ← 通用样式副本
  i18n/
    zh-CN.json
    en.json
```

### 引用方式

在 `<head>` 中按顺序引入：

```html
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>...</title>
  <!-- Bootstrap -->
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css">
  <!-- Font Awesome (jsdelivr) -->
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@fortawesome/fontawesome-free@6.4.0/css/all.min.css">
  <!-- 通用样式（带版本参数防缓存） -->
  <link rel="stylesheet" href="style/common.css?v=1.0">
  <!-- 工具专属样式（内联） -->
  <style>
    /* Tool-specific styles for xxx */
    .custom-class { ... }
  </style>
</head>
```

- **加载顺序**：Bootstrap → Font Awesome → common.css → 工具内联 style
- **缓存破坏**：`href="style/common.css?v=1.0"`，版本号与 CSS 文件头注释保持一致

### 工具专属样式

工具特有的样式（如 `.camera-card`、`.drop-zone`、`.tree-container` 等）继续使用内联 `<style>` 块，置于通用样式之后，避免污染通用规范。

### 同步流程

更新 `doc/web/common.css` 后，将其复制到各工具的 `style/common.css`，并同步更新 HTML 中的缓存参数 `?v=X.Y`。新增工具时同理在 `style/` 目录放置副本并引用。

### 页面结构约定

#### 1. Header 结构 (`.tool-header`)

```html
<body>
  <!-- Header 直接置于 body 下，全宽展示 -->
  <header class="tool-header">
    <div class="container">
      <div class="title-group">
        <h1><i class="fas fa-xxx"></i> <span data-i18n="app_title">工具标题</span></h1>
        <span class="badge bg-dark badge-version"><i class="fas fa-tag"></i> 1.0</span>
        <!-- 可选功能 badge，平级排布 -->
        <span class="badge bg-info badge-feature"><i class="fas fa-xxx"></i><span data-i18n="badge_xxx">功能名</span></span>
      </div>
      <!-- 可选描述文案 -->
      <div class="desc-group"><small class="text-muted" data-i18n="app_desc">工具描述</small></div>
      <div class="lang-group">语言下拉</div>
    </div>
  </header>

  <!-- 主工作区单独用 container 包裹 -->
  <div class="container py-3">
    ...
  </div>
</body>
```

- **布局**：`.tool-header` 全宽（背景色+底边框），内部 `.container` 用 `d-flex justify-content-between align-items-center flex-wrap gap-2` 实现左右分布。
- **左侧 `.title-group`**：`h1`(图标+标题) + `.badge-version`(版本号) + `.badge-feature*`(功能标签)，同一 flex 行，wrap 换行。
- **版本标签**：`.badge-version` + `bg-dark` + `fa-tag` 图标，字号 `0.75rem`，与标题平级。
- **功能标签**：`.badge-feature` + 语义色(`bg-info`/`bg-secondary`/`bg-success`等) + 图标 + 文案，字号 `0.7rem`，可翻译。
- **描述文案**：可选，置于 `.desc-group`，全宽、次行显示，`order: 2`，移动端 `order: 3` 置底。
- **语言下拉**：置于 `.lang-group`，右侧对齐，`order: 1`，移动端 `order: 2`。

#### 2. 卡片结构 (`.tool-card`)

```html
<div class="card tool-card h-100">
  <div class="card-header tool-card-header d-flex justify-content-between align-items-center">
    <div class="title-group"><i class="fas fa-xxx"></i> <span data-i18n="xxx_title">卡片标题</span></div>
    <div class="action-group">操作控件(搜索/只读badge/按钮等)</div>
  </div>
  <div class="card-body tool-card-body">...</div>
</div>
```

- **Header 必须无背景色**（`background: transparent`），仅保留底边框 `border-bottom: 1px solid var(--tool-border)`。
- **必须包含图标+标题**（`.title-group`），左侧对齐。
- **操作区统一置于 Header 右侧** `.action-group` (flex 末尾)，包含搜索输入框、只读 badge、按钮等。
- **Body** 使用 `.tool-card-body` 统一内边距 `1rem`。

#### 3. 图标使用规范

所有 Font Awesome `<i>` 元素必须遵循最小化原则：

| 要求 | 说明 |
|------|------|
| **仅保留两个 class** | `fas` + `fa-xxx`（图标名），禁止添加颜色（`text-*`）、边距（`me-*`/`ms-*`/`mb-*`）、尺寸（`fa-2x` 等）、显示类（`d-block`/`d-inline-block`）等额外 class |
| **颜色由上下文决定** | 图标继承父元素 `color`，标题区文本色、按钮文本色、muted 文本色等由 Bootstrap 语义类控制 |
| **间距由布局控制** | 图标与文字间距通过父容器 flex/gap 或 CSS 变量统一管理，不在 `<i>` 上写死 `me-*` |
| **空状态图标** | 需要大号展示时，包裹在 `<div class="icon-wrapper mb-2">` 等容器中，由容器控制尺寸与间距，`<i>` 本身保持纯净 |
| **JS 动态生成的图标** | 同理，`innerHTML` 拼接时仅输出 `<i class="fas fa-xxx"></i>`，样式交由外层容器 |

**示例对比：**

```html
<!-- ❌ 违规 -->
<i class="fas fa-magic text-primary me-3"></i>
<i class="fas fa-inbox fa-2x d-block mb-2"></i>
<i class="fas fa-folder me-1 text-warning"></i>

<!-- ✅ 合规 -->
<i class="fas fa-magic"></i>
<div class="mb-2"><i class="fas fa-inbox"></i></div>
<i class="fas fa-folder"></i>
```

#### 4. Badge 使用规范

| 类型 | 类名 | 颜色 | 图标 | 说明 |
|------|------|------|------|------|
| 版本号 | `.badge-version` | `bg-dark` | `fa-tag` | 固定格式 `1.0`，不翻译 |
| 功能标签 | `.badge-feature` | 语义色 | 任意 | 可翻译，平级追加 |

#### 5. 多语言资源

- 新增 `app_desc` 键（所有工具），描述文案随语言切换。
- 功能 badge 文案使用 `data-i18n` 翻译。

#### 6. 响应式断点

- 统一 `768px`，Header 在移动端自动换行：标题行→语言下拉→描述文案。

## 版本号

- 版本号格式：`主版本.次版本`。
- 版本号是头部与标题平级展示的一个「标签」，与其它功能标签平等排布，全体置于同一 `d-flex align-items-center gap-2` 容器内，便于后续扩展新的功能标签（以 Badge 平级追加即可）。
- 外观：使用 Bootstrap Badge（`badge bg-dark`）并搭配 `fa-tag` 图标作为版本标签的辨识样式；字号与其它标签一致，不包裹 `<small>` 缩小，显示形如 `1.0`，用户可见。
- 版本标签不属于文案，不携带 `data-i18n`、不进入 i18n 资源、不随语言切换变化；其余功能标签的文案如需翻译使用 `data-i18n`。
- 变更须递增版本号；版本升级遵循 `主版本`（不兼容/重大变更）与 `次版本`（功能变更/修复）约定。

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
| js-yaml | 4.1.0 | `https://cdn.jsdelivr.net/npm/js-yaml@4.1.0/dist/js-yaml.min.js` |

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