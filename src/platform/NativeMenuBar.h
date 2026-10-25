#pragma once

#include <QObject>

/**
 * @brief 通过 NSMenu 构建 macOS 顶部系统菜单栏。
 *
 * Qt Quick Controls 的 MenuBar 在 macOS 上依赖平台菜单桥接，
 * 当前使用的 Qt 构建未包含该能力（菜单不会出现在系统菜单栏），
 * 因此这里直接操作 AppKit 的 [NSApp mainMenu] 安装「文件 / 帮助」两个菜单。
 *
 * 菜单项被点击时发出对应信号，由 main.cpp 转发到 QML 里的对话框函数。
 */
class NativeMenuBar : public QObject
{
    Q_OBJECT

public:
    explicit NativeMenuBar(QObject *parent = nullptr);

    /// 安装（或重建）菜单，语言切换后可再次调用以刷新文案
    Q_INVOKABLE void install();

    /// 菜单项 tag 与信号的映射（供 Objective-C 目标对象回调）
    void trigger(int actionId);

signals:
    void openFileRequested();
    void openUrlRequested();
    void settingsRequested();
    void helpRequested();
    void aboutRequested();
    void quitRequested();
};
