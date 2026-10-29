# Web — Emacs 中的原生 CEF 浏览器

macOS 实验性插件：一个网页对应一个 Emacs buffer，Chromium 视图作为 Emacs 窗口内的 `NSView` 显示。借鉴 Appine 的同进程原生视图方案，使用 CEF 替代 WebKit，不依赖 Qt，也不修改 Emacs 源码或 `Emacs.app`。

**这是浏览器插件的第一版，不是完整 Chrome。** CEF 在 macOS 使用 `parent_view` 嵌入时会进入 Alloy 模式。这一版有网页渲染、导航、独立 profile、浏览历史和 DevTools；没有实现密码管理、Chrome Web Store 安装、Chrome 同步、书签管理或下载管理。持久化 Cookie 不等于保存密码。

本次新增 `X` 恢复关闭页面、会话自动保存和延迟恢复，只涉及 Elisp。已有实例用 `M-x load-file` 加载本项目的 `web.el` 即可，当前打开的网页也会纳入会话保存。

此前的原生消息循环修复仍要求重启一次；如果尚未重启，请先退出浏览器所在的 Emacs，再通过 `./scripts/launch.sh` 启动。

键位已对齐 Vimium：`g` 刷新改为 `r`，`G` 改为滚动到底部，`b` 后退改为 `H`，`F` 改为后台打开链接。

## 开始使用

要求：macOS 13+、Cocoa/NS 版 Emacs 29+（启用动态模块）、Xcode Command Line Tools、CMake、Python 3。原生模块必须与运行 Emacs 的 CPU 架构一致。当前本机验证环境是 Apple Silicon + Emacs 32。

```sh
cd ~/code/elisp/web
./scripts/build.sh
```

首次构建下载 `cef.lock.json` 中固定版本的 CEF，按官方 SHA-1 校验后解包到 `.deps/`，产物放在 `build/`。网络中断可以重跑，已完整下载的分段会复用。建议预留 2 GB 可用空间。

**必须通过项目提供的启动脚本运行浏览器所在的 Emacs：**

```sh
./scripts/launch.sh
# 首次尝试可以不加载个人配置：
./scripts/launch.sh -Q
```

脚本在 `build/EmacsWeb.app` 中生成一个独立副本：使用现有 Emacs 的原始二进制和资源，将 CEF framework 放入副本的 `Contents/Frameworks/`，并对副本做本机 ad-hoc 签名。原来的 `/Applications/Emacs.app` 不会被修改，也不需要重新编译 Emacs。正常启动会读取相同的个人配置；`-Q` 可启动干净实例。启动脚本自动加载 `web.el`。

这是 Chromium macOS 沙箱的约束：它按**实际主应用 bundle**授权 framework 读取，CEF 的 `main_bundle_path` 参数不能替代这个边界。在普通 Emacs 中加载 Elisp 没问题，但打开网页会给出启动脚本提示，不会关闭沙箱强行启动。不能仅把 framework 软链接到副本外面。

如果 Emacs 装在别处：

```sh
EMACS_APP=/path/to/Emacs.app ./scripts/launch.sh
```

如果已经有匹配版本的 CEF 二进制分发包：

```sh
CEF_ROOT=/absolute/path/to/cef_binary_... ./scripts/build.sh
```

如果找不到 Emacs 模块头文件，指定包含 `emacs-module.h` 的目录：

```sh
EMACS_INCLUDE_DIR=/path/to/emacs/include ./scripts/build.sh
```

如需从 `build/EmacsWeb.app` 自行启动，可以把下面配置加入 Emacs。使用启动脚本时不需要重复配置。构建完成后不需要每次启动都重新构建。

```elisp
(add-to-list 'load-path (expand-file-name "~/code/elisp/web"))
(require 'web)

;; 可选；必须在首次打开网页之前设置。
;; (setq web-data-directory (expand-file-name "web/" user-emacs-directory))
;; (setq web-home-url "https://example.org")
```

