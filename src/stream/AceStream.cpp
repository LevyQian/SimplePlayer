#include "AceStream.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QUrl>

#include <memory>

namespace {

/// 本机 Ace Stream 引擎默认监听地址
const char *kEngineBase = "http://127.0.0.1:6878";

/// 引擎容器镜像（随 App 一起分发的本地镜像）与容器名
const char *kDockerImage = "acestream-engine:local";
const char *kContainerName = "simpleplayer-acestream";

/// 随包分发的虚拟机磁盘镜像与容器镜像压缩包（避免首次联网下载）
const char *kVmImageName = "ubuntu-24.04-minimal-cloudimg-arm64-docker.raw.gz";
const char *kImageTarName = "acestream-image.tar.gz";

/// 引擎轮询：每 1.5s 一次，最多 40 次（约 1 分钟）
constexpr int kPollIntervalMs = 1500;
constexpr int kMaxPollAttempts = 40;

/// docker 守护进程轮询：每 2s 一次，最多 90 次（约 3 分钟）
constexpr int kDockerWaitIntervalMs = 2000;
constexpr int kMaxDockerWaitAttempts = 90;

/// 页面里只取第一个 40 位十六进制串，即频道最活跃的 Content ID
const QRegularExpression &contentIdPattern()
{
    static const QRegularExpression pattern(QStringLiteral("\\b[0-9a-fA-F]{40}\\b"));
    return pattern;
}

} // namespace

AceStream::AceStream(QObject *parent)
    : QObject(parent)
{
    m_pollTimer.setInterval(kPollIntervalMs);
    connect(&m_pollTimer, &QTimer::timeout, this, [this] {
        QNetworkRequest request(
            QUrl(QStringLiteral("%1/webui/api/service?method=get_version")
                     .arg(QLatin1String(kEngineBase))));
        request.setTransferTimeout(2000);

        QNetworkReply *reply = m_nam.get(request);
        connect(reply, &QNetworkReply::finished, this, [this, reply] {
            reply->deleteLater();

            const int status =
                reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            if (reply->error() == QNetworkReply::NoError && status == 200) {
                m_pollTimer.stop();
                m_engineBusy = false;
                emit resolved(playbackUrl(m_pendingContentId));
                return;
            }

            if (++m_pollAttempts >= kMaxPollAttempts) {
                m_pollTimer.stop();
                m_engineBusy = false;
                emit failed(tr("引擎启动超时，请稍后重试"));
            }
        });
    });
}

QString AceStream::extractContentId(const QString &text)
{
    const auto match = contentIdPattern().match(text);
    return match.hasMatch() ? match.captured(0) : QString();
}

QString AceStream::playbackUrl(const QString &contentId)
{
    return QStringLiteral("%1/ace/getstream?id=%2")
        .arg(QLatin1String(kEngineBase), contentId);
}

QString AceStream::engineDir() const
{
    // 开发期可用 SP_ENGINE_DIR 指向随包引擎目录
    const QString fromEnv = qEnvironmentVariable("SP_ENGINE_DIR");
    if (!fromEnv.isEmpty())
        return fromEnv;

    // 打包后：SimplePlayer.app/Contents/Resources/engine
    const QString bundled =
        QCoreApplication::applicationDirPath() + QStringLiteral("/../Resources/engine");
    if (QFileInfo::exists(bundled + QStringLiteral("/bin")))
        return QDir(bundled).absolutePath();

    return QString();
}

QString AceStream::findTool(const QString &name) const
{
    const QString dir = engineDir();
    if (!dir.isEmpty()) {
        const QString bundled = dir + QStringLiteral("/bin/") + name;
        if (QFileInfo(bundled).isExecutable())
            return bundled;
    }

    const QString fromPath = QStandardPaths::findExecutable(name);
    if (!fromPath.isEmpty())
        return fromPath;

    for (const QString &prefix : {QStringLiteral("/opt/homebrew/bin"),
                                  QStringLiteral("/usr/local/bin"),
                                  QStringLiteral("/usr/bin")}) {
        const QString candidate = prefix + QLatin1Char('/') + name;
        if (QFileInfo(candidate).isExecutable())
            return candidate;
    }
    return QString();
}

QProcessEnvironment AceStream::toolEnv() const
{
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();

    const QString dir = engineDir();
    if (!dir.isEmpty()) {
        const QString bin = dir + QStringLiteral("/bin");
        env.insert(QStringLiteral("PATH"),
                   bin + QLatin1Char(':') + env.value(QStringLiteral("PATH")));
    }

    // 走 colima 时 docker CLI 需要显式指向它的 socket
    if (!m_dockerHost.isEmpty())
        env.insert(QStringLiteral("DOCKER_HOST"), m_dockerHost);

    return env;
}

