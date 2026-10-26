#pragma once

#include <QQuickFramebufferObject>
#include <QString>
#include <QVariantList>

struct mpv_handle;
struct mpv_event_property;

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
    Q_PROPERTY(bool mediaLoaded READ mediaLoaded NOTIFY mediaLoadedChanged)
    Q_PROPERTY(int videoWidth READ videoWidth NOTIFY videoSizeChanged)
    Q_PROPERTY(int videoHeight READ videoHeight NOTIFY videoSizeChanged)
    Q_PROPERTY(int loadSerial READ loadSerial NOTIFY loadSerialChanged)

    /// 当前媒体是否为网络流（http/https/rtsp 等），决定是否显示流健康入口
    Q_PROPERTY(bool networkStream READ networkStream NOTIFY networkStreamChanged)

    /// 流健康状况（网络流才有意义）
    Q_PROPERTY(bool pausedForCache READ pausedForCache NOTIFY streamStatsChanged)
    Q_PROPERTY(qreal cacheDuration READ cacheDuration NOTIFY streamStatsChanged)
    Q_PROPERTY(qreal cacheSpeed READ cacheSpeed NOTIFY streamStatsChanged)
    Q_PROPERTY(int cacheBufferingState READ cacheBufferingState NOTIFY streamStatsChanged)
    Q_PROPERTY(int frameDropCount READ frameDropCount NOTIFY streamStatsChanged)
    Q_PROPERTY(int decoderFrameDropCount READ decoderFrameDropCount NOTIFY streamStatsChanged)
    Q_PROPERTY(qreal videoBitrate READ videoBitrate NOTIFY streamStatsChanged)
    Q_PROPERTY(qreal containerFps READ containerFps NOTIFY streamStatsChanged)

    /// 字幕轨道列表：[{ id, title }]
    Q_PROPERTY(QVariantList subtitleTracks READ subtitleTracks NOTIFY subtitleTracksChanged)
    Q_PROPERTY(int activeSubtitleId READ activeSubtitleId NOTIFY subtitleStateChanged)
    Q_PROPERTY(qreal subtitleDelay READ subtitleDelay NOTIFY subtitleStateChanged)
    Q_PROPERTY(qreal subtitleScale READ subtitleScale NOTIFY subtitleStateChanged)
    Q_PROPERTY(int subtitlePosition READ subtitlePosition NOTIFY subtitleStateChanged)

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
    /// 是否已有媒体加载完成（直播流同样为 true，判断界面状态时不要用 duration）
    bool mediaLoaded() const { return m_mediaLoaded; }
    int videoWidth() const { return m_videoWidth; }
    int videoHeight() const { return m_videoHeight; }
    /// 每次 load() 自增，用于识别「换了一个文件」
    int loadSerial() const { return m_loadSerial; }

    bool pausedForCache() const { return m_pausedForCache; }
    bool networkStream() const { return m_networkStream; }
    /// 已缓冲的秒数；不可用时为 -1
    qreal cacheDuration() const { return m_cacheDuration; }
    /// 缓存填充速度（字节/秒）；不可用时为 -1
    qreal cacheSpeed() const { return m_cacheSpeed; }
    /// 缓存填充百分比 0–100；-1 表示当前不可用
    int cacheBufferingState() const { return m_cacheBufferingState; }
    int frameDropCount() const { return m_frameDropCount; }
    int decoderFrameDropCount() const { return m_decoderFrameDropCount; }
    /// 视频码率（bit/s）；不可用时为 -1
    qreal videoBitrate() const { return m_videoBitrate; }
    qreal containerFps() const { return m_containerFps; }

    QVariantList subtitleTracks() const { return m_subtitleTracks; }
    int activeSubtitleId() const { return m_activeSubtitleId; }
    qreal subtitleDelay() const { return m_subtitleDelay; }
    qreal subtitleScale() const { return m_subtitleScale; }
    int subtitlePosition() const { return m_subtitlePosition; }

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

    /// 加载外挂字幕并选中
    void addSubtitle(const QUrl &url);
    /// sid < 0 表示关闭字幕
    void selectSubtitle(int sid);
    void toggleSubtitles();
    void changeSubtitleDelay(qreal delta);
    void resetSubtitleDelay();
    void changeSubtitleScale(qreal delta);
    void changeSubtitlePosition(int delta);
    void resetSubtitleStyle();
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
    void mediaLoadedChanged();
    void videoSizeChanged();
    void loadSerialChanged();
    void streamStatsChanged();
    void networkStreamChanged();
    void subtitleTracksChanged();
    void subtitleStateChanged();
    void fileEnded();
    void fileError(const QString &reason);

private slots:
    void handleMpvEvents();
    /** 渲染线程创建好 mpv_render_context 后回调（GUI 线程执行） */
    void handleRenderReady();

private:
    static void mpvWakeup(void *ctx);
    void updateLoading();
    void resetStreamStats();
    void refreshSubtitleTracks();
    void applySubtitleProperty(const char *name, const struct mpv_event_property *prop);

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
    bool m_mediaLoaded = false;
    int m_videoWidth = 0;
    int m_videoHeight = 0;
    int m_loadSerial = 0;

    qreal m_cacheDuration = -1.0;
    qreal m_cacheSpeed = -1.0;
    int m_cacheBufferingState = -1;
    int m_frameDropCount = 0;
    int m_decoderFrameDropCount = 0;
    qreal m_videoBitrate = -1.0;
    qreal m_containerFps = 0.0;
    bool m_networkStream = false;

    QVariantList m_subtitleTracks;
    int m_activeSubtitleId = -1;
    int m_lastSubtitleId = -1;   ///< 关闭字幕后用于恢复
    qreal m_subtitleDelay = 0.0;
    qreal m_subtitleScale = 1.0;
    int m_subtitlePosition = 100;

    friend class MpvRenderer;
};
