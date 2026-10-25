#include "MpvObject.h"

#include <QByteArray>
#include <QDebug>
#include <QMetaObject>
#include <QOpenGLContext>
#include <QOpenGLFramebufferObject>

#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>

#include <cmath>
#include <cstring>

namespace {

void *getProcAddressMpv(void *ctx, const char *name)
{
    auto *glctx = static_cast<QOpenGLContext *>(ctx);
    return reinterpret_cast<void *>(glctx->getProcAddress(name));
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

        // QQuickFramebufferObject 的纹理 Y 方向与 GL 原点相反，需要翻转
        int flipY = 1;
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

    if (mpv_initialize(m_mpv) < 0) {
        qWarning() << "[SimplePlayer] mpv_initialize failed";
        mpv_terminate_destroy(m_mpv);
        m_mpv = nullptr;
        return;
    }

    mpv_set_wakeup_callback(m_mpv, &MpvObject::mpvWakeup, this);

    mpv_observe_property(m_mpv, 1, "time-pos", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 2, "duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 3, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, 4, "media-title", MPV_FORMAT_STRING);
    mpv_observe_property(m_mpv, 5, "volume", MPV_FORMAT_DOUBLE);
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
            }
            break;
        }
        case MPV_EVENT_END_FILE: {
            auto *ef = static_cast<mpv_event_end_file *>(event->data);
            if (ef->reason == MPV_END_FILE_REASON_ERROR) {
                qWarning() << "[SimplePlayer] file error:" << mpv_error_string(ef->error);
                emit fileError(QString::fromUtf8(mpv_error_string(ef->error)));
            } else if (ef->reason == MPV_END_FILE_REASON_EOF) {
                emit fileEnded();
            }
            break;
        }
        default:
            break;
        }
    }
}

void MpvObject::load(const QString &url)
{
    if (!m_mpv)
        return;

    // vo=libmpv 要求先有 mpv_render_context，否则 VO 初始化失败、视频被禁用。
    // 首帧渲染完成前到达的加载请求先排队。
    if (!m_renderReady) {
        m_pendingUrl = url;
        qInfo() << "[SimplePlayer] render context not ready, pending:" << url;
        return;
    }

    const QUrl parsed(url);
    const QString target = parsed.isLocalFile() ? parsed.toLocalFile() : url;

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