执行 `M-x web` 输入地址。也可调用 `(web "https://example.org")`。无协议域名默认使用 HTTPS，`localhost:端口` 默认 HTTP，包含空格的输入作为搜索词。

## 在 Emacs 与网页间切换

用 `M-x web` 新建网页后自动选中所在窗口并聚焦网页；`Esc` 或 `C-g` 返回 Emacs，按 `i` 或点击网页重新进入网页输入。通过提示点击按钮或链接后保留 Emacs 命令焦点，可以直接再次按 `f`；普通链接或弹窗产生的前台新 buffer 也会选中并保留命令焦点；`F` 和 `M-f` 打开的链接留在后台。选择输入框、编辑区或下拉框时才进入网页输入。网页聚焦时，`C-x`、`C-c`、`C-h` 和 `M-x` 会交回 Emacs；非输入控件中的 `j` / `k` 用于滚动，其他输入交给 Chromium。页面中的复制粘贴使用 macOS 的 `s-c` / `s-v`。浏览器 buffer 内的独立 `Esc` 键按 `C-g` 处理，用于取消或返回命令状态，不再传给网页触发退出全屏；其他 buffer 的按键保持不变。

| 按键 / 命令 | 操作 |
|---|---|
| `M-x web` | 新建网页 buffer，并聚焦网页 |
| `o` / `O` | 输入地址或搜索词，在当前 / 新页面打开；可补全历史地址 |
| `ge` / `gE` | 编辑当前地址，在当前 / 新页面打开 |
| `r` / `C-c C-r` | 刷新 |
| `j` / `k` | 向下 / 向上滚动；支持数字前缀，例如 `C-u 3 j` |
| `gg` / `G` | 当前滚动区域的顶部 / 底部 |
| `H` / `L` | 后退 / 前进 |
| `gF` | 返回最外层页面，随后滚动外页 |
| `C-c C-p` / `C-u C-c C-p` | 返回上一层 / 最外层页面 |
| `f` / `C-c C-j` | 显示交互元素标签，点击链接、按钮或聚焦输入框 |
| `F` | 提示选择后在后台打开链接；其他控件仍在当前页操作 |
| `C-u C-c C-j` / `M-x web-follow-new-buffer` | 提示选择后在前台打开链接 |
| `p` / `P` | 把最新复制的文本作为地址或搜索词，在当前 / 新页面打开 |
| `t` | 新建页面，打开 `web-home-url`，保留 Emacs 命令焦点 |
| `J` / `K` 或 `gT` / `gt` | 按标签顺序切换到上一个 / 下一个网页，首尾循环 |
| `T` | 按标题或地址补全选择网页 buffer |
| `^` | 返回最近访问的另一个网页 buffer |
| `x` | 关闭当前网页，并切到下一个网页；最后一个关闭后返回普通 buffer |
| `X` | 恢复最近关闭的网页，放回关闭时的标签位置并选中 |
| `C-c w R` / `M-x web-restore-session` | 恢复上一次运行保存的会话 |
| `C-c w S` / `M-x web-save-session` | 立即保存当前会话 |
| `i` / `RET` / `C-c C-i` | 聚焦网页 |
| `Esc` / `C-g` | 取消当前操作、从网页返回 Emacs 命令状态 |
| `C-c w h` / `M-x web-history` | 搜索持久化浏览历史 |
| `C-c C-o` | 编辑并打开当前页面地址，同 `ge` |
| `C-c C-d` | 独立窗口打开 DevTools |
| `M-x web-stop` | 停止加载 |
| `q` | 隐藏当前网页窗口，保留 buffer |
| `C-x k` | 用 Emacs 的 buffer 关闭命令关闭网页 |
| `M-x web-diagnostics` | 查看 CEF 版本、profile 路径及浏览器数量 |

页面切换包含已加载网页和等待加载的会话标签；`gt` / `gT` 的顺序不随最近访问顺序改变。`t`、`O` 和切换页面命令在当前 Emacs 窗口显示目标页面并保留命令焦点。`o` / `O` 使用 Emacs minibuffer 和历史 URL 补全，尚未实现 Vimium 的书签混合搜索。`p` / `P` 与 Emacs 的 yank 一样，通过 `current-kill` 遵循个人剪贴板设置。

