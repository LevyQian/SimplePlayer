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
 * - 频道页地址，如 https://acestreamid.com/channel/（抓取页面并提取 Content ID）
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

    // ---- Docker / 引擎信息（设置页「Docker」分页使用） ----
    Q_PROPERTY(bool dockerConnected READ dockerConnected NOTIFY dockerInfoChanged)
    Q_PROPERTY(QString dockerSocketPath READ dockerSocketPath NOTIFY dockerInfoChanged)
    Q_PROPERTY(QString dockerVersion READ dockerVersion NOTIFY dockerInfoChanged)
    /// "running" | "stopped" | "missing" | ""（未知）
    Q_PROPERTY(QString containerState READ containerState NOTIFY dockerInfoChanged)
    /// "present" | "absent" | ""（未知）
    Q_PROPERTY(QString imageState READ imageState NOTIFY dockerInfoChanged)
    Q_PROPERTY(bool engineReady READ engineReady NOTIFY dockerInfoChanged)
    Q_PROPERTY(bool checking READ checking NOTIFY dockerInfoChanged)
    Q_PROPERTY(QString imageName READ imageName CONSTANT)
    Q_PROPERTY(QString containerName READ containerName CONSTANT)
    Q_PROPERTY(QString engineUrl READ engineUrl CONSTANT)

public:
    explicit AceStream(QObject *parent = nullptr);

    /// 解析输入并保证引擎就绪后播放
    Q_INVOKABLE void resolve(const QString &input);

    /// 仅启动引擎（供界面上手动重试）
    Q_INVOKABLE void startEngine();

    /// 重新探测 Docker / 引擎状态（设置页刷新按钮）
    Q_INVOKABLE void refreshDockerInfo();

    /// 设置页：自定义 Docker socket（空字符串 = 自动探测）
    Q_INVOKABLE void setDockerSocketPath(const QString &path);
    /// 设置页：退出播放器时是否关闭 colima
    Q_INVOKABLE void setStopColimaOnQuit(bool on);

    /// 退出播放器时调用：若本应用用过引擎且 colima 仍在后台运行，则停掉它
    void shutdownEngine();

    bool dockerConnected() const { return m_dockerConnected; }
    QString dockerSocketPath() const { return m_dockerSocketPath; }
    QString dockerVersion() const { return m_dockerVersion; }
    QString containerState() const { return m_containerState; }
    QString imageState() const { return m_imageState; }
    bool engineReady() const { return m_engineReady; }
    bool checking() const { return m_checking; }
    QString imageName() const;
    QString containerName() const;
    QString engineUrl() const;

signals:
    /// 解析成功，playbackUrl 可直接交给播放器
    void resolved(const QString &playbackUrl);
    void failed(const QString &message);
    /// 启动过程中的阶段性提示
    void progress(const QString &message);
    void dockerInfoChanged();

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
    void probeDockerInfo();

    /// 候选 socket：优先用户在设置里指定的路径，其次常见的 colima / Docker Desktop 位置
    QStringList dockerSockets() const;

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

    bool m_dockerConnected = false;
    QString m_dockerSocketPath;
    QString m_dockerVersion;
    QString m_containerState;
    QString m_imageState;
    bool m_engineReady = false;
    bool m_checking = false;
    /// socket 覆盖路径（空 = 自动探测），与 QSettings 同步
    QString m_socketOverride;
    bool m_stopColimaOnQuit = true;
};
