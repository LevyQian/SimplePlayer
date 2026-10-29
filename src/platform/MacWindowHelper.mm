#include "MacWindowHelper.h"

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

#include <QCoreApplication>
#include <QQuickWindow>

namespace {

/// 关联对象 key：把点击 target 绑在按钮上，保证其生命周期
const char kUpdateTargetKey = 0;

/// 标题栏 accessory 容器 / 按钮尺寸（按钮固定高度，在容器内四向居中）
constexpr CGFloat kAccessoryWidth  = 104.0;
constexpr CGFloat kAccessoryHeight =  28.0; // macOS titlebar accessory 标准高度
constexpr CGFloat kButtonHeight    =  22.0; // 固定高度 → 上下各留 3pt，垂直居中
constexpr CGFloat kButtonPadX      =   9.0; // 内容左右留白
constexpr CGFloat kButtonCornerRadius = 6.5; // 小圆角矩形（参考图样式，非半高胶囊）
constexpr CGFloat kIconHeight      =  14.0; // 图标绘制高度（上下各留约 4pt）
constexpr CGFloat kIconGap         =   4.0; // 图标与文字间距

} // namespace

/// 标题栏「更新」按钮：深灰圆角背景 + 白色图标/文字，内容自绘并四边留白，
/// 带 hover / pressed 反馈，深色模式下自动反色
@interface SPUpdateButton : NSButton {
    BOOL _pressed;
    BOOL _hovering;
    NSTrackingArea *_trackingArea;
    NSColor *_fgColor; // 前景色（自绘图标与文字时使用，retain）
}
- (void)refreshStyle;
- (CGFloat)contentWidth; // 图标 + 间距 + 文字的实际宽度
@end

@implementation SPUpdateButton

- (instancetype)initWithFrame:(NSRect)frameRect
{
    if ((self = [super initWithFrame:frameRect])) {
        self.bordered = NO;
        self.buttonType = NSButtonTypeMomentaryChange;
        self.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        self.wantsLayer = YES;
        self.layer.cornerRadius = kButtonCornerRadius;

        _trackingArea = [[NSTrackingArea alloc]
            initWithRect:NSZeroRect
                 options:(NSTrackingMouseEnteredAndExited
                          | NSTrackingActiveAlways
                          | NSTrackingInVisibleRect)
                   owner:self
                userInfo:nil];
        [self addTrackingArea:_trackingArea];
        [self refreshStyle];
    }
    return self;
}

- (void)dealloc
{
    [_trackingArea release];
    [_fgColor release];
    [super dealloc];
}

- (BOOL)isDarkMode
{
    return [[self.effectiveAppearance
        bestMatchFromAppearancesWithNames:@[NSAppearanceNameDarkAqua,
                                            NSAppearanceNameAqua]]
        isEqualToString:NSAppearanceNameDarkAqua];
}

- (void)refreshStyle
{
    const BOOL dark = [self isDarkMode];

    // 前景（图标 + 文字）：浅色模式白色，深色模式近黑
    NSColor *fg = dark ? [NSColor colorWithWhite:0.10 alpha:1.0]
                       : [NSColor whiteColor];

    NSColor *bg;
    if (_pressed)
        bg = dark ? [NSColor colorWithWhite:0.72 alpha:1.0]
                  : [NSColor colorWithWhite:0.15 alpha:1.0];
    else if (_hovering)
        bg = dark ? [NSColor colorWithWhite:0.86 alpha:1.0]
                  : [NSColor colorWithWhite:0.30 alpha:1.0];
    else
        // 正常态：深灰（浅色模式）/ 浅灰（深色模式），贴近 macOS 原生 accessory 控件
        bg = dark ? [NSColor colorWithWhite:0.94 alpha:1.0]
                  : [NSColor colorWithWhite:0.20 alpha:1.0];

    [_fgColor release];
    _fgColor = [fg retain];

    self.layer.backgroundColor = bg.CGColor;
    [self setNeedsDisplay:YES];
}

- (void)viewDidChangeEffectiveAppearance
{
    [super viewDidChangeEffectiveAppearance];
    [self refreshStyle];
}

