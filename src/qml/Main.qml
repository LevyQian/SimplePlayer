import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Universal
import QtQuick.Layouts
import QtQuick.Dialogs
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
    color: "#101013"

    Universal.theme: Universal.Dark
    Universal.accent: "#3d9bff"
    Universal.foreground: "#e8e8ec"

    title: mpv.mediaTitle.length > 0 ? (mpv.mediaTitle + " — SimplePlayer") : "SimplePlayer"

    // ---------- 状态 ----------

    readonly property bool hasMedia: mpv.duration > 0
    property bool controlsHovered: false
    readonly property bool controlsVisible:
        hasMedia && (mpv.paused || controlsHovered || hideControlsTimer.running)

    // ---------- 原生菜单栏（macOS 顶部系统菜单） ----------

    menuBar: MenuBar {
        Menu {
            title: qsTr("文件")

            // Menu 直接包含 Action，自动渲染为菜单项（MenuItem 无 shortcut 属性）
            Action {
                text: qsTr("打开文件…")
                shortcut: "Ctrl+O"
                onTriggered: openDialog.open()
            }
            Action {
                text: qsTr("打开链接…")
                shortcut: "Ctrl+L"
                onTriggered: urlPopup.open()
            }
            MenuSeparator {}
            Action {
                text: qsTr("退出")
                shortcut: "Ctrl+Q"
                onTriggered: Qt.quit()
            }
        }
        Menu {
            title: qsTr("帮助")
            Action {
                text: qsTr("SimplePlayer 帮助")
                shortcut: "Ctrl+/"
                onTriggered: helpDialog.open()
            }
            MenuSeparator {}
            Action {
                text: qsTr("关于 SimplePlayer")
                onTriggered: aboutDialog.open()
            }
        }
    }

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
                border.color: "#3a3a44"
                border.width: 1.5
                anchors.horizontalCenter: parent.horizontalCenter

                Label {
                    anchors.centerIn: parent
                    anchors.horizontalCenterOffset: 2
                    text: "▶\uFE0E"
                    color: "#8a8a94"
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
                color: "#6a6a74"
                font.pixelSize: 15
            }

            Label {
                anchors.horizontalCenter: parent.horizontalCenter
                text: qsTr("⌘O 打开文件 · ⌘L 打开链接 · 支持拖拽")
                color: "#4a4a54"
                font.pixelSize: 12
            }
        }
    }

    // ---------- 悬浮控制栏（QuickTime 风格） ----------

    Timer {
        id: hideControlsTimer
        interval: 2600
    }

    Rectangle {
        id: controlBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 14
        height: 58
        radius: 14
        color: Qt.rgba(0.10, 0.10, 0.12, 0.88)
        border.color: "#34343e"
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
                    color: playBtn.pressed ? Qt.rgba(1, 1, 1, 0.20)
                         : playBtn.hovered ? Qt.rgba(1, 1, 1, 0.12)
                         : "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }
                }

                // 图标：单色三角 / 双竖条（非 emoji）
                Text {
                    anchors.centerIn: parent
                    anchors.horizontalCenterOffset: 1
                    visible: mpv.paused
                    text: "▶"
                    color: "#e8e8ec"
                    font.pixelSize: 18
                }
                Row {
                    anchors.centerIn: parent
                    spacing: 3
                    visible: !mpv.paused
                    Repeater {
                        model: 2
                        Rectangle { width: 4; height: 16; radius: 1; color: "#e8e8ec" }
                    }
                }
            }

            Label {
                Layout.preferredWidth: 92
                horizontalAlignment: Text.AlignRight
                text: fmtTime(mpv.position)
                color: "#9a9aa3"
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
                    color: "#43434c"

                    Rectangle {
                        width: seekBar.visualPosition * parent.width
                        height: parent.height
                        radius: 2
                        color: root.hasMedia ? "#e8e8ec" : "#43434c"
                    }
                }

                handle: Rectangle {
                    x: seekBar.leftPadding
                         + seekBar.visualPosition * (seekBar.availableWidth - width)
                    y: seekBar.topPadding + seekBar.availableHeight / 2 - height / 2
                    width: 12
                    height: 12
                    radius: 6
                    color: "#ffffff"
                }
            }

            Label {
                Layout.preferredWidth: 92
                horizontalAlignment: Text.AlignLeft
                text: "−" + fmtTime(Math.max(mpv.duration - mpv.position, 0))
                color: "#9a9aa3"
                font.pixelSize: 11
                font.family: "Menlo"
            }

            // 扁平音量图标（Canvas 单色矢量绘制，静音时显示斜杠）
            Canvas {
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: 18
                Layout.preferredHeight: 16
                property bool muted: mpv.volume === 0
                onMutedChanged: requestPaint()

                onPaint: {
                    const ctx = getContext("2d")
                    ctx.reset()
                    ctx.fillStyle = "#9a9aa3"
                    ctx.beginPath()
                    ctx.moveTo(1, 6)
                    ctx.lineTo(5, 6)
                    ctx.lineTo(9, 2.5)
                    ctx.lineTo(9, 13.5)
                    ctx.lineTo(5, 10)
                    ctx.lineTo(1, 10)
                    ctx.closePath()
                    ctx.fill()
                    ctx.strokeStyle = "#9a9aa3"
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
                    color: "#43434c"

                    Rectangle {
                        width: volumeBar.visualPosition * parent.width
                        height: parent.height
                        radius: 2
                        color: "#e8e8ec"
                    }
                }

                handle: Rectangle {
                    x: volumeBar.leftPadding
                         + volumeBar.visualPosition * (volumeBar.availableWidth - width)
                    y: volumeBar.topPadding + volumeBar.availableHeight / 2 - height / 2
                    width: 12
                    height: 12
                    radius: 6
                    color: "#ffffff"
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
                    color: fsBtn.pressed ? Qt.rgba(1, 1, 1, 0.20)
                         : fsBtn.hovered ? Qt.rgba(1, 1, 1, 0.12)
                         : "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }
                }

                // 扁平全屏图标：四角括号
                Canvas {
                    anchors.centerIn: parent
                    width: 16
                    height: 16
                    onPaint: {
                        const ctx = getContext("2d")
                        ctx.reset()
                        ctx.strokeStyle = "#e8e8ec"
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

    Popup {
        id: urlPopup
        x: (parent.width - width) / 2
        y: 24
        width: Math.min(parent.width - 48, 620)
        padding: 12
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        onOpened: {
            urlField.selectAll()
            urlField.forceActiveFocus()
        }

        RowLayout {
            spacing: 8

            TextField {
                id: urlField
                Layout.fillWidth: true
                font.pixelSize: 13
                placeholderText: qsTr("粘贴直链：MP4 / m3u8(HLS) / 直播流…")
                onAccepted: urlPopup.play()
            }

            Button {
                text: qsTr("播放")
                onClicked: urlPopup.play()
            }
        }

        function play() {
            const t = urlField.text.trim()
            if (t.length > 0)
                mpv.load(t)
            close()
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
            color: "#26262e"
            radius: 8
            border.color: "#3a3a44"
            border.width: 1
        }
        contentItem: Label {
            text: toast.msg
            color: "#e8e8ec"
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

    Dialog {
        id: helpDialog
        parent: Overlay.overlay
        x: (parent.width - width) / 2
        y: (parent.height - height) / 2
        width: Math.min(parent.width - 80, 580)
        height: Math.min(parent.height - 120, 540)
        modal: true
        title: qsTr("SimplePlayer 帮助")
        standardButtons: Dialog.Close
        padding: 8

        background: Rectangle {
            color: "#1b1b20"
            radius: 12
            border.color: "#33333c"
            border.width: 1
        }

        contentItem: Flickable {
            id: helpFlick
            clip: true
            contentWidth: width

            TextArea.flickable: TextArea {
                readOnly: true
                wrapMode: TextArea.Wrap
                textFormat: Text.RichText
                color: "#c8c8d0"
                font.pixelSize: 13
                selectionColor: "#3d9bff"
                text: qsTr("
<h3 style='color:#e8e8ec'>打开视频</h3>
<p>三种方式任选：</p>
<p>• 菜单 <b>文件 → 打开文件…</b>（⌘O），或在未播放时点击窗口中央的播放按钮<br/>
• 菜单 <b>文件 → 打开链接…</b>（⌘L），粘贴直链：MP4 / m3u8(HLS) / 直播流<br/>
• 直接把视频文件拖进窗口</p>

<h3 style='color:#e8e8ec'>播放控制</h3>
<p>• 空格 —— 播放 / 暂停（也可以单击画面）<br/>
• ← / → —— 后退 / 前进 10 秒<br/>
• ↑ / ↓ —— 音量 ±5<br/>
• 拖动底部进度条跳转，右侧显示剩余时间</p>

<h3 style='color:#e8e8ec'>画面与窗口</h3>
<p>• F 或双击画面 —— 进入 / 退出全屏<br/>
• Esc —— 退出全屏<br/>
• 播放中鼠标静止片刻，控制栏会自动隐藏，移动鼠标即可唤出</p>

<h3 style='color:#e8e8ec'>支持格式</h3>
<p>• 本地：mp4 / mkv / mov / avi / flv / wmv / webm / m4v / ts 等，以及 mp3 / flac / wav 等音频<br/>
• 在线：http(s) 直链视频、HLS（m3u8）直播与点播</p>

<h3 style='color:#e8e8ec'>小提示</h3>
<p>• 在线流加载需要短暂缓冲，网络较慢时请稍候<br/>
• 播放结束会停留在最后一帧，打开新视频即可继续</p>
")
            }

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        }
    }

    // ---------- 关于 ----------

    Dialog {
        id: aboutDialog
        parent: Overlay.overlay
        x: (parent.width - width) / 2
        y: (parent.height - height) / 2
        width: 380
        modal: true
        title: qsTr("关于 SimplePlayer")
        standardButtons: Dialog.Close
        padding: 20

        background: Rectangle {
            color: "#1b1b20"
            radius: 12
            border.color: "#33333c"
            border.width: 1
        }

        contentItem: ColumnLayout {
            spacing: 6

            Image {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 4
                source: "qrc:/icons/logo.png"
                width: 96
                height: 96
                mipmap: true
                smooth: true
            }
            Label {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 10
                text: "SimplePlayer"
                color: "#e8e8ec"
                font.pixelSize: 20
                font.bold: true
            }
            Label {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 2
                text: qsTr("版本 ") + Qt.application.version
                color: "#9a9aa3"
                font.pixelSize: 12
            }
            Label {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 14
                text: qsTr("简洁的本地 & 在线视频播放器")
                color: "#c8c8d0"
                font.pixelSize: 13
            }
            Label {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 6
                text: "Qt " + Qt.version + " · mpv " + (mpv.mpvVersion.length > 0 ? mpv.mpvVersion : "libmpv")
                color: "#7a7a84"
                font.pixelSize: 11
            }
            Label {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 14
                text: qsTr("© 2026 SimplePlayer 项目")
                color: "#5a5a64"
                font.pixelSize: 11
            }
        }
    }

    // ---------- 快捷键 ----------

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
