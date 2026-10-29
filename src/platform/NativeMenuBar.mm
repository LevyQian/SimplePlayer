#include "NativeMenuBar.h"
#include "NativeMenuBarStrings.h"
#include "../update/UpdateChecker.h"

#include <QCoreApplication>
#include <QSettings>
#include <QTimer>
#include <QVariantMap>

#import <Cocoa/Cocoa.h>

namespace {

/// 菜单项动作编号，与 NativeMenuBar::trigger() 的 switch 保持一致
enum MenuAction {
    ActionOpenFile = 100,
    ActionOpenUrl,
    ActionOpenStream,
    ActionSettings,
    ActionQuit,
    ActionHelp,
    ActionAbout,

    ActionCheckUpdate = 110,   // 检查更新 / 下载进度 / 更新按钮（复用一个菜单项）

    ActionSubtitleLoad = 200,
    ActionSubtitleOff,
    ActionSubtitleDelayUp,
    ActionSubtitleDelayDown,
    ActionSubtitleDelayReset,
    ActionSubtitleScaleUp,
    ActionSubtitleScaleDown,
    ActionSubtitlePosUp,
    ActionSubtitlePosDown,
    ActionSubtitleReset,
    /// 具体字幕轨道：tag = ActionSubtitleTrackBase + 序号
    ActionSubtitleTrackBase = 300,
};

/// 用于标记「由本应用安装的菜单」，语言切换重建时据此移除旧菜单
NSString *const kMenuTag = @"SimplePlayerMenu";

NSString *trLabel(const char *source)
{
    return QCoreApplication::translate("NativeMenu", source).toNSString();
}

QString qstringFrom(NSString *s)
{
    return QString::fromUtf8([s UTF8String]);
}

} // namespace

/// NSMenu 的 target：点击后回调 C++ 侧
@interface SPNativeMenuTarget : NSObject
@property (nonatomic, assign) NativeMenuBar *owner;
- (void)handleAction:(NSMenuItem *)sender;
@end

@implementation SPNativeMenuTarget

- (void)handleAction:(NSMenuItem *)sender
{
    if (self.owner)
        self.owner->trigger(static_cast<int>(sender.tag));
}

@end

NativeMenuBar::NativeMenuBar(QObject *parent)
    : QObject(parent)
{
}

NativeMenuBar::~NativeMenuBar()
{
    m_updateItem = nullptr;
}

void NativeMenuBar::setUpdateChecker(UpdateChecker *checker)
{
    if (m_updateChecker) {
        m_updateChecker->disconnect(this);
    }

    m_updateChecker = checker;
    if (!checker) return;

    auto updateItem = [this]() -> NSMenuItem * {
        return static_cast<NSMenuItem *>(m_updateItem);
    };

    connect(checker, &UpdateChecker::checking, this, [this, updateItem] {
        if (auto *item = updateItem()) {
            item.title = trLabel("检查更新中...");
            item.enabled = NO;
        }
    });

    connect(checker, &UpdateChecker::updateAvailable, this,
            [this, updateItem](const QString &tagName, const QString &, qint64) {
                // 检查用户是否已忽略此版本
                const QString ignored = QSettings().value(
                    QStringLiteral("player/ignoredUpdate")).toString();
                if (tagName == ignored) {
                    // 忽略版本：菜单还原为"检查更新"
                    if (auto *item = updateItem()) {
                        item.title = trLabel("检查更新");
                        item.enabled = YES;
                    }
                    return;
                }

                // QML 绑定的 Q_PROPERTY
                m_updateAvailable = true;
                m_updateTagName = tagName;
                m_updateDownloading = false;
                m_updateDownloadPercent = 0;
                emitUpdateStateChanged();

                // 菜单项：有新版本 → "查看新版本"
                if (auto *item = updateItem()) {
                    item.title = trLabel("查看新版本");
                    item.enabled = YES;
                }
            });

    connect(checker, &UpdateChecker::noUpdateAvailable, this, [this, updateItem] {
        m_updateAvailable = false;
        m_updateTagName.clear();
        m_updateDownloading = false;
        m_updateDownloadPercent = 0;
        emitUpdateStateChanged();

        if (auto *item = updateItem()) {
            item.title = trLabel("已是最新版本");
            item.enabled = NO;
        }
        QTimer::singleShot(2000, this, [this, updateItem] {
            if (auto *item = updateItem()) {
                item.title = trLabel("检查更新");
                item.enabled = YES;
            }
        });
    });

    connect(checker, &UpdateChecker::errorOccurred, this,
            [this, updateItem](const QString &) {
                m_updateAvailable = false;
                m_updateDownloading = false;
                emitUpdateStateChanged();

                if (auto *item = updateItem()) {
                    item.title = trLabel("检查更新失败");
                    item.enabled = YES;
                }
                QTimer::singleShot(2000, this, [this, updateItem] {
                    if (auto *item = updateItem()) {
                        item.title = trLabel("检查更新");
                        item.enabled = YES;
                    }
                });
            });

    connect(checker, &UpdateChecker::downloadProgress, this,
            [this, updateItem](int percent) {
                m_updateDownloading = true;
                m_updateDownloadPercent = percent;
                emitUpdateStateChanged();

                if (auto *item = updateItem()) {
                    item.title = [NSString stringWithFormat:@"%@ %d%%",
                                  trLabel("下载中…"), percent];
                    item.enabled = NO;
                }
            });

    connect(checker, &UpdateChecker::downloadFinished, this,
            [this, updateItem](const QString &dmgPath) {
                m_pendingDmgPath = dmgPath;
                m_updateDownloading = false;
                m_updateDownloadPercent = 100;
                emitUpdateStateChanged();

                if (auto *item = updateItem()) {
                    item.title = trLabel("更新到最新版本");
                    item.enabled = YES;
                }
            });

    connect(checker, &UpdateChecker::downloadCancelled, this, [this, updateItem] {
        m_updateDownloading = false;
        m_updateDownloadPercent = 0;
        emitUpdateStateChanged();

        if (auto *item = updateItem()) {
            item.title = trLabel("检查更新");
            item.enabled = YES;
        }
    });
}

