#include "NativeMenuBar.h"
#include "NativeMenuBarStrings.h"

#include <QCoreApplication>
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

void NativeMenuBar::install()
{
    @autoreleasepool {
        NSMenu *mainMenu = [NSApp mainMenu];
        if (!mainMenu) {
            mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];
            [NSApp setMainMenu:mainMenu];
        }

        // 移除上一次安装的菜单（语言切换后重建）
        for (NSMenuItem *item in [mainMenu.itemArray copy]) {
            if ([item.representedObject isEqualToString:kMenuTag])
                [mainMenu removeItem:item];
        }

        SPNativeMenuTarget *target = [[SPNativeMenuTarget alloc] init];
        target.owner = this;

        // ---- 文件 ----
        NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:trLabel("文件")];
        auto addItem = ^(NSMenu *menu, const char *label, MenuAction action,
                         NSString *key, BOOL enabled) {
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:trLabel(label)
                                                          action:@selector(handleAction:)
                                                   keyEquivalent:key];
            item.target = target;
            item.tag = action;
            item.enabled = enabled;
            [menu addItem:item];
        };

        addItem(fileMenu, "打开文件…", ActionOpenFile, @"o", YES);
        addItem(fileMenu, "打开链接…", ActionOpenUrl, @"l", YES);
        addItem(fileMenu, "打开流媒体…", ActionOpenStream, @"", YES);
        addItem(fileMenu, "设置…", ActionSettings, @",", YES);
        [fileMenu addItem:[NSMenuItem separatorItem]];
        addItem(fileMenu, "退出", ActionQuit, @"q", YES);

        NSMenuItem *fileRoot = [[NSMenuItem alloc] initWithTitle:trLabel("文件")
                                                          action:nil
                                                   keyEquivalent:@""];
        fileRoot.submenu = fileMenu;
        fileRoot.representedObject = kMenuTag;
        [mainMenu insertItem:fileRoot atIndex:(mainMenu.numberOfItems > 0 ? 1 : 0)];

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
        [mainMenu insertItem:subtitleRoot atIndex:[mainMenu indexOfItem:fileRoot] + 1];

        // ---- 帮助（放在末尾，符合 macOS 习惯） ----
        NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:trLabel("帮助")];
        addItem(helpMenu, "简播 帮助", ActionHelp, @"/", YES);
        addItem(helpMenu, "关于简播", ActionAbout, @"", YES);

        NSMenuItem *helpRoot = [[NSMenuItem alloc] initWithTitle:trLabel("帮助")
                                                          action:nil
                                                   keyEquivalent:@""];
        helpRoot.submenu = helpMenu;
        helpRoot.representedObject = kMenuTag;
        [mainMenu addItem:helpRoot];

        // 应用菜单里 Qt 默认的「Preferences…」接到设置对话框，同时按 macOS 习惯改名
        NSMenuItem *appMenuRoot = mainMenu.itemArray.firstObject;
        for (NSMenuItem *item in appMenuRoot.submenu.itemArray) {
            if ([item.keyEquivalent isEqualToString:@","]) {
                item.title = trLabel("设置…");
                item.target = target;
                item.tag = ActionSettings;
            }
        }
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
