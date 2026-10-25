#include <QCoreApplication>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QUrl>
#include <QVariant>

#include <clocale>

#include "mpv/MpvObject.h"

int main(int argc, char *argv[])
{
    // 深色现代风：Universal 主题，QML 内再切 Dark
    qputenv("QT_QUICK_CONTROLS_STYLE", "Universal");

    // QQuickFramebufferObject 只支持 OpenGL 后端，而 macOS 上 Qt6 默认 Metal，
    // 不切换的话 MpvObject 的 render() 永远不会被调用
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);

    QGuiApplication app(argc, argv);
    app.setOrganizationName("SimplePlayer");
    app.setApplicationName("SimplePlayer");
    app.setApplicationVersion("0.1.0");

    // 注意：QGuiApplication 构造时会 setlocale(LC_ALL, "")，
    // 因此必须在它之后把 LC_NUMERIC 复位为 C，否则 libmpv 直接创建失败。
    std::setlocale(LC_NUMERIC, "C");

    qmlRegisterType<MpvObject>("SimplePlayer", 1, 0, "MpvObject");

    QQmlApplicationEngine engine;
    const QUrl url(QStringLiteral("qrc:/qml/Main.qml"));
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated,
                     &app, [url](QObject *obj, const QUrl &objUrl) {
        if (!obj && url == objUrl)
            QCoreApplication::exit(-1);
    }, Qt::QueuedConnection);
    engine.load(url);
    if (engine.rootObjects().isEmpty())
        return -1;

    // 命令行直接传媒体路径/URL 启动播放
    if (argc > 1) {
        if (auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first())) {
            QMetaObject::invokeMethod(window, "loadFromCli",
                                      Q_ARG(QVariant, QVariant::fromValue(
                                          QUrl::fromUserInput(QString::fromLocal8Bit(argv[1])))));
        }
    }

    return app.exec();
}