不同网页可以并排显示。同一个 buffer 同时出现在多个分屏时，只有被选中的分屏显示原生网页；其余分屏显示提示文字。切换 buffer 会隐藏对应视图，切回时恢复。页面随所在 Emacs frame 移动，不使用外部置顶窗口跟随位置。

`j` / `k` 在 Emacs 命令状态和网页聚焦时都可滚动，每次默认滚动 60 CSS 像素，可通过 `web-scroll-step` 调整。命令交给 CEF 当前聚焦的 frame，支持同域、跨域和多层嵌套 iframe：点击内页后直接按 `j` / `k`，无需先按 `C-g`。网页中的输入框、可编辑区域和下拉框保留正常字母输入；数字前缀在 Emacs 命令状态下使用。按 `C-c C-p`（`web-focus-parent-frame`）将焦点移到上一层页面；`C-u C-c C-p` 直接返回最外层。返回时取消原 frame 的滚动动画并保留 Emacs 命令焦点，不用再按 `C-g`。点击外页空白处也可切回外页。

在选中的 frame 内，从页面初始化时开始记录点击与焦点，优先滚动最近操作区域，到达边界后寻找该文档内的外层滚动区域。可见的原生 dialog、popover 和 ARIA 对话框优先限定滚动范围；外页被锁定时，会寻找弹层内可滚动的面板，并通过实际位移确认能否滚动。点击文字滚出可视区后仍保留其可见滚动容器。暂不跨 iframe 边界向父文档传递滚动。滚动保留原有的 Emacs 或网页键盘焦点。

默认使用按帧平滑动画，`web-scroll-duration` 为约 140 毫秒。连续按键累计目标距离，反向按键取消原方向尚未完成的距离；鼠标滚轮、触摸或点击会打断动画。设置为 `0` 可恢复即时滚动，系统“减少动态效果”偏好也会关闭动画。这是对键盘滚动的平滑处理，没有完整复刻 Vimium 的按住/松开按键速度校准。

Meow 用户：`web-mode` 默认使用 **motion** 状态，浏览器键位定义在 `web-mode-map` 中，`SPC` 继续进入 Meow keypad。只将 `meow-next` / `meow-prev` 局部重映射为网页滚动，以适配常见的 motion `j` / `k` 配置；不修改 Meow 的共享键位或其他 buffer。支持先加载 Meow 或先加载 web；若你在 `meow-mode-state-list` 明确设置了 `web-mode` 的状态，会保留该设置。个人额外定义的 motion 按键仍优先于 major mode。

## 用键盘操作链接和控件

网页聚焦时按 `C-c C-j`，或先按 `C-g` 回到 Emacs 再按 `f`。可见的链接、按钮和表单控件旁会出现黄色字母标签，例如 `a`、`s`、`aa`。输入完整标签立即执行操作，不需要回车。输入过程中不匹配的标签会隐藏；退格可以重新选择，`C-g` 或 Escape 取消。

- 链接、按钮、复选框、单选框、折叠区标题：触发 Chromium 的鼠标点击，保留页面的事件处理、`preventDefault`、表单默认动作和弹窗行为。
- 输入框、文本区域、可编辑内容：聚焦后可以直接输入；单行文本框初始光标在开头时移到末尾，已有光标位置尽量保留。
- 下拉框：聚焦后用空格、方向键和回车操作。
- `F`：普通链接按新标签方式在后台 buffer 打开，当前页面保持选中；按钮和表单仍在当前页操作。需要前台打开时使用 `C-u C-c C-j`。

标签默认使用 `asdfghjklqwertyuiopzxcvbnm`；可通过 `web-hint-alphabet` 自定义至少两个不重复的小写字母。若滚动或尺寸变化使标签位置失效，会清除提示，需要重新调用命令。

