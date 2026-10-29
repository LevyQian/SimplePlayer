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
 *
 * 同时负责在主窗口标题栏右侧挂载「更新云朵」按钮
 * （NSTitlebarAccessoryViewController，由 NativeMenuBar 的状态驱动）。
 */
class MacWindowHelper : public QObject
{
    Q_OBJECT

public:
    explicit MacWindowHelper(QObject *parent = nullptr);

    /// window 传入 QML 的 Window 对象
    Q_INVOKABLE void lockWindow(QObject *window);

    /// 在主窗口标题栏注册更新云朵宿主（实际按钮在有新版本时才挂载）
    Q_INVOKABLE void attachUpdateButton(QObject *window);

    /// 云朵点击回调（ObjC target 调用，转发给 NativeMenuBar）
    void notifyUpdateButtonClicked() { emit updateButtonClicked(); }

public slots:
    /// 更新云朵状态：有新版本或下载中时显示，其余情况移除
    void setUpdateState(bool available, bool downloading, int percent);

signals:
    /// 标题栏云朵被点击
    void updateButtonClicked();

private:
    void *m_window = nullptr;      // NSWindow*（assign，生命周期与 App 相同）
    void *m_accessory = nullptr;   // NSTitlebarAccessoryViewController*（assign，window 持有）
    void *m_button = nullptr;      // NSButton*（assign，accessory 视图持有）

    /// 刷新云朵按钮内容：下载中显示百分比，否则显示云朵图标
    void updateButtonContent(bool downloading, int percent);
};