/// 图标绘制尺寸：按 kIconHeight 等比缩放，避免被拉伸变形
- (NSSize)iconDrawSize
{
    NSImage *icon = self.image;
    if (!icon)
        return NSZeroSize;
    const NSSize s = icon.size;
    if (s.height <= 0 || s.width <= 0)
        return NSZeroSize;
    return NSMakeSize(ceil(s.width / s.height * kIconHeight), kIconHeight);
}

- (CGFloat)contentWidth
{
    const NSSize icon = [self iconDrawSize];
    const NSSize text = [self.title sizeWithAttributes:@{NSFontAttributeName: self.font}];
    CGFloat w = icon.width + text.width;
    if (icon.width > 0 && text.width > 0)
        w += kIconGap;
    return w;
}

/// 自绘内容：整体居中 → 四边自然等距留白（NSButton 无边框样式没有内边距 API）
- (void)drawRect:(NSRect)dirtyRect
{
    (void)dirtyRect;

    const NSRect bounds = self.bounds;
    NSColor *fg = _fgColor ? _fgColor : [NSColor whiteColor];
    NSDictionary *attrs =
        @{NSForegroundColorAttributeName: fg,
          NSFontAttributeName: self.font};

    const NSSize iconSize = [self iconDrawSize];
    const NSSize textSize = [self.title sizeWithAttributes:attrs];
    const CGFloat contentW = [self contentWidth];

    // 内容整体水平居中 → 左右各留 (按钮宽 - 内容宽) / 2
    CGFloat x = rint((bounds.size.width - contentW) / 2);

    if (iconSize.width > 0) {
        NSImage *icon = self.image;
        // SF Symbol 是模板图，手动绘制需显式着色
        if (@available(macOS 12.0, *)) {
            icon = [icon imageWithSymbolConfiguration:
                [NSImageSymbolConfiguration configurationWithHierarchicalColor:fg]];
        }
        [icon drawInRect:NSMakeRect(x, rint((bounds.size.height - iconSize.height) / 2),
                                    iconSize.width, iconSize.height)
                 fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver
                 fraction:1.0
           respectFlipped:YES
                    hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
        x += iconSize.width + kIconGap;
    }

    if (self.title.length > 0) {
        // 文字垂直居中 → 上下各留 (按钮高 - 文字高) / 2
        [self.title drawAtPoint:NSMakePoint(x, rint((bounds.size.height - textSize.height) / 2))
                  withAttributes:attrs];
    }
}

- (void)mouseEntered:(NSEvent *)event
{
    (void)event;
    _hovering = YES;
    [self refreshStyle];
}

- (void)mouseExited:(NSEvent *)event
{
    (void)event;
    _hovering = NO;
    _pressed = NO;
    [self refreshStyle];
}

- (void)mouseDown:(NSEvent *)event
{
    _pressed = YES;
    [self refreshStyle];
    [super mouseDown:event]; // 内部完成 tracking 并发送 action
    _pressed = NO;
    [self refreshStyle];
}

@end

/// 按钮点击 target：回调 C++ 侧
@interface SPTitlebarUpdateTarget : NSObject
@property (nonatomic, assign) MacWindowHelper *owner;
- (void)onClick:(id)sender;
@end

@implementation SPTitlebarUpdateTarget

- (void)onClick:(id)sender
{
    (void)sender;
    if (self.owner)
        self.owner->notifyUpdateButtonClicked();
}

@end

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

void MacWindowHelper::attachUpdateButton(QObject *window)
{
    if (m_window)
        return;

    auto *quickWindow = qobject_cast<QQuickWindow *>(window);
    if (!quickWindow)
        return;

    NSView *view = reinterpret_cast<NSView *>(quickWindow->winId());
    if (!view.window)
        return;

    // assign：主窗口生命周期与 App 一致，不额外持有
    m_window = view.window;
}

void MacWindowHelper::setUpdateState(bool available, bool downloading, int percent)
{
    if (!m_window)
        return;

    NSWindow *nsWindow = static_cast<NSWindow *>(m_window);
    const bool visible = available || downloading;

    if (!visible) {
        if (m_accessory) {
            NSInteger idx = [[nsWindow titlebarAccessoryViewControllers]
                indexOfObjectIdenticalTo:static_cast<id>(m_accessory)];
            if (idx != NSNotFound)
                [nsWindow removeTitlebarAccessoryViewControllerAtIndex:idx];
            m_accessory = nullptr;
            m_button = nullptr;
        }
        return;
    }

    if (!m_accessory) {
        // 胶囊按钮：图标 + 文字（下载时文字变为百分比）；初始 frame 随后由
        // updateButtonContent 按 intrinsicContentSize 重新收紧
        SPUpdateButton *button =
            [[[SPUpdateButton alloc] initWithFrame:NSMakeRect(0, 0, 70, kButtonHeight)]
                autorelease];
        button.toolTip = QCoreApplication::translate("NativeMenu", "查看新版本")
                             .toNSString();

        SPTitlebarUpdateTarget *target =
            [[[SPTitlebarUpdateTarget alloc] init] autorelease];
        target.owner = this;
        button.target = target;
        button.action = @selector(onClick:);
        // target 随按钮存活，按钮移除时自动释放
        objc_setAssociatedObject(button, &kUpdateTargetKey, target,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        NSView *container =
            [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, kAccessoryWidth,
                                                       kAccessoryHeight)]
                autorelease];
        // 让 container 跟随系统分配的 accessory 区域尺寸（高度可变）
        container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        // 按钮固定尺寸 + 四向弹性边距 → 容器尺寸变化时始终水平/垂直居中
        button.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin
                                | NSViewMinYMargin | NSViewMaxYMargin;
        button.frame = NSMakeRect((kAccessoryWidth - 70) / 2,
                                  (kAccessoryHeight - kButtonHeight) / 2,
                                  70, kButtonHeight);
        [container addSubview:button];

        NSTitlebarAccessoryViewController *accessory =
            [[[NSTitlebarAccessoryViewController alloc] init] autorelease];
        accessory.view = container;
        accessory.layoutAttribute = NSLayoutAttributeRight;
        [nsWindow addTitlebarAccessoryViewController:accessory]; // window 持有

        m_accessory = accessory; // assign
        m_button = button;      // assign，container 持有
    }

    updateButtonContent(downloading, percent);
}