void NativeMenuBar::install()
{
    @autoreleasepool {
        NSMenu *mainMenu = [NSApp mainMenu];
        if (!mainMenu) {
            mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];
            [NSApp setMainMenu:mainMenu];
        }

        // ---- 清空已有菜单 ----
        [mainMenu removeAllItems];
        m_updateItem = nullptr;

        SPNativeMenuTarget *target = [[SPNativeMenuTarget alloc] init];
        target.owner = this;

        auto addItem = ^(NSMenu *menu, const char *label, MenuAction action,
                         NSString *key, BOOL enabled) {
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:trLabel(label)
                                                          action:@selector(handleAction:)
                                                   keyEquivalent:key];
            item.target = target;
            item.tag = action;
            item.enabled = enabled;
            [menu addItem:item];
            return item;
        };

        // ========== 应用菜单（第 1 位，macOS 自动加粗） ==========
        NSString *appName = NSBundle.mainBundle.infoDictionary[@"CFBundleName"];
        if (appName.length == 0) appName = @"SimplePlayer";

        NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];
        addItem(appMenu, "关于简播", ActionAbout, @"", YES);
        [appMenu addItem:[NSMenuItem separatorItem]];

        // ---- 检查更新菜单项 ----
        {
            NSMenuItem *updateItem = addItem(appMenu, "检查更新", ActionCheckUpdate, @"", YES);
            m_updateItem = updateItem;
        }
        [appMenu addItem:[NSMenuItem separatorItem]];

        addItem(appMenu, "设置…", ActionSettings, @",", YES);
        [appMenu addItem:[NSMenuItem separatorItem]];

        // macOS 标准的 隐藏 / 隐藏其他 / 全部显示
        NSMenuItem *hideItem = [[NSMenuItem alloc] initWithTitle:
            QCoreApplication::translate("NativeMenu", "隐藏").toNSString()
            action:@selector(hide:) keyEquivalent:@"h"];
        hideItem.target = NSApp;
        [appMenu addItem:hideItem];

        NSMenuItem *hideOther = [[NSMenuItem alloc] initWithTitle:
            QCoreApplication::translate("NativeMenu", "隐藏其他").toNSString()
            action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
        hideOther.keyEquivalentModifierMask = NSEventModifierFlagOption | NSEventModifierFlagCommand;
        hideOther.target = NSApp;
        [appMenu addItem:hideOther];

        NSMenuItem *showAll = [[NSMenuItem alloc] initWithTitle:
            QCoreApplication::translate("NativeMenu", "全部显示").toNSString()
            action:@selector(unhideAllApplications:) keyEquivalent:@""];
        showAll.target = NSApp;
        [appMenu addItem:showAll];

        [appMenu addItem:[NSMenuItem separatorItem]];
        addItem(appMenu, "退出", ActionQuit, @"q", YES);

        NSMenuItem *appRoot = [[NSMenuItem alloc] initWithTitle:appName
                                                         action:nil
                                                  keyEquivalent:@""];
        appRoot.submenu = appMenu;
        appRoot.representedObject = kMenuTag;
        [mainMenu addItem:appRoot];  // index 0 —— macOS 自动加粗

        // ---- 文件 ----
        NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:trLabel("文件")];

        addItem(fileMenu, "打开文件…", ActionOpenFile, @"o", YES);
        addItem(fileMenu, "打开链接…", ActionOpenUrl, @"l", YES);
        addItem(fileMenu, "打开流媒体…", ActionOpenStream, @"", YES);
        [fileMenu addItem:[NSMenuItem separatorItem]];
        addItem(fileMenu, "退出", ActionQuit, @"q", YES);

        NSMenuItem *fileRoot = [[NSMenuItem alloc] initWithTitle:trLabel("文件")
                                                          action:nil
                                                   keyEquivalent:@""];
        fileRoot.submenu = fileMenu;
        fileRoot.representedObject = kMenuTag;
        [mainMenu addItem:fileRoot];  // index 1

        // ---- 字幕 ----
        NSMenu *subtitleMenu = [[NSMenu alloc] initWithTitle:trLabel("字幕")];

        auto addStateItem = ^(const char *label, MenuAction action, BOOL checked, BOOL enabled) {
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:trLabel(label)
                                                          action:@selector(handleAction:)
                                                   keyEquivalent:@""];
            item.target = target;
            item.tag = action;
            item.enabled = enabled;
            item.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
            [subtitleMenu addItem:item];
        };

        auto addTrackItem = ^(const QString &label, MenuAction action, BOOL checked) {
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:label.toNSString()
                                                          action:@selector(handleAction:)
                                                   keyEquivalent:@""];
            item.target = target;
            item.tag = action;
            item.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
            [subtitleMenu addItem:item];
        };

        addItem(subtitleMenu, "加载字幕文件…", ActionSubtitleLoad, @"S", YES);
        [subtitleMenu addItem:[NSMenuItem separatorItem]];

        const bool hasTracks = !m_subtitleTracks.isEmpty();
        addStateItem("无字幕", ActionSubtitleOff, m_activeSubtitle < 0, hasTracks);
        for (int i = 0; i < m_subtitleTracks.size(); ++i) {
            const QVariantMap track = m_subtitleTracks.at(i).toMap();
            const int sid = track.value(QStringLiteral("id")).toInt();
            addTrackItem(track.value(QStringLiteral("title")).toString(),
                         static_cast<MenuAction>(ActionSubtitleTrackBase + i),
                         sid == m_activeSubtitle);
        }

        [subtitleMenu addItem:[NSMenuItem separatorItem]];
        addItem(subtitleMenu, "字幕延迟 +0.5 秒", ActionSubtitleDelayUp, @"", hasTracks);
        addItem(subtitleMenu, "字幕延迟 −0.5 秒", ActionSubtitleDelayDown, @"", hasTracks);
        addItem(subtitleMenu, "重置字幕延迟", ActionSubtitleDelayReset, @"", hasTracks);
        [subtitleMenu addItem:[NSMenuItem separatorItem]];
        addItem(subtitleMenu, "放大字幕", ActionSubtitleScaleUp, @"=", hasTracks);
        addItem(subtitleMenu, "缩小字幕", ActionSubtitleScaleDown, @"-", hasTracks);
        addItem(subtitleMenu, "字幕上移", ActionSubtitlePosUp, @"", hasTracks);
        addItem(subtitleMenu, "字幕下移", ActionSubtitlePosDown, @"", hasTracks);
        [subtitleMenu addItem:[NSMenuItem separatorItem]];
        addItem(subtitleMenu, "重置字幕样式", ActionSubtitleReset, @"", hasTracks);

        NSMenuItem *subtitleRoot = [[NSMenuItem alloc] initWithTitle:trLabel("字幕")
                                                              action:nil
                                                       keyEquivalent:@""];
        subtitleRoot.submenu = subtitleMenu;
        subtitleRoot.representedObject = kMenuTag;
        [mainMenu addItem:subtitleRoot];  // index 2

        // ---- 帮助 ----
        NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:trLabel("帮助")];
        addItem(helpMenu, "简播 帮助", ActionHelp, @"/", YES);

        NSMenuItem *helpRoot = [[NSMenuItem alloc] initWithTitle:trLabel("帮助")
                                                          action:nil
                                                   keyEquivalent:@""];
        helpRoot.submenu = helpMenu;
        helpRoot.representedObject = kMenuTag;
        [mainMenu addItem:helpRoot];  // index 3
    }
}

