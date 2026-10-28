#include "UpdateChecker.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QUrl>

namespace {

constexpr const char *kApiUrl = "https://api.github.com/repos/LevyQian/SimplePlayer/releases/latest";
constexpr const char *kUserAgent = "SimplePlayer-Updater";

/// 从 DMG 文件名里提取括号内的完整版本号
/// 格式：SimplePlayer(0.1.0-659a-10281941).dmg 或 SimplePlayer (0.1.0-659a-10281941).dmg
QString extractVersionFromDmgName(const QString &name)
{
    QRegularExpression re(QStringLiteral(R"(SimplePlayer\s*\((.+?)\)\.dmg)"),
                          QRegularExpression::CaseInsensitiveOption);
    const auto match = re.match(name);
    if (match.hasMatch())
        return match.captured(1);
    return {};
}

/// 比较完整版本字符串（含 suffix）。不同返回 true（有更新）
bool isNewer(const QString &remote, const QString &current)
{
    if (remote.isEmpty()) return false;
    return remote != current;
}

/// DMG 保存目录
QString cacheDir()
{
    return QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + QStringLiteral("/SimplePlayer");
}

} // namespace

UpdateChecker::UpdateChecker(QObject *parent)
    : QObject(parent)
{
}

void UpdateChecker::checkForUpdate()
{
    emit checking();

    QNetworkRequest request(QUrl::fromUserInput(kApiUrl));
    request.setHeader(QNetworkRequest::UserAgentHeader, kUserAgent);
    request.setRawHeader("Accept", "application/vnd.github+json");

    QNetworkReply *reply = m_nam.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();

        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred(reply->errorString());
            return;
        }

        const QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());
        if (doc.isNull()) {
            emit errorOccurred(tr("无法解析服务器响应"));
            return;
        }

        const QJsonObject root = doc.object();
        m_tagName = root.value("tag_name").toString();

        // 找 .dmg asset，并从文件名里解析完整版本号
        QString dmgVersion;
        const QJsonArray assets = root.value("assets").toArray();
        for (const QJsonValue &v : assets) {
            const QJsonObject asset = v.toObject();
            const QString name = asset.value("name").toString();
            if (name.endsWith(QStringLiteral(".dmg"), Qt::CaseInsensitive)) {
                m_downloadUrl = asset.value("browser_download_url").toString();
                m_downloadSize = asset.value("size").toInteger();
                dmgVersion = extractVersionFromDmgName(name);
                break;
            }
        }

        if (m_downloadUrl.isEmpty()) {
            emit errorOccurred(tr("找不到可下载的 DMG 文件"));
            return;
        }

        // 优先用 DMG 文件名里的完整版本号（带 suffix，每次 build 唯一）
        // 如果文件名解析不出，退回到 tag_name（去掉 v 前缀）
        QString remoteVersion = dmgVersion;
        if (remoteVersion.isEmpty()) {
            remoteVersion = m_tagName;
            remoteVersion.remove(QRegularExpression("^[vV]"));
        }

        const QString current = QCoreApplication::applicationVersion();
        if (!isNewer(remoteVersion, current)) {
            emit noUpdateAvailable();
            return;
        }

        // 用于 QML 显示：优先 DMG 里的版本号，没有就用 tag_name
        m_tagName = remoteVersion;
        emit updateAvailable(m_tagName, m_downloadUrl, m_downloadSize);
    });
}

void UpdateChecker::startDownload()
{
    if (m_downloadUrl.isEmpty()) {
        emit errorOccurred(tr("请先检查更新"));
        return;
    }

    const QString dir = cacheDir();
    QDir().mkpath(dir);
    const QString dmgPath = dir + QStringLiteral("/SimplePlayer.dmg");
    const QString partPath = dmgPath + QStringLiteral(".part");

    QNetworkRequest request(QUrl::fromUserInput(m_downloadUrl));
    request.setHeader(QNetworkRequest::UserAgentHeader, kUserAgent);

    QNetworkReply *reply = m_nam.get(request);

    QFile *file = new QFile(partPath);
    if (!file->open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        emit errorOccurred(tr("无法写入缓存目录：%1").arg(partPath));
        delete file;
        reply->abort();
        reply->deleteLater();
        return;
    }

    connect(reply, &QNetworkReply::downloadProgress, this,
            [this](qint64 received, qint64 total) {
                if (total > 0)
                    emit downloadProgress(static_cast<int>(received * 100 / total));
            });

    connect(reply, &QNetworkReply::readyRead, this, [reply, file] {
        file->write(reply->readAll());
    });

    connect(reply, &QNetworkReply::finished, this,
            [this, reply, file, partPath, dmgPath] {
        reply->deleteLater();

        // 把残留数据也写进去（readyRead 可能漏最后一包）
        file->write(reply->readAll());
        file->close();

        if (reply->error() == QNetworkReply::NoError) {
            // rename .part → .dmg
            QFile::remove(dmgPath);
            if (QFile::rename(partPath, dmgPath)) {
                emit downloadFinished(dmgPath);
            } else {
                QFile::remove(partPath);
                emit errorOccurred(tr("重命名临时文件失败"));
            }
        } else if (reply->error() == QNetworkReply::OperationCanceledError) {
            QFile::remove(partPath);
            emit downloadCancelled();
        } else {
            QFile::remove(partPath);
            emit errorOccurred(reply->errorString());
        }

        delete file;
    });
}

void UpdateChecker::cancelDownload()
{
    // abort 会触发 finished 信号，由那里统一处理
    const auto replies = m_nam.children();
    for (QObject *child : replies) {
        if (auto *reply = qobject_cast<QNetworkReply *>(child)) {
            if (reply->isRunning())
                reply->abort();
        }
    }
}
