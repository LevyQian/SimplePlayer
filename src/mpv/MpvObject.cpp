#include "MpvObject.h"

#include <QByteArray>
#include <QDebug>
#include <QFileInfo>
#include <QMetaObject>
#include <QQuickWindow>
#include <QOpenGLContext>
#include <QOpenGLFramebufferObject>
#include <QImage>
#include <QVariantMap>

#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>

#include <cmath>
#include <cstdint>
#include <cstring>

namespace {

void *getProcAddressMpv(void *ctx, const char *name)
{
    auto *glctx = static_cast<QOpenGLContext *>(ctx);
    return reinterpret_cast<void *>(glctx->getProcAddress(name));
}

/// 从 mpv 的 NODE 结构里取一个键的字符串值
QString nodeString(const mpv_node &node, const char *key)
{
    if (node.format != MPV_FORMAT_NODE_MAP || !node.u.list)
        return {};

    mpv_node_list *list = node.u.list;
    for (int i = 0; i < list->num; ++i) {
        if (!list->keys[i] || std::strcmp(list->keys[i], key) != 0)
            continue;

        const mpv_node &value = list->values[i];
        if (value.format == MPV_FORMAT_STRING)
            return QString::fromUtf8(value.u.string);
        if (value.format == MPV_FORMAT_INT64)
            return QString::number(value.u.int64);
        return {};
    }
    return {};
}

/// 同上，取布尔值（mpv 用 MPV_FORMAT_FLAG 表示）
bool nodeFlag(const mpv_node &node, const char *key)
{
    if (node.format != MPV_FORMAT_NODE_MAP || !node.u.list)
        return false;

    mpv_node_list *list = node.u.list;
    for (int i = 0; i < list->num; ++i) {
        if (!list->keys[i] || std::strcmp(list->keys[i], key) != 0)
            continue;
        const mpv_node &value = list->values[i];
        return value.format == MPV_FORMAT_FLAG && value.u.flag;
    }
    return false;
}

} // namespace

/**
 * 渲染器运行在 Qt 场景图渲染线程上，把 mpv 画面画进 QML 提供的 FBO。
 * mpv_render_context 在首次 render() 时创建（此时 GL 上下文已 current）。
 */
class MpvRenderer : public QQuickFramebufferObject::Renderer
{
public:
    explicit MpvRenderer(MpvObject *obj)
        : m_obj(obj)
    {
    }

    ~MpvRenderer() override
    {
        if (m_ctx) {
            mpv_render_context_set_update_callback(m_ctx, nullptr, nullptr);
            mpv_render_context_free(m_ctx);
            m_ctx = nullptr;
        }
    }

    QOpenGLFramebufferObject *createFramebufferObject(const QSize &size) override
    {
        QOpenGLFramebufferObjectFormat format;
        format.setAttachment(QOpenGLFramebufferObject::CombinedDepthStencil);
        return new QOpenGLFramebufferObject(size, format);
    }

    void synchronize(QQuickFramebufferObject *) override { }