void NativeMenuBar::setSubtitleState(const QVariantList &tracks, int activeId)
{
    if (tracks == m_subtitleTracks && activeId == m_activeSubtitle)
        return;

    m_subtitleTracks = tracks;
    m_activeSubtitle = activeId;
    install();
}

void NativeMenuBar::trigger(int actionId)
{
    switch (actionId) {
    case ActionOpenFile:
        emit openFileRequested();
        break;
    case ActionOpenUrl:
        emit openUrlRequested();
        break;
    case ActionOpenStream:
        emit openStreamRequested();
        break;
    case ActionSettings:
        emit settingsRequested();
        break;
    case ActionQuit:
        emit quitRequested();
        break;
    case ActionHelp:
        emit helpRequested();
        break;
    case ActionAbout:
        emit aboutRequested();
        break;

    case ActionCheckUpdate: {
        if (!m_pendingDmgPath.isEmpty()) {
            // 下载完成 → 执行自更新
            const QString path = m_pendingDmgPath;
            m_pendingDmgPath.clear();
            emit doUpdateRequested(path);
        } else if (m_updateAvailable) {
            // 有更新待处理 → 弹 QML 对话框让用户选择
            emit showUpdateDialogRequested();
        } else if (m_updateChecker) {
            // 空闲态 → 主动去检查
            m_updateChecker->checkForUpdate();
        }
        break;
    }

    case ActionSubtitleLoad:
        emit subtitleActionRequested(QStringLiteral("load"), 0);
        break;
    case ActionSubtitleOff:
        emit subtitleActionRequested(QStringLiteral("off"), 0);
        break;
    case ActionSubtitleDelayUp:
        emit subtitleActionRequested(QStringLiteral("delay-up"), 0);
        break;
    case ActionSubtitleDelayDown:
        emit subtitleActionRequested(QStringLiteral("delay-down"), 0);
        break;
    case ActionSubtitleDelayReset:
        emit subtitleActionRequested(QStringLiteral("delay-reset"), 0);
        break;
    case ActionSubtitleScaleUp:
        emit subtitleActionRequested(QStringLiteral("scale-up"), 0);
        break;
    case ActionSubtitleScaleDown:
        emit subtitleActionRequested(QStringLiteral("scale-down"), 0);
        break;
    case ActionSubtitlePosUp:
        emit subtitleActionRequested(QStringLiteral("pos-up"), 0);
        break;
    case ActionSubtitlePosDown:
        emit subtitleActionRequested(QStringLiteral("pos-down"), 0);
        break;
    case ActionSubtitleReset:
        emit subtitleActionRequested(QStringLiteral("reset"), 0);
        break;

    default:
        if (actionId >= ActionSubtitleTrackBase) {
            const int index = actionId - ActionSubtitleTrackBase;
            if (index >= 0 && index < m_subtitleTracks.size()) {
                const int sid = m_subtitleTracks.at(index)
                                    .toMap()
                                    .value(QStringLiteral("id"))
                                    .toInt();
                emit subtitleActionRequested(QStringLiteral("track"), sid);
            }
        }
        break;
    }
}

void NativeMenuBar::ignoreUpdate()
{
    if (m_updateTagName.isEmpty()) return;

    QSettings().setValue(QStringLiteral("player/ignoredUpdate"), m_updateTagName);

    // 清掉 QML 绑定的状态 + 还原菜单项
    m_updateAvailable = false;
    m_updateTagName.clear();
    m_updateDownloading = false;
    m_updateDownloadPercent = 0;
    emitUpdateStateChanged();

    if (auto *item = static_cast<NSMenuItem *>(m_updateItem)) {
        item.title = trLabel("检查更新");
        item.enabled = YES;
    }
}

void NativeMenuBar::startUpdateDownload()
{
    if (m_updateChecker) {
        m_updateChecker->startDownload();
    }
}

void NativeMenuBar::activateUpdateEntry()
{
    trigger(ActionCheckUpdate);
}
