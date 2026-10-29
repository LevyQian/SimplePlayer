#include "AceStream.h"

#include "DockerClient.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QSettings>
#include <QStandardPaths>
#include <QUrl>

#include <memory>

namespace {

/// 本机 Ace Stream 引擎默认监听地址
const char *kEngineBase = "http://127.0.0.1:6878";

/// 随包分发的容器镜像与容器名
const char *kImageName = "acestream-engine:local";
const char *kContainerName = "simpleplayer-acestream";

/// 随包分发的虚拟机磁盘镜像与容器镜像压缩包（避免首次联网下载）
const char *kVmImageName = "ubuntu-24.04-minimal-cloudimg-arm64-docker.raw.gz";
const char *kImageTarName = "acestream-image.tar.gz";

/// 引擎轮询：每 1.5s 一次，最多 40 次（约 1 分钟）
constexpr int kPollIntervalMs = 1500;
constexpr int kMaxPollAttempts = 40;

/// 容器服务轮询：每 2s 一次，最多 90 次（约 3 分钟）
constexpr int kDockerWaitIntervalMs = 2000;
constexpr int kMaxDockerWaitAttempts = 90;

/// 页面里只取第一个 40 位十六进制串，即频道最活跃的 Content ID
const QRegularExpression &contentIdPattern()
{
    static const QRegularExpression pattern(QStringLiteral("\\b[0-9a-fA-F]{40}\\b"));
    return pattern;
}

/// 从 colima 日志中提取真正的错误信息
/// colima 输出格式：time="..." level=fatal msg="实际错误"
QString parseColimaError(const QString &raw)
{
    // 1. 优先取 fatal 级别的 msg
    QRegularExpression re(QStringLiteral(R"--(level=fatal\s+msg="([^"]*)")--"));
    auto match = re.match(raw);
    if (match.hasMatch())
        return match.captured(1);

    // 2. 次选 error 级别
    re.setPattern(QStringLiteral(R"--(level=error\s+msg="([^"]*)")--"));
    match = re.match(raw);
    if (match.hasMatch())
        return match.captured(1);

    // 3. 如果有 Lima/VZ 相关的底层错误行（colima 有时候不会带 level 标签）
    QRegularExpression reLima(QStringLiteral(R"(Error:\s*(.+(?:lima|vm|vz|driver).*))"),
                              QRegularExpression::CaseInsensitiveOption);
    match = reLima.match(raw);
    if (match.hasMatch())
        return match.captured(1).trimmed();

    // 4. 退而求其次：返回去掉 time= 开头 info 行的最后一条有效输出
    const QStringList lines = raw.trimmed().split('\n');
    for (auto it = lines.constEnd(); it != lines.constBegin(); --it) {
        QString line = (*(it - 1)).trimmed();
        if (line.isEmpty()) continue;
        // 去掉 "time=\"...\" level=info msg=\"...\"" 里的 info 行
        if (line.contains(QStringLiteral("level=info"))) continue;
        // 去掉开头的 time="..." level=... 前缀
        QRegularExpression rePrefix(QStringLiteral(R"--(^time="[^"]+"\s+level=\w+\s+msg=")--"));
        line.remove(rePrefix);
        if (line.endsWith('"')) line.chop(1);
        if (!line.isEmpty()) return line;
    }

    // 5. 实在不行返回前 150 字原始内容
    return raw.trimmed().left(150);
}

} // namespace

AceStream::AceStream(QObject *parent)
    : QObject(parent)
    , m_docker(new DockerClient(this))
{
    // 设置页的 Docker 选项在启动时读入内存，避免退出/刷新时读到未落盘的旧值
    const QSettings settings;
    m_socketOverride =
        settings.value(QStringLiteral("player/dockerSocketPath")).toString().trimmed();
    m_stopColimaOnQuit =
        settings.value(QStringLiteral("player/stopColimaOnQuit"), true).toBool();

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
                verifyContent();
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

QStringList AceStream::dockerSockets() const
{
    QStringList candidates;

    // 设置页里手动指定的 socket 优先
    if (!m_socketOverride.isEmpty())
        candidates << m_socketOverride;

    const QString home = QDir::homePath();
    candidates << home + QStringLiteral("/.colima/docker.sock")
               << home + QStringLiteral("/.colima/default/docker.sock")
               << home + QStringLiteral("/.docker/run/docker.sock")
               << QStringLiteral("/var/run/docker.sock");
    return candidates;
}

void AceStream::setDockerSocketPath(const QString &path)
{
    const QString trimmed = path.trimmed();
    if (trimmed == m_socketOverride)
        return;

    m_socketOverride = trimmed;
    QSettings().setValue(QStringLiteral("player/dockerSocketPath"), trimmed);
}

void AceStream::setStopColimaOnQuit(bool on)
{
    if (on == m_stopColimaOnQuit)
        return;

    m_stopColimaOnQuit = on;
    QSettings().setValue(QStringLiteral("player/stopColimaOnQuit"), on);
}

QString AceStream::imageName() const
{
    return QString::fromLatin1(kImageName);
}

QString AceStream::containerName() const
{
    return QString::fromLatin1(kContainerName);
}

QString AceStream::engineUrl() const
{
    return QString::fromLatin1(kEngineBase);
}

QString AceStream::extractContentId(const QString &text)
{
    const auto match = contentIdPattern().match(text);
    return match.hasMatch() ? match.captured(0) : QString();
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
    m_engineTouched = true;
    emit progress(tr("正在检测本机 Ace Stream 引擎…"));

    QNetworkRequest request(
        QUrl(QStringLiteral("%1/webui/api/service?method=get_version")
                 .arg(QLatin1String(kEngineBase))));
    request.setTransferTimeout(2500);

    QNetworkReply *reply = m_nam.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();

        const int status =
            reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (reply->error() == QNetworkReply::NoError && status == 200) {
            verifyContent();
            return;
        }
        startEngine();
    });
}

void AceStream::verifyContent()
{
    emit progress(tr("正在连接流媒体…"));

    // id 走 AceStream 在线索引，需要对端服务可达；失败时用 infohash 本地直连
    probeContent(QStringLiteral("id"), [this](bool ok, const QString &url) {
        if (ok) {
            m_engineBusy = false;
            emit resolved(url);
            return;
        }

        probeContent(QStringLiteral("infohash"), [this](bool okHash, const QString &hashUrl) {
            m_engineBusy = false;
            if (okHash) {
                emit resolved(hashUrl);
                return;
            }
            emit failed(tr("无法加载该频道内容，可能当前没有人在直播"));
        });
    });
}

void AceStream::probeContent(const QString &param, Probe done)
{
    const QUrl url(QStringLiteral("%1/ace/getstream?%2=%3&format=json")
                       .arg(QLatin1String(kEngineBase), param, m_pendingContentId));

    QNetworkRequest request(url);
    request.setTransferTimeout(20000);

    QNetworkReply *reply = m_nam.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, done] {
        reply->deleteLater();

        const QJsonObject response = QJsonDocument::fromJson(reply->readAll())
                                         .object()
                                         .value(QStringLiteral("response"))
                                         .toObject();
        const QString playback = response.value(QStringLiteral("playback_url")).toString();

        const bool ok = reply->error() == QNetworkReply::NoError && !playback.isEmpty();
        done(ok, playback);
    });
}

void AceStream::startEngine()
{
    m_engineTouched = true;

    if (m_engineBusy) {
        emit progress(tr("引擎正在启动，请稍候…"));
        return;
    }

    m_engineBusy = true;
    emit progress(tr("正在检查容器服务…"));

    m_docker->locateSocket(dockerSockets(), 2500,
                           [this](const DockerClient::Response &response) {
                               if (response.ok()) {
                                   runContainer();
                                   return;
                               }
                               startRuntime();
                           });
}

void AceStream::startRuntime()
{
    m_colima = findTool(QStringLiteral("colima"));

    if (!m_colima.isEmpty()) {
        // --activate=false：不依赖 docker CLI 去设置 context
        QStringList args{QStringLiteral("start"), QStringLiteral("--vm-type"),
                         QStringLiteral("vz"), QStringLiteral("--vz-rosetta"),
                         QStringLiteral("--activate=false")};

        // 首次启动时用随包的磁盘镜像，避免联网下载几百 MB
        const QString vmImage =
            engineDir() + QStringLiteral("/vm/") + QLatin1String(kVmImageName);
        const bool configured =
            QFileInfo::exists(QDir::homePath() + QStringLiteral("/.colima/default/colima.yaml"));
        if (!configured && QFileInfo::exists(vmImage)) {
            args << QStringLiteral("--disk-image") << vmImage
                 << QStringLiteral("--force-disk-image");
        }

        emit progress(tr("正在启动轻量 Linux 引擎（首次初始化约需 1-2 分钟）…"));
        exec(m_colima, args, QString(), 180000,
             [this](bool ok, const QString &, const QString &err) {
                 if (!ok) {
                     m_engineBusy = false;
                     emit failed(tr("启动容器服务失败：%1").arg(
                         parseColimaError(err)));
                     return;
                 }
                 waitForDocker(0);
             });
        return;
    }

    // 退而求其次：拉起系统上已安装的容器服务
    if (QFileInfo::exists(QStringLiteral("/Applications/Docker.app"))) {
        emit progress(tr("正在启动系统容器服务…"));
        QProcess::startDetached(QStringLiteral("open"),
                                {QStringLiteral("-a"), QStringLiteral("Docker")});
        waitForDocker(0);
        return;
    }

    m_engineBusy = false;
    emit failed(tr("未找到可用的容器环境，请先安装 colima"));
}

void AceStream::waitForDocker(int attempt)
{
    if (attempt == 0)
        emit progress(tr("正在等待容器服务就绪…"));

    m_docker->locateSocket(dockerSockets(), 3000,
                           [this, attempt](const DockerClient::Response &response) {
                               if (response.ok()) {
                                   runContainer();
                                   return;
                               }
                               if (attempt >= kMaxDockerWaitAttempts) {
                                   m_engineBusy = false;
                                   emit failed(tr("容器服务启动超时，请稍后重试"));
                                   return;
                               }
                               QTimer::singleShot(kDockerWaitIntervalMs, this,
                                                  [this, attempt] {
                                                      waitForDocker(attempt + 1);
                                                  });
                           });
}

void AceStream::runContainer()
{
    emit progress(tr("正在启动 Ace Stream 引擎容器…"));

    m_docker->containerState(
        QLatin1String(kContainerName), [this](const DockerClient::Response &response) {
            if (response.status == 404) {
                ensureImage();
                return;
            }
            if (!response.ok()) {
                m_engineBusy = false;
                emit failed(tr("启动引擎容器失败：%1").arg(response.error));
                return;
            }

            const QJsonObject info = QJsonDocument::fromJson(response.body).object();
            const bool running = info.value(QStringLiteral("State"))
                                     .toObject()
                                     .value(QStringLiteral("Running"))
                                     .toBool();
            if (running) {
                startPolling();
                return;
            }
            startContainer(info.value(QStringLiteral("Id")).toString());
        });
}

void AceStream::ensureImage()
{
    m_docker->imageExists(
        QLatin1String(kImageName), [this](const DockerClient::Response &response) {
            if (response.status == 200) {
                createContainer();
                return;
            }

            const QString tar =
                engineDir() + QStringLiteral("/image/") + QLatin1String(kImageTarName);
            if (!QFileInfo::exists(tar)) {
                m_engineBusy = false;
                emit failed(tr("内置引擎镜像缺失，请重新安装 SimplePlayer"));
                return;
            }

            emit progress(tr("正在导入内置引擎镜像…"));
            m_docker->loadImage(tar, [this](const DockerClient::Response &loaded) {
                if (!loaded.ok()) {
                    m_engineBusy = false;
                    emit failed(tr("导入引擎镜像失败：%1").arg(loaded.error));
                    return;
                }
                createContainer();
            });
        });
}

void AceStream::createContainer()
{
    m_docker->createContainer(
        QLatin1String(kContainerName), QLatin1String(kImageName),
        [this](const DockerClient::Response &response) {
            // 同名容器被并发创建，重新走一遍状态判断
            if (response.status == 409) {
                runContainer();
                return;
            }

            const QString id = QJsonDocument::fromJson(response.body)
                                   .object()
                                   .value(QStringLiteral("Id"))
                                   .toString();
            if (!response.ok() || id.isEmpty()) {
                m_engineBusy = false;
                emit failed(tr("启动引擎容器失败：%1").arg(response.error));
                return;
            }
            startContainer(id);
        });
}

void AceStream::startContainer(const QString &id)
{
    m_docker->startContainer(id, [this](const DockerClient::Response &response) {
        // 304：容器已在运行
        if (!response.ok() && response.status != 304) {
            m_engineBusy = false;
            emit failed(tr("启动引擎容器失败：%1").arg(response.error));
            return;
        }
        startPolling();
    });
}

void AceStream::startPolling()
{
    m_pollAttempts = 0;
    emit progress(tr("引擎已启动，正在连接流媒体…"));
    m_pollTimer.start();
}

void AceStream::refreshDockerInfo()
{
    if (m_checking)
        return;

    m_checking = true;
    m_dockerConnected = false;
    m_dockerSocketPath.clear();
    m_dockerVersion.clear();
    m_containerState.clear();
    m_imageState.clear();
    emit dockerInfoChanged();

    // 先看引擎端口是否在监听，再探测 Docker（两者互不依赖）
    QNetworkRequest request(
        QUrl(QStringLiteral("%1/webui/api/service?method=get_version")
                 .arg(QLatin1String(kEngineBase))));
    request.setTransferTimeout(1500);

    QNetworkReply *reply = m_nam.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();

        const int status =
            reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        m_engineReady = reply->error() == QNetworkReply::NoError && status == 200;
        probeDockerInfo();
    });
}

void AceStream::probeDockerInfo()
{
    m_docker->locateSocket(dockerSockets(), 2000,
                           [this](const DockerClient::Response &response) {
                               if (!response.ok()) {
                                   m_checking = false;
                                   emit dockerInfoChanged();
                                   return;
                               }

                               m_dockerConnected = true;
                               m_dockerSocketPath = m_docker->socketPath();

                               m_docker->containerState(
                                   QLatin1String(kContainerName),
                                   [this](const DockerClient::Response &state) {
                                       if (state.status == 200) {
                                           const QJsonObject info =
                                               QJsonDocument::fromJson(state.body).object();
                                           const bool running = info
                                               .value(QStringLiteral("State"))
                                               .toObject()
                                               .value(QStringLiteral("Running"))
                                               .toBool();
                                           m_containerState = running
                                               ? QStringLiteral("running")
                                               : QStringLiteral("stopped");
                                       } else if (state.status == 404) {
                                           m_containerState = QStringLiteral("missing");
                                       } else {
                                           m_containerState = QStringLiteral("unknown");
                                       }

                                       m_docker->imageExists(
                                           QLatin1String(kImageName),
                                           [this](const DockerClient::Response &image) {
                                               if (image.status == 200)
                                                   m_imageState = QStringLiteral("present");
                                               else if (image.status == 404)
                                                   m_imageState = QStringLiteral("absent");
                                               else
                                                   m_imageState = QStringLiteral("unknown");

                                               m_docker->versionInfo(
                                                   [this](const DockerClient::Response &version) {
                                                       if (version.ok()) {
                                                           m_dockerVersion =
                                                               QJsonDocument::fromJson(version.body)
                                                                   .object()
                                                                   .value(QStringLiteral("Version"))
                                                                   .toString();
                                                       }
                                                       m_checking = false;
                                                       emit dockerInfoChanged();
                                                   });
                                           });
                                   });
                           });
}

void AceStream::shutdownEngine()
{
    // 用户可以在设置里关掉这个行为
    if (!m_stopColimaOnQuit)
        return;

    // 没用过引擎就不干预：用户自己启动的 colima 可能承载着别的东西
    if (!m_engineTouched)
        return;

    const QString colima =
        m_colima.isEmpty() ? findTool(QStringLiteral("colima")) : m_colima;
    if (colima.isEmpty())
        return;

    // 先确认 colima 真的在后台运行，没跑就什么都不做
    QProcess statusProc;
    statusProc.setProcessEnvironment(toolEnv());
    statusProc.start(colima, {QStringLiteral("status")});
    const bool running = statusProc.waitForFinished(4000)
        && statusProc.exitStatus() == QProcess::NormalExit
        && statusProc.exitCode() == 0;
    if (!running) {
        if (statusProc.state() != QProcess::NotRunning)
            statusProc.kill();
        return;
    }

    qInfo() << "[SimplePlayer] stopping colima on quit";

    QProcess stopProc;
    stopProc.setProcessEnvironment(toolEnv());
    stopProc.start(colima, {QStringLiteral("stop")});
    if (stopProc.waitForFinished(12000))
        return;

    // 优雅停止超时：强制停一次，避免留下还在运行的虚拟机
    stopProc.kill();
    stopProc.waitForFinished(2000);

    QProcess forceProc;
    forceProc.setProcessEnvironment(toolEnv());
    forceProc.start(colima, {QStringLiteral("stop"), QStringLiteral("--force")});
    forceProc.waitForFinished(5000);
}
