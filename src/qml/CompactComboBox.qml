import QtQuick
import QtQuick.Controls

/**
 * 紧凑型下拉框：高度 28、圆角 6、自绘小箭头与紧凑弹出列表。
 * 颜色由使用方传入（皮肤色板在 Main.qml 内，无法直接访问）。
 */
ComboBox {
    id: control

    property color bgColor: "#26262e"
    property color borderColor: "#3a3a44"
    property color textColor: "#e8e8ec"
    property color popupColor: "#202027"
    property color accentColor: "#3d9bff"

    implicitWidth: 128
    implicitHeight: 28
    font.pixelSize: 13
    hoverEnabled: true

    background: Rectangle {
        radius: 6
        color: control.popup.visible ? Qt.lighter(control.bgColor, 1.15) : control.bgColor
        border.width: 1
        border.color: control.activeFocus ? control.accentColor : control.borderColor

        HoverHandler {
            cursorShape: Qt.PointingHandCursor
        }
    }

    contentItem: Text {
        leftPadding: 10
        rightPadding: 22
        text: control.displayText
        font: control.font
        color: control.textColor
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }

    // 自绘小箭头（比默认指示器更细、更紧凑）
    indicator: Canvas {
        x: control.width - width - 9
        y: (control.height - height) / 2
        width: 9
        height: 6

        property color strokeColor: control.textColor
        onStrokeColorChanged: requestPaint()
        Component.onCompleted: requestPaint()

        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            ctx.strokeStyle = strokeColor
            ctx.lineWidth = 1.4
            ctx.lineCap = "round"
            ctx.lineJoin = "round"
            ctx.beginPath()
            ctx.moveTo(1, 1.5)
            ctx.lineTo(4.5, 5)
            ctx.lineTo(8, 1.5)
            ctx.stroke()
        }
    }

    delegate: ItemDelegate {
        id: entry
        width: control.width
        height: 26
        highlighted: control.highlightedIndex === index

        contentItem: Text {
            text: modelData
            font.pixelSize: 13
            color: control.textColor
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            leftPadding: 6
        }

        background: Rectangle {
            radius: 4
            color: entry.highlighted
                   ? Qt.rgba(control.accentColor.r, control.accentColor.g,
                             control.accentColor.b, 0.20)
                   : "transparent"
        }
    }

    popup: Popup {
        y: control.height + 4
        width: control.width
        implicitHeight: contentItem.implicitHeight + 8
        padding: 4

        background: Rectangle {
            color: control.popupColor
            radius: 8
            border.color: control.borderColor
            border.width: 1
        }

        contentItem: ListView {
            clip: true
            implicitHeight: contentHeight
            model: control.popup.visible ? control.delegateModel : null
            currentIndex: control.highlightedIndex
            boundsBehavior: Flickable.StopAtBounds
        }
    }
}
