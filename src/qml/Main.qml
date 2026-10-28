import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Universal
import QtQuick.Layouts
import QtQuick.Dialogs
import QtCore
import SimplePlayer 1.0

/**
 * QuickTime Player 风格界面：
 * - 视频铺满窗口，控制栏悬浮在底部（半透明圆角，播放中鼠标静止自动隐藏）
 * - 空闲时显示居中的打开入口
 * - macOS 原生菜单栏：文件 / 帮助
 */
ApplicationWindow {
    id: root
    visible: true
    width: 1100
    height: 680
    minimumWidth: 320
    minimumHeight: 200
    color: skin.windowBg

    Universal.theme: skin.dark ? Universal.Dark : Universal.Light
    Universal.accent: "#3d9bff"
    Universal.foreground: skin.textPrimary

    /** 应用显示名：跟随界面语言（简体「简播」/ 繁体「簡播」/ 英文 SimplePlayer） */
    readonly property string appName: {
        // 退出时 App 上下文对象可能先于界面销毁，这里做空值兜底
        const lang = App ? App.language : "zh_CN"
        return lang === "en" ? "SimplePlayer"
             : lang === "zh_TW" ? "簡播"
             : "简播"
    }

    readonly property var languageCodes: ["zh_CN", "zh_TW", "en"]

    title: mpv.mediaTitle.length > 0 ? (mpv.mediaTitle + " — " + root.appName) : root.appName

    // ---------- 状态 ----------

    /// 用 mediaLoaded 而不是 duration：直播流（AceStream / HLS）的 duration 为 0
    readonly property bool hasMedia: mpv.mediaLoaded
    property bool controlsHovered: false
    readonly property bool controlsVisible:
        hasMedia && (mpv.paused || controlsHovered || hideControlsTimer.running
                     || statsOpen)

    // ---------- 流健康状态 ----------

    /// 是否正在播放网络流（由 mpv.load 传入的 URL 协议判断）
    readonly property bool isNetworkStream: mpv.networkStream
    property bool statsOpen: false
    /// 0 = 流畅，1 = 一般，2 = 卡顿，-1 = 不适用
    readonly property int streamHealth: {
        if (!isNetworkStream || mpv.cacheBufferingState < 0)
            return -1
        if (mpv.pausedForCache || mpv.cacheBufferingState < 20)
            return 2
        if (mpv.cacheBufferingState < 60 || mpv.cacheDuration < 3)
            return 1
        return 0
    }
    readonly property color healthColor: streamHealth === 2 ? "#ff5f57"
                                        : streamHealth === 1 ? "#f0b400"
                                        : streamHealth === 0 ? "#32c759"
                                        : skin.textFaint
    readonly property string healthLabel: streamHealth === 2 ? qsTr("卡顿")
                                          : streamHealth === 1 ? qsTr("一般")
                                          : streamHealth === 0 ? qsTr("流畅")
                                          : "—"

    /// 直播流：没有时长，进度条只显示缓冲、不显示播放进度
    /// AceStream 引擎代理层会伪造短 duration（~12 秒），需要单独识别
    readonly property bool liveStream: hasMedia
                                      && (mpv.duration <= 0 || mpv.aceStreamSource)

    /// 缓冲段在进度条上的起止比例（仅网络流；直播以缓存目标时长为基准）
    readonly property real bufferStartFraction: {
        if (!isNetworkStream || !hasMedia || liveStream)
            return 0
        return mpv.duration > 0 ? Math.min(mpv.position / mpv.duration, 1) : 0
    }
    readonly property real bufferEndFraction: {
        if (!isNetworkStream || !hasMedia || mpv.cacheDuration < 0)
            return 0
        if (liveStream) {
            const target = Math.max(appSettings.networkCacheSecs, 1)
            return Math.min(mpv.cacheDuration / target, 1)
        }
        return mpv.duration > 0
            ? Math.min((mpv.position + mpv.cacheDuration) / mpv.duration, 1) : 0
    }

    onIsNetworkStreamChanged: {
        if (!isNetworkStream)
            statsOpen = false
    }
    onHasMediaChanged: {
        if (!hasMedia)
            statsOpen = false
    }

    function fmtCacheSeconds(v) {
        if (!isFinite(v) || v < 0)
            return "—"
        return v.toFixed(1) + " " + qsTr("秒")
    }

    function fmtSpeed(v) {
        if (!isFinite(v) || v < 0)
            return "—"
        if (v >= 1048576)
            return (v / 1048576).toFixed(1) + " MB/s"
        if (v >= 1024)
            return (v / 1024).toFixed(0) + " KB/s"
        return Math.round(v) + " B/s"
    }

    function fmtBitrate(v) {
        if (!isFinite(v) || v <= 0)
            return "—"
        if (v >= 1e6)
            return (v / 1e6).toFixed(1) + " Mbps"
        return Math.round(v / 1000) + " kbps"
    }

    // ---------- 设置持久化（QSettings） ----------

    Settings {
        id: appSettings
        category: "player"
        property bool hardwareDecoding: true
        property bool loopPlayback: false
        property int networkCacheSecs: 10
        property int hideControlsDelay: 2600
        // 外观："system" | "light" | "dark"
        property string appearance: "system"
        // Docker：留空表示自动探测常见 socket
        property string dockerSocketPath: ""
        property bool stopColimaOnQuit: true
        // AceStream 最近输入历史（最多 8 条，最近在前）
        property var recentStreams: []
        // 启动时自动检查更新（菜单"检查更新"仍可手动触发）
        property bool autoCheckUpdate: true
    }

    // ---------- 皮肤（浅色 / 深色调色板） ----------

    SystemPalette {
        id: sysPalette
        colorGroup: SystemPalette.Active
    }

    readonly property bool systemDark:
        (sysPalette.window.r * 0.299 + sysPalette.window.g * 0.587
         + sysPalette.window.b * 0.114) < 0.5

    QtObject {
        id: skin

        readonly property bool dark:
            appSettings.appearance === "dark"
            || (appSettings.appearance === "system" && root.systemDark)

        readonly property color windowBg: dark ? "#101013" : "#f2f2f7"
        readonly property color panel: dark ? "#1b1b20" : "#ffffff"
        readonly property color panelBorder: dark ? "#33333c" : "#d9d9df"
        readonly property color separator: dark ? "#2a2a33" : "#e4e4ea"

        readonly property color textPrimary: dark ? "#e8e8ec" : "#1c1c1e"
        readonly property color textSecondary: dark ? "#d0d0d8" : "#3c3c42"
        readonly property color textMuted: dark ? "#9a9aa3" : "#6a6a72"
        readonly property color textFaint: dark ? "#7a7a84" : "#8a8a92"
        readonly property color hintText: dark ? "#6a6a74" : "#8a8a92"
        readonly property color hintSub: dark ? "#4a4a54" : "#a0a0a8"
        readonly property color bodyText: dark ? "#c8c8d0" : "#3c3c42"

        readonly property color barBg: dark ? Qt.rgba(0.10, 0.10, 0.12, 0.88)
                                           : Qt.rgba(0.98, 0.98, 1.00, 0.94)
        readonly property color barBorder: dark ? "#34343e" : "#d5d5db"
        readonly property color track: dark ? "#43434c" : "#d6d6dc"
        readonly property color handle: dark ? "#ffffff" : "#8e8e93"
        readonly property color hoverLight: dark ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(0, 0, 0, 0.07)
        readonly property color hoverStrong: dark ? Qt.rgba(1, 1, 1, 0.20) : Qt.rgba(0, 0, 0, 0.14)

        readonly property color idleRing: dark ? "#3a3a44" : "#c9c9d0"
        readonly property color idleIcon: dark ? "#8a8a94" : "#7a7a84"

        readonly property color toastBg: dark ? "#26262e" : "#ffffff"
        readonly property color toastBorder: dark ? "#3a3a44" : "#d9d9df"

        // 输入类控件（下拉框 / 输入框 / 按钮）
        readonly property color controlBg: dark ? "#26262e" : "#ffffff"
        readonly property color controlBorder: dark ? "#3a3a44" : "#d0d0d6"
        readonly property color popupBg: dark ? "#202027" : "#ffffff"
        readonly property color accent: "#3d9bff"
    }

    /** 把当前设置应用到播放器 */
    function applySettings() {
        mpv.hardwareDecoding = appSettings.hardwareDecoding
        mpv.loopPlayback = appSettings.loopPlayback
        mpv.networkCache = appSettings.networkCacheSecs
    }

    // 菜单栏由原生 NSMenu 实现（见 src/platform/NativeMenuBar.mm），
    // 菜单回调通过下面的函数打开对应对话框。

    function showWindow(w) {
        w.show()
        w.raise()
        w.requestActivate()
    }

    function openFileDialog() { openDialog.open() }
    function openUrlDialog() { showWindow(urlWindow) }
    function openStreamDialog() { showWindow(streamWindow) }
    function openSettingsDialog() { showWindow(settingsWindow) }
    function openHelpDialog() { showWindow(helpWindow) }
    function openAboutDialog() { showWindow(aboutWindow) }

    function loadFromCli(url) {
        mpv.load(url.toString ? url.toString() : url)
    }

    /// 原生「字幕」菜单的动作入口
    function handleSubtitleAction(action, value) {
        switch (action) {
        case "load":
            subtitleDialog.open()
            break
        case "off":
            mpv.selectSubtitle(-1)
            break
        case "track":
            mpv.selectSubtitle(value)
            break
        case "delay-up":
            mpv.changeSubtitleDelay(0.5)
            break
        case "delay-down":
            mpv.changeSubtitleDelay(-0.5)
            break
        case "delay-reset":
            mpv.resetSubtitleDelay()
            break
        case "scale-up":
            mpv.changeSubtitleScale(0.1)
            break
        case "scale-down":
            mpv.changeSubtitleScale(-0.1)
            break
        case "pos-up":
            mpv.changeSubtitlePosition(5)
            break
        case "pos-down":
            mpv.changeSubtitlePosition(-5)
            break
        case "reset":
            mpv.resetSubtitleStyle()
            break
        }
    }

    /// 把当前字幕轨道状态同步给原生菜单（勾选当前轨道 / 「无字幕」）
    function syncSubtitleMenu() {
        NativeMenu.setSubtitleState(mpv.subtitleTracks, mpv.activeSubtitleId)
    }

    Connections {
        target: mpv
        function onSubtitleTracksChanged() { root.syncSubtitleMenu() }
        function onSubtitleStateChanged() { root.syncSubtitleMenu() }
    }

    function fmtTime(t) {
        if (!isFinite(t) || t <= 0)
            return "00:00"
        const h = Math.floor(t / 3600)
        const m = Math.floor((t % 3600) / 60)
        const s = Math.floor(t % 60)
        const mm = String(m).padStart(2, "0")
        const ss = String(s).padStart(2, "0")
        return h > 0 ? (h + ":" + mm + ":" + ss) : (mm + ":" + ss)
    }

    function toggleFullscreen() {
        if (root.visibility === Window.FullScreen)
            root.showNormal()
        else
            root.showFullScreen()
    }

    /// 已经按哪个 loadSerial 调整过窗口，避免同一文件重复改尺寸
    property int fittedSerial: -1

    /** 打开新视频时，把窗口调整成与视频一致的比例 */
    function fitToVideo() {
        const vw = mpv.videoWidth
        const vh = mpv.videoHeight
        if (vw <= 0 || vh <= 0)
            return
        if (root.visibility === Window.FullScreen || root.visibility === Window.Maximized)
            return

        const ratio = vw / vh
        const area = root.screen ? root.screen.availableGeometry : null
        const maxW = area ? area.width * 0.9 : 1280
        const maxH = area ? area.height * 0.9 : 800

        // 以当前宽度为基准，且不超过视频原始宽度（小视频不放大过头）
        let tw = Math.min(Math.max(root.width, root.minimumWidth), maxW,
                          Math.max(vw, 640))
        let th = tw / ratio

        if (th > maxH) {
            th = maxH
            tw = th * ratio
        }
        if (tw < root.minimumWidth) {
            tw = root.minimumWidth
            th = tw / ratio
        }
        if (th < root.minimumHeight) {
            th = root.minimumHeight
            tw = th * ratio
        }

        root.width = Math.round(tw)
        root.height = Math.round(th)
    }

    function maybeFitVideo() {
        if (mpv.loadSerial === fittedSerial)
            return
        if (mpv.videoWidth <= 0 || mpv.videoHeight <= 0)
            return
        fittedSerial = mpv.loadSerial
        fitToVideo()
    }

    Connections {
        target: mpv
        function onVideoSizeChanged() { root.maybeFitVideo() }
        function onMediaLoadedChanged() { root.maybeFitVideo() }
    }

    Component.onCompleted: {
        volumeBar.value = mpv.volume
        applySettings()
        syncSubtitleMenu()
    }

    // ---------- 视频区 ----------

    MpvObject {
        id: mpv
        anchors.fill: parent
    }

    DropArea {
        anchors.fill: parent
        onDropped: (drop) => {
            if (drop.urls && drop.urls.length > 0)
                mpv.load(drop.urls[0])
        }
    }

    // 鼠标活动层：点击播放/暂停、双击全屏、移动唤出控制栏
    // 放在 DropArea 之后，保证它是最上层的 hover 接收者；
    // 反过来会被 DropArea 挡住 hover，导致移动鼠标唤不出控制栏
    MouseArea {
        id: activityArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        onClicked: {
            if (root.statsOpen) {
                root.statsOpen = false
                return
            }
            if (mpv.loading)
                return
            if (root.hasMedia)
                mpv.playPause()
            else
                openDialog.open()
        }
        onDoubleClicked: root.toggleFullscreen()
        onEntered: {
            if (root.hasMedia && !mpv.paused)
                hideControlsTimer.restart()
        }
        onPositionChanged: {
            if (root.hasMedia && !mpv.paused)
                hideControlsTimer.restart()
        }
    }

    // ---------- 更新提示：右上角云朵 ----------
    // 仅在发现新版本时显示，下载中也会保留并显示百分比
    Row {
        id: updateCloud
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 14
        anchors.rightMargin: 16
        spacing: 6

        // 下载进度条（下载中时在云朵下方显示）
        Column {
            spacing: 6

            ZStack {
                width: 44
                height: 28

                // 胶囊背景（圆角矩形模拟云朵）
                Rectangle {
                    anchors.fill: parent
                    radius: 14
                    color: skin.dark ? "#2a2a32" : "#ffffff"
                    border.width: 1
                    border.color: skin.controlBorder
                    opacity: updateCloud.hovered ? 1 : 0.85
                    Behavior on opacity { NumberAnimation { duration: 120 } }
                }

                // 下载箭头图标
                Canvas {
                    anchors.centerIn: parent
                    width: 18
                    height: 18
                    property color iconColor: skin.accent
                    onPaint: {
                        const ctx = getContext("2d")
                        ctx.reset()
                        ctx.strokeStyle = iconColor
                        ctx.lineWidth = 1.8
                        ctx.lineCap = "round"
                        ctx.lineJoin = "round"
                        // 向下箭头：竖线 + 底部 v 形
                        ctx.beginPath()
                        ctx.moveTo(9, 3)
                        ctx.lineTo(9, 13)
                        ctx.stroke()
                        ctx.beginPath()
                        ctx.moveTo(4, 9)
                        ctx.lineTo(9, 15)
                        ctx.lineTo(14, 9)
                        ctx.stroke()
                    }
                }

                // 百分比文字（下载中时显示）
                Text {
                    anchors.centerIn: parent
                    text: NativeMenu.updateDownloadPercent + "%"
                    visible: NativeMenu.updateDownloading
                    color: skin.textPrimary
                    font.pixelSize: 10
                    font.bold: true
                }

                // 脉冲红点，吸引注意力
                Rectangle {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.rightMargin: 10
                    anchors.topMargin: 8
                    width: 6
                    height: 6
                    radius: 3
                    color: "#ff5f57"
                    opacity: updateCloud.visible && !NativeMenu.updateDownloading ? 1 : 0
                    visible: opacity > 0
                }
            }

            // 下载进度条
            Rectangle {
                visible: NativeMenu.updateDownloading
                width: 44
                height: 3
                radius: 1.5
                color: skin.track

                Rectangle {
                    width: Math.min(parent.width * NativeMenu.updateDownloadPercent / 100,
                                    parent.width)
                    height: parent.height
                    radius: 1.5
                    color: skin.accent
                }
            }
        }

        // 点击弹出对话框
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (!NativeMenu.updateDownloading && NativeMenu.updateAvailable) {
                    updateDialog.open()
                }
            }
        }

        // 可见性：有更新 或 下载中
        visible: NativeMenu.updateAvailable || NativeMenu.updateDownloading

        Behavior on scale {
            NumberAnimation { duration: 220; easing.type: Easing.OutBack }
        }
    }

    // ---------- 更新对话框（云朵点击弹出） ----------
    Dialog {
        id: updateDialog
        title: qsTr("发现新版本")
        modal: true
        standardButtons: Dialog.NoButton
        width: 340

        ColumnLayout {
            anchors.fill: parent
            spacing: 12

            Label {
                text: qsTr("已发现新版本 %1").arg(NativeMenu.updateTagName)
                font.pixelSize: 13
                font.bold: true
                color: skin.textPrimary
                Layout.fillWidth: true
            }

            Label {
                text: qsTr("是否立即下载更新？")
                color: skin.textSecondary
                font.pixelSize: 12
                Layout.fillWidth: true
            }

            Item { Layout.fillHeight: true }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Item { Layout.fillWidth: true }

                Button {
                    text: qsTr("忽略此版本")
                    onClicked: {
                        NativeMenu.ignoreUpdate()
                        updateDialog.close()
                    }
                }

                Button {
                    text: qsTr("下载")
                    isDefault: true
                    onClicked: {
                        NativeMenu.startUpdateDownload()
                        updateDialog.close()
                    }
                }
            }
        }
    }

    // ---------- 加载中 ----------

    Item {
        id: loadingOverlay
        anchors.centerIn: parent
        width: 156
        height: 112
        visible: mpv.loading
        z: 6

        Rectangle {
            anchors.fill: parent
            radius: 16
            color: skin.dark ? Qt.rgba(0.06, 0.06, 0.08, 0.78) : Qt.rgba(1, 1, 1, 0.88)
            border.width: 1
            border.color: skin.dark ? Qt.rgba(1, 1, 1, 0.07) : Qt.rgba(0, 0, 0, 0.07)
        }

        Canvas {
            id: spinner
            width: 34
            height: 34
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: 24
            // 轨道与进度用固定中性色，深浅色主题下都清晰
            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                ctx.lineWidth = 3
                ctx.lineCap = "round"
                ctx.strokeStyle = "#5a5a66"
                ctx.beginPath()
                ctx.arc(width / 2, height / 2, width / 2 - 3, 0, Math.PI * 1.5, false)
                ctx.stroke()
                ctx.strokeStyle = "#3d9bff"
                ctx.beginPath()
                ctx.arc(width / 2, height / 2, width / 2 - 3, Math.PI * 1.5,
                        Math.PI * 2, false)
                ctx.stroke()
            }

            NumberAnimation on rotation {
                from: 0
                to: 360
                duration: 900
                loops: Animation.Infinite
                running: loadingOverlay.visible
            }
        }

        Label {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 18
            text: mpv.pausedForCache ? qsTr("正在缓冲…") : qsTr("正在加载…")
            color: skin.textSecondary
            font.pixelSize: 12
        }
    }

    // ---------- 空闲态（居中打开入口） ----------

    Item {
        anchors.centerIn: parent
        visible: !root.hasMedia && !mpv.loading
        width: childrenRect.width
        height: childrenRect.height

        Column {
            spacing: 16

            Rectangle {
                width: 76
                height: 76
                radius: 38
                color: "transparent"
                border.color: skin.idleRing
                border.width: 1.5
                anchors.horizontalCenter: parent.horizontalCenter

                Label {
                    anchors.centerIn: parent
                    anchors.horizontalCenterOffset: 2
                    text: "▶\uFE0E"
                    color: skin.idleIcon
                    font.pixelSize: 26
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: openDialog.open()
                }
            }

            Label {
                anchors.horizontalCenter: parent.horizontalCenter
                text: qsTr("点击打开视频")
                color: skin.hintText
                font.pixelSize: 15
            }

            Label {
                anchors.horizontalCenter: parent.horizontalCenter
                text: qsTr("⌘O 打开文件 · ⌘L 打开链接 · 支持拖拽")
                color: skin.hintSub
                font.pixelSize: 12
            }
        }
    }

    // ---------- 悬浮控制栏（QuickTime 风格） ----------

    Timer {
        id: hideControlsTimer
        interval: appSettings.hideControlsDelay
    }

    Rectangle {
        id: controlBar
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 24
        width: Math.min(560, parent.width - 48)
        height: 92
        radius: 16
        // 固定深色半透明（与 QuickTime 一致），浅色 / 深色主题下都清晰
        color: Qt.rgba(0.11, 0.11, 0.13, 0.84)
        border.color: Qt.rgba(1, 1, 1, 0.08)
        border.width: 1
        opacity: root.controlsVisible ? 1 : 0
        visible: root.controlsVisible || opacity > 0.01
        enabled: root.controlsVisible

        readonly property color iconColor: "#f0f0f4"
        readonly property color iconMuted: Qt.rgba(1, 1, 1, 0.55)
        readonly property color hoverBg: Qt.rgba(1, 1, 1, 0.12)
        readonly property color pressedBg: Qt.rgba(1, 1, 1, 0.20)
        readonly property color trackColor: Qt.rgba(1, 1, 1, 0.20)

        Behavior on opacity {
            NumberAnimation { duration: 180 }
        }

        HoverHandler {
            onHoveredChanged: {
                root.controlsHovered = hovered
                // 移出控制栏后给一段时间再隐藏，避免来回移动时闪烁
                if (!hovered)
                    hideControlsTimer.restart()
            }
        }

        // 吞掉控制栏空白处（以及禁用控件）的点击，
        // 否则事件会穿透到视频区的 MouseArea，误触发播放/暂停
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
        }

        // ---- 第一行：音量 / 传输控制 / 右侧功能 ----
        Item {
            id: controlsRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: 6
            height: 44

            Row {
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6

                // 喇叭图标：点击静音 / 取消静音
                Item {
                    id: muteBtn
                    width: 20
                    height: 22

                    Canvas {
                        id: volCanvas
                        anchors.centerIn: parent
                        width: 17
                        height: 14
                        property bool muted: mpv.volume === 0
                        property color iconColor: controlBar.iconColor
                        onMutedChanged: requestPaint()
                        onIconColorChanged: requestPaint()
                        Component.onCompleted: requestPaint()

                        onPaint: {
                            const ctx = getContext("2d")
                            ctx.reset()
                            ctx.fillStyle = iconColor
                            ctx.beginPath()
                            ctx.moveTo(1, 5)
                            ctx.lineTo(4.5, 5)
                            ctx.lineTo(8, 1.5)
                            ctx.lineTo(8, 12.5)
                            ctx.lineTo(4.5, 9)
                            ctx.lineTo(1, 9)
                            ctx.closePath()
                            ctx.fill()
                            ctx.strokeStyle = iconColor
                            ctx.lineWidth = 1.4
                            ctx.lineCap = "round"
                            if (!muted) {
                                ctx.beginPath()
                                ctx.arc(8, 7, 3, -Math.PI / 3.2, Math.PI / 3.2)
                                ctx.stroke()
                                ctx.beginPath()
                                ctx.arc(8, 7, 5.5, -Math.PI / 3.2, Math.PI / 3.2)
                                ctx.stroke()
                            } else {
                                ctx.beginPath()
                                ctx.moveTo(11, 4.5)
                                ctx.lineTo(16, 9.5)
                                ctx.moveTo(16, 4.5)
                                ctx.lineTo(11, 9.5)
                                ctx.stroke()
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: mpv.volume = mpv.volume === 0 ? 100 : 0
                    }
                }

                Slider {
                    id: volumeBar
                    width: 78
                    height: 22
                    // 窗口很窄时只保留喇叭图标，给传输按钮让位
                    visible: controlBar.width >= 440
                    from: 0
                    to: 100
                    stepSize: 1
                    property bool scrubbing: false
                    onPressedChanged: scrubbing = pressed
                    onMoved: if (scrubbing) mpv.volume = Math.round(value)

                    background: Rectangle {
                        x: volumeBar.leftPadding
                        y: volumeBar.topPadding + volumeBar.availableHeight / 2 - height / 2
                        width: volumeBar.availableWidth
                        height: 4
                        radius: 2
                        color: controlBar.trackColor

                        Rectangle {
                            width: volumeBar.visualPosition * parent.width
                            height: parent.height
                            radius: 2
                            color: controlBar.iconColor
                        }
                    }

                    handle: Rectangle {
                        x: volumeBar.leftPadding
                           + volumeBar.visualPosition * (volumeBar.availableWidth - width)
                        y: volumeBar.topPadding + volumeBar.availableHeight / 2 - height / 2
                        width: 10
                        height: 10
                        radius: 5
                        color: "#ffffff"
                    }
                }
            }

            // 传输控制：后退 10 秒 / 播放暂停 / 前进 10 秒
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6

                ToolButton {
                    id: rewindBtn
                    width: 32
                    height: 40
                    hoverEnabled: true
                    onClicked: mpv.seekRelative(-10)
                    background: null

                    Rectangle {
                        anchors.centerIn: parent
                        width: 30
                        height: 30
                        radius: 15
                        color: rewindBtn.pressed ? controlBar.pressedBg
                             : rewindBtn.hovered ? controlBar.hoverBg
                             : "transparent"
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }

                    Canvas {
                        anchors.centerIn: parent
                        width: 17
                        height: 13
                        property color iconColor: controlBar.iconColor
                        onIconColorChanged: requestPaint()
                        Component.onCompleted: requestPaint()
                        onPaint: {
                            const ctx = getContext("2d")
                            ctx.reset()
                            ctx.fillStyle = iconColor
                            ctx.fillRect(0, 0, 2, 13)
                            ctx.beginPath()
                            ctx.moveTo(9, 0)
                            ctx.lineTo(9, 13)
                            ctx.lineTo(2.5, 6.5)
                            ctx.closePath()
                            ctx.fill()
                            ctx.beginPath()
                            ctx.moveTo(17, 0)
                            ctx.lineTo(17, 13)
                            ctx.lineTo(10.5, 6.5)
                            ctx.closePath()
                            ctx.fill()
                        }
                    }
                }

                ToolButton {
                    id: playBtn
                    width: 40
                    height: 40
                    hoverEnabled: true
                    onClicked: mpv.playPause()
                    background: null

                    Rectangle {
                        anchors.centerIn: parent
                        width: 36
                        height: 36
                        radius: 18
                        color: playBtn.pressed ? controlBar.pressedBg
                             : playBtn.hovered ? controlBar.hoverBg
                             : "transparent"
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }

                    // 单色三角 / 双竖条（非 emoji）
                    Text {
                        anchors.centerIn: parent
                        anchors.horizontalCenterOffset: 1
                        visible: mpv.paused
                        text: "▶"
                        color: controlBar.iconColor
                        font.pixelSize: 19
                    }
                    Row {
                        anchors.centerIn: parent
                        spacing: 4
                        visible: !mpv.paused
                        Repeater {
                            model: 2
                            Rectangle {
                                width: 4
                                height: 16
                                radius: 1
                                color: controlBar.iconColor
                            }
                        }
                    }
                }

                ToolButton {
                    id: forwardBtn
                    width: 32
                    height: 40
                    hoverEnabled: true
                    onClicked: mpv.seekRelative(10)
                    background: null

                    Rectangle {
                        anchors.centerIn: parent
                        width: 30
                        height: 30
                        radius: 15
                        color: forwardBtn.pressed ? controlBar.pressedBg
                             : forwardBtn.hovered ? controlBar.hoverBg
                             : "transparent"
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }

                    Canvas {
                        anchors.centerIn: parent
                        width: 17
                        height: 13
                        property color iconColor: controlBar.iconColor
                        onIconColorChanged: requestPaint()
                        Component.onCompleted: requestPaint()
                        onPaint: {
                            const ctx = getContext("2d")
                            ctx.reset()
                            ctx.fillStyle = iconColor
                            ctx.fillRect(15, 0, 2, 13)
                            ctx.beginPath()
                            ctx.moveTo(8, 0)
                            ctx.lineTo(8, 13)
                            ctx.lineTo(14.5, 6.5)
                            ctx.closePath()
                            ctx.fill()
                            ctx.beginPath()
                            ctx.moveTo(0, 0)
                            ctx.lineTo(0, 13)
                            ctx.lineTo(6.5, 6.5)
                            ctx.closePath()
                            ctx.fill()
                        }
                    }
                }
            }

            // 右侧：字幕 / 流健康 / 全屏
            Row {
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                ToolButton {
                    id: ccBtn
                    width: 30
                    height: 30
                    visible: controlBar.width >= 360
                    hoverEnabled: true
                    // 始终保持可点击：禁用会让事件穿透到视频区，误触发播放/暂停
                    property bool hasSubtitles: mpv.subtitleTracks.length > 0
                    onClicked: {
                        if (hasSubtitles)
                            mpv.toggleSubtitles()
                        else
                            subtitleDialog.open()
                    }

                    background: null

                    Rectangle {
                        anchors.centerIn: parent
                        width: 28
                        height: 28
                        radius: 14
                        color: ccBtn.pressed ? controlBar.pressedBg
                             : ccBtn.hovered ? controlBar.hoverBg
                             : "transparent"
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }

                    Text {
                        anchors.centerIn: parent
                        text: "CC"
                        font.pixelSize: 10
                        font.bold: true
                        color: !ccBtn.hasSubtitles ? controlBar.iconMuted
                             : (mpv.activeSubtitleId >= 0) ? skin.accent
                             : controlBar.iconColor
                    }
                }

                // 流健康：三格信号条，颜色反映当前卡顿程度；点击展开详细面板
                ToolButton {
                    id: statsBtn
                    width: 30
                    height: 30
                    visible: root.isNetworkStream && root.hasMedia
                    hoverEnabled: true
                    onClicked: root.statsOpen = !root.statsOpen

                    background: null

                    Rectangle {
                        anchors.centerIn: parent
                        width: 28
                        height: 28
                        radius: 14
                        color: statsBtn.pressed ? controlBar.pressedBg
                             : (statsBtn.hovered || root.statsOpen) ? controlBar.hoverBg
                             : "transparent"
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }

                    Row {
                        anchors.centerIn: parent
                        spacing: 2
                        Repeater {
                            model: 3
                            Item {
                                width: 2.5
                                height: 12
                                Rectangle {
                                    anchors.bottom: parent.bottom
                                    width: 2.5
                                    height: 5 + index * 3.5
                                    radius: 1.25
                                    color: root.healthColor
                                    opacity: root.streamHealth === 2 ? (index === 0 ? 1 : 0.22)
                                           : root.streamHealth === 1 ? (index < 2 ? 1 : 0.22)
                                           : 1
                                }
                            }
                        }
                    }
                }

                ToolButton {
                    id: fsBtn
                    width: 30
                    height: 30
                    hoverEnabled: true
                    onClicked: root.toggleFullscreen()

                    background: null

                    Rectangle {
                        anchors.centerIn: parent
                        width: 28
                        height: 28
                        radius: 14
                        color: fsBtn.pressed ? controlBar.pressedBg
                             : fsBtn.hovered ? controlBar.hoverBg
                             : "transparent"
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }

                    // 扁平全屏图标：四角括号
                    Canvas {
                        anchors.centerIn: parent
                        width: 14
                        height: 14
                        property color iconColor: controlBar.iconColor
                        onIconColorChanged: requestPaint()
                        Component.onCompleted: requestPaint()
                        onPaint: {
                            const ctx = getContext("2d")
                            ctx.reset()
                            ctx.strokeStyle = iconColor
                            ctx.lineWidth = 1.7
                            ctx.lineCap = "square"
                            const L = 4.8
                            ctx.beginPath()
                            ctx.moveTo(0, L)
                            ctx.lineTo(0, 0)
                            ctx.lineTo(L, 0)
                            ctx.moveTo(14 - L, 0)
                            ctx.lineTo(14, 0)
                            ctx.lineTo(14, L)
                            ctx.moveTo(14, 14 - L)
                            ctx.lineTo(14, 14)
                            ctx.lineTo(14 - L, 14)
                            ctx.moveTo(L, 14)
                            ctx.lineTo(0, 14)
                            ctx.lineTo(0, 14 - L)
                            ctx.stroke()
                        }
                    }
                }
            }
        }

        // ---- 第二行：时间 / 进度（含黄色缓冲段） ----
        RowLayout {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            anchors.bottomMargin: 9
            height: 18
            spacing: 8

            Label {
                Layout.preferredWidth: 54
                text: root.liveStream ? "● LIVE" : fmtTime(mpv.position)
                color: root.liveStream ? "#ff5f57" : controlBar.iconMuted
                font.pixelSize: 11
                // 系统字体（SF Pro）+ 等宽数字，与 QuickTime 的时间显示一致
                font.features: ({ "tnum": 1 })
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }

            Slider {
                id: seekBar
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                implicitHeight: 16
                from: 0
                to: Math.max(mpv.duration, 1)
                // 直播没有可拖动的时间轴，只作缓冲显示
                enabled: root.hasMedia && !root.liveStream
                property bool scrubbing: false
                onPressedChanged: {
                    if (pressed)
                        scrubbing = true
                    else {
                        mpv.seekTo(value)
                        scrubbing = false
                    }
                }

                background: Item {
                    x: seekBar.leftPadding
                    y: seekBar.topPadding + seekBar.availableHeight / 2 - height / 2
                    width: seekBar.availableWidth
                    height: 4

                    Rectangle {
                        anchors.fill: parent
                        radius: 2
                        color: controlBar.trackColor
                    }

                    // 网络流的缓冲段（黄色）
                    Rectangle {
                        visible: root.isNetworkStream && !root.liveStream
                                 && root.bufferEndFraction > root.bufferStartFraction
                        x: parent.width * root.bufferStartFraction
                        width: parent.width
                               * Math.max(0, root.bufferEndFraction - root.bufferStartFraction)
                        height: parent.height
                        radius: 2
                        color: "#f5c518"
                    }

                    // 已播放进度（本地 / 点播；直播不显示）
                    Rectangle {
                        visible: !root.liveStream
                        width: seekBar.visualPosition * parent.width
                        height: parent.height
                        radius: 2
                        color: "#ffffff"
                    }
                }

                handle: Rectangle {
                    visible: !root.liveStream
                    x: seekBar.leftPadding
                       + seekBar.visualPosition * (seekBar.availableWidth - width)
                    y: seekBar.topPadding + seekBar.availableHeight / 2 - height / 2
                    width: 10
                    height: 10
                    radius: 5
                    color: "#ffffff"
                }
            }

            Label {
                Layout.preferredWidth: 54
                horizontalAlignment: Text.AlignRight
                text: root.liveStream
                      ? (mpv.cacheDuration > 0 ? mpv.cacheDuration.toFixed(1) + "s" : "—")
                      : fmtTime(mpv.duration)
                color: controlBar.iconMuted
                font.pixelSize: 11
                font.features: ({ "tnum": 1 })
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
        }
    }

    // ---------- 流健康详情面板 ----------

    Rectangle {
        id: statsPanel
        visible: root.statsOpen && root.isNetworkStream && root.hasMedia
        anchors.right: controlBar.right
        anchors.bottom: controlBar.top
        anchors.bottomMargin: 8
        width: 244
        height: statsColumn.implicitHeight + 28
        radius: 12
        color: skin.panel
        border.width: 1
        border.color: skin.panelBorder

        ColumnLayout {
            id: statsColumn
            anchors.fill: parent
            anchors.margins: 14
            spacing: 7

            RowLayout {
                Layout.fillWidth: true
                Label {
                    text: qsTr("流状态")
                    color: skin.textMuted
                    font.pixelSize: 11
                }
                Item { Layout.fillWidth: true }
                Rectangle {
                    implicitWidth: 8
                    implicitHeight: 8
                    radius: 4
                    color: root.healthColor
                    Layout.alignment: Qt.AlignVCenter
                }
                Label {
                    text: root.healthLabel
                    color: root.healthColor
                    font.pixelSize: 12
                    font.bold: true
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 1
                color: skin.separator
            }

            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: 12
                rowSpacing: 6

                Label {
                    text: qsTr("缓冲")
                    color: skin.textMuted
                    font.pixelSize: 11
                }
                Label {
                    text: root.fmtCacheSeconds(mpv.cacheDuration)
                    color: skin.textPrimary
                    font.pixelSize: 12
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignRight
                }

                Label {
                    text: qsTr("下载")
                    color: skin.textMuted
                    font.pixelSize: 11
                }
                Label {
                    text: root.fmtSpeed(mpv.cacheSpeed)
                    color: skin.textPrimary
                    font.pixelSize: 12
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignRight
                }

                Label {
                    text: qsTr("码率")
                    color: skin.textMuted
                    font.pixelSize: 11
                }
                Label {
                    text: root.fmtBitrate(mpv.videoBitrate)
                    color: skin.textPrimary
                    font.pixelSize: 12
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignRight
                }

                Label {
                    text: qsTr("帧率")
                    color: skin.textMuted
                    font.pixelSize: 11
                }
                Label {
                    text: mpv.containerFps > 0 ? mpv.containerFps.toFixed(2) + " fps" : "—"
                    color: skin.textPrimary
                    font.pixelSize: 12
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignRight
                }

                Label {
                    text: qsTr("丢帧（渲染/解码）")
                    color: skin.textMuted
                    font.pixelSize: 11
                }
                Label {
                    text: mpv.frameDropCount + " / " + mpv.decoderFrameDropCount
                    color: mpv.frameDropCount > 0 ? root.healthColor : skin.textPrimary
                    font.pixelSize: 12
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignRight
                }

                Label {
                    text: qsTr("分辨率")
                    color: skin.textMuted
                    font.pixelSize: 11
                }
                Label {
                    text: mpv.videoWidth > 0 ? mpv.videoWidth + " × " + mpv.videoHeight : "—"
                    color: skin.textPrimary
                    font.pixelSize: 12
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignRight
                }
            }
        }
    }

    // mpv 属性 → 控件状态（避免与拖动状态打架）
    Connections {
        target: mpv
        function onPositionChanged() {
            if (root.liveStream) {
                // 直播流：进度条始终停在 0
                if (!seekBar.scrubbing)
                    seekBar.value = 0
            } else if (!seekBar.scrubbing) {
                seekBar.value = Math.min(mpv.position, seekBar.to)
            }
        }
        function onVolumeChanged() {
            if (!volumeBar.scrubbing)
                volumeBar.value = mpv.volume
        }
        function onPausedChanged() {
            if (!mpv.paused && root.hasMedia)
                hideControlsTimer.restart()
            else
                hideControlsTimer.stop()
        }
        function onFileError(reason) {
            toast.show(qsTr("播放失败：") + reason)
        }
    }

    // ---------- 文件 / URL ----------

    FileDialog {
        id: openDialog
        title: qsTr("打开媒体文件")
        nameFilters: [
            qsTr("常用媒体 (*.mp4 *.mkv *.mov *.avi *.flv *.wmv *.webm *.m4v *.ts *.m2ts *.rmvb *.ogv *.mp3 *.flac *.wav *.aac *.m4a *.opus)"),
            qsTr("所有文件 (*)")
        ]
        onAccepted: mpv.load(selectedFile)
    }

    FileDialog {
        id: subtitleDialog
        title: qsTr("加载字幕文件")
        nameFilters: [
            qsTr("字幕文件 (*.srt *.ass *.ssa *.vtt *.sub *.idx *.lrc)"),
            qsTr("所有文件 (*)")
        ]
        onAccepted: mpv.addSubtitle(selectedFile)
    }

    // 原生窗口（macOS 标准标题栏与左上角红黄绿按钮）
    Window {
        id: urlWindow
        title: qsTr("打开链接")
        flags: Qt.Window | Qt.WindowTitleHint | Qt.WindowCloseButtonHint
        width: 560
        height: 205
        minimumWidth: 480
        maximumWidth: 900
        maximumHeight: 205
        modality: Qt.ApplicationModal
        color: skin.panel

        Shortcut {
            sequence: "Escape"
            onActivated: urlWindow.close()
        }

        function play() {
            const t = urlField.text.trim()
            if (t.length > 0)
                mpv.load(t)
            close()
        }

        onVisibleChanged: {
            if (visible) {
                urlField.selectAll()
                urlField.forceActiveFocus()
                MacWindow.lockWindow(urlWindow)
            }
        }
        Component.onCompleted: MacWindow.lockWindow(urlWindow)

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 20
            spacing: 12

            Label {
                Layout.fillWidth: true
                text: qsTr("输入媒体地址，支持 MP4 直链、HLS（m3u8）点播与直播流。")
                color: skin.textMuted
                font.pixelSize: 11
                wrapMode: Text.WordWrap
            }

            TextField {
                id: urlField
                Layout.fillWidth: true
                Layout.topMargin: 2
                Layout.preferredHeight: 30
                font.pixelSize: 13
                color: skin.textPrimary
                placeholderTextColor: skin.textFaint
                placeholderText: "https://example.com/video.mp4"
                selectByMouse: true
                leftPadding: 10
                rightPadding: 10
                background: Rectangle {
                    radius: 6
                    color: skin.controlBg
                    border.width: 1
                    border.color: urlField.activeFocus ? skin.accent : skin.controlBorder
                }
                onAccepted: urlWindow.play()
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 2

                Item { Layout.fillWidth: true }

                Button {
                    id: urlCancelBtn
                    text: qsTr("取消")
                    font.pixelSize: 13
                    implicitWidth: 76
                    implicitHeight: 28
                    onClicked: urlWindow.close()

                    background: Rectangle {
                        radius: 6
                        color: urlCancelBtn.pressed ? skin.hoverStrong
                             : urlCancelBtn.hovered ? skin.hoverLight
                             : skin.controlBg
                        border.width: 1
                        border.color: skin.controlBorder
                    }
                    contentItem: Text {
                        text: urlCancelBtn.text
                        font: urlCancelBtn.font
                        color: skin.textPrimary
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Button {
                    id: urlOpenBtn
                    text: qsTr("打开")
                    font.pixelSize: 13
                    implicitWidth: 76
                    implicitHeight: 28
                    onClicked: urlWindow.play()

                    background: Rectangle {
                        radius: 6
                        color: urlOpenBtn.pressed ? Qt.darker(skin.accent, 1.15)
                             : urlOpenBtn.hovered ? Qt.lighter(skin.accent, 1.08)
                             : skin.accent
                    }
                    contentItem: Text {
                        text: urlOpenBtn.text
                        font: urlOpenBtn.font
                        color: "#ffffff"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }

    // ---------- 打开流媒体（AceStream） ----------

    Window {
        id: streamWindow
        title: qsTr("打开流媒体")
        flags: Qt.Window | Qt.WindowTitleHint | Qt.WindowCloseButtonHint
        width: 660
        height: 240
        modality: Qt.ApplicationModal
        color: skin.panel

        property string statusText: ""
        property bool statusIsError: false
        /// 正在解析地址（防止重复点击「开始播放」）
        property bool busy: false
        /// 历史记录下拉弹层
        property bool historyOpen: false
        /// 待保存的原始输入（解析成功后写入历史）
        property string pendingInput: ""

        Shortcut {
            sequence: "Escape"
            onActivated: streamWindow.close()
        }

        /// 把一条输入加入历史（去重，最多保留 8 条，最近在前）
        function pushHistory(entry) {
            const t = (entry || "").trim()
            if (!t)
                return
            const MAX = 8
            const list = appSettings.recentStreams || []
            const filtered = list.filter(function(s) { return s.trim() !== t })
            filtered.unshift(t)
            if (filtered.length > MAX)
                filtered.length = MAX
            appSettings.recentStreams = filtered
        }

        function play() {
            if (busy)
                return
            const t = streamField.text.trim()
            if (t.length === 0)
                return
            pendingInput = t
            busy = true
            statusIsError = false
            statusText = qsTr("正在解析流媒体地址…")
            AceStream.resolve(t)
        }

        onVisibleChanged: {
            if (visible) {
                busy = false
                historyOpen = false
                pendingInput = ""
                statusText = ""
                statusIsError = false
                // 默认不自动聚焦输入框，让光标停在窗口层级；
                // 点击空白处也会自然让输入框失焦，历史列表随之收起
                MacWindow.lockWindow(streamWindow)
            }
        }
        Component.onCompleted: MacWindow.lockWindow(streamWindow)

        // 最底层空白点击捕获器：点击 Label / 间距 / 空白区时让 TextField 失焦
        // 放在 ColumnLayout 之前（z-order 更低），后面的 ColumnLayout 自然在它上面
        MouseArea {
            anchors.fill: parent
            onClicked: streamField.focus = false
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 20
            spacing: 10

            Label {
                Layout.fillWidth: true
                text: qsTr("支持 AceStream 频道页（如 acestreamid.com/channel/）、acestream:// 链接或 40 位 Content ID。本机没有引擎时会自动启动，无需手动操作。")
                color: skin.textMuted
                font.pixelSize: 11
                wrapMode: Text.WordWrap
            }

            Item {
                id: streamInputRow
                Layout.fillWidth: true
                Layout.topMargin: 2
                Layout.preferredHeight: 30

                TextField {
                    id: streamField
                    anchors.fill: parent
                    font.pixelSize: 13
                    color: skin.textPrimary
                    placeholderTextColor: skin.textFaint
                    placeholderText: "https://acestreamid.com/channel/"
                    selectByMouse: true
                    enabled: !streamWindow.busy
                    leftPadding: 10
                    rightPadding: 10
                    background: Rectangle {
                        radius: 6
                        color: skin.controlBg
                        border.width: 1
                        border.color: streamField.activeFocus ? skin.accent : skin.controlBorder
                    }
                    onAccepted: streamWindow.play()
                    // 光标进入输入框时自动展开历史，失焦收起
                    onActiveFocusChanged: {
                        if (!activeFocus) {
                            Qt.callLater(function() {
                                if (!streamField.activeFocus)
                                    streamWindow.historyOpen = false
                            })
                        } else {
                            streamWindow.historyOpen = !!(appSettings.recentStreams
                                    && appSettings.recentStreams.length > 0)
                        }
                    }
                }
            }

            Label {
                Layout.fillWidth: true
                Layout.preferredHeight: 16
                text: streamWindow.statusText
                color: streamWindow.statusIsError ? "#ff6b6b" : skin.textMuted
                font.pixelSize: 11
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
            }

            RowLayout {
                Layout.fillWidth: true

                Item { Layout.fillWidth: true }

                Button {
                    id: streamCancelBtn
                    text: qsTr("取消")
                    font.pixelSize: 13
                    implicitWidth: 76
                    implicitHeight: 28
                    onClicked: streamWindow.close()

                    background: Rectangle {
                        radius: 6
                        color: streamCancelBtn.pressed ? skin.hoverStrong
                             : streamCancelBtn.hovered ? skin.hoverLight
                             : skin.controlBg
                        border.width: 1
                        border.color: skin.controlBorder
                    }
                    contentItem: Text {
                        text: streamCancelBtn.text
                        font: streamCancelBtn.font
                        color: skin.textPrimary
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Button {
                    id: streamPlayBtn
                    text: qsTr("开始播放")
                    font.pixelSize: 13
                    implicitWidth: 76
                    implicitHeight: 28
                    enabled: !streamWindow.busy && streamField.text.trim().length > 0
                    onClicked: streamWindow.play()

                    background: Rectangle {
                        radius: 6
                        color: !streamPlayBtn.enabled ? skin.controlBorder
                             : streamPlayBtn.pressed ? Qt.darker(skin.accent, 1.15)
                             : streamPlayBtn.hovered ? Qt.lighter(skin.accent, 1.08)
                             : skin.accent
                    }
                    contentItem: Text {
                        text: streamPlayBtn.text
                        font: streamPlayBtn.font
                        color: streamPlayBtn.enabled ? "#ffffff" : skin.textFaint
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }

        // 历史记录弹层（放在 ColumnLayout 外，作为 Window 直接子项）
        Popup {
            id: historyPopup
            padding: 0
            closePolicy: Popup.CloseOnEscape
            visible: streamWindow.historyOpen && (appSettings.recentStreams || []).length > 0
            onVisibleChanged: {
                streamWindow.historyOpen = visible
                if (visible) {
                    // Popup 定位：锚定到 streamInputRow 正下方
                    const p = streamInputRow.mapToItem(streamWindow.contentItem, 0, streamInputRow.height + 4)
                    x = p.x
                    y = p.y
                    width = streamInputRow.width
                }
            }

            background: Rectangle {
                color: skin.popupBg
                radius: 8
                border.color: skin.controlBorder
                border.width: 1
            }

            contentItem: Column {
                Repeater {
                    model: appSettings.recentStreams || []

                    Rectangle {
                        width: historyPopup.width - 4
                        height: 28
                        radius: 4
                        color: ma.containsMouse
                               ? Qt.rgba(skin.accent.r, skin.accent.g, skin.accent.b, 0.18)
                               : "transparent"

                        Text {
                            text: modelData
                            font.pixelSize: 12
                            color: skin.textPrimary
                            leftPadding: 10
                            rightPadding: 8
                            elide: Text.ElideRight
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                        }

                        MouseArea {
                            id: ma
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                streamField.text = modelData
                                streamWindow.historyOpen = false
                                streamField.forceActiveFocus()
                                streamField.selectAll()
                            }
                        }
                    }
                }
            }
        }
    }

    // AceStream 解析结果
    Connections {
        target: AceStream
        function onResolved(playbackUrl) {
            streamWindow.busy = false
            streamWindow.statusText = ""
            streamWindow.pushHistory(streamWindow.pendingInput)
            mpv.load(playbackUrl)
            streamWindow.close()
            toast.show(qsTr("正在连接 AceStream 流…"))
        }
        function onFailed(message) {
            streamWindow.busy = false
            streamWindow.statusIsError = true
            streamWindow.statusText = message
        }
        function onProgress(message) {
            streamWindow.statusIsError = false
            streamWindow.statusText = message
        }
    }

    // ---------- 设置 ----------

    // 原生窗口（macOS 标准标题栏与左上角红黄绿按钮）
    Window {
        id: settingsWindow
        // 标题跟随当前分页，与 macOS 偏好设置一致
        title: tab === 0 ? qsTr("通用") : "Docker"
        // 只保留关闭按钮（无最小化 / 缩放）
        flags: Qt.Window | Qt.WindowTitleHint | Qt.WindowCloseButtonHint
        width: 560
        height: 640
        minimumWidth: 520
        minimumHeight: 470
        modality: Qt.ApplicationModal
        color: skin.panel

        /// 0 = 通用，1 = Docker
        property int tab: 0
        readonly property var cacheValues: [5, 10, 30, 60]
        /// 内容列宽度：仿 macOS 偏好设置，居中且不铺满整窗
        readonly property int contentWidth: Math.min(420, width - 72)
        /// 左侧标签列宽（右对齐）
        readonly property int labelWidth: 88

        onVisibleChanged: {
            if (visible) {
                syncControls()
                MacWindow.lockWindow(settingsWindow)
                if (tab === 1)
                    AceStream.refreshDockerInfo()
            }
        }
        Component.onCompleted: MacWindow.lockWindow(settingsWindow)

        function switchTab(index) {
            tab = index
            if (index === 1)
                AceStream.refreshDockerInfo()
        }

        /** 打开时把持久化设置同步到各控件（避免双向绑定被用户操作打断） */
        function syncControls() {
            const appearanceValues = ["system", "light", "dark"]
            appearanceCombo.currentIndex =
                Math.max(0, appearanceValues.indexOf(appSettings.appearance))
            languageCombo.currentIndex = Math.max(0, root.languageCodes.indexOf(App.language))
            hwdecCheck.checked = appSettings.hardwareDecoding
            loopCheck.checked = appSettings.loopPlayback
            cacheCombo.currentIndex = Math.max(0, cacheValues.indexOf(appSettings.networkCacheSecs))
            delaySlider.value = appSettings.hideControlsDelay / 1000
            socketField.text = appSettings.dockerSocketPath
            stopColimaCheck.checked = appSettings.stopColimaOnQuit
            autoCheckUpdateCheck.checked = appSettings.autoCheckUpdate
        }

        function resetToDefaults() {
            appSettings.appearance = "system"
            appSettings.hardwareDecoding = true
            appSettings.loopPlayback = false
            appSettings.networkCacheSecs = 10
            appSettings.hideControlsDelay = 2600
            appSettings.dockerSocketPath = ""
            appSettings.stopColimaOnQuit = true
            appSettings.autoCheckUpdate = true
            AceStream.setDockerSocketPath("")
            AceStream.setStopColimaOnQuit(true)
            root.applySettings()
            syncControls()
        }

        Shortcut {
            sequence: "Escape"
            onActivated: settingsWindow.close()
        }

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            // ---- 分页标签（图标 + 文字，仿 macOS 偏好设置） ----
            Row {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 12
                Layout.bottomMargin: 12
                spacing: 10

                Repeater {
                    model: [
                        { title: qsTr("通用"), kind: 0 },
                        { title: "Docker", kind: 1 }
                    ]
                    delegate: Item {
                        width: 84
                        height: 58

                        Rectangle {
                            anchors.fill: parent
                            radius: 9
                            color: settingsWindow.tab === index ? skin.controlBg : "transparent"
                            border.width: settingsWindow.tab === index ? 1 : 0
                            border.color: skin.controlBorder
                        }

                        Column {
                            anchors.centerIn: parent
                            spacing: 4

                            Canvas {
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: 22
                                height: 22
                                property int kind: modelData.kind
                                property color iconColor: settingsWindow.tab === index
                                                       ? skin.accent : skin.textMuted
                                onIconColorChanged: requestPaint()
                                Component.onCompleted: requestPaint()

                                onPaint: {
                                    const ctx = getContext("2d")
                                    ctx.reset()
                                    ctx.strokeStyle = iconColor
                                    ctx.lineWidth = 1.5
                                    ctx.lineCap = "round"
                                    ctx.lineJoin = "round"
                                    const cx = 11
                                    const cy = 11

                                    if (kind === 0) {
                                        // 齿轮：一圈短齿 + 内外圆
                                        for (let i = 0; i < 8; ++i) {
                                            const a = i * Math.PI / 4
                                            ctx.beginPath()
                                            ctx.moveTo(cx + Math.cos(a) * 7,
                                                       cy + Math.sin(a) * 7)
                                            ctx.lineTo(cx + Math.cos(a) * 9.5,
                                                       cy + Math.sin(a) * 9.5)
                                            ctx.stroke()
                                        }
                                        ctx.beginPath()
                                        ctx.arc(cx, cy, 6.2, 0, Math.PI * 2)
                                        ctx.stroke()
                                        ctx.beginPath()
                                        ctx.arc(cx, cy, 2.4, 0, Math.PI * 2)
                                        ctx.stroke()
                                    } else {
                                        // 容器 / 包裹（立方体）
                                        ctx.beginPath()
                                        ctx.moveTo(11, 2.5)
                                        ctx.lineTo(18, 6.2)
                                        ctx.lineTo(11, 9.9)
                                        ctx.lineTo(4, 6.2)
                                        ctx.closePath()
                                        ctx.stroke()
                                        ctx.beginPath()
                                        ctx.moveTo(4, 6.2)
                                        ctx.lineTo(4, 14.5)
                                        ctx.lineTo(11, 18.2)
                                        ctx.lineTo(18, 14.5)
                                        ctx.lineTo(18, 6.2)
                                        ctx.stroke()
                                        ctx.beginPath()
                                        ctx.moveTo(11, 9.9)
                                        ctx.lineTo(11, 18.2)
                                        ctx.stroke()
                                    }
                                }
                            }

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: modelData.title
                                font.pixelSize: 11
                                font.bold: settingsWindow.tab === index
                                color: settingsWindow.tab === index ? skin.textPrimary
                                     : skin.textMuted
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: settingsWindow.switchTab(index)
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 1
                color: skin.separator
            }

            // ---- 内容（超出高度时滚动） ----
            ScrollView {
                id: settingsScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                Item {
                    width: settingsScroll.availableWidth
                    height: contentColumn.implicitHeight

                    ColumnLayout {
                        id: contentColumn
                        width: settingsWindow.contentWidth
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 0

                    // ==== 通用分页 ====
                    ColumnLayout {
                        visible: settingsWindow.tab === 0
                        Layout.fillWidth: true
                        spacing: 0

                        // ---- 外观 ----
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 18
                            spacing: 12

                            Label {
                                Layout.preferredWidth: settingsWindow.labelWidth
                                horizontalAlignment: Text.AlignRight
                                text: qsTr("外观")
                                color: skin.textSecondary
                                font.pixelSize: 12
                            }

                            CompactComboBox {
                                id: appearanceCombo
                                Layout.preferredWidth: 132
                                bgColor: skin.controlBg
                                borderColor: skin.controlBorder
                                textColor: skin.textPrimary
                                popupColor: skin.popupBg
                                accentColor: skin.accent
                                model: [qsTr("跟随系统"), qsTr("浅色"), qsTr("深色")]
                                onActivated: (index) => {
                                    const values = ["system", "light", "dark"]
                                    appSettings.appearance = values[index]
                                }
                            }

                            Item { Layout.fillWidth: true }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 4
                            spacing: 0

                            Item { Layout.preferredWidth: settingsWindow.labelWidth + 12 }

                            Label {
                                Layout.fillWidth: true
                                text: qsTr("浅色 / 深色，或跟随系统外观")
                                color: skin.textFaint
                                font.pixelSize: 11
                                wrapMode: Text.WordWrap
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 12
                            spacing: 12

                            Label {
                                Layout.preferredWidth: settingsWindow.labelWidth
                                horizontalAlignment: Text.AlignRight
                                text: qsTr("语言")
                                color: skin.textSecondary
                                font.pixelSize: 12
                            }

                            CompactComboBox {
                                id: languageCombo
                                Layout.preferredWidth: 132
                                bgColor: skin.controlBg
                                borderColor: skin.controlBorder
                                textColor: skin.textPrimary
                                popupColor: skin.popupBg
                                accentColor: skin.accent
                                model: [qsTr("简体中文"), qsTr("繁體中文"), "English"]
                                onActivated: (index) => {
                                    App.setLanguage(root.languageCodes[index])
                                    // 原生菜单文案需要重建
                                    NativeMenu.install()
                                }
                            }

                            Item { Layout.fillWidth: true }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 4
                            spacing: 0

                            Item { Layout.preferredWidth: settingsWindow.labelWidth + 12 }

                            Label {
                                Layout.fillWidth: true
                                text: qsTr("界面语言，切换后立即生效")
                                color: skin.textFaint
                                font.pixelSize: 11
                                wrapMode: Text.WordWrap
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 1
                            color: skin.separator
                            Layout.topMargin: 16
                            Layout.bottomMargin: 16
                        }

                        // ---- 播放 ----
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 12

                            Label {
                                Layout.preferredWidth: settingsWindow.labelWidth
                                Layout.alignment: Qt.AlignTop
                                topPadding: 4
                                horizontalAlignment: Text.AlignRight
                                text: qsTr("播放")
                                color: skin.textSecondary
                                font.pixelSize: 12
                            }

                            ColumnLayout {
                                spacing: 4

                                MacCheckBox {
                                    id: hwdecCheck
                                    text: qsTr("硬件解码")
                                    accentColor: skin.accent
                                    borderColor: skin.textFaint
                                    textColor: skin.textPrimary
                                    onToggled: {
                                        appSettings.hardwareDecoding = checked
                                        mpv.hardwareDecoding = checked
                                        if (root.hasMedia)
                                            toast.show(qsTr("硬件解码将在下次打开视频时生效"))
                                    }
                                }

                                MacCheckBox {
                                    id: loopCheck
                                    text: qsTr("循环播放")
                                    accentColor: skin.accent
                                    borderColor: skin.textFaint
                                    textColor: skin.textPrimary
                                    onToggled: {
                                        appSettings.loopPlayback = checked
                                        mpv.loopPlayback = checked
                                    }
                                }
                            }

                            Item { Layout.fillWidth: true }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 4
                            spacing: 0

                            Item { Layout.preferredWidth: settingsWindow.labelWidth + 12 }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2

                                Label {
                                    text: qsTr("使用 VideoToolbox 硬解，降低 CPU 占用")
                                    color: skin.textFaint
                                    font.pixelSize: 11
                                }
                                Label {
                                    text: qsTr("单个视频播放结束后自动从头重播")
                                    color: skin.textFaint
                                    font.pixelSize: 11
                                }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 1
                            color: skin.separator
                            Layout.topMargin: 16
                            Layout.bottomMargin: 16
                        }

                        // ---- 网络 ----
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 12

                            Label {
                                Layout.preferredWidth: settingsWindow.labelWidth
                                horizontalAlignment: Text.AlignRight
                                text: qsTr("网络")
                                color: skin.textSecondary
                                font.pixelSize: 12
                            }

                            CompactComboBox {
                                id: cacheCombo
                                Layout.preferredWidth: 110
                                bgColor: skin.controlBg
                                borderColor: skin.controlBorder
                                textColor: skin.textPrimary
                                popupColor: skin.popupBg
                                accentColor: skin.accent
                                model: [qsTr("5 秒"), qsTr("10 秒"), qsTr("30 秒"), qsTr("60 秒")]
                                onActivated: (index) => {
                                    appSettings.networkCacheSecs = settingsWindow.cacheValues[index]
                                    mpv.networkCache = settingsWindow.cacheValues[index]
                                }
                            }

                            Item { Layout.fillWidth: true }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 4
                            spacing: 0

                            Item { Layout.preferredWidth: settingsWindow.labelWidth + 12 }

                            Label {
                                Layout.fillWidth: true
                                text: qsTr("缓冲越多抗卡顿越强，但起播更慢")
                                color: skin.textFaint
                                font.pixelSize: 11
                                wrapMode: Text.WordWrap
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 1
                            color: skin.separator
                            Layout.topMargin: 16
                            Layout.bottomMargin: 16
                        }

                        // ---- 控制栏 ----
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 12

                            Label {
                                Layout.preferredWidth: settingsWindow.labelWidth
                                horizontalAlignment: Text.AlignRight
                                text: qsTr("控制栏")
                                color: skin.textSecondary
                                font.pixelSize: 12
                            }

                            Slider {
                                id: delaySlider
                                Layout.preferredWidth: 150
                                Layout.preferredHeight: 20
                                Layout.alignment: Qt.AlignVCenter
                                from: 1
                                to: 8
                                stepSize: 0.5
                                onMoved: appSettings.hideControlsDelay = Math.round(value * 1000)

                                background: Rectangle {
                                    x: delaySlider.leftPadding
                                    y: delaySlider.topPadding + delaySlider.availableHeight / 2 - height / 2
                                    width: delaySlider.availableWidth
                                    height: 3
                                    radius: 1.5
                                    color: skin.track

                                    Rectangle {
                                        width: delaySlider.visualPosition * parent.width
                                        height: parent.height
                                        radius: 1.5
                                        color: skin.accent
                                    }
                                }

                                handle: Rectangle {
                                    x: delaySlider.leftPadding
                                       + delaySlider.visualPosition
                                         * (delaySlider.availableWidth - width)
                                    y: delaySlider.topPadding + delaySlider.availableHeight / 2 - height / 2
                                    width: 14
                                    height: 14
                                    radius: 7
                                    color: "#ffffff"
                                    border.width: 1
                                    border.color: skin.controlBorder
                                }
                            }

                            Label {
                                Layout.preferredWidth: 48
                                text: delaySlider.value.toFixed(1) + qsTr(" 秒")
                                color: skin.textMuted
                                font.pixelSize: 12
                            }

                            Item { Layout.fillWidth: true }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 4
                            spacing: 0

                            Item { Layout.preferredWidth: settingsWindow.labelWidth + 12 }

                            Label {
                                Layout.fillWidth: true
                                text: qsTr("播放时鼠标静止多久后隐藏控制栏")
                                color: skin.textFaint
                                font.pixelSize: 11
                                wrapMode: Text.WordWrap
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 1
                            color: skin.separator
                            Layout.topMargin: 16
                            Layout.bottomMargin: 16
                        }

                        // ---- 更新 ----
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 12

                            Label {
                                Layout.preferredWidth: settingsWindow.labelWidth
                                Layout.alignment: Qt.AlignTop
                                topPadding: 4
                                horizontalAlignment: Text.AlignRight
                                text: qsTr("更新")
                                color: skin.textSecondary
                                font.pixelSize: 12
                            }

                            ColumnLayout {
                                spacing: 4

                                MacCheckBox {
                                    id: autoCheckUpdateCheck
                                    text: qsTr("自动检查更新")
                                    accentColor: skin.accent
                                    borderColor: skin.textFaint
                                    textColor: skin.textPrimary
                                    onToggled: {
                                        appSettings.autoCheckUpdate = checked
                                    }
                                }
                            }

                            Item { Layout.fillWidth: true }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 4
                            spacing: 0

                            Item { Layout.preferredWidth: settingsWindow.labelWidth + 12 }

                            Label {
                                Layout.fillWidth: true
                                text: qsTr("启动后在后台自动检查新版本，发现更新会在菜单栏提示你")
                                color: skin.textFaint
                                font.pixelSize: 11
                                wrapMode: Text.WordWrap
                            }
                        }

                        // ---- 恢复默认 ----
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 22
                            Layout.bottomMargin: 24
                            spacing: 0

                            Item { Layout.preferredWidth: settingsWindow.labelWidth + 12 }

                            Text {
                                text: qsTr("恢复默认")
                                color: skin.accent
                                font.pixelSize: 12

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: settingsWindow.resetToDefaults()
                                }
                            }

                            Item { Layout.fillWidth: true }
                        }
                    }

                    // ==== Docker 分页 ====
                    ColumnLayout {
                        visible: settingsWindow.tab === 1
                        Layout.fillWidth: true
                        spacing: 0

                        // ---- 状态 ----
                        GridLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 18
                            columns: 2
                            columnSpacing: 12
                            rowSpacing: 9

                            Label {
                                Layout.preferredWidth: settingsWindow.labelWidth
                                horizontalAlignment: Text.AlignRight
                                text: qsTr("连接状态")
                                color: skin.textSecondary
                                font.pixelSize: 12
                            }
                            Label {
                                Layout.fillWidth: true
                                font.pixelSize: 12
                                text: "● " + (AceStream.checking ? qsTr("正在检测…")
                                      : AceStream.dockerConnected ? qsTr("已连接")
                                      : qsTr("未连接"))
                                color: AceStream.checking ? skin.textFaint
                                     : AceStream.dockerConnected ? "#32c759"
                                     : "#ff5f57"
                            }

                            Label {
                                Layout.preferredWidth: settingsWindow.labelWidth
                                horizontalAlignment: Text.AlignRight
                                text: "Socket"
                                color: skin.textSecondary
                                font.pixelSize: 12
                            }
                            Label {
                                Layout.fillWidth: true
                                elide: Text.ElideMiddle
                                text: AceStream.dockerSocketPath.length > 0
                                      ? AceStream.dockerSocketPath : "—"
                                color: skin.textMuted
                                font.pixelSize: 11
                            }

                            Label {
                                Layout.preferredWidth: settingsWindow.labelWidth
                                horizontalAlignment: Text.AlignRight
                                text: qsTr("版本")
                                color: skin.textSecondary
                                font.pixelSize: 12
                            }
                            Label {
                                Layout.fillWidth: true
                                text: AceStream.dockerVersion.length > 0
                                      ? AceStream.dockerVersion : "—"
                                color: skin.textPrimary
                                font.pixelSize: 12
                            }

                            Label {
                                Layout.preferredWidth: settingsWindow.labelWidth
                                horizontalAlignment: Text.AlignRight
                                text: qsTr("镜像")
                                color: skin.textSecondary
                                font.pixelSize: 12
                            }
                            Label {
                                Layout.fillWidth: true
                                font.pixelSize: 12
                                text: "● " + (AceStream.imageState === "present" ? qsTr("已导入")
                                      : AceStream.imageState === "absent" ? qsTr("未导入")
                                      : AceStream.imageState === "unknown" ? qsTr("未知")
                                      : "—")
                                color: AceStream.imageState === "present" ? "#32c759"
                                     : skin.textFaint
                            }

                            Label {
                                Layout.preferredWidth: settingsWindow.labelWidth
                                horizontalAlignment: Text.AlignRight
                                text: qsTr("容器")
                                color: skin.textSecondary
                                font.pixelSize: 12
                            }
                            Label {
                                Layout.fillWidth: true
                                font.pixelSize: 12
                                text: "● " + (AceStream.containerState === "running" ? qsTr("运行中")
                                      : AceStream.containerState === "stopped" ? qsTr("已停止")
                                      : AceStream.containerState === "missing" ? qsTr("未创建")
                                      : AceStream.containerState === "unknown" ? qsTr("未知")
                                      : "—")
                                color: AceStream.containerState === "running" ? "#32c759"
                                     : AceStream.containerState === "stopped" ? "#f0b400"
                                     : skin.textFaint
                            }

                            Label {
                                Layout.preferredWidth: settingsWindow.labelWidth
                                horizontalAlignment: Text.AlignRight
                                text: qsTr("引擎")
                                color: skin.textSecondary
                                font.pixelSize: 12
                            }
                            Label {
                                Layout.fillWidth: true
                                font.pixelSize: 12
                                text: "● " + (AceStream.checking ? qsTr("正在检测…")
                                      : AceStream.engineReady ? qsTr("可用")
                                      : qsTr("不可用"))
                                color: AceStream.checking ? skin.textFaint
                                     : AceStream.engineReady ? "#32c759"
                                     : "#ff5f57"
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 8
                            spacing: 0

                            Item { Layout.preferredWidth: settingsWindow.labelWidth + 12 }

                            Label {
                                Layout.fillWidth: true
                                text: qsTr("镜像 %1 · 容器 %2 · 引擎 %3")
                                          .arg(AceStream.imageName)
                                          .arg(AceStream.containerName)
                                          .arg(AceStream.engineUrl)
                                color: skin.textFaint
                                font.pixelSize: 10
                                elide: Text.ElideRight
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 12
                            Layout.bottomMargin: 20
                            spacing: 0

                            Item { Layout.preferredWidth: settingsWindow.labelWidth + 12 }

                            Text {
                                text: qsTr("刷新状态")
                                color: AceStream.checking ? skin.textFaint : skin.accent
                                font.pixelSize: 12

                                MouseArea {
                                    anchors.fill: parent
                                    enabled: !AceStream.checking
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: AceStream.refreshDockerInfo()
                                }
                            }

                            Item { Layout.fillWidth: true }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 1
                            color: skin.separator
                            Layout.topMargin: 4
                            Layout.bottomMargin: 16
                        }

                        // ---- Socket ----
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 12

                            Label {
                                Layout.preferredWidth: settingsWindow.labelWidth
                                horizontalAlignment: Text.AlignRight
                                text: "Socket"
                                color: skin.textSecondary
                                font.pixelSize: 12
                            }

                            TextField {
                                id: socketField
                                Layout.fillWidth: true
                                Layout.preferredHeight: 28
                                font.pixelSize: 12
                                color: skin.textPrimary
                                placeholderTextColor: skin.textFaint
                                placeholderText: qsTr("留空则自动探测")
                                selectByMouse: true
                                leftPadding: 10
                                rightPadding: 10
                                background: Rectangle {
                                    radius: 6
                                    color: skin.controlBg
                                    border.width: 1
                                    border.color: socketField.activeFocus ? skin.accent
                                                 : skin.controlBorder
                                }
                                onEditingFinished: {
                                    appSettings.dockerSocketPath = text.trim()
                                    AceStream.setDockerSocketPath(text.trim())
                                    AceStream.refreshDockerInfo()
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 4
                            spacing: 0

                            Item { Layout.preferredWidth: settingsWindow.labelWidth + 12 }

                            Label {
                                Layout.fillWidth: true
                                text: qsTr("留空自动使用 colima / Docker Desktop 的默认位置，修改后回车生效")
                                color: skin.textFaint
                                font.pixelSize: 11
                                wrapMode: Text.WordWrap
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 1
                            color: skin.separator
                            Layout.topMargin: 16
                            Layout.bottomMargin: 16
                        }

                        // ---- 退出行为 ----
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 12

                            Item { Layout.preferredWidth: settingsWindow.labelWidth }

                            MacCheckBox {
                                id: stopColimaCheck
                                text: qsTr("退出时关闭 colima")
                                accentColor: skin.accent
                                borderColor: skin.textFaint
                                textColor: skin.textPrimary
                                onToggled: {
                                    appSettings.stopColimaOnQuit = checked
                                    AceStream.setStopColimaOnQuit(checked)
                                }
                            }

                            Item { Layout.fillWidth: true }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 4
                            Layout.bottomMargin: 24
                            spacing: 0

                            Item { Layout.preferredWidth: settingsWindow.labelWidth + 12 }

                            Label {
                                Layout.fillWidth: true
                                text: qsTr("关闭后 colima 虚拟机不会驻留后台")
                                color: skin.textFaint
                                font.pixelSize: 11
                                wrapMode: Text.WordWrap
                            }
                        }
                    }
                    }
                }
            }

            // ---- 底部操作栏 ----
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 1
                color: skin.separator
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.topMargin: 10
                Layout.bottomMargin: 12
                spacing: 10

                // ? 打开帮助
                Item {
                    width: 26
                    height: 26

                    Rectangle {
                        anchors.fill: parent
                        radius: 13
                        color: "transparent"
                        border.width: 1
                        border.color: skin.controlBorder
                    }

                    Text {
                        anchors.centerIn: parent
                        text: "?"
                        color: skin.textMuted
                        font.pixelSize: 13
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: openHelpDialog()
                    }
                }

                Item { Layout.fillWidth: true }

                Button {
                    id: doneBtn
                    text: qsTr("完成")
                    font.pixelSize: 13
                    implicitWidth: 76
                    implicitHeight: 28
                    onClicked: settingsWindow.close()

                    background: Rectangle {
                        radius: 6
                        color: doneBtn.pressed ? Qt.darker(skin.accent, 1.15)
                             : doneBtn.hovered ? Qt.lighter(skin.accent, 1.08)
                             : skin.accent
                    }

                    contentItem: Text {
                        text: doneBtn.text
                        font: doneBtn.font
                        color: "#ffffff"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }

    // ---------- Toast ----------

    Popup {
        id: toast
        property string msg: ""
        x: (parent.width - implicitWidth) / 2
        y: 16
        padding: 10
        background: Rectangle {
            color: skin.toastBg
            radius: 8
            border.color: skin.toastBorder
            border.width: 1
        }
        contentItem: Label {
            text: toast.msg
            color: skin.textPrimary
            font.pixelSize: 12
        }
        onAboutToShow: hideTimer.restart()

        Timer {
            id: hideTimer
            interval: 3200
            onTriggered: toast.close()
        }

        function show(message) {
            msg = message
            open()
        }
    }

    // ---------- 帮助文档 ----------

    Window {
        id: helpWindow
        title: qsTr("%1 帮助").arg(root.appName)
        flags: Qt.Window | Qt.WindowTitleHint | Qt.WindowCloseButtonHint
        width: 620
        height: 600
        minimumWidth: 460
        minimumHeight: 320
        modality: Qt.ApplicationModal
        color: skin.panel

        Shortcut {
            sequence: "Escape"
            onActivated: helpWindow.close()
        }
        onVisibleChanged: if (visible) MacWindow.lockWindow(helpWindow)
        Component.onCompleted: MacWindow.lockWindow(helpWindow)

        Flickable {
            id: helpFlick
            anchors.fill: parent
            anchors.margins: 20
            clip: true
            contentWidth: width

            TextArea.flickable: TextArea {
                readOnly: true
                wrapMode: TextArea.Wrap
                textFormat: Text.RichText
                color: skin.bodyText
                font.pixelSize: 13
                selectionColor: "#3d9bff"
                text: qsTr("
<h3>打开视频</h3>
<p>三种方式任选：</p>
<p>• 菜单 <b>文件 → 打开文件…</b>（⌘O），或在未播放时点击窗口中央的播放按钮<br/>
• 菜单 <b>文件 → 打开链接…</b>（⌘L），粘贴直链：MP4 / m3u8(HLS) / 直播流<br/>
• 直接把视频文件拖进窗口</p>

<h3>播放控制</h3>
<p>• 空格 —— 播放 / 暂停（也可以单击画面）<br/>
• ← / → —— 后退 / 前进 10 秒<br/>
• ↑ / ↓ —— 音量 ±5<br/>
• 拖动底部进度条跳转，右侧显示剩余时间</p>

<h3>画面与窗口</h3>
<p>• F 或双击画面 —— 进入 / 退出全屏<br/>
• Esc —— 退出全屏<br/>
• 播放中鼠标静止片刻，控制栏会自动隐藏，移动鼠标即可唤出</p>

<h3>支持格式</h3>
<p>• 本地：mp4 / mkv / mov / avi / flv / wmv / webm / m4v / ts 等，以及 mp3 / flac / wav 等音频<br/>
• 在线：http(s) 直链视频、HLS（m3u8）直播与点播</p>

<h3>设置</h3>
<p>菜单 <b>文件 → 设置…</b>（⌘,）可调整：外观（浅色 / 深色 / 跟随系统）、界面语言、硬件解码、循环播放、在线视频缓冲时长、控制栏自动隐藏延时。设置会自动保存，下次启动生效。</p>

<h3>小提示</h3>
<p>• 在线流加载需要短暂缓冲，网络较慢时请稍候<br/>
• 播放结束会停留在最后一帧，打开新视频即可继续</p>
")
            }

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        }
    }

    // ---------- 关于 ----------

    Window {
        id: aboutWindow
        title: qsTr("关于 %1").arg(root.appName)
        flags: Qt.Window | Qt.WindowTitleHint | Qt.WindowCloseButtonHint
        width: 400
        height: 420
        minimumWidth: 340
        minimumHeight: 380
        modality: Qt.ApplicationModal
        color: skin.panel

        Shortcut {
            sequence: "Escape"
            onActivated: aboutWindow.close()
        }
        onVisibleChanged: if (visible) MacWindow.lockWindow(aboutWindow)
        Component.onCompleted: MacWindow.lockWindow(aboutWindow)

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 20
            spacing: 4

            Image {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 2
                Layout.preferredWidth: 72
                Layout.preferredHeight: 72
                Layout.maximumWidth: 72
                Layout.maximumHeight: 72
                source: "qrc:/icons/logo.png"
                sourceSize: Qt.size(144, 144)
                fillMode: Image.PreserveAspectFit
                mipmap: true
                smooth: true
            }
            Label {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 6
                text: root.appName
                color: skin.textPrimary
                font.pixelSize: 18
                font.bold: true
            }
            Label {
                Layout.alignment: Qt.AlignHCenter
                text: qsTr("版本 ") + Qt.application.version
                color: skin.textMuted
                font.pixelSize: 11
            }
            Label {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 6
                text: qsTr("简洁的本地 & 在线视频播放器")
                color: skin.bodyText
                font.pixelSize: 12
            }
            Label {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 2
                text: "Qt " + qtVersion + " · mpv " + (mpv.mpvVersion.length > 0 ? mpv.mpvVersion : "libmpv")
                color: skin.textFaint
                font.pixelSize: 10
            }

            Item { Layout.fillHeight: true }  // 弹簧，把底部信息推到底

            // 底部联系信息 — inline 紧凑排版
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 4
                spacing: 10
                Text {
                    text: qsTr("作者 LevyQian")
                    color: skin.bodyText
                    font.pixelSize: 11
                }
                Text {
                    text: "qian.chenhao@icloud.com"
                    color: skin.accent
                    font.pixelSize: 11
                    MouseArea {
                        anchors.fill: parent
                        onClicked: Qt.openUrlExternally("mailto:qian.chenhao@icloud.com")
                    }
                }
            }
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "github.com/LevyQian/SimplePlayer"
                color: skin.accent
                font.pixelSize: 11
                MouseArea {
                    anchors.fill: parent
                    onClicked: Qt.openUrlExternally("https://github.com/LevyQian/SimplePlayer")
                }
            }
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 2
                Label {
                    text: qsTr("MIT License · © 2026")
                    color: skin.textFaint
                    font.pixelSize: 10
                }
                Text {
                    text: qsTr("查看协议")
                    color: skin.accent
                    font.pixelSize: 10
                    MouseArea {
                        anchors.fill: parent
                        onClicked: Qt.openUrlExternally("https://opensource.org/licenses/MIT")
                    }
                }
            }
        }
    }

    // ---------- 快捷键 ----------

    // 菜单项（原生菜单栏的 MenuItem 无 shortcut 属性，这里统一绑定）
    Shortcut {
        sequence: "Ctrl+O"
        onActivated: openDialog.open()
    }
    Shortcut {
        sequence: "Ctrl+L"
        onActivated: openUrlDialog()
    }
    Shortcut {
        sequence: "Ctrl+,"
        onActivated: openSettingsDialog()
    }
    Shortcut {
        sequence: "Ctrl+Q"
        onActivated: Qt.quit()
    }
    Shortcut {
        sequence: "Ctrl+/"
        onActivated: openHelpDialog()
    }

    Shortcut {
        sequence: "Space"
        onActivated: mpv.playPause()
    }
    Shortcut {
        sequence: "Left"
        onActivated: mpv.seekRelative(-10)
    }
    Shortcut {
        sequence: "Right"
        onActivated: mpv.seekRelative(10)
    }
    Shortcut {
        sequence: "Up"
        onActivated: mpv.volume = Math.min(100, mpv.volume + 5)
    }
    Shortcut {
        sequence: "Down"
        onActivated: mpv.volume = Math.max(0, mpv.volume - 5)
    }
    Shortcut {
        sequence: "Escape"
        onActivated: if (root.visibility === Window.FullScreen) root.showNormal()
    }
    Shortcut {
        sequence: "F"
        onActivated: root.toggleFullscreen()
    }
}