    void render() override
    {
        if (!m_ctx && !m_failed) {
            if (QOpenGLContext *glctx = QOpenGLContext::currentContext()) {
                mpv_opengl_init_params initParams{};
                initParams.get_proc_address = &getProcAddressMpv;
                initParams.get_proc_address_ctx = glctx;

                mpv_render_param createParams[] = {
                    { MPV_RENDER_PARAM_API_TYPE,
                      const_cast<char *>(MPV_RENDER_API_TYPE_OPENGL) },
                    { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &initParams },
                    { MPV_RENDER_PARAM_INVALID, nullptr },
                };
                if (mpv_render_context_create(&m_ctx, m_obj->m_mpv, createParams) < 0) {
                    m_ctx = nullptr;
                    m_failed = true;
                    qWarning() << "[SimplePlayer] mpv_render_context_create failed";
                } else {
                    mpv_render_context_set_update_callback(
                        m_ctx, &MpvRenderer::onMpvRedraw, this);
                    // 通知 GUI 线程：render context 就绪，可以安全 loadfile 了
                    QMetaObject::invokeMethod(m_obj, "handleRenderReady",
                                              Qt::QueuedConnection);
                }
            }
        }

        if (!m_ctx)
            return;

        QOpenGLFramebufferObject *fbo = framebufferObject();
        mpv_opengl_fbo mpvFbo{};
        mpvFbo.fbo = static_cast<int>(fbo->handle());
        mpvFbo.w = fbo->size().width();
        mpvFbo.h = fbo->size().height();

        // Qt6 RHI(OpenGL) 后端在合成 QQuickFramebufferObject 纹理时已经做了
        // Y 翻转，mpv 这里不能再翻，否则双重翻转导致画面上下颠倒。
        // （已用 FBO 转储验证：flip=1 时 FBO 内容为正像，而屏幕显示为倒像）
        int flipY = 0;
        mpv_render_param renderParams[] = {
            { MPV_RENDER_PARAM_OPENGL_FBO, &mpvFbo },
            { MPV_RENDER_PARAM_FLIP_Y, &flipY },
            { MPV_RENDER_PARAM_INVALID, nullptr },
        };
        mpv_render_context_render(m_ctx, renderParams);
    }

private:
    static void onMpvRedraw(void *ctx)
    {
        auto *self = static_cast<MpvRenderer *>(ctx);
        // mpv 内部线程 → 排队到 GUI 线程触发重绘
        QMetaObject::invokeMethod(self->m_obj, "update", Qt::QueuedConnection);
    }

    MpvObject *m_obj = nullptr;
    mpv_render_context *m_ctx = nullptr;
    bool m_failed = false;
};

