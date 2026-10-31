#include "DockerClient.h"

#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>
#include <QTimer>

#include <memory>

namespace {

QByteArray dechunk(const QByteArray &input)
{
    QByteArray output;
    int pos = 0;

    while (pos < input.size()) {
        const int eol = input.indexOf("\r\n", pos);
        if (eol < 0)
            break;

        bool ok = false;
        const int size = input.mid(pos, eol - pos).toInt(&ok, 16);
        if (!ok || size < 0)
            break;

        pos = eol + 2;
        if (size == 0)
            break;

        if (pos + size > input.size()) {
            output += input.mid(pos);
            break;
        }
        output += input.mid(pos, size);
        pos += size + 2;
    }
    return output;
}

DockerClient::Response parseResponse(const QByteArray &raw)
{
    DockerClient::Response response;

    const int separator = raw.indexOf("\r\n\r\n");
    if (separator < 0) {
        response.error = QStringLiteral("响应格式无效");
        return response;
    }

    const QList<QByteArray> lines = raw.left(separator).split('\n');
    response.status = lines.value(0).trimmed().split(' ').value(1).toInt();

    bool chunked = false;
    for (const QByteArray &line : lines) {
        if (line.toLower().startsWith("transfer-encoding:")
            && line.toLower().contains("chunked")) {
            chunked = true;
        }
    }

    const QByteArray body = raw.mid(separator + 4);
    response.body = chunked ? dechunk(body) : body;
    return response;
}

QString daemonMessage(const QByteArray &body)
{
    const QString message = QJsonDocument::fromJson(body)
                                .object()
                                .value(QStringLiteral("message"))
                                .toString();
    return message.isEmpty() ? QString::fromUtf8(body.left(200)) : message;
}

} // namespace

DockerClient::DockerClient(QObject *parent)
    : QObject(parent)
{
}

void DockerClient::locateSocket(const QStringList &candidates, int timeoutMs, Handler done)
{
    auto remaining = std::make_shared<QStringList>(candidates);
    auto step = std::make_shared<std::function<void()>>();

    *step = [this, remaining, timeoutMs, done, step] {
        while (!remaining->isEmpty()) {
            const QString path = remaining->takeFirst();
            if (!QFileInfo::exists(path))
                continue;

            m_socketPath = path;
            request(QByteArrayLiteral("GET"), QStringLiteral("/_ping"), {}, {}, timeoutMs,
                    [this, done, step](const Response &response) {
                        if (response.ok()) {
                            done(response);
                            return;
                        }
                        (*step)();
                    });
            return;
        }

        m_socketPath.clear();
        Response response;
        response.error = QStringLiteral("没有可用的 Docker socket");
        done(response);
    };

    (*step)();
}

void DockerClient::containerState(const QString &name, Handler done)
{
    request(QByteArrayLiteral("GET"), QStringLiteral("/containers/%1/json").arg(name), {}, {},
            8000, done);
}

void DockerClient::createContainer(const QString &name, const QString &image, Handler done)
{
    auto hostPort = [](const QString &port) {
        QJsonObject binding;
        binding.insert(QStringLiteral("HostPort"), port);
        return QJsonArray{binding};
    };

    // 8621 是 AceStream 引擎的 P2P 传输端口（tcp+udp），
    // 只映射 6878(tcp) 会导致引擎收不到 peer 的 UDP 数据，直播永远停在 prebuf。
    QJsonObject hostConfig;
    hostConfig.insert(QStringLiteral("AutoRemove"), true);
    hostConfig.insert(QStringLiteral("PortBindings"),
                      QJsonObject{
                          {QStringLiteral("6878/tcp"), hostPort(QStringLiteral("6878"))},
                          {QStringLiteral("8621/tcp"), hostPort(QStringLiteral("8621"))},
                          {QStringLiteral("8621/udp"), hostPort(QStringLiteral("8621"))},
                      });

    QJsonObject config;
    config.insert(QStringLiteral("Image"), image);
    config.insert(QStringLiteral("ExposedPorts"),
                  QJsonObject{{QStringLiteral("6878/tcp"), QJsonObject{}},
                              {QStringLiteral("8621/tcp"), QJsonObject{}},
                              {QStringLiteral("8621/udp"), QJsonObject{}}});
    config.insert(QStringLiteral("HostConfig"), hostConfig);

    const QByteArray body = QJsonDocument(config).toJson(QJsonDocument::Compact);
    request(QByteArrayLiteral("POST"),
            QStringLiteral("/containers/create?name=%1&platform=linux/amd64").arg(name), body,
            {}, 30000, done);
}

