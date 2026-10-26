# 简播 · SimplePlayer

一个 macOS 原生视频播放器：Qt 6 + libmpv，界面用 QML 手绘（QuickTime Player 风格），支持本地视频、在线直链 / HLS，以及 **AceStream** 流媒体。

应用名随界面语言变化：简体 → **简播**，繁体 → **簡播**，英文 → **SimplePlayer**。

---

## 功能

- **本地播放**：mp4 / mkv / mov / avi / flv / wmv / webm / m4v / ts / m2ts / rmvb 等视频，以及 mp3 / flac / wav / aac 等音频
- **在线播放**：http(s) 直链、HLS（m3u8）点播与直播
- **AceStream**：粘贴频道页、`acestream://` 链接或 40 位 Content ID 即可播放，引擎缺失时自动拉起
- **拖拽打开**：视频文件直接拖进窗口
- **界面**：视频铺满窗口，底部悬浮半透明控制栏（播放中鼠标静止自动隐藏）；空闲态居中一个打开入口
- **加载提示**：打开文件与缓冲卡顿时，画面中央显示旋转指示器与「正在加载…」
- **设置**：外观（浅色 / 深色 / 跟随系统）、界面语言、硬件解码、循环播放、在线缓冲时长、控制栏隐藏延时，全部自动持久化
- **多语言**：简体中文（源语言）、繁體中文、English，切换即时生效（含原生菜单栏与窗口标题）
- **macOS 集成**：顶部系统菜单栏（原生 NSMenu）、应用菜单、关于 / 帮助窗口、应用图标

---

## 系统要求

| 项 | 要求 |
|---|---|
| 系统 | macOS 13 或更高（AceStream 功能依赖 Virtualization.framework） |
| 芯片 | **Apple Silicon（arm64）**；Intel Mac 无法运行随包的 AceStream 虚拟机 |
| 磁盘 | App 本体约 690 MB（其中引擎运行时约 510 MB） |

---

## 直接使用安装包

1. 打开 `SimplePlayer.dmg`，把 App 拖进「应用程序」
2. 首次启动需右键 → **打开**（安装包为 ad-hoc 签名，未经 Apple 公证）
3. 本地播放开箱即用；**首次播放 AceStream 需要 1–2 分钟**初始化虚拟机与引擎，之后秒起

> 也可以从命令行直接传入要播放的文件或 URL：
>
> ```bash
> ./build/SimplePlayer.app/Contents/MacOS/SimplePlayer /path/to/video.mp4
> ```

---

## 从源码构建

### 依赖

```bash
brew install qt@6 mpv cmake
```

- Qt ≥ 6.5（开发时使用 6.9）
- libmpv（Homebrew 的 mpv 自带）
- CMake ≥ 3.24、Xcode Command Line Tools

### 构建与运行

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
cmake --build build -j8
open build/SimplePlayer.app
```

`-DCMAKE_EXPORT_COMPILE_COMMANDS=ON` 会生成 `build/compile_commands.json`，供 IDE 做 C++ 跳转与补全。QML 语法高亮需要在 IDE 里另装 QML 插件。

项目根目录可以软链一份编译数据库，方便编辑器直接引用：

```bash
ln -sf build/compile_commands.json compile_commands.json
```

---

## 打包

### 1. 准备 AceStream 引擎运行时（可选）

```bash
./scripts/prepare-engine.sh
```

脚本会下载 colima / lima / Ubuntu 虚拟机镜像 / Ace Stream 引擎，构建容器镜像并 `docker save` 成压缩包，产出到 `third_party/acestream-engine/`（约 510 MB，已在 `.gitignore` 中忽略）。

- 需要本机有可用的 `docker`（仅用于**构建镜像**，运行时不依赖 docker CLI）
- GitHub 访问受限时可指定加速前缀：`GH_PROXY=https://ghfast.top ./scripts/prepare-engine.sh`
- 不执行这一步也能正常构建，只是 AceStream 功能会退化为使用系统上已安装的容器服务

### 2. 生成 DMG

```bash
./scripts/package-dmg.sh
```

产物：`dist/SimplePlayer.app` 与 `dist/SimplePlayer.dmg`。脚本依次做：Release 构建 → `macdeployqt` 部署 Qt/QML → 修正 rpath → 补齐第三方 dylib 与 Qt 框架 → ad-hoc 签名 → 生成 DMG。

> `macdeployqt` 需要逐个处理几百个 Mach-O，这一步比较慢（十几分钟量级）。

---

## 目录结构

```
SimplePlayer/
├── CMakeLists.txt
├── resources.qrc              # QML / 图标 / 翻译 的资源清单
├── assets/                    # logo.svg、icon-512.png、SimplePlayer.icns
├── scripts/
│   ├── prepare-engine.sh      # 生成 AceStream 引擎运行时
│   └── package-dmg.sh         # 部署依赖 + 签名 + 出 DMG
├── src/
│   ├── main.cpp               # 入口：OpenGL 后端、语言、菜单、上下文属性
│   ├── AppController.{h,cpp}  # 语言 / 翻译器管理（App.language）
│   ├── mpv/
│   │   └── MpvObject.{h,cpp}  # libmpv render API → QQuickFramebufferObject
│   ├── platform/
│   │   ├── NativeMenuBar.{h,mm}       # 原生 NSMenu 菜单栏
│   │   ├── NativeMenuBarStrings.h     # 菜单文案（供 lupdate 提取）
│   │   └── MacWindowHelper.{h,mm}     # 去掉缩放/最小化按钮
│   ├── stream/
│   │   ├── AceStream.{h,cpp}          # 频道解析 + 引擎自动启动编排
│   │   └── DockerClient.{h,cpp}       # unix socket 直连 Docker Engine API
│   └── qml/
│       ├── Main.qml                   # 主界面与全部对话框
│       └── CompactComboBox.qml        # 紧凑下拉框
├── translations/
│   ├── app_en.ts / .qm
│   └── app_zh_TW.ts / .qm
└── third_party/acestream-engine/      # 引擎运行时（脚本生成，不入库）
    ├── bin/          # colima、limactl
    ├── share/        # lima 模板与脚本
    ├── libexec/      # lima guest agent
    ├── vm/           # Ubuntu 虚拟机镜像（~317 MB）
    └── image/        # Ace Stream 引擎容器镜像（~139 MB）
```

