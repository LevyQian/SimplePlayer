#pragma once

#include <QObject>
#include <QNetworkAccessManager>

/**
 * @brief 从 GitHub Releases 检查更新并下载 DMG。
 *
 * 流程：
 *   1. checkForUpdate()  → GET /repos/LevyQian/SimplePlayer/releases/latest
 *   2. 解析 JSON，找 tag_name 和 .dmg asset
 *   3. 比较版本号 → 发出 updateAvailable / noUpdateAvailable
 *   4. startDownload() → 下载到 ~/Library/Caches/SimplePlayer/SimplePlayer.dmg
 *   5. downloadProgress / downloadFinished / downloadError
 */
class UpdateChecker : public QObject
{
    Q_OBJECT

public:
    explicit UpdateChecker(QObject *parent = nullptr);

    /// 立即检查；完成后无论是否有更新都会发一个信号
    Q_INVOKABLE void checkForUpdate();

    /// 开始下载上次 checkForUpdate 得到的 DMG
    Q_INVOKABLE void startDownload();

    /// 取消当前下载
    Q_INVOKABLE void cancelDownload();

signals:
    /// 正在请求 API（菜单项可以显示 "检查更新中..."）
    void checking();

    /// 发现更新
    void updateAvailable(const QString &tagName, const QString &downloadUrl, qint64 size);

    /// 无更新 / 已是最新
    void noUpdateAvailable();

    /// 检查或下载失败
    void errorOccurred(const QString &message);

    /// 下载进度（0~100）
    void downloadProgress(int percent);

    /// 下载完成，给出 DMG 本地路径
    void downloadFinished(const QString &dmgPath);

    /// 下载被用户取消
    void downloadCancelled();

private:
    QNetworkAccessManager m_nam;
    QString m_tagName;
    QString m_downloadUrl;
    qint64 m_downloadSize = 0;
};
