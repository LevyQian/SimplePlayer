#include <QCoreApplication>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QSettings>
#include <QSGRendererInterface>
#include <QTimer>
#include <QUrl>
#include <QVariant>

#include <clocale>

#include "AppController.h"
#include "BuildInfo.h"
#include "mpv/MpvObject.h"
#include "platform/MacWindowHelper.h"
#include "platform/NativeMenuBar.h"
#include "stream/AceStream.h"

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

    // 编译时写入的唯一子版本号（git 短 hash + 时间戳），每次 cmake 重新配置时更新
    const QString buildSuffix = QStringLiteral(APP_BUILD_SUFFIX);
    app.setApplicationVersion(app.applicationVersion() + "-" + buildSuffix);

    // 注意：QGuiApplication 构造时会 setlocale(LC_ALL, "")，
    // 因此必须在它之后把 LC_NUMERIC 复位为 C，否则 libmpv 直接创建失败。
    std::setlocale(LC_NUMERIC, "C");

    qmlRegisterType<MpvObject>("SimplePlayer", 1, 0, "MpvObject");

    QQmlApplicationEngine engine;

    // Qt 框架版本 + 本次编译唯一后缀（git hash + 时间戳）
    // 在 QML 里通过 qtVersion / buildSuffix / fullVersion 引用
    engine.rootContext()->setContextProperty(QStringLiteral("qtVersion"),
                                             QStringLiteral(QT_VERSION_STR));
    engine.rootContext()->setContextProperty(QStringLiteral("buildSuffix"),
                                             buildSuffix);
    engine.rootContext()->setContextProperty(QStringLiteral("fullVersion"),
                                             app.applicationVersion());

    // 界面语言（持久化于 QSettings 的 player/language，由设置页写入）
    AppController controller(&engine);
    engine.rootContext()->setContextProperty(QStringLiteral("App"), &controller);
    controller.setLanguage(QSettings()
                               .value(QStringLiteral("player/language"),
                                      QStringLiteral("zh_CN"))
                               .toString());

    // macOS 系统菜单栏（原生 NSMenu；语言切换时由 QML 调用 install() 重建）
    NativeMenuBar nativeMenu;
    engine.rootContext()->setContextProperty(QStringLiteral("NativeMenu"), &nativeMenu);

    // 窗口原生行为微调（去掉缩放/最小化按钮）
    MacWindowHelper macWindow;
    engine.rootContext()->setContextProperty(QStringLiteral("MacWindow"), &macWindow);

    // AceStream 流解析（频道页 → Content ID → 本机引擎）
    AceStream aceStream;
    engine.rootContext()->setContextProperty(QStringLiteral("AceStream"), &aceStream);

    // 退出时关闭本应用用过的 colima，避免虚拟机在后台常驻
    QObject::connect(&app, &QCoreApplication::aboutToQuit, &aceStream,
                     &AceStream::shutdownEngine);

    // 先销毁 QML 根对象：否则上下文对象（App / AceStream 等）析构后，
    // 界面绑定会重新求值并访问已失效的上下文，退出时刷一堆 TypeError
    QObject::connect(&app, &QCoreApplication::aboutToQuit, &app, [&engine] {
        const QList<QObject *> roots = engine.rootObjects();
        for (QObject *root : roots)
            delete root;
    });

    const QUrl url(QStringLiteral("qrc:/qml/Main.qml"));
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated,
                     &app, [url](QObject *obj, const QUrl &objUrl) {
        if (!obj && url == objUrl)
            QCoreApplication::exit(-1);
    }, Qt::QueuedConnection);
    engine.load(url);
    if (engine.rootObjects().isEmpty())
        return -1;

    if (auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first())) {
        // 菜单项 → QML 对话框
        QObject::connect(&nativeMenu, &NativeMenuBar::openFileRequested, window,
                         [window] { QMetaObject::invokeMethod(window, "openFileDialog"); });
        QObject::connect(&nativeMenu, &NativeMenuBar::openUrlRequested, window,
                         [window] { QMetaObject::invokeMethod(window, "openUrlDialog"); });
        QObject::connect(&nativeMenu, &NativeMenuBar::openStreamRequested, window,
                         [window] { QMetaObject::invokeMethod(window, "openStreamDialog"); });
        QObject::connect(&nativeMenu, &NativeMenuBar::settingsRequested, window,
                         [window] { QMetaObject::invokeMethod(window, "openSettingsDialog"); });
        QObject::connect(&nativeMenu, &NativeMenuBar::helpRequested, window,
                         [window] { QMetaObject::invokeMethod(window, "openHelpDialog"); });
        QObject::connect(&nativeMenu, &NativeMenuBar::aboutRequested, window,
                         [window] { QMetaObject::invokeMethod(window, "openAboutDialog"); });
        QObject::connect(&nativeMenu, &NativeMenuBar::quitRequested, &app,
                         &QCoreApplication::quit);

        // 字幕菜单动作 → QML（调用 mpv 或打开字幕文件对话框）
        QObject::connect(&nativeMenu, &NativeMenuBar::subtitleActionRequested, window,
                         [window](const QString &action, int value) {
                             QMetaObject::invokeMethod(window, "handleSubtitleAction",
                                                       Q_ARG(QVariant, action),
                                                       Q_ARG(QVariant, value));
                         });

        // 命令行直接传媒体路径/URL 启动播放
        if (argc > 1) {
            QMetaObject::invokeMethod(window, "loadFromCli",
                                      Q_ARG(QVariant, QVariant::fromValue(
                                          QUrl::fromUserInput(QString::fromLocal8Bit(argv[1])))));
        }
    }

    // 窗口创建后 Qt 才会装好默认主菜单，这里在其后插入「文件 / 帮助」
    QTimer::singleShot(0, &nativeMenu, [&nativeMenu] { nativeMenu.install(); });

    return app.exec();
}
