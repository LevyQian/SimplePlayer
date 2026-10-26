#include "NativeMenuBar.h"
#include "NativeMenuBarStrings.h"

#include <QCoreApplication>

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
    default:
        break;
    }
}