void AceStream::exec(const QString &program, const QStringList &args, const QString &workDir,
                     int timeoutMs, Done done)
{
    if (program.isEmpty()) {
        done(false, QString(), tr("找不到可执行文件"));
        return;
    }

    auto *proc = new QProcess(this);
    proc->setProcessEnvironment(toolEnv());
    proc->setProcessChannelMode(QProcess::MergedChannels);
    if (!workDir.isEmpty())
        proc->setWorkingDirectory(workDir);

    auto notified = std::make_shared<bool>(false);

    connect(proc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), proc,
            [proc, done, notified](int code, QProcess::ExitStatus status) {
                if (*notified)
                    return;
                *notified = true;
                const QString output = QString::fromLocal8Bit(proc->readAll());
                done(status == QProcess::NormalExit && code == 0, output, output);
                proc->deleteLater();
            });

    connect(proc, &QProcess::errorOccurred, proc,
            [proc, done, notified](QProcess::ProcessError error) {
                if (*notified || error != QProcess::FailedToStart)
                    return;
                *notified = true;
                done(false, QString(),
                     tr("无法执行 %1").arg(QFileInfo(proc->program()).fileName()));
                proc->deleteLater();
            });

    if (timeoutMs > 0) {
        QTimer::singleShot(timeoutMs, proc, [proc, done, notified] {
            if (*notified)
                return;
            *notified = true;
            const QString output = QString::fromLocal8Bit(proc->readAll());
            proc->kill();
            done(false, output, tr("命令执行超时"));
        });
    }

    proc->start(program, args);
}

void AceStream::resolve(const QString &input)
{
    const QString text = input.trimmed();
    if (text.isEmpty()) {
        emit failed(tr("请输入流媒体地址或 Content ID"));
        return;
    }

    // acestream:// 链接与纯 Content ID：直接提取
    if (!text.startsWith(QLatin1String("http://"), Qt::CaseInsensitive)
        && !text.startsWith(QLatin1String("https://"), Qt::CaseInsensitive)) {
        const QString id = extractContentId(text);
        if (id.isEmpty()) {
            emit failed(tr("无法识别 AceStream Content ID"));
            return;
        }
        ensureEngine(id);
        return;
    }

    fetchPage(text);
}

void AceStream::fetchPage(const QString &url)
{
    emit progress(tr("正在解析流媒体地址…"));

    QNetworkRequest request(QUrl::fromUserInput(url));
    request.setHeader(QNetworkRequest::UserAgentHeader,
                      QStringLiteral("Mozilla/5.0 (Macintosh; Intel Mac OS X) SimplePlayer"));
    request.setTransferTimeout(10000);

    QNetworkReply *reply = m_nam.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();

        if (reply->error() != QNetworkReply::NoError) {
            emit failed(tr("页面请求失败：%1").arg(reply->errorString()));
            return;
        }

        const QByteArray body = reply->readAll();
        const QString id = extractContentId(QString::fromUtf8(body));
        if (id.isEmpty()) {
            emit failed(tr("页面中没有找到 AceStream Content ID"));
            return;
        }
        ensureEngine(id);
    });
}

void AceStream::ensureEngine(const QString &contentId)
{
    m_pendingContentId = contentId;
    emit progress(tr("正在检测本机 Ace Stream 引擎…"));

    QNetworkRequest request(
        QUrl(QStringLiteral("%1/webui/api/service?method=get_version")
                 .arg(QLatin1String(kEngineBase))));
    request.setTransferTimeout(2500);

    QNetworkReply *reply = m_nam.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, contentId] {
        reply->deleteLater();

        const int status =
            reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (reply->error() == QNetworkReply::NoError && status == 200) {
            emit resolved(playbackUrl(contentId));
            return;
        }
        startEngine();
    });
}