支持主文档和开放 shadow DOM 中的标准控件、关联隐藏表单控件的 label、常用 ARIA 交互角色，以及带 `onclick`、可键盘聚焦或显示手形光标的自定义控件。隐藏、被遮挡、禁用、inert 和屏幕外的元素会跳过，最多标注 1000 个。选择后会重新检查元素位置与可用状态，模态对话框内也能显示标签。

去重参考 [Vimium 的候选过滤](https://github.com/philc/vimium/blob/master/content_scripts/link_hints.js)：区分实际控件和可能误判的包装层。原生按钮内部带 `role`、`onclick` 或 `tabindex` 的装饰节点不再单独标注；外层包装与内部控件去重，多个 label 指向同一控件也只保留一个目标。相邻的独立按钮仍分别标注。

这是对 Vimium 常见提示交互的实现，并非 Vimium 的全部功能：`f` / `F` 提示暂不进入 iframe 或关闭的 shadow DOM（`j` / `k` 滚动支持聚焦的 iframe）；没有语义标记、焦点或手形光标的自定义事件控件可能无法识别。`F` 的后台行为与 Vimium 默认键位对齐。特殊页面和控件仍需实际验证。

如果更新了原生模块或 Helper，需要退出浏览器所在的 Emacs 并重新运行 `./scripts/launch.sh`；仅调整 Elisp 键位不需要重启。

## 查找页面内容、快速滚动和处理链接

按 `Esc` 返回 Emacs 命令状态后，可用下面的简短按键。Meow motion 下可直接使用这些键；另外保留 `C-c w` 命令入口，网页正聚焦时可直接从 `C-c w` 开始。

| 操作 | 简短按键 | 通用入口 / 命令 |
|---|---|---|
| 页内搜索 | `/` | `C-c w s` / `web-find` |
| 下一个 / 上一个匹配 | `n` / `N` | `C-c w n` / `C-c w p` |
| 清除搜索高亮 | — | `C-c w c` / `web-find-clear` |
| 向下 / 向上半页 | `d` / `u` | `C-c w d` / `C-c w u` |
| 滚动区域顶部 / 底部 | `gg` / `G`（也保留 `M-<` / `M->`） | `C-c w <` / `C-c w >` |
| 复制当前地址 | `yy` | `C-c w y` / `web-copy-url` |
| 用提示标签复制链接 | `yf` | `C-c w f` / `web-copy-link` |
| 连续在后台打开链接 | `M-f` | `C-c w m` / `web-follow-multiple` |

搜索在 minibuffer 输入文字，按回车后定位并高亮，mode line 显示当前匹配序号和总数。搜索使用 Chromium 原生接口，支持跨域 iframe 内的可搜索文本；当前为不区分大小写的字面文本搜索，不提供正则表达式。`n` / `N` 循环查找，查询和匹配状态按 buffer 保存。在输入查询时按 `Esc` / `C-g` 会取消并清除高亮；已经完成搜索后用 `C-c w c` 清除。清除后仍可用 `n` / `N` 再次搜索上次文字。

半页距离取当前滚动区域高度的一半：页面、内嵌页和弹层中的面板分别按自己的高度计算。`C-u 3 d` 向下滚动三个半页。顶部/底部命令同样作用于当前区域，在区域已到顶部/底部时不跳到外页。刷新使用 `r`，编辑地址使用 `ge`，历史使用 `C-c w h`。

`yy` 和 `yf` 使用 `kill-new`，放入 Emacs kill-ring，并按 Emacs 的剪贴板设置同步。`yf` 只标注可见链接，选择时重新读取并校验地址，不触发网站点击事件，也不会打开网页。

连续打开模式只标注普通 HTTP、HTTPS、file 链接。每选中一个，发送真实的修饰鼠标点击，新页面在后台 buffer 打开，原页面保持选中，原来的标签继续可用。`Esc` / `C-g` 结束并清除标签；随后用 Emacs buffer 切换命令访问新页面。网站的点击处理仍会执行，也可以通过 `preventDefault` 阻止打开。页面若发生导致标签位置变化的滚动或重排，需要重新调用命令。`F` 只打开一次并结束提示，`M-f` 则保留提示以连续打开。

复制及连续打开的提示范围沿用现有提示：主文档和开放 shadow DOM，暂不进入 iframe。后台 buffer 与前台 buffer 共享同一 profile。`F` / `M-f` 打开的网页立即在后台加载；会话恢复出的后台标签则等选中时再创建浏览器。已加载页面尚不自动休眠或卸载。

## 找回关闭的页面和恢复会话

按 `X` 恢复最近关闭的网页，连续按可逐个找回。用 `x`、`C-x k` 或切换 major mode 关闭的网页都会记录，默认保留最近 30 个。恢复会尽量插入关闭时的位置并保留 Emacs 命令焦点。最后一个网页关闭后，在其他 buffer 执行 `M-x web-reopen-closed-tab` 即可。恢复失败时保留原记录，可以重试。

打开、关闭、导航、标题或选中项变化后，会话会在约 1 秒内自动保存；正常退出时再保存一次，然后等待原生浏览器完成关闭。重启后执行 `M-x web-restore-session`，或在网页中按 `C-c w R`：

- 恢复保存的地址、标题、标签顺序和选中项；关闭记录也会保留，重启后仍可用 `X`。
- 最初只为保存的选中页面创建 CEF 浏览器。其他标签可以在 `T` 或普通 Emacs buffer 列表中找到，首次选中时才加载；`J/K`、`gt/gT` 和普通 buffer 切换都支持。
- 保留当前已打开的页面，恢复出的标签追加在后面。同一次 Emacs 运行中只允许恢复这份会话一次，避免重复打开。
- 只加载插件而没有打开或恢复网页，不会把上次会话覆盖为空。即使先打开了新页面，上次会话仍保留在内存中供恢复；首次保存新会话时也会把上一份写入 `session.previous.json`。
- 会话文件用 UTF-8 JSON 原子替换，权限为 `0600`；读取失败或版本不支持时会提示并停止覆盖该文件，正常浏览仍可使用。

这恢复的是页面地址，不保存网页内容、表单输入、滚动位置或每页的前进后退栈。页面会重新请求网站，登录状态由现有 CEF profile 决定。突然崩溃时可能丢失尚未写出的变动；通常保存间隔约一秒，Emacs 长时间忙碌时会延后。手动关闭全部页面会保存空的打开列表，但仍可通过 `X` 的关闭记录找回。

```elisp
;; 可选：调整关闭记录数，或关闭自动会话保存。
(setq web-closed-tab-limit 30)
;; (setq web-session-auto-save nil)
```

`C-c w S` 可随时立即保存。自动保存关闭时，该命令仍可手动保存。

## 数据和能力边界

默认数据在 `~/.emacs.d/web/`（实际相对 `user-emacs-directory`）：

```text
web/
├── history.json          # 插件维护的历史；默认最多 1000 个不同 URL
├── session.json          # 当前会话：标签、选中项和关闭记录
├── session.previous.json # 本次运行首次保存前的上一份会话备份
└── profile/
    ├── cef.log           # 原生错误日志
    └── Default/          # CEF Cookie、站点存储与缓存
```

这个 profile 独立于系统 Chrome。修改 `web-data-directory` 后需要重启 Emacs；不要指向现有 Chrome profile，也不要让两个 Emacs 实例同时使用同一个 profile。CEF 初始化后不能在同一进程中卸载、重新初始化；更新 `.dylib` 后也需要重启 Emacs。首次使用系统钥匙串加密时，macOS 可能显示授权对话框。

- Cookie 和站点存储使用磁盘 profile；网站仍可按自身规则让登录失效。
- 历史由 Elisp 从成功加载事件记录，使用 JSON 和原子替换保存，不依赖 `chrome://history`。
- 点击打开新窗口的链接会转成新 Emacs buffer。第一版不保留 `window.opener` 关系，依赖脚本弹窗通信的登录流程可能不兼容。
- 页面关闭会强制完成，暂不提供 `beforeunload` 的“未保存内容”确认。
- 没有实现密码自动填充、扩展商店、下载管理、权限管理界面。不能用 CEF 的网页兼容性推断这些 Chrome 产品功能可用。
- CEF helper 保持 Chromium 沙箱开启，没有添加 `--no-sandbox` 或绕过证书校验的参数。
- 目前支持 NS/Cocoa Emacs，不支持终端 Emacs、Linux、GNUstep 或 emacs-mac port。

## 验证与排错

本机已通过（2026-10-29，Apple Silicon / Emacs 32.0.50 / 锁定的 CEF 156）：

- 34 项 ERT 测试及无警告 Elisp 字节编译，包括中文历史记录、标签输入、取消清理、控件激活、过期回复、页面创建顺序/MRU 切换、关闭取消和剪贴板入口。
- 会话测试覆盖关闭位置、取消关闭、延迟创建、失败重试、中文编码、原子写失败、损坏文件保护、退出保存和上一份备份。
- 两个独立 GUI 进程验证会话恢复：3 个标签最初只创建 1 个 CEF 浏览器，普通 buffer 切换才加载下一页，并验证 `X` 和共享 profile。
- 2 项真实 Meow 集成测试，覆盖两种加载顺序：motion 默认状态、Vimium 键位、局部 j/k、SPC keypad 和其他 buffer 不受影响。
- 原生 C++/Objective-C++ 编译、Cocoa 独立测试：渲染、跨窗口重挂载、隐藏、关闭、退出。
- 独立 GUI Emacs：实际 `NSView` 几何与分屏坐标一致、焦点 API、跨 frame 移动、关闭后浏览器计数归零。
- 两次独立 Emacs 进程间 Cookie、localStorage 和 JSON 浏览历史恢复。
- 真实网页上的链接标注：可见性过滤、开放 shadow DOM、多字母标签、前缀筛选、取消、当前页及新 buffer 跳转、标签清理。
- 真实控件交互：可信 pointer/mouse 点击事件、JS/ARIA 按钮、嵌套控件与 label 去重、独立按钮保留、点击后命令焦点、表单焦点与光标、复选框、单选框、自定义 label、折叠区、禁用过滤、SPA 链接拦截、弹窗和模态对话框。
- `j` / `k` 实际页面滚动、数字前缀与连续滚动、内层区域滚动及边界向外层传递、命令焦点保留。
- 启用 Meow 的 GUI 实例：同域、跨域和两层嵌套 iframe 焦点路由、键盘返回上一层/最外层、平滑滚动中间帧、累计距离、反向响应、滚轮打断和即时滚动模式。
- Cocoa `Esc` 事件在网页输入框和 Emacs/Meow 命令状态下等价于 `C-g`，不传给网页，并保持 Emacs `fullboth` 全屏状态。
- Cocoa 键盘事件驱动的 `j` / `k`：内页保持网页焦点、首次点击非输入面板、长外页锁定时的原生/ARIA 弹层滚动、弹层关闭后恢复外页、输入框/contenteditable/select 正常输入。

- 页内搜索：中文、字面标点、跨域 iframe、前后匹配、无匹配和清除；搜索取消及过期回调隔离。
- 半页/首尾滚动：页面、固定面板、跨域 iframe 和原生弹层；区域边界不误跳外页。
- 链接复制和连续打开：过滤按钮/隐藏链接、编码地址、复制不点击、真实点击处理、阻止跳转、后台隐藏/焦点保留、取消清理。
- Vimium 键位 GUI 回归：实际按键序列驱动 `gg/G`、`F` 后台打开、`t/J/K/gt/gT/T/^/x`，检查 Emacs 命令焦点与原生视图关闭。
- 消息循环回归：测试探针检查原生 `web::pump` 调用栈内是否重新进入 `NSApp.run`，覆盖持续绘制及 60 步页面创建、切换、隐藏和关闭；探针只加载到隔离测试进程。

尚未完成人工验收：中文输入法、真实键盘快捷键组合、多显示器不同缩放比、Spaces/全屏切换、复杂站点弹窗登录。几何与生命周期测试通过不代表这些场景已经验证。

Elisp 测试不需要启动 CEF：

```sh
emacs -Q --batch -L . -l test/web-test.el -l test/web-session-test.el -f ert-run-tests-batch-and-exit
```

可选的 Meow 测试需要把 Meow 安装目录加入 load-path：

```sh
emacs -Q --batch -L . -L ~/.emacs.d/elpa/meow -l test/web-meow-test.el -f ert-run-tests-batch-and-exit
# 反向加载顺序：
emacs -Q --batch -L . -L ~/.emacs.d/elpa/meow -l web -l test/web-meow-test.el -f ert-run-tests-batch-and-exit
```

独立 GUI 集成测试先构建测试专用的消息循环探针，再启动 `-Q` Emacs，使用自动清理的临时 profile，不加载你的个人配置：

```sh
python3 scripts/test-gui.py
# 指定其他 Cocoa Emacs：
EMACS_APP=/path/to/Emacs.app python3 scripts/test-gui.py
```

独立 Cocoa/CEF 测试用于隔离 Emacs 和 CEF 的问题：

```sh
TEST_PROFILE="$(mktemp -d)"
build/WebRuntime.app/Contents/MacOS/WebRuntime --smoke-test "$TEST_PROFILE"
```

该命令使用专用临时目录，测试后可删除。`WebRuntime.app` 本身不是日常浏览器入口。自动化测试只对临时 profile 设置 `WEB_CEF_TEST_MODE=1`，使用 Chromium 的 mock keychain；日常运行不使用它。测试验证站点持久化，但不验证系统钥匙串授权、真实网站登录或密码自动填充。

如果遇到 `Invalid or prematurely-freed autorelease pool` 并伴随 `abort trap`，需检查 macOS 崩溃报告。本项目在 2026-10-29 捕获到的调用链是 `web::pump → CEF → EmacsApp run → NSApplication run → NSAutoreleasePool drain`。旧模块的隔离测试也确认 CEF pump 会重新进入 `NSApp.run`。修复使用 CEF external message pump，并提供 browser process handler，避免 CEF 回退到默认 Cocoa 消息循环。`M-x web-diagnostics` 应显示 `Message pump: external (Emacs timer)`。这针对已定位的循环重入路径，不代表所有 GPU 或 frame 超时问题都已解决；这些日志需要结合显示异常和独立堆栈分析。

如果网页不显示，先看 `M-x web-diagnostics` 和 `profile/cef.log`。若 minibuffer 提示 `Web paused`，修复日志中的原因后执行 `M-x web-resume`。请在独立测试实例中尝试新的原生代码：浏览器 UI 和 Emacs 共享进程，原生模块崩溃仍可能导致整个 Emacs 退出。

## 实现结构

```text
web.el                    buffer、布局、按键、历史、事件轮询
native/module.mm          Emacs 动态模块 API，参数检查与错误转换
native/web_core.mm        CEF、Cocoa 子视图、焦点和浏览器生命周期
native/helper.cc          CEF 子进程入口、沙箱、每个 frame 的初始化与输入焦点报告
native/scripts.h.in       将同一份滚动脚本编入 Helper
native/hints.js           可交互元素筛选、标签、前缀过滤与激活位置校验
native/scroll.js          聚焦文档内的滚动目标选择与平滑动画
native/smoke.mm           独立 Cocoa 集成测试
scripts/                  下载、构建、bundle 组装与 GUI 测试
```

Elisp 使用 `window-inside-pixel-edges` 得到排除 header/mode line 的矩形。macOS 下这些坐标对应逻辑点，不乘 Retina 比例。原生模块按宿主视图的坐标方向转换，再放置 CEF 的容器视图。

NS 版 Emacs 的 `window-id` 是内部计数器，不可当作 `NSWindow` 句柄。首次绑定 frame 时，插件临时设置一个唯一标题来定位窗口，立即恢复标题，然后保存弱引用。这样无需访问 Emacs 私有 C 结构，也不依赖“当前 key window”猜测宿主。

CEF 要求 `NSApplication` 实现 `CefAppProtocol`。模块给 Emacs 的 application 类补充对应方法，包装 `sendEvent:` 并保留原有实现、类身份和 delegate，兼容已经注册的 KVO 观察。初始化期间还会保存、恢复 Emacs 依赖的进程信号处理，防止 Chromium 重置 `SIGALRM` 后中断宿主。这些是需要持续兼容性测试的原生集成点。

每个网页保留一个由 CEF 自己持有、始终隐藏的生命周期窗口：显示时把其中的浏览器 `NSView` 挂入 Emacs，关闭时归还给 CEF，让它完成原生窗口及浏览器的销毁流程。插件对生命周期窗口只持有弱引用。该隐藏窗口不参与显示、定位或遮挡，与 EAF 的外部窗口覆盖方式不同。

CEF 使用 [external message pump](https://github.com/chromiumembedded/cef/blob/master/libcef/browser/browser_message_loop.cc)，由 Emacs 主线程的 20 毫秒定时器调用 `CefDoMessageLoopWork`。必须同时设置 `external_message_pump` 并提供 `CefBrowserProcessHandler`；只有设置开关时 CEF 仍可能回退到默认循环。`OnScheduleMessagePumpWork` 的请求由已有的周期定时器合并处理，不从可能位于工作线程的回调进入 Lisp 或 Cocoa。CEF 处理自己的任务，Cocoa 事件继续由 Emacs 分发，避免在 Lisp 定时器内重新执行 `NSApp.run`。

CEF 回调只写事件队列，由 Elisp 定时读取，回调中不重入 Lisp。页内查找使用 `CefBrowserHost::Find` 和 `CefFindHandler`，查询串行发起、按 token 接收结果，直到最终回调；停止时清除高亮。当前版本首次查找先重置会话，再请求选中匹配，避免只统计而不定位。网页聚焦时通过 CEF 键盘回调识别非输入控件的 `j` / `k`，同时记录 frame ID；Elisp 处理事件后把滚动脚本发回该 frame，避免事件排队期间焦点变化导致滚错页面。

滚动实现参考 [Vimium scroller](https://github.com/philc/vimium/blob/5aa29614bf1dce05e0d316f8c38722e17f9b38c3/content_scripts/scroller.js) 和 [所有 frame 的初始化配置](https://github.com/philc/vimium/blob/5aa29614bf1dce05e0d316f8c38722e17f9b38c3/manifest.json)：尽早跟踪激活元素、实测滚动能力、寻找可见主要滚动容器。Vimium 还包含特定站点的目标选择和更完整的按住/松开速度处理；当前实现尚不等价于安装 Vimium 扩展。

交互提示通过 CEF 进程消息发送 Emacs 发起的脚本请求，在 renderer 的页面上下文中执行，再返回 JSON 数据。网页没有可调用的原生/Lisp 接口；请求按浏览器和 token 匹配，并有超时。标签输入由 Emacs 读取，选中后清理标签、重新校验目标，并聚焦编辑控件或通过 CEF 鼠标接口点击；新窗口请求仍通过统一的 popup 事件创建 buffer。

参考：[Appine](../appine)、[CEF 项目](https://github.com/chromiumembedded/cef)、[CEF macOS window info](https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_types_mac.h)、[CEF 生命周期约定](https://github.com/chromiumembedded/cef/blob/master/include/cef_life_span_handler.h)。本项目按上述接口重新实现；CEF 的许可证及第三方声明保留在下载的分发包中。

本项目代码采用 GPL-3.0-or-later，见 [LICENSE](LICENSE)。CEF 及 Chromium 组件遵循各自许可证。