MpvObject::MpvObject(QQuickItem *parent)
    : QQuickFramebufferObject(parent)
{
    m_mpv = mpv_create();
    if (!m_mpv) {
        qWarning() << "[SimplePlayer] mpv_create failed";
        return;
    }

    // render API 的前提：vo 必须为 libmpv
    mpv_set_option_string(m_mpv, "vo", "libmpv");
    // macOS 上 auto 即走 VideoToolbox 硬解
    mpv_set_option_string(m_mpv, "hwdec", "auto");
    // 播放结束后保持最后一帧
    mpv_set_option_string(m_mpv, "keep-open", "yes");
    // 嵌入式内核不需要终端输出
    mpv_set_option_string(m_mpv, "terminal", "no");
    // 自动加载同名字幕（视频.mp4 旁边的 视频.srt / 视频.zh.srt 等）
    mpv_set_option_string(m_mpv, "sub-auto", "fuzzy");
    // 网络流抗卡顿：缓存不足时多等一会儿再恢复，避免「缓冲→播放」反复抖动
    mpv_set_option_string(m_mpv, "cache-pause", "yes");
    mpv_set_option_string(m_mpv, "cache-pause-wait", "3");
    // HTTP / HLS 连接中断后自动重连，而不是直接结束播放
    mpv_set_option_string(m_mpv, "stream-lavf-o",
                          "reconnect=1,reconnect_streamed=1,reconnect_delay_max=5");

    if (mpv_initialize(m_mpv) < 0) {
        qWarning() << "[SimplePlayer] mpv_initialize failed";
        mpv_terminate_destroy(m_mpv);
        m_mpv = nullptr;
        return;
    }

    mpv_set_wakeup_callback(m_mpv, &MpvObject::mpvWakeup, this);

    // 供「关于」对话框展示
    if (char *v = mpv_get_property_string(m_mpv, "mpv-version")) {
        m_mpvVersion = QString::fromUtf8(v);
        mpv_free(v);
        if (m_mpvVersion.startsWith(QStringLiteral("mpv ")))
            m_mpvVersion.remove(0, 4);
        emit mpvVersionChanged();
    }

    mpv_observe_property(m_mpv, 1, "time-pos", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 2, "duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 3, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, 4, "media-title", MPV_FORMAT_STRING);
    mpv_observe_property(m_mpv, 5, "volume", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 6, "core-idle", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, 7, "paused-for-cache", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, 8, "width", MPV_FORMAT_INT64);
    mpv_observe_property(m_mpv, 9, "height", MPV_FORMAT_INT64);
    mpv_observe_property(m_mpv, 10, "track-list", MPV_FORMAT_NODE);
    mpv_observe_property(m_mpv, 12, "sub-delay", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 13, "sub-scale", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 14, "sub-pos", MPV_FORMAT_DOUBLE);
    // 流健康指标
    mpv_observe_property(m_mpv, 15, "demuxer-cache-duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 16, "cache-speed", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 17, "cache-buffering-state", MPV_FORMAT_INT64);
    mpv_observe_property(m_mpv, 18, "frame-drop-count", MPV_FORMAT_INT64);
    mpv_observe_property(m_mpv, 19, "decoder-frame-drop-count", MPV_FORMAT_INT64);
    mpv_observe_property(m_mpv, 20, "video-bitrate", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 21, "container-fps", MPV_FORMAT_DOUBLE);
}

MpvObject::~MpvObject()
{
    if (m_mpv)
        mpv_terminate_destroy(m_mpv);
}

QQuickFramebufferObject::Renderer *MpvObject::createRenderer() const
{
    return new MpvRenderer(const_cast<MpvObject *>(this));
}

void MpvObject::mpvWakeup(void *ctx)
{
    auto *self = static_cast<MpvObject *>(ctx);
    QMetaObject::invokeMethod(self, &MpvObject::handleMpvEvents, Qt::QueuedConnection);
}

void MpvObject::handleMpvEvents()
{
    if (!m_mpv)
        return;

    while (true) {
        mpv_event *event = mpv_wait_event(m_mpv, 0);
        if (event->event_id == MPV_EVENT_NONE)
            break;

        switch (event->event_id) {
        case MPV_EVENT_PROPERTY_CHANGE: {
            auto *prop = static_cast<mpv_event_property *>(event->data);
            if (!std::strcmp(prop->name, "time-pos")) {
                if (prop->format == MPV_FORMAT_DOUBLE) {
                    const double v = *static_cast<double *>(prop->data);
                    m_position = std::isfinite(v) ? v : 0.0;
                    emit positionChanged();
                }
            } else if (!std::strcmp(prop->name, "duration")) {
                if (prop->format == MPV_FORMAT_DOUBLE) {
                    m_duration = *static_cast<double *>(prop->data);
                    emit durationChanged();
                }
            } else if (!std::strcmp(prop->name, "pause")) {
                if (prop->format == MPV_FORMAT_FLAG) {
                    m_paused = *static_cast<int *>(prop->data);
                    emit pausedChanged();
                }
            } else if (!std::strcmp(prop->name, "media-title")) {
                if (prop->format == MPV_FORMAT_STRING) {
                    auto *str = *static_cast<char **>(prop->data);
                    m_mediaTitle = QString::fromUtf8(str);
                    emit mediaTitleChanged();
                }
            } else if (!std::strcmp(prop->name, "volume")) {
                if (prop->format == MPV_FORMAT_DOUBLE) {
                    m_volume = static_cast<int>(*static_cast<double *>(prop->data));
                    emit volumeChanged();
                }
            } else if (!std::strcmp(prop->name, "core-idle")) {
                if (prop->format == MPV_FORMAT_FLAG) {
                    m_coreIdle = *static_cast<int *>(prop->data);
                    updateLoading();
                }
            } else if (!std::strcmp(prop->name, "paused-for-cache")) {
                if (prop->format == MPV_FORMAT_FLAG) {
                    m_pausedForCache = *static_cast<int *>(prop->data);
                    updateLoading();
                    emit streamStatsChanged();
                }
            } else if (!std::strcmp(prop->name, "demuxer-cache-duration")
                       || !std::strcmp(prop->name, "cache-speed")
                       || !std::strcmp(prop->name, "cache-buffering-state")
                       || !std::strcmp(prop->name, "frame-drop-count")
                       || !std::strcmp(prop->name, "decoder-frame-drop-count")
                       || !std::strcmp(prop->name, "video-bitrate")
                       || !std::strcmp(prop->name, "container-fps")) {
                if (prop->data) {
                    if (prop->format == MPV_FORMAT_DOUBLE) {
                        const double v = *static_cast<double *>(prop->data);
                        if (!std::strcmp(prop->name, "demuxer-cache-duration"))
                            m_cacheDuration = v;
                        else if (!std::strcmp(prop->name, "cache-speed"))
                            m_cacheSpeed = v;
                        else if (!std::strcmp(prop->name, "video-bitrate"))
                            m_videoBitrate = v;
                        else
                            m_containerFps = v;
                    } else if (prop->format == MPV_FORMAT_INT64) {
                        const int v = static_cast<int>(*static_cast<int64_t *>(prop->data));
                        if (!std::strcmp(prop->name, "cache-buffering-state"))
                            m_cacheBufferingState = v;
                        else if (!std::strcmp(prop->name, "frame-drop-count"))
                            m_frameDropCount = v;
                        else
                            m_decoderFrameDropCount = v;
                    }
                }
                emit streamStatsChanged();
            } else if (!std::strcmp(prop->name, "width")
                       || !std::strcmp(prop->name, "height")) {
                if (prop->format == MPV_FORMAT_INT64) {
                    const int value = static_cast<int>(*static_cast<int64_t *>(prop->data));
                    if (!std::strcmp(prop->name, "width"))
                        m_videoWidth = value;
                    else
                        m_videoHeight = value;
                    emit videoSizeChanged();
                }
            } else if (!std::strcmp(prop->name, "track-list")
                       || !std::strcmp(prop->name, "sub-delay")
                       || !std::strcmp(prop->name, "sub-scale")
                       || !std::strcmp(prop->name, "sub-pos")) {
                applySubtitleProperty(prop->name, prop);
            }
            break;
        }
        case MPV_EVENT_FILE_LOADED: {
            m_pendingPlayback = false;
            m_mediaLoaded = true;
            emit mediaLoadedChanged();
            updateLoading();
            break;
        }
        case MPV_EVENT_END_FILE: {
            auto *ef = static_cast<mpv_event_end_file *>(event->data);
            // 换片时旧文件先收到 STOP；新文件还没加载完，此时不能清掉
            // loading / mediaLoaded，否则空闲态的「点击打开视频」会盖在画面上
            if (ef->reason != MPV_END_FILE_REASON_STOP) {
                m_pendingPlayback = false;
                updateLoading();
                resetStreamStats();
                if (m_mediaLoaded) {
                    m_mediaLoaded = false;
                    emit mediaLoadedChanged();
                }
                if (ef->reason == MPV_END_FILE_REASON_ERROR) {
                    qWarning() << "[SimplePlayer] file error:"
                               << mpv_error_string(ef->error);
                    emit fileError(QString::fromUtf8(mpv_error_string(ef->error)));
                } else if (ef->reason == MPV_END_FILE_REASON_EOF) {
                    emit fileEnded();
                }
            }
            break;
        }
        default:
            break;
        }
    }
}

void MpvObject::updateLoading()
{
    // pendingPlayback 只在 FILE_LOADED（或非换片的 END_FILE）时清除
    const bool loading = m_pendingPlayback || m_pausedForCache;
    if (loading == m_loading)
        return;

    m_loading = loading;
    emit loadingChanged();
}

void MpvObject::resetStreamStats()
{
    m_cacheDuration = -1.0;
    m_cacheSpeed = -1.0;
    m_cacheBufferingState = -1;
    m_frameDropCount = 0;
    m_decoderFrameDropCount = 0;
    m_videoBitrate = -1.0;
    m_containerFps = 0.0;
    emit streamStatsChanged();
}

void MpvObject::refreshSubtitleTracks()
{
    QVariantList tracks;
    int active = -1;

    if (m_mpv) {
        mpv_node root{};
        if (mpv_get_property(m_mpv, "track-list", MPV_FORMAT_NODE, &root) >= 0) {
            if (root.format == MPV_FORMAT_NODE_ARRAY && root.u.list) {
                for (int i = 0; i < root.u.list->num; ++i) {
                    const mpv_node &item = root.u.list->values[i];
                    if (nodeString(item, "type") != QLatin1String("sub"))
                        continue;

                    const int id = nodeString(item, "id").toInt();
                    const QString title = nodeString(item, "title");
                    const QString external = nodeString(item, "external-filename");
                    const QString lang = nodeString(item, "lang");

                    // 外挂字幕用文件名（mpv 给的 title 只有扩展名），内嵌字幕用 title/lang
                    QString label;
                    if (!external.isEmpty())
                        label = QFileInfo(external).completeBaseName();
                    if (label.isEmpty())
                        label = title;
                    if (label.isEmpty())
                        label = lang;
                    if (label.isEmpty())
                        label = tr("字幕 %1").arg(id);
                    else if (!external.isEmpty() && !lang.isEmpty())
                        label += QStringLiteral(" (") + lang + QStringLiteral(")");

                    tracks.append(QVariantMap{{QStringLiteral("id"), id},
                                              {QStringLiteral("title"), label}});

                    if (nodeFlag(item, "selected"))
                        active = id;
                }
            }
            mpv_free_node_contents(&root);
        }
    }

    if (tracks != m_subtitleTracks) {
        m_subtitleTracks = tracks;
        emit subtitleTracksChanged();
    }

    if (active != m_activeSubtitleId) {
        m_activeSubtitleId = active;
        emit subtitleStateChanged();
    }
}

void MpvObject::applySubtitleProperty(const char *name, const struct mpv_event_property *prop)
{
    if (!std::strcmp(name, "track-list")) {
        refreshSubtitleTracks();
        return;
    }

    if (!prop->data)
        return;

    bool changed = false;

    if (!std::strcmp(name, "sub-delay") && prop->format == MPV_FORMAT_DOUBLE) {
        const qreal delay = *static_cast<double *>(prop->data);
        if (std::abs(delay - m_subtitleDelay) > 1e-6) {
            m_subtitleDelay = delay;
            changed = true;
        }
    } else if (!std::strcmp(name, "sub-scale") && prop->format == MPV_FORMAT_DOUBLE) {
        const qreal scale = *static_cast<double *>(prop->data);
        if (std::abs(scale - m_subtitleScale) > 1e-6) {
            m_subtitleScale = scale;
            changed = true;
        }
    } else if (!std::strcmp(name, "sub-pos") && prop->format == MPV_FORMAT_DOUBLE) {
        const int pos = static_cast<int>(*static_cast<double *>(prop->data));
        if (pos != m_subtitlePosition) {
            m_subtitlePosition = pos;
            changed = true;
        }
    }

    if (changed)
        emit subtitleStateChanged();
}

void MpvObject::addSubtitle(const QUrl &url)
{
    if (!m_mpv)
        return;

    const QString path = url.isLocalFile() ? url.toLocalFile() : url.toString();
    if (path.isEmpty())
        return;

    const QByteArray path8 = path.toUtf8();
    const char *args[] = { "sub-add", path8.constData(), "select", nullptr };
    if (mpv_command(m_mpv, args) < 0)
        qWarning() << "[SimplePlayer] sub-add failed:" << path;
    else
        qInfo() << "[SimplePlayer] subtitle added:" << path;
}

void MpvObject::selectSubtitle(int sid)
{
    if (!m_mpv)
        return;

    if (sid < 0) {
        if (m_activeSubtitleId >= 0)
            m_lastSubtitleId = m_activeSubtitleId;
        mpv_set_property_string(m_mpv, "sid", "no");
        return;
    }

    m_lastSubtitleId = sid;
    int64_t id = sid;
    mpv_set_property(m_mpv, "sid", MPV_FORMAT_INT64, &id);
}

void MpvObject::toggleSubtitles()
{
    if (!m_mpv)
        return;

    if (m_activeSubtitleId >= 0) {
        selectSubtitle(-1);
        return;
    }

    // 恢复上次用过的轨道；它已不存在时退回第一条
    bool exists = false;
    for (const QVariant &track : m_subtitleTracks) {
        if (track.toMap().value(QStringLiteral("id")).toInt() == m_lastSubtitleId)
            exists = true;
    }

    int target = m_lastSubtitleId;
    if (!exists && !m_subtitleTracks.isEmpty())
        target = m_subtitleTracks.first().toMap().value(QStringLiteral("id")).toInt();

    if (target >= 0)
        selectSubtitle(target);
}

void MpvObject::changeSubtitleDelay(qreal delta)
{
    if (!m_mpv)
        return;

    double value = qBound(-30.0, m_subtitleDelay + delta, 30.0);
    mpv_set_property(m_mpv, "sub-delay", MPV_FORMAT_DOUBLE, &value);
}

void MpvObject::resetSubtitleDelay()
{
    if (!m_mpv)
        return;

    double value = 0.0;
    mpv_set_property(m_mpv, "sub-delay", MPV_FORMAT_DOUBLE, &value);
}

void MpvObject::changeSubtitleScale(qreal delta)
{
    if (!m_mpv)
        return;

    double value = qBound(0.4, m_subtitleScale + delta, 3.0);
    mpv_set_property(m_mpv, "sub-scale", MPV_FORMAT_DOUBLE, &value);
}

void MpvObject::changeSubtitlePosition(int delta)
{
    if (!m_mpv)
        return;

    double value = qBound(0.0, static_cast<double>(m_subtitlePosition + delta), 150.0);
    mpv_set_property(m_mpv, "sub-pos", MPV_FORMAT_DOUBLE, &value);
}

void MpvObject::resetSubtitleStyle()
{
    if (!m_mpv)
        return;

    double delay = 0.0;
    double scale = 1.0;
    double pos = 100.0;
    mpv_set_property(m_mpv, "sub-delay", MPV_FORMAT_DOUBLE, &delay);
    mpv_set_property(m_mpv, "sub-scale", MPV_FORMAT_DOUBLE, &scale);
    mpv_set_property(m_mpv, "sub-pos", MPV_FORMAT_DOUBLE, &pos);
}

void MpvObject::load(const QString &url)
{
    if (!m_mpv)
        return;

    const QUrl parsed(url);
    const QString target = parsed.isLocalFile() ? parsed.toLocalFile() : url;
    const QString scheme = parsed.scheme().toLower();
    const bool network = scheme == QLatin1String("http")
                      || scheme == QLatin1String("https")
                      || scheme == QLatin1String("rtsp")
                      || scheme == QLatin1String("rtmp")
                      || scheme == QLatin1String("rtmps")
                      || scheme == QLatin1String("mms")
                      || scheme == QLatin1String("ftp");
    if (network != m_networkStream) {
        m_networkStream = network;
        emit networkStreamChanged();
    }

    m_pendingPlayback = true;
    updateLoading();

    ++m_loadSerial;
    emit loadSerialChanged();

    if (m_videoWidth != 0 || m_videoHeight != 0) {
        m_videoWidth = 0;
        m_videoHeight = 0;
        emit videoSizeChanged();
    }

    // 换片后字幕轨道与微调参数都回到默认，避免上一部片的状态残留
    if (!m_subtitleTracks.isEmpty()) {
        m_subtitleTracks.clear();
        emit subtitleTracksChanged();
    }
    resetSubtitleStyle();
    resetStreamStats();

    // vo=libmpv 要求先有 mpv_render_context，否则 VO 初始化失败、视频被禁用。
    // 首帧渲染完成前到达的加载请求先排队。
    if (!m_renderReady) {
        m_pendingUrl = url;
        qInfo() << "[SimplePlayer] render context not ready, pending:" << url;
        return;
    }

    // 注意：QByteArray 必须具名持有，否则 constData() 悬空（临时对象语句末销毁）
    const QByteArray target8 = target.toUtf8();
    const char *args[] = { "loadfile", target8.constData(), nullptr };
    if (mpv_command(m_mpv, args) < 0)
        qWarning() << "[SimplePlayer] loadfile failed:" << url;
    else
        qInfo() << "[SimplePlayer] load:" << target;
}

void MpvObject::handleRenderReady()
{
    m_renderReady = true;
    if (!m_pendingUrl.isEmpty()) {
        const QString url = m_pendingUrl;
        m_pendingUrl.clear();
        load(url);
    }
}

void MpvObject::playPause()
{
    if (!m_mpv)
        return;
    int flag = !m_paused;
    mpv_set_property(m_mpv, "pause", MPV_FORMAT_FLAG, &flag);
}

void MpvObject::play()
{
    if (!m_mpv)
        return;
    int flag = 0;
    mpv_set_property(m_mpv, "pause", MPV_FORMAT_FLAG, &flag);
}

void MpvObject::pause()
{
    if (!m_mpv)
        return;
    int flag = 1;
    mpv_set_property(m_mpv, "pause", MPV_FORMAT_FLAG, &flag);
}

void MpvObject::seekTo(qreal seconds)
{
    if (!m_mpv)
        return;
    const QByteArray target = QByteArray::number(seconds);
    const char *args[] = { "seek", target.constData(), "absolute", "exact", nullptr };
    mpv_command(m_mpv, args);
}

void MpvObject::seekRelative(qreal seconds)
{
    if (!m_mpv)
        return;
    const QByteArray delta = QByteArray::number(seconds);
    const char *args[] = { "seek", delta.constData(), "relative", "exact", nullptr };
    mpv_command(m_mpv, args);
}

void MpvObject::setVolume(int volume)
{
    if (!m_mpv)
        return;
    const int v = qBound(0, volume, 130);
    double dv = v;
    if (mpv_set_property(m_mpv, "volume", MPV_FORMAT_DOUBLE, &dv) < 0)
        return;
    if (m_volume != v) {
        m_volume = v;
        emit volumeChanged();
    }
}

void MpvObject::setHardwareDecoding(bool on)
{
    if (m_hardwareDecoding == on)
        return;
    m_hardwareDecoding = on;
    if (m_mpv) {
        // 保持 QByteArray 生命周期至调用结束，避免悬空指针
        const QByteArray value = on ? QByteArrayLiteral("auto") : QByteArrayLiteral("no");
        mpv_set_property_string(m_mpv, "hwdec", value.constData());
    }
    emit hardwareDecodingChanged();
}

void MpvObject::setLoopPlayback(bool on)
{
    if (m_loopPlayback == on)
        return;
    m_loopPlayback = on;
    if (m_mpv) {
        const QByteArray value = on ? QByteArrayLiteral("inf") : QByteArrayLiteral("no");
        mpv_set_property_string(m_mpv, "loop-file", value.constData());
    }
    emit loopPlaybackChanged();
}

void MpvObject::setNetworkCache(int seconds)
{
    if (m_networkCache == seconds)
        return;
    m_networkCache = seconds;
    if (m_mpv) {
        const QByteArray value = QByteArray::number(seconds);
        mpv_set_property_string(m_mpv, "cache-secs", value.constData());
    }
    emit networkCacheChanged();
}
