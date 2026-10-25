#pragma once

#include <QQuickFramebufferObject>
#include <QString>

struct mpv_handle;

/**
 * @brief 承载 libmpv 的 QML 视频项。
 *
 * macOS 下 mpv 不支持 --wid 嵌窗，这里通过 libmpv render API
 * 把画面渲染进 QQuickFramebufferObject 的 OpenGL FBO（IINA 同款路线）。
 * 播放控制全部走 mpv 属性/命令，属性变化通过 mpv_observe_property 同步到 Qt 信号。
 */
class MpvObject : public QQuickFramebufferObject
{
    Q_OBJECT
    Q_PROPERTY(qreal position READ position NOTIFY positionChanged)
    Q_PROPERTY(qreal duration READ duration NOTIFY durationChanged)
    Q_PROPERTY(bool paused READ paused NOTIFY pausedChanged)
    Q_PROPERTY(int volume READ volume WRITE setVolume NOTIFY volumeChanged)
    Q_PROPERTY(QString mediaTitle READ mediaTitle NOTIFY mediaTitleChanged)

public:
    explicit MpvObject(QQuickItem *parent = nullptr);
    ~MpvObject() override;

    Renderer *createRenderer() const override;

    qreal position() const { return m_position; }
    qreal duration() const { return m_duration; }
    bool paused() const { return m_paused; }
    int volume() const { return m_volume; }
    QString mediaTitle() const { return m_mediaTitle; }

    void setVolume(int volume);

public slots:
    void load(const QString &url);
    void playPause();
    void play();
    void pause();
    void seekTo(qreal seconds);
    void seekRelative(qreal seconds);
signals:
    void positionChanged();
    void durationChanged();
    void pausedChanged();
    void volumeChanged();
    void mediaTitleChanged();
    void fileEnded();
    void fileError(const QString &reason);

private slots:
    void handleMpvEvents();
    /** 渲染线程创建好 mpv_render_context 后回调（GUI 线程执行） */
    void handleRenderReady();

private:
    static void mpvWakeup(void *ctx);

    mpv_handle *m_mpv = nullptr;

    bool m_renderReady = false;   ///< mpv_render_context 是否已创建（决定能否 loadfile）
    QString m_pendingUrl;         ///< render context 就绪前排队的待播地址

    qreal m_position = 0.0;
    qreal m_duration = 0.0;
    bool m_paused = true;
    int m_volume = 100;
    QString m_mediaTitle;

    friend class MpvRenderer;
};
