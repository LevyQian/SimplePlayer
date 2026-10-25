#include "MacWindowHelper.h"

#import <Cocoa/Cocoa.h>

#include <QQuickWindow>

MacWindowHelper::MacWindowHelper(QObject *parent)
    : QObject(parent)
{
}

void MacWindowHelper::lockWindow(QObject *window)
{
    auto *quickWindow = qobject_cast<QQuickWindow *>(window);
    if (!quickWindow)
        return;

    // winId() 在 macOS 上返回 NSView*
    NSView *view = reinterpret_cast<NSView *>(quickWindow->winId());
    NSWindow *nsWindow = view.window;
    if (!nsWindow)
        return;

    // 不可缩放：去掉 resizable / miniaturizable
    nsWindow.styleMask &= ~(NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable);
    // 禁用绿色按钮的全屏行为
    nsWindow.collectionBehavior &= ~NSWindowCollectionBehaviorFullScreenPrimary;
    // 直接隐藏最小化与缩放按钮
    [nsWindow standardWindowButton:NSWindowMiniaturizeButton].hidden = YES;
    [nsWindow standardWindowButton:NSWindowZoomButton].hidden = YES;
}
