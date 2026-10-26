#include "AppController.h"

#include <QCoreApplication>
#include <QQmlEngine>
#include <QSettings>
#include <QTranslator>

AppController::AppController(QQmlEngine *engine, QObject *parent)
    : QObject(parent)
    , m_engine(engine)
{
    // 母语（简体中文）即源码语言，无需翻译文件；仅英文需要加载 .qm
}

void AppController::setLanguage(const QString &code)
{
    if (m_translator) {
        QCoreApplication::removeTranslator(m_translator);
        delete m_translator;
        m_translator = nullptr;
    }

    // 简体中文即源码语言，无需翻译文件；英文与繁体中文各有一份 .qm
    QString resource;
    if (code == QLatin1String("en"))
        resource = QStringLiteral(":/i18n/app_en.qm");
    else if (code == QLatin1String("zh_TW"))
        resource = QStringLiteral(":/i18n/app_zh_TW.qm");

    if (!resource.isEmpty()) {
        auto *translator = new QTranslator(this);
        if (translator->load(resource)) {
            m_translator = translator;
            QCoreApplication::installTranslator(m_translator);
        } else {
            qWarning("[SimplePlayer] failed to load %s", qPrintable(resource));
            delete translator;
        }
    }

    // 与 QML Settings（category=player）共用同一份持久化
    QSettings().setValue(QStringLiteral("player/language"), code);

    if (m_language != code) {
        m_language = code;
        emit languageChanged();
    }

    if (m_engine)
        m_engine->retranslate();
}