---

## AceStream 是怎么跑起来的

Ace Stream 引擎只有 Windows / Linux / Android 版本，没有 macOS 原生版。这里把它放进一个 Linux 轻量虚拟机里，通过 Docker Engine 启动容器：

```
点击「开始播放」
   │
   ├─ ① 探测 127.0.0.1:6878 ── 引擎已在 → 直接播放
   │
   ├─ ② 探测容器服务（QLocalSocket 直连 Docker Engine API）
   │       └─ 有 → 直接起容器
   │
   └─ ③ 都没有 → 用随包的 colima 启动 Linux VM（vz + Rosetta）
                   → 从本地 tar 导入镜像（不联网）
                   → 创建并启动容器
                   → 轮询 6878 就绪 → 播放
```

几个设计要点：

- **不依赖 Docker Desktop，也不需要 docker CLI**。App 用 `QLocalSocket` 直接和 `~/.colima/…/docker.sock` 说 HTTP，镜像通过 `/images/load` 从本地压缩包导入，全程不访问镜像仓库
- **虚拟机镜像随包分发**，首次启动只是解压，不下载几百 MB
- **amd64 容器跑在 arm64 虚拟机上**，靠 colima 的 `--vz-rosetta` 注册 Rosetta binfmt
- 播放地址优先用 `?id=`；若 AceStream 在线索引不可达（常见），自动回退到 `?infohash=` 直连

引擎容器名 `simpleplayer-acestream`，映射 `6878:6878`，随 App 退出不清理（下次直接复用）。

---

## 设置与持久化

所有设置写在 `QSettings` 的 `player` 分组下，跟随 macOS 偏好设置：

| 键 | 说明 |
|---|---|
| `player/language` | `zh_CN` / `zh_TW` / `en` |
| `player.appearance` | `system` / `light` / `dark` |
| `player/hardwareDecoding` | 使用 VideoToolbox 硬解（下次打开视频生效） |
| `player/loopPlayback` | 单文件循环 |
| `player/networkCacheSecs` | 在线视频缓冲时长（5 / 10 / 30 / 60 秒） |
| `player/hideControlsDelay` | 控制栏自动隐藏延时（毫秒） |

---

## 快捷键

| 快捷键 | 功能 |
|---|---|
| `⌘O` | 打开文件 |
| `⌘L` | 打开链接 |
| `⌘,` | 设置 |
| `⌘/` | 帮助 |
| `⌘Q` | 退出 |
| `空格` | 播放 / 暂停（也可单击画面） |
| `←` / `→` | 后退 / 前进 10 秒 |
| `↑` / `↓` | 音量 ±5 |
| `F` / 双击画面 | 进入 / 退出全屏 |
| `Esc` | 退出全屏 |

---

## 多语言开发

简体中文是源码语言，不需要翻译文件；英文与繁体各有一份 `.ts`：

```bash
# 提取源码中的字符串（含原生菜单的 QT_TRANSLATE_NOOP 清单）
/opt/homebrew/opt/qt@6/bin/lupdate src -extensions cpp,h,mm,m,qml -ts translations/app_en.ts
/opt/homebrew/opt/qt@6/bin/lupdate src -extensions cpp,h,mm,m,qml -ts translations/app_zh_TW.ts

# 编译成 .qm（resources.qrc 会把它们打进 App）
/opt/homebrew/opt/qt@6/bin/lrelease translations/app_en.ts -qm translations/app_en.qm
/opt/homebrew/opt/qt@6/bin/lrelease translations/app_zh_TW.ts -qm translations/app_zh_TW.qm
```

`NativeMenuBar.mm` 用的是 `QCoreApplication::translate("NativeMenu", …)`，lupdate 无法直接提取，因此文案在 `src/platform/NativeMenuBarStrings.h` 里用 `QT_TRANSLATE_NOOP` 登记了一遍——新增菜单项时两处都要改。

---

## 已知限制

- **仅 Apple Silicon**：随包的虚拟机镜像是 arm64，Intel Mac 用不了 AceStream（其它播放功能不受影响）
- **未公证**：DMG 是 ad-hoc 签名，换机器首次打开需右键 → 打开
- **AceStream 依赖上游 P2P**：频道当前无人直播时，引擎会返回 `failed to load content`，界面提示「无法加载该频道内容」
- **首次启动较慢**：需要解压虚拟机镜像并初始化，约 1–2 分钟；之后复用同一虚拟机
- 引擎容器不会随 App 退出自动清理，需要时可自行 `colima stop`

---

## 许可与合规

- 本项目自身尚未声明开源许可证
- 第三方组件遵循各自许可：Qt（LGPL/GPL）、libmpv（GPL/LGPL）、colima 与 lima（Apache-2.0）
- **Ace Stream 引擎为闭源第三方软件**，其许可条款与再分发条件请自行确认后再对外分发安装包
