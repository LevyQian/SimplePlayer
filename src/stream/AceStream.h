#pragma once

#include <QNetworkAccessManager>
#include <QObject>
#include <QProcessEnvironment>
#include <QString>
#include <QStringList>
#include <QTimer>

#include <functional>

/**
 * @brief AceStream 流地址解析 + 本机引擎自动启动。
 *
 * 支持的输入：
 * - 频道页地址，如 https://acestreamid.com/channel/motogp（抓取页面并提取 Content ID）
 * - acestream://<40 位 Content ID>
 * - 直接粘贴 40 位 Content ID
 *
 * 引擎启动顺序（全自动，无需用户介入）：
 * 1. 探测 127.0.0.1:6878，已在运行则直接播放；
 * 2. 用本机（或 App 内嵌）docker CLI 启动容器；
 * 3. docker 守护进程没起来时，优先用 colima 拉起轻量 Linux 虚拟机；
 * 4. 没有 colima 则尝试拉起 Docker Desktop。
 */
class AceStream : public QObject
{
    Q_OBJECT

public:
    explicit AceStream(QObject *parent = nullptr);

    /// 解析输入并保证引擎就绪后播放
    Q_INVOKABLE void resolve(const QString &input);

    /// 仅启动引擎（供界面上手动重试）
    Q_INVOKABLE void startEngine();

signals:
    /// 解析成功，playbackUrl 可直接交给播放器
    void resolved(const QString &playbackUrl);
    void failed(const QString &message);
    /// 启动过程中的阶段性提示
    void progress(const QString &message);

private:
    using Done = std::function<void(bool ok, const QString &out, const QString &err)>;

    void fetchPage(const QString &url);
    void ensureEngine(const QString &contentId);
    void probeEngine(const QString &contentId);
    void runContainer();
    void waitForDocker(int attempt);
    void startPolling();

    void exec(const QString &program, const QStringList &args, const QString &workDir,
              int timeoutMs, Done done);
    QString findTool(const QString &name) const;
    QString engineDir() const;
    QProcessEnvironment toolEnv() const;
    static QString extractContentId(const QString &text);
    static QString playbackUrl(const QString &contentId);

    QNetworkAccessManager m_nam;
    QTimer m_pollTimer;

    QString m_pendingContentId;
    QString m_docker;
    QString m_colima;
    QString m_dockerHost;
    int m_pollAttempts = 0;
    bool m_engineBusy = false;
};
