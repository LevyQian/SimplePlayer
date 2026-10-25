#pragma once

#include <QObject>

/**
 * @brief 针对单个窗口的 macOS 原生行为微调。
 *
 * QML 的 Window.flags 在 macOS 上不足以去掉「缩放 / 全屏」能力，
 * 因此这里直接操作对应的 NSWindow：
 * - 移除 resizable / miniaturizable 样式位
 * - 取消 FullScreenPrimary，禁用绿色全屏
 * - 隐藏最小化与缩放按钮，只留关闭
 */
class MacWindowHelper : public QObject
{
    Q_OBJECT

public:
    explicit MacWindowHelper(QObject *parent = nullptr);

    /// window 传入 QML 的 Window 对象
    Q_INVOKABLE void lockWindow(QObject *window);
};
