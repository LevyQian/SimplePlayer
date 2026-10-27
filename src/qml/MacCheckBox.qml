import QtQuick
import QtQuick.Controls

/**
 * macOS 偏好设置风格的复选框：圆角小方框 + 勾选时实心强调色。
 * 颜色由使用方传入（皮肤色板在 Main.qml 内，无法直接访问）。
 */
CheckBox {
    id: control

    property color accentColor: "#3d9bff"
    property color borderColor: "#8a8a92"
    property color textColor: "#e8e8ec"

    implicitHeight: 22
    spacing: 8
    font.pixelSize: 13

    indicator: Rectangle {
        implicitWidth: 15
        implicitHeight: 15
        x: control.leftPadding
        y: Math.round((control.height - height) / 2)
        radius: 3.5
        color: control.checked ? control.accentColor : "transparent"
        border.width: 1
        border.color: control.checked ? control.accentColor
                    : control.hovered ? control.accentColor : control.borderColor

        Text {
            anchors.centerIn: parent
            visible: control.checked
            text: "✓"
            color: "#ffffff"
            font.pixelSize: 10
            font.bold: true
        }
    }

    contentItem: Text {
        leftPadding: control.indicator.width + control.spacing
        text: control.text
        font: control.font
        color: control.enabled ? control.textColor : control.borderColor
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
}