void DockerClient::startContainer(const QString &id, Handler done)
{
    request(QByteArrayLiteral("POST"), QStringLiteral("/containers/%1/start").arg(id), {}, {},
            60000, done);
}

void DockerClient::imageExists(const QString &image, Handler done)
{
    request(QByteArrayLiteral("GET"), QStringLiteral("/images/%1/json").arg(image), {}, {},
            8000, done);
}

void DockerClient::loadImage(const QString &tarPath, Handler done)
{
    request(QByteArrayLiteral("POST"), QStringLiteral("/images/load?quiet=1"), {}, tarPath,
            600000, done);
}

void DockerClient::versionInfo(Handler done)
{
    request(QByteArrayLiteral("GET"), QStringLiteral("/version"), {}, {}, 5000, done);
}

void DockerClient::request(const QByteArray &method, const QString &path,
                           const QByteArray &jsonBody, const QString &uploadFile,
                           int timeoutMs, Handler done)
{
    if (m_socketPath.isEmpty()) {
        Response response;
        response.error = QStringLiteral("没有可用的 Docker socket");
        done(response);
        return;
    }

    auto *socket = new QLocalSocket(this);
    auto *timer = new QTimer(this);
    timer->setSingleShot(true);

    auto buffer = std::make_shared<QByteArray>();
    auto file = std::make_shared<QFile>(uploadFile);
    auto bodySent = std::make_shared<bool>(false);
    auto completed = std::make_shared<bool>(false);

    const qint64 length = uploadFile.isEmpty() ? jsonBody.size() : QFileInfo(uploadFile).size();

    if (!uploadFile.isEmpty() && !file->open(QIODevice::ReadOnly)) {
        Response response;
        response.error = QStringLiteral("无法读取镜像文件");
        done(response);
        socket->deleteLater();
        timer->deleteLater();
        return;
    }

    QByteArray head = method + ' ' + path.toUtf8() + " HTTP/1.1\r\n";
    head += "Host: docker\r\n";
    head += "Connection: close\r\n";
    head += uploadFile.isEmpty() ? "Content-Type: application/json\r\n"
                                 : "Content-Type: application/x-tar\r\n";
    head += "Content-Length: " + QByteArray::number(length) + "\r\n\r\n";

    auto finish = [=](Response response) {
        if (*completed)
            return;
        *completed = true;
        timer->stop();
        socket->abort();
        done(response);
        socket->deleteLater();
        timer->deleteLater();
    };

    auto pump = std::make_shared<std::function<void()>>();
    *pump = [=] {
        if (*completed)
            return;

        while (socket->bytesToWrite() < (1 << 20)) {
            QByteArray chunk;
            if (!uploadFile.isEmpty()) {
                chunk = file->read(256 * 1024);
            } else if (!*bodySent) {
                chunk = jsonBody;
                *bodySent = true;
            }

            if (chunk.isEmpty())
                return;
            socket->write(chunk);
        }
    };

    auto complete = [=] {
        Response response = parseResponse(*buffer);
        if (response.status == 0) {
            response.error = QStringLiteral("连接已关闭");
        } else if (!response.ok() && response.error.isEmpty()) {
            response.error = daemonMessage(response.body);
        }
        finish(response);
    };

    connect(socket, &QLocalSocket::connected, this, [=] {
        socket->write(head);
        (*pump)();
    });
    connect(socket, &QLocalSocket::bytesWritten, this, [=](qint64) { (*pump)(); });
    connect(socket, &QLocalSocket::readyRead, this, [=] { buffer->append(socket->readAll()); });
    connect(socket, &QLocalSocket::disconnected, this, complete);
    connect(socket, &QLocalSocket::errorOccurred, this,
            [=](QLocalSocket::LocalSocketError error) {
                // 服务端按 Connection: close 主动断开时也会走到这里，
                // 此时数据已经收完，直接解析缓冲区。
                if (error == QLocalSocket::PeerClosedError && !buffer->isEmpty()) {
                    complete();
                    return;
                }
                Response response;
                response.error = socket->errorString();
                finish(response);
            });
    connect(timer, &QTimer::timeout, this, [=] {
        Response response;
        response.error = QStringLiteral("请求超时");
        finish(response);
    });

    timer->start(timeoutMs);
    socket->connectToServer(m_socketPath);
}
