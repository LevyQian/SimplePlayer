import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Universal
import QtQuick.Layouts
import QtQuick.Dialogs
import SimplePlayer 1.0

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

    // 空闲提示
    Label {
        anchors.centerIn: parent
        visible: mpv.duration <= 0
        text: qsTr("拖入文件，或使用下方「打开 / 链接」")
        color: "#4c4c56"
        font.pixelSize: 15
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        onClicked: mpv.playPause()
        onDoubleClicked: root.toggleFullscreen()
    }

    DropArea {
        anchors.fill: parent
        onDropped: (drop) => {
            if (drop.urls && drop.urls.length > 0)
                mpv.load(drop.urls[0])
        }
    }

    // ---------- 控制条 ----------

    footer: Rectangle {
        id: controlBar
        height: 54
        color: "#17171b"

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 14
            spacing: 10

            Button {
                flat: true
                text: qsTr("打开")
                onClicked: openDialog.open()
            }

            Button {
                flat: true
                text: qsTr("链接")
                onClicked: urlPopup.open()
            }

            ToolSeparator {}

            Button {
                flat: true
                Layout.preferredWidth: 46
                font.pixelSize: 15
                text: mpv.paused ? "▶" : "⏸"
                onClicked: mpv.playPause()
            }

            Label {
                text: fmtTime(mpv.position) + " / " + fmtTime(mpv.duration)
                color: "#9a9aa3"
                font.pixelSize: 12
                horizontalAlignment: Text.AlignHCenter
                Layout.preferredWidth: 108
            }

            Slider {
                id: seekBar
                Layout.fillWidth: true
                from: 0
                to: Math.max(mpv.duration, 1)
                enabled: mpv.duration > 0
                property bool scrubbing: false
                onPressedChanged: {
                    if (pressed)
                        scrubbing = true
                    else {
                        mpv.seekTo(value)
                        scrubbing = false
                    }
                }
            }

            Label {
                text: qsTr("音量")
                color: "#9a9aa3"
                font.pixelSize: 12
            }

            Slider {
                id: volumeBar
                Layout.preferredWidth: 110
                from: 0
                to: 100
                stepSize: 1
                property bool scrubbing: false
                onPressedChanged: {
                    if (pressed)
                        scrubbing = true
                    else
                        scrubbing = false
                }
                onMoved: if (scrubbing) mpv.volume = Math.round(value)
            }
        }
    }

    // mpv 属性 → 滑条（避免与拖动状态打架）
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
