#pragma once

#include <QNetworkAccessManager>
#include <QObject>
#include <QProcessEnvironment>
#include <QString>
#include <QStringList>
#include <QTimer>

#include <functional>

class DockerClient;

/**
 * @brief AceStream 流地址解析 + 本机引擎自动启动。
 *
 * 支持的输入：
 * - 频道页地址，如 https://acestreamid.com/channel/motogp（抓取页面并提取 Content ID）
 * - acestream://<40 位 Content ID>
 * - 直接粘贴 40 位 Content ID
 *
 * 引擎启动顺序（全自动）：
 * 1. 探测 127.0.0.1:6878，已在运行则直接播放；
 * 2. 找到容器服务则直接起容器（镜像随 App 分发，首次从本地导入）；
 * 3. 容器服务未运行则用随包的 colima 拉起轻量 Linux 虚拟机。
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

    /// 退出播放器时调用：若本应用用过引擎且 colima 仍在后台运行，则停掉它
    void shutdownEngine();

signals:
    /// 解析成功，playbackUrl 可直接交给播放器
    void resolved(const QString &playbackUrl);
    void failed(const QString &message);
    /// 启动过程中的阶段性提示
    void progress(const QString &message);

private:
    using Done = std::function<void(bool ok, const QString &out, const QString &err)>;
    using Probe = std::function<void(bool ok, const QString &url)>;

    void fetchPage(const QString &url);
    void ensureEngine(const QString &contentId);
    void startRuntime();
    void waitForDocker(int attempt);
    void runContainer();
    void ensureImage();
    void createContainer();
    void startContainer(const QString &id);
    void startPolling();

    /// 引擎就绪后向它申请播放地址：优先 id，失败再退到 infohash
    void verifyContent();
    void probeContent(const QString &param, Probe done);

    void exec(const QString &program, const QStringList &args, const QString &workDir,
              int timeoutMs, Done done);
    QString findTool(const QString &name) const;
    QString engineDir() const;
    QProcessEnvironment toolEnv() const;
    static QString extractContentId(const QString &text);

    QNetworkAccessManager m_nam;
    QTimer m_pollTimer;
    DockerClient *m_docker = nullptr;

    QString m_pendingContentId;
    QString m_colima;
    int m_pollAttempts = 0;
    bool m_engineBusy = false;
    /// 本应用是否使用过 Ace Stream 引擎（决定退出时是否需要收拾 colima）
    bool m_engineTouched = false;
};
