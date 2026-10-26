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
    Q_PROPERTY(QString mpvVersion READ mpvVersion NOTIFY mpvVersionChanged)
    Q_PROPERTY(bool hardwareDecoding READ hardwareDecoding WRITE setHardwareDecoding NOTIFY hardwareDecodingChanged)
    Q_PROPERTY(bool loopPlayback READ loopPlayback WRITE setLoopPlayback NOTIFY loopPlaybackChanged)
    Q_PROPERTY(int networkCache READ networkCache WRITE setNetworkCache NOTIFY networkCacheChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)

public:
    explicit MpvObject(QQuickItem *parent = nullptr);
    ~MpvObject() override;

    Renderer *createRenderer() const override;

    qreal position() const { return m_position; }
    qreal duration() const { return m_duration; }
    bool paused() const { return m_paused; }
    int volume() const { return m_volume; }
    QString mediaTitle() const { return m_mediaTitle; }
    QString mpvVersion() const { return m_mpvVersion; }
    bool hardwareDecoding() const { return m_hardwareDecoding; }
    bool loopPlayback() const { return m_loopPlayback; }
    int networkCache() const { return m_networkCache; }
    /// 正在打开媒体 / 缓冲中，界面据此显示加载提示
    bool loading() const { return m_loading; }

    void setVolume(int volume);
    void setHardwareDecoding(bool on);
    void setLoopPlayback(bool on);
    void setNetworkCache(int seconds);

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
    void mpvVersionChanged();
    void hardwareDecodingChanged();
    void loopPlaybackChanged();
    void networkCacheChanged();
    void loadingChanged();
    void fileEnded();
    void fileError(const QString &reason);

private slots:
    void handleMpvEvents();
    /** 渲染线程创建好 mpv_render_context 后回调（GUI 线程执行） */
    void handleRenderReady();

private:
    static void mpvWakeup(void *ctx);
    void updateLoading();

    mpv_handle *m_mpv = nullptr;

    bool m_renderReady = false;   ///< mpv_render_context 是否已创建（决定能否 loadfile）
    QString m_pendingUrl;         ///< render context 就绪前排队的待播地址

    qreal m_position = 0.0;
    qreal m_duration = 0.0;
    bool m_paused = true;
    int m_volume = 100;
    QString m_mediaTitle;
    QString m_mpvVersion;
    bool m_hardwareDecoding = true;
    bool m_loopPlayback = false;
    int m_networkCache = 10;
    bool m_loading = false;
    bool m_pendingPlayback = false; ///< 已请求打开、尚未真正播起来
    bool m_coreIdle = true;
    bool m_pausedForCache = false;

    friend class MpvRenderer;
};