void AceStream::startEngine()
{
    if (m_engineBusy) {
        emit progress(tr("引擎正在启动，请稍候…"));
        return;
    }

    m_docker = findTool(QStringLiteral("docker"));
    m_colima = findTool(QStringLiteral("colima"));

    if (m_docker.isEmpty()) {
        emit failed(tr("未找到容器运行时（docker）。请安装 Docker Desktop 或 colima 后重试"));
        return;
    }

    // colima 已创建过实例时，直接复用它的 socket
    const QString colimaSocket =
        QDir::homePath() + QStringLiteral("/.colima/docker.sock");
    if (QFileInfo::exists(colimaSocket))
        m_dockerHost = QStringLiteral("unix://") + colimaSocket;

    m_engineBusy = true;
    emit progress(tr("正在检查容器服务…"));

    exec(m_docker, {QStringLiteral("info")}, QString(), 15000,
         [this](bool ok, const QString &, const QString &) {
             if (ok) {
                 runContainer();
                 return;
             }

             // docker 守护进程没起来：优先用 colima 拉起轻量虚拟机
             if (!m_colima.isEmpty()) {
                 if (m_dockerHost.isEmpty()) {
                     m_dockerHost = QStringLiteral("unix://") + QDir::homePath()
                         + QStringLiteral("/.colima/docker.sock");
                 }

                 QStringList args{QStringLiteral("start"), QStringLiteral("--vm-type"),
                                  QStringLiteral("vz"), QStringLiteral("--vz-rosetta")};

                 // 首次启动时用随包的磁盘镜像，避免联网下载几百 MB
                 const QString vmImage = engineDir().isEmpty()
                     ? QString()
                     : engineDir() + QStringLiteral("/vm/") + QLatin1String(kVmImageName);
                 const bool configured = QFileInfo::exists(
                     QDir::homePath() + QStringLiteral("/.colima/default/colima.yaml"));
                 if (!configured && !vmImage.isEmpty() && QFileInfo::exists(vmImage)) {
                     args << QStringLiteral("--disk-image") << vmImage
                          << QStringLiteral("--force-disk-image");
                 }

                 emit progress(tr("正在启动轻量 Linux 引擎（首次初始化约需 1-2 分钟）…"));
                 exec(m_colima, args, QString(), 0,
                      [this](bool started, const QString &, const QString &err) {
                          if (!started) {
                              m_engineBusy = false;
                              emit failed(tr("启动容器服务失败：%1").arg(err.trimmed()));
                              return;
                          }
                          waitForDocker(0);
                      });
                 return;
             }

             // 退而求其次：拉起 Docker Desktop
             if (QFileInfo::exists(QStringLiteral("/Applications/Docker.app"))) {
                 emit progress(tr("正在启动 Docker…"));
                 QProcess::startDetached(QStringLiteral("open"),
                                         {QStringLiteral("-a"), QStringLiteral("Docker")});
                 waitForDocker(0);
                 return;
             }

             m_engineBusy = false;
             emit failed(tr("未找到可用的容器环境。请安装 Docker Desktop 或 colima 后重试"));
         });
}

void AceStream::waitForDocker(int attempt)
{
    if (attempt == 0)
        emit progress(tr("正在等待容器服务就绪…"));

    exec(m_docker, {QStringLiteral("info")}, QString(), 10000,
         [this, attempt](bool ok, const QString &, const QString &) {
             if (ok) {
                 runContainer();
                 return;
             }
             if (attempt >= kMaxDockerWaitAttempts) {
                 m_engineBusy = false;
                 emit failed(tr("容器服务启动超时，请稍后重试"));
                 return;
             }
             QTimer::singleShot(kDockerWaitIntervalMs, this,
                                [this, attempt] { waitForDocker(attempt + 1); });
         });
}

void AceStream::runContainer()
{
    emit progress(tr("正在启动 Ace Stream 引擎容器…"));

    // 若随包带了镜像压缩包，先加载，避免首次联网拉取
    const QString imageTar = engineDir().isEmpty()
        ? QString()
        : engineDir() + QStringLiteral("/image/") + QLatin1String(kImageTarName);

    auto run = [this] {
        exec(m_docker,
             {QStringLiteral("run"), QStringLiteral("-d"), QStringLiteral("--rm"),
              QStringLiteral("--name"), QLatin1String(kContainerName),
              QStringLiteral("--platform"), QStringLiteral("linux/amd64"),
              QStringLiteral("-p"), QStringLiteral("6878:6878"),
              QLatin1String(kDockerImage)},
             QString(), 600000,
             [this](bool ok, const QString &out, const QString &err) {
                 // 容器已存在（上一次启动残留）时不视为失败
                 const bool exists = out.contains(QStringLiteral("already in use"))
                     || out.contains(QStringLiteral("Conflict"));
                 if (!ok && !exists) {
                     m_engineBusy = false;
                     emit failed(tr("启动引擎容器失败：%1").arg(err.trimmed()));
                     return;
                 }
                 if (exists)
                     exec(m_docker, {QStringLiteral("start"), QLatin1String(kContainerName)},
                          QString(), 60000, [](bool, const QString &, const QString &) {});
                 startPolling();
             });
    };

    if (!imageTar.isEmpty() && QFileInfo::exists(imageTar)) {
        exec(m_docker,
             {QStringLiteral("image"), QStringLiteral("inspect"), QLatin1String(kDockerImage)},
             QString(), 20000,
             [this, imageTar, run](bool found, const QString &, const QString &) {
                 if (found) {
                     run();
                     return;
                 }
                 emit progress(tr("正在导入内置引擎镜像…"));
                 exec(m_docker, {QStringLiteral("load"), QStringLiteral("-i"), imageTar},
                      QString(), 600000,
                      [this, run](bool loaded, const QString &, const QString &err) {
                          if (!loaded) {
                              m_engineBusy = false;
                              emit failed(tr("导入引擎镜像失败：%1").arg(err.trimmed()));
                              return;
                          }
                          run();
                      });
             });
        return;
    }

    run();
}

void AceStream::startPolling()
{
    m_pollAttempts = 0;
    emit progress(tr("引擎已启动，正在连接流媒体…"));
    m_pollTimer.start();
}
