#pragma once

#include <QObject>
#include <QString>

class QQmlEngine;
class QTranslator;

/**
 * @brief 暴露给 QML 的应用级控制器（当前仅负责界面语言切换）。
 *
 * QML 通过上下文属性 `App` 使用，例如 App.setLanguage("en")。
 * 切换后调用 QQmlEngine::retranslate()，界面上所有 qsTr 文本立即刷新。
 */
class AppController : public QObject
{
    Q_OBJECT

    /// 当前界面语言（"zh_CN" / "zh_TW" / "en"），QML 直接绑定它决定显示名等
    Q_PROPERTY(QString language READ language NOTIFY languageChanged)

public:
    explicit AppController(QQmlEngine *engine, QObject *parent = nullptr);

    QString language() const { return m_language; }

    Q_INVOKABLE void setLanguage(const QString &code);

signals:
    void languageChanged();

private:
    QQmlEngine *m_engine = nullptr;
    QTranslator *m_translator = nullptr;
    QString m_language = QStringLiteral("zh_CN");
};
