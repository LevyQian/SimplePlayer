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
    minimumWidth: 720
    minimumHeight: 420
    color: skin.windowBg

    Universal.theme: skin.dark ? Universal.Dark : Universal.Light
    Universal.accent: "#3d9bff"
    Universal.foreground: skin.textPrimary

    title: mpv.mediaTitle.length > 0 ? (mpv.mediaTitle + " — SimplePlayer") : "SimplePlayer"

    // ---------- 状态 ----------

    readonly property bool hasMedia: mpv.duration > 0
    property bool controlsHovered: false
    readonly property bool controlsVisible:
        hasMedia && (mpv.paused || controlsHovered || hideControlsTimer.running)

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
        // 语言："zh_CN" | "en"
        property string language: "zh_CN"
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
    function openSettingsDialog() { showWindow(settingsWindow) }
    function openHelpDialog() { showWindow(helpWindow) }
    function openAboutDialog() { showWindow(aboutWindow) }

    function loadFromCli(url) {
        mpv.load(url.toString ? url.toString() : url)
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

    Component.onCompleted: {
        volumeBar.value = mpv.volume
        applySettings()
    }

    // ---------- 视频区 ----------

    MpvObject {
        id: mpv
        anchors.fill: parent
    }

    // 鼠标活动层：点击播放/暂停、双击全屏、移动唤出控制栏
    MouseArea {
        id: activityArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        onClicked: {
            if (root.hasMedia)
                mpv.playPause()
            else
                openDialog.open()
        }
        onDoubleClicked: root.toggleFullscreen()
        onPositionChanged: {
            if (root.hasMedia && !mpv.paused)
                hideControlsTimer.restart()
        }
    }

    DropArea {
        anchors.fill: parent
        onDropped: (drop) => {
            if (drop.urls && drop.urls.length > 0)
                mpv.load(drop.urls[0])
        }
    }

    // ---------- 空闲态（居中打开入口） ----------

    Item {
        anchors.centerIn: parent
        visible: !root.hasMedia
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
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 14
        height: 58
        radius: 14
        color: skin.barBg
        border.color: skin.barBorder
        border.width: 1
        opacity: root.controlsVisible ? 1 : 0
        visible: root.controlsVisible || opacity > 0.01
        enabled: root.controlsVisible

        Behavior on opacity {
            NumberAnimation { duration: 180 }
        }

        HoverHandler {
            onHoveredChanged: root.controlsHovered = hovered
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            spacing: 12

            ToolButton {
                id: playBtn
                Layout.preferredWidth: 40
                Layout.preferredHeight: 40
                Layout.alignment: Qt.AlignVCenter
                hoverEnabled: true
                onClicked: mpv.playPause()

                background: null

                // 悬停/按压：正圆高亮，居中于图标
                Rectangle {
                    anchors.centerIn: parent
                    width: 32
                    height: 32
                    radius: 16
                    color: playBtn.pressed ? skin.hoverStrong
                         : playBtn.hovered ? skin.hoverLight
                         : "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }
                }

                // 图标：单色三角 / 双竖条（非 emoji）
                Text {
                    anchors.centerIn: parent
                    anchors.horizontalCenterOffset: 1
                    visible: mpv.paused
                    text: "▶"
                    color: skin.textPrimary
                    font.pixelSize: 18
                }
                Row {
                    anchors.centerIn: parent
                    spacing: 3
                    visible: !mpv.paused
                    Repeater {
                        model: 2
                        Rectangle { width: 4; height: 16; radius: 1; color: skin.textPrimary }
                    }
                }
            }

            Label {
                Layout.preferredWidth: 92
                horizontalAlignment: Text.AlignRight
                text: fmtTime(mpv.position)
                color: skin.textMuted
                font.pixelSize: 11
                font.family: "Menlo"
            }

            Slider {
                id: seekBar
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                from: 0
                to: Math.max(mpv.duration, 1)
                implicitHeight: 26
                enabled: root.hasMedia
                property bool scrubbing: false
                onPressedChanged: {
                    if (pressed)
                        scrubbing = true
                    else {
                        mpv.seekTo(value)
                        scrubbing = false
                    }
                }

                background: Rectangle {
                    x: seekBar.leftPadding
                    y: seekBar.topPadding + seekBar.availableHeight / 2 - height / 2
                    width: seekBar.availableWidth
                    height: 4
                    radius: 2
                    color: skin.track

                    Rectangle {
                        width: seekBar.visualPosition * parent.width
                        height: parent.height
                        radius: 2
                        color: root.hasMedia ? skin.textPrimary : skin.track
                    }
                }

                handle: Rectangle {
                    x: seekBar.leftPadding
                         + seekBar.visualPosition * (seekBar.availableWidth - width)
                    y: seekBar.topPadding + seekBar.availableHeight / 2 - height / 2
                    width: 12
                    height: 12
                    radius: 6
                    color: skin.handle
                }
            }

            Label {
                Layout.preferredWidth: 92
                horizontalAlignment: Text.AlignLeft
                text: "−" + fmtTime(Math.max(mpv.duration - mpv.position, 0))
                color: skin.textMuted
                font.pixelSize: 11
                font.family: "Menlo"
            }

            // 扁平音量图标（Canvas 单色矢量绘制，静音时显示斜杠）
            Canvas {
                id: volCanvas
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: 18
                Layout.preferredHeight: 16
                property bool muted: mpv.volume === 0
                onMutedChanged: requestPaint()
                // 皮肤切换时重绘（Canvas 不随属性绑定自动刷新）
                property color iconColor: skin.textMuted
                onIconColorChanged: requestPaint()
                Component.onCompleted: requestPaint()

                onPaint: {
                    const ctx = getContext("2d")
                    ctx.reset()
                    ctx.fillStyle = iconColor
                    ctx.beginPath()
                    ctx.moveTo(1, 6)
                    ctx.lineTo(5, 6)
                    ctx.lineTo(9, 2.5)
                    ctx.lineTo(9, 13.5)
                    ctx.lineTo(5, 10)
                    ctx.lineTo(1, 10)
                    ctx.closePath()
                    ctx.fill()
                    ctx.strokeStyle = iconColor
                    ctx.lineWidth = 1.5
                    ctx.lineCap = "round"
                    if (!muted) {
                        ctx.beginPath()
                        ctx.arc(9.5, 8, 3, -Math.PI / 3.2, Math.PI / 3.2)
                        ctx.stroke()
                        ctx.beginPath()
                        ctx.arc(9.5, 8, 6, -Math.PI / 3.2, Math.PI / 3.2)
                        ctx.stroke()
                    } else {
                        ctx.beginPath()
                        ctx.moveTo(12, 6)
                        ctx.lineTo(17, 10)
                        ctx.moveTo(17, 6)
                        ctx.lineTo(12, 10)
                        ctx.stroke()
                    }
                }
            }

            Slider {
                id: volumeBar
                Layout.preferredWidth: 84
                Layout.alignment: Qt.AlignVCenter
                from: 0
                to: 100
                stepSize: 1
                implicitHeight: 26
                property bool scrubbing: false
                onPressedChanged: {
                    if (pressed)
                        scrubbing = true
                    else
                        scrubbing = false
                }
                onMoved: if (scrubbing) mpv.volume = Math.round(value)

                background: Rectangle {
                    x: volumeBar.leftPadding
                    y: volumeBar.topPadding + volumeBar.availableHeight / 2 - height / 2
                    width: volumeBar.availableWidth
                    height: 4
                    radius: 2
                    color: skin.track

                    Rectangle {
                        width: volumeBar.visualPosition * parent.width
                        height: parent.height
                        radius: 2
                        color: skin.textPrimary
                    }
                }

                handle: Rectangle {
                    x: volumeBar.leftPadding
                         + volumeBar.visualPosition * (volumeBar.availableWidth - width)
                    y: volumeBar.topPadding + volumeBar.availableHeight / 2 - height / 2
                    width: 12
                    height: 12
                    radius: 6
                    color: skin.handle
                }
            }

            ToolButton {
                id: fsBtn
                Layout.preferredWidth: 40
                Layout.preferredHeight: 40
                Layout.alignment: Qt.AlignVCenter
                hoverEnabled: true
                onClicked: root.toggleFullscreen()

                background: null

                Rectangle {
                    anchors.centerIn: parent
                    width: 32
                    height: 32
                    radius: 16
                    color: fsBtn.pressed ? skin.hoverStrong
                         : fsBtn.hovered ? skin.hoverLight
                         : "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }
                }

                // 扁平全屏图标：四角括号
                Canvas {
                    anchors.centerIn: parent
                    width: 16
                    height: 16
                    property color iconColor: skin.textPrimary
                    onIconColorChanged: requestPaint()
                    Component.onCompleted: requestPaint()
                    onPaint: {
                        const ctx = getContext("2d")
                        ctx.reset()
                        ctx.strokeStyle = iconColor
                        ctx.lineWidth = 1.8
                        ctx.lineCap = "square"
                        const L = 5.5
                        ctx.beginPath()
                        ctx.moveTo(0, L)
                        ctx.lineTo(0, 0)
                        ctx.lineTo(L, 0)
                        ctx.moveTo(16 - L, 0)
                        ctx.lineTo(16, 0)
                        ctx.lineTo(16, L)
                        ctx.moveTo(16, 16 - L)
                        ctx.lineTo(16, 16)
                        ctx.lineTo(16 - L, 16)
                        ctx.moveTo(L, 16)
                        ctx.lineTo(0, 16)
                        ctx.lineTo(0, 16 - L)
                        ctx.stroke()
                    }
                }
            }
        }
    }

    // mpv 属性 → 控件状态（避免与拖动状态打架）
    Connections {
        target: mpv
        function onPositionChanged() {
            if (!seekBar.scrubbing)
                seekBar.value = Math.min(mpv.position, seekBar.to)
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

    // ---------- 设置 ----------

    // 原生窗口（macOS 标准标题栏与左上角红黄绿按钮）
    Window {
        id: settingsWindow
        title: qsTr("设置")
        // 只保留关闭按钮（无最小化 / 缩放）
        flags: Qt.Window | Qt.WindowTitleHint | Qt.WindowCloseButtonHint
        width: 540
        height: 620
        minimumWidth: 500
        minimumHeight: 380
        modality: Qt.ApplicationModal
        color: skin.panel

        onVisibleChanged: {
            if (visible) {
                syncControls()
                MacWindow.lockWindow(settingsWindow)
            }
        }
        Component.onCompleted: MacWindow.lockWindow(settingsWindow)

        /** 打开时把持久化设置同步到各控件（避免双向绑定被用户操作打断） */
        function syncControls() {
            const appearanceValues = ["system", "light", "dark"]
            appearanceCombo.currentIndex =
                Math.max(0, appearanceValues.indexOf(appSettings.appearance))
            languageCombo.currentIndex = appSettings.language === "en" ? 1 : 0
            hwdecSwitch.checked = appSettings.hardwareDecoding
            loopSwitch.checked = appSettings.loopPlayback
            cacheCombo.currentIndex = Math.max(0, cacheValues.indexOf(appSettings.networkCacheSecs))
            delaySlider.value = appSettings.hideControlsDelay / 1000
        }

        function resetToDefaults() {
            appSettings.appearance = "system"
            appSettings.hardwareDecoding = true
            appSettings.loopPlayback = false
            appSettings.networkCacheSecs = 10
            appSettings.hideControlsDelay = 2600
            root.applySettings()
            syncControls()
        }

        readonly property var cacheValues: [5, 10, 30, 60]

        Shortcut {
            sequence: "Escape"
            onActivated: settingsWindow.close()
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 20
            spacing: 0

            // ---- 内容（超出高度时滚动） ----
            ScrollView {
                id: settingsScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                ColumnLayout {
                    width: settingsScroll.availableWidth
                    spacing: 14

            // ---- 通用 ----
            Label {
                text: qsTr("通用")
                color: skin.textPrimary
                font.pixelSize: 13
                font.bold: true
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Label { text: qsTr("外观"); color: skin.textSecondary; font.pixelSize: 13 }
                    Label {
                        text: qsTr("浅色 / 深色，或跟随系统外观")
                        color: skin.textFaint
                        font.pixelSize: 11
                    }
                }

                CompactComboBox {
                    id: appearanceCombo
                    Layout.preferredWidth: 128
                    bgColor: skin.controlBg
                    borderColor: skin.controlBorder
                    textColor: skin.textPrimary
                    popupColor: skin.popupBg
                    model: [qsTr("跟随系统"), qsTr("浅色"), qsTr("深色")]
                    onActivated: (index) => {
                        const values = ["system", "light", "dark"]
                        appSettings.appearance = values[index]
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Label { text: qsTr("语言"); color: skin.textSecondary; font.pixelSize: 13 }
                    Label {
                        text: qsTr("界面语言，切换后立即生效")
                        color: skin.textFaint
                        font.pixelSize: 11
                    }
                }

                CompactComboBox {
                    id: languageCombo
                    Layout.preferredWidth: 128
                    bgColor: skin.controlBg
                    borderColor: skin.controlBorder
                    textColor: skin.textPrimary
                    popupColor: skin.popupBg
                    model: [qsTr("简体中文"), "English"]
                    onActivated: (index) => {
                        const code = index === 1 ? "en" : "zh_CN"
                        appSettings.language = code
                        App.setLanguage(code)
                        // 原生菜单文案需要重建
                        NativeMenu.install()
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: skin.separator
            }

            // ---- 播放 ----
            Label {
                text: qsTr("播放")
                color: skin.textPrimary
                font.pixelSize: 13
                font.bold: true
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Label { text: qsTr("硬件解码"); color: skin.textSecondary; font.pixelSize: 13 }
                    Label {
                        text: qsTr("使用 VideoToolbox 硬解，降低 CPU 占用")
                        color: skin.textFaint
                        font.pixelSize: 11
                    }
                }

                Switch {
                    id: hwdecSwitch
                    onToggled: {
                        appSettings.hardwareDecoding = checked
                        mpv.hardwareDecoding = checked
                        if (root.hasMedia)
                            toast.show(qsTr("硬件解码将在下次打开视频时生效"))
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Label { text: qsTr("循环播放"); color: skin.textSecondary; font.pixelSize: 13 }
                    Label {
                        text: qsTr("单个视频播放结束后自动从头重播")
                        color: skin.textFaint
                        font.pixelSize: 11
                    }
                }

                Switch {
                    id: loopSwitch
                    onToggled: {
                        appSettings.loopPlayback = checked
                        mpv.loopPlayback = checked
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: skin.separator
            }

            // ---- 网络 ----
            Label {
                text: qsTr("网络")
                color: skin.textPrimary
                font.pixelSize: 13
                font.bold: true
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Label { text: qsTr("在线视频缓冲"); color: skin.textSecondary; font.pixelSize: 13 }
                    Label {
                        text: qsTr("缓冲越多抗卡顿越强，但起播更慢")
                        color: skin.textFaint
                        font.pixelSize: 11
                    }
                }

                CompactComboBox {
                    id: cacheCombo
                    Layout.preferredWidth: 100
                    bgColor: skin.controlBg
                    borderColor: skin.controlBorder
                    textColor: skin.textPrimary
                    popupColor: skin.popupBg
                    model: [qsTr("5 秒"), qsTr("10 秒"), qsTr("30 秒"), qsTr("60 秒")]
                    onActivated: (index) => {
                        appSettings.networkCacheSecs = settingsWindow.cacheValues[index]
                        mpv.networkCache = settingsWindow.cacheValues[index]
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: skin.separator
            }

            // ---- 界面 ----
            Label {
                text: qsTr("界面")
                color: skin.textPrimary
                font.pixelSize: 13
                font.bold: true
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Label { text: qsTr("控制栏自动隐藏"); color: skin.textSecondary; font.pixelSize: 13 }
                    Label {
                        text: qsTr("播放时鼠标静止多久后隐藏控制栏")
                        color: skin.textFaint
                        font.pixelSize: 11
                    }
                }

                Slider {
                    id: delaySlider
                    Layout.preferredWidth: 120
                    from: 1
                    to: 8
                    stepSize: 0.5
                    onMoved: appSettings.hideControlsDelay = Math.round(value * 1000)
                }

                Label {
                    Layout.preferredWidth: 44
                    text: delaySlider.value.toFixed(1) + qsTr(" 秒")
                    color: skin.textMuted
                    font.pixelSize: 12
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 6

                Item { Layout.fillWidth: true }

                Button {
                    id: resetBtn
                    text: qsTr("恢复默认")
                    font.pixelSize: 13
                    implicitHeight: 28
                    leftPadding: 12
                    rightPadding: 12
                    onClicked: settingsWindow.resetToDefaults()

                    background: Rectangle {
                        radius: 6
                        color: resetBtn.pressed ? skin.hoverStrong
                             : resetBtn.hovered ? skin.hoverLight
                             : skin.controlBg
                        border.width: 1
                        border.color: skin.controlBorder
                    }
                    contentItem: Text {
                        text: resetBtn.text
                        font: resetBtn.font
                        color: skin.textPrimary
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
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
        title: qsTr("SimplePlayer 帮助")
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
        title: qsTr("关于 SimplePlayer")
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
            anchors.margins: 24
            spacing: 6

            Image {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 4
                // 布局内必须用 Layout.* 约束尺寸，直接写 width/height 会被忽略，
                // 图标会按原图 512px 撑满整页
                Layout.preferredWidth: 88
                Layout.preferredHeight: 88
                Layout.maximumWidth: 88
                Layout.maximumHeight: 88
                source: "qrc:/icons/logo.png"
                sourceSize: Qt.size(176, 176)
                fillMode: Image.PreserveAspectFit
                mipmap: true
                smooth: true
            }
            Label {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 10
                text: "SimplePlayer"
                color: skin.textPrimary
                font.pixelSize: 20
                font.bold: true
            }
            Label {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 2
                text: qsTr("版本 ") + Qt.application.version
                color: skin.textMuted
                font.pixelSize: 12
            }
            Label {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 14
                text: qsTr("简洁的本地 & 在线视频播放器")
                color: skin.bodyText
                font.pixelSize: 13
            }
            Label {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 6
                text: "Qt " + Qt.version + " · mpv " + (mpv.mpvVersion.length > 0 ? mpv.mpvVersion : "libmpv")
                color: skin.textFaint
                font.pixelSize: 11
            }
            Label {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 14
                text: qsTr("© 2026 SimplePlayer 项目")
                color: skin.textFaint
                font.pixelSize: 11
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
