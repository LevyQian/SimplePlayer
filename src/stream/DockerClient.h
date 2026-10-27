#pragma once

#include <QByteArray>
#include <QObject>
#include <QString>
#include <QStringList>

#include <functional>

/**
 * @brief 通过 unix socket 直接调用 Docker Engine HTTP API。
 *
 * 取代原先「启动 docker CLI 子进程」的做法，只保留一个轻量 HTTP/1.1 实现：
 * 请求头带 Connection: close，响应读到底后按 Content-Length / chunked 解析。
 */
class DockerClient : public QObject
{
    Q_OBJECT

public:
    struct Response
    {
        int status = 0;
        QByteArray body;
        QString error;

        bool ok() const { return status >= 200 && status < 300; }
    };

    using Handler = std::function<void(const Response &)>;

    explicit DockerClient(QObject *parent = nullptr);

    QString socketPath() const { return m_socketPath; }

    /// 依次 ping 候选 socket，第一个连通的会被记住
    void locateSocket(const QStringList &candidates, int timeoutMs, Handler done);

    void containerState(const QString &name, Handler done);
    void createContainer(const QString &name, const QString &image, Handler done);
    void startContainer(const QString &id, Handler done);
    void imageExists(const QString &image, Handler done);
    void loadImage(const QString &tarPath, Handler done);
    /// GET /version，用于设置页展示 Docker 版本
    void versionInfo(Handler done);

private:
    void request(const QByteArray &method, const QString &path, const QByteArray &jsonBody,
                 const QString &uploadFile, int timeoutMs, Handler done);

    QString m_socketPath;
};
