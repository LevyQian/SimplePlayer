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

    if (code == QLatin1String("en")) {
        auto *translator = new QTranslator(this);
        if (translator->load(QStringLiteral(":/i18n/app_en.qm"))) {
            m_translator = translator;
            QCoreApplication::installTranslator(m_translator);
        } else {
            qWarning("[SimplePlayer] failed to load :/i18n/app_en.qm");
            delete translator;
        }
    }

    // 与 QML Settings（category=player）共用同一份持久化
    QSettings().setValue(QStringLiteral("player/language"), code);

    if (m_engine)
        m_engine->retranslate();
}