void MacWindowHelper::updateButtonContent(bool downloading, int percent)
{
    if (!m_button)
        return;

    SPUpdateButton *button = static_cast<SPUpdateButton *>(m_button);

    // 云 + 向下箭头图标（SF Symbols，macOS 11+）
    NSImage *cloud = nil;
    if (@available(macOS 11.0, *)) {
        cloud = [NSImage imageWithSystemSymbolName:@"icloud.and.arrow.down"
                          accessibilityDescription:nil];
        if (cloud) {
            NSImageSymbolConfiguration *cfg =
                [NSImageSymbolConfiguration configurationWithPointSize:13
                                                                 weight:NSFontWeightMedium];
            if (cfg)
                cloud = [cloud imageWithSymbolConfiguration:cfg];
        }
    }
    [cloud setTemplate:YES];
    button.image = cloud;
    button.imagePosition = cloud ? NSImageLeft : NSNoImage;

    // 下载中显示百分比，否则显示「更新」
    button.title = downloading
        ? [NSString stringWithFormat:@"%d%%", percent]
        : QCoreApplication::translate("NativeMenu", "更新").toNSString();

    // title 变更后重建前景色，并按「内容宽 + 左右留白」收紧宽度（容器内四向居中）
    [button refreshStyle];
    const CGFloat w = ceil([button contentWidth]) + kButtonPadX * 2;
    const NSSize box = button.superview.bounds.size;
    button.layer.cornerRadius = kButtonCornerRadius;
    [button setFrame:NSMakeRect(rint((box.width - w) / 2),
                                rint((box.height - kButtonHeight) / 2),
                                w, kButtonHeight)];
}
