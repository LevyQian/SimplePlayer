#pragma once

#include <QObject>
#include <QVariantList>

class UpdateChecker;

/**
 * @brief 通过 NSMenu 构建 macOS 顶部系统菜单栏。
 *
 * Qt Quick Controls 的 MenuBar 在 macOS 上依赖平台菜单桥接，
 * 当前使用的 Qt 构建未包含该能力（菜单不会出现在系统菜单栏），
 * 因此这里直接操作 AppKit 的 [NSApp mainMenu] 安装「应用 / 文件 / 字幕 / 帮助」菜单。
 *
 * 菜单项被点击时发出对应信号，由 main.cpp 转发到 QML 里的对话框函数。
 *
 * 同时暴露 Q_PROPERTY update* 系列给 QML，用于在界面右上角显示更新提示云朵。
 */
class NativeMenuBar : public QObject
{
    Q_OBJECT

    /// 是否发现了可下载的新版本（QML 绑定云朵显示）
    Q_PROPERTY(bool updateAvailable READ updateAvailable NOTIFY updateStateChanged)

    /// 最新版本 tag（如 "v1.0"），供 QML 显示"更新到 v1.0"
    Q_PROPERTY(QString updateTagName READ updateTagName NOTIFY updateStateChanged)

    /// 下载进行中
    Q_PROPERTY(bool updateDownloading READ updateDownloading NOTIFY updateStateChanged)

    /// 下载百分比 0~100
    Q_PROPERTY(int updateDownloadPercent READ updateDownloadPercent NOTIFY updateStateChanged)

public:
    explicit NativeMenuBar(QObject *parent = nullptr);
    ~NativeMenuBar() override;

    /// 安装（或重建）菜单，语言切换后可再次调用以刷新文案
    Q_INVOKABLE void install();

    /// 同步字幕状态（轨道列表、当前选中），有变化时自动重建菜单
    Q_INVOKABLE void setSubtitleState(const QVariantList &tracks, int activeId);

    /// 关联 UpdateChecker，自动响应其信号更新菜单项状态 + Q_PROPERTY
    Q_INVOKABLE void setUpdateChecker(UpdateChecker *checker);

    /// 忽略当前发现的版本（存 QSettings，不再弹提示，直到下个版本）
    Q_INVOKABLE void ignoreUpdate();

    /// 手动触发检查（云朵/菜单项点击下载时可直接调）
    Q_INVOKABLE void startUpdateDownload();

    /// 菜单项 tag 与信号的映射（供 Objective-C 目标对象回调）
    void trigger(int actionId);

    bool updateAvailable() const { return m_updateAvailable; }
    QString updateTagName() const { return m_updateTagName; }
    bool updateDownloading() const { return m_updateDownloading; }
    int updateDownloadPercent() const { return m_updateDownloadPercent; }

signals:
    void openFileRequested();
    void openUrlRequested();
    void openStreamRequested();
    void settingsRequested();
    void helpRequested();
    void aboutRequested();
    void quitRequested();

    /// 点击「检查更新」
    void checkUpdateRequested();

    /// 下载完成，点击「更新到 vX.X.X」执行自更新
    void doUpdateRequested(const QString &dmgPath);

    /// 更新状态变化（updateAvailable / updateDownloading / updateDownloadPercent 任一变更）
    void updateStateChanged();

    /// action 取值：load / off / track / toggle / delay-up / delay-down / delay-reset /
    ///              scale-up / scale-down / pos-up / pos-down / reset
    void subtitleActionRequested(const QString &action, int value);

private:
    QVariantList m_subtitleTracks;
    int m_activeSubtitle = -1;

    // ---- 更新相关 ----
    UpdateChecker *m_updateChecker = nullptr;
    void *m_updateItem = nullptr;         // NSMenuItem*，用 void* 避免头文件依赖 ObjC
    QString m_pendingDmgPath;             // 下载完成后保存 DMG 路径供 doUpdate 使用

    // ---- 暴露给 QML 的更新状态 ----
    bool m_updateAvailable = false;
    QString m_updateTagName;
    bool m_updateDownloading = false;
    int m_updateDownloadPercent = 0;

    /// 统一发 updateStateChanged，让所有 Q_PROPERTY 同时刷新
    void emitUpdateStateChanged() { emit updateStateChanged(); }
};
