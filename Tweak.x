#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface _UIEditMenuListView : UIView
@end

@interface _UIEditMenuPageButton : UIView
@end

@interface _UIEditMenuContainerView : UIView
@end

#pragma mark - Constants

static NSString * const kVLMPrefsID = @"com.qins.verticalmenu";
static NSString * const kVLMReloadNotification = @"com.qins.verticalmenu/ReloadPrefs";

// UIMenuOptionsDisplayAsPalette (iOS 17) = 1 << 7
static const NSUInteger kVLMPaletteOption = (1 << 7);

// UIMenuElementSizeLarge (iOS 16+) = 2
static const NSInteger kVLMElementSizeLarge = 2;

static const CGFloat kVLMMenuWidth = 280.0;
static const CGFloat kVLMRowHeight = 44.0;
static const NSInteger kVLMVisibleRows = 5;
static const CGFloat kVLMListInset = 16.0;
static const CGFloat kVLMScreenInset = 8.0;
static const CGFloat kVLMSelectionGap = 6.0;
static const CGFloat kVLMIconSize = 22.0;
static const CGFloat kVLMIconLeft = 16.0;
static const CGFloat kVLMIconTextGap = 10.0;
static const CGFloat kVLMArrowWidth = 20.0;
static const CGFloat kVLMArrowHeight = 11.0;

#pragma mark - Prefs

static BOOL gEnabled = YES;
static BOOL gContextMenus = YES;
static BOOL gEditMenus = YES;
static BOOL gDebug = NO;

#define VLMLog(fmt, ...) do { \
    if (gDebug) NSLog(@"[VerticalMenu] " fmt, ##__VA_ARGS__); \
} while (0)

static NSDictionary *VLMPrefsDictionary(void) {
    CFStringRef ident = (__bridge CFStringRef)kVLMPrefsID;
    CFPreferencesAppSynchronize(ident);
    CFArrayRef keys = CFPreferencesCopyKeyList(ident, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys) {
        CFDictionaryRef cfDict = CFPreferencesCopyMultiple(keys, ident, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFRelease(keys);
        NSDictionary *dict = CFBridgingRelease(cfDict);
        if (dict.count > 0) {
            return dict;
        }
    }

    NSArray<NSString *> *paths = @[
        @"/var/jb/var/mobile/Library/Preferences/com.qins.verticalmenu.plist",
        @"/var/jb/Library/Preferences/com.qins.verticalmenu.plist",
        @"/var/mobile/Library/Preferences/com.qins.verticalmenu.plist",
    ];
    for (NSString *path in paths) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (dict.count > 0) {
            return dict;
        }
    }
    return @{};
}

static BOOL VLMBool(NSDictionary *dict, NSString *key, BOOL fallback) {
    id value = dict[key];
    if (!value) {
        return fallback;
    }
    return [value boolValue];
}

static void VLMLoadPrefs(void) {
    NSDictionary *dict = VLMPrefsDictionary();
    gEnabled = VLMBool(dict, @"Enabled", YES);
    gContextMenus = VLMBool(dict, @"ContextMenus", YES);
    gEditMenus = VLMBool(dict, @"EditMenus", YES);
    gDebug = VLMBool(dict, @"Debug", NO);
}

static BOOL VLMContextOn(void) {
    return gEnabled && gContextMenus;
}

static BOOL VLMEditOn(void) {
    return gEnabled && gEditMenus;
}

#pragma mark - View helpers

static const void *kVLMApplyingKey = &kVLMApplyingKey;
static const void *kVLMLayoutGuardKey = &kVLMLayoutGuardKey;
static const void *kVLMLoggedLayoutKey = &kVLMLoggedLayoutKey;
static const void *kVLMGrowDownKey = &kVLMGrowDownKey;
static const void *kVLMFallbackIconKey = &kVLMFallbackIconKey;
static const void *kVLMTitleSlotKey = &kVLMTitleSlotKey;
static const void *kVLMCoverKey = &kVLMCoverKey;
static const void *kVLMTitleOverlayActiveKey = &kVLMTitleOverlayActiveKey;
static const void *kVLMCustomArrowKey = &kVLMCustomArrowKey;
static const void *kVLMContainerGuardKey = &kVLMContainerGuardKey;
static const void *kVLMCellGuardKey = &kVLMCellGuardKey;
static const void *kVLMArrowScheduledKey = &kVLMArrowScheduledKey;
static const void *kVLMHidSystemArrowKey = &kVLMHidSystemArrowKey;
static const void *kVLMStrippedButtonKey = &kVLMStrippedButtonKey;
static const void *kVLMCapturedTitleKey = &kVLMCapturedTitleKey;
static const void *kVLMCapturedImageKey = &kVLMCapturedImageKey;
static const void *kVLMCapturedFontKey = &kVLMCapturedFontKey;
static const void *kVLMCapturedColorKey = &kVLMCapturedColorKey;

static BOOL VLMNameLooksLikeArrow(UIView *view);
static void VLMDisableConstraints(UIView *view);
static BOOL VLMImageIsUsableIcon(UIImage *image);
static void VLMRefreshArrow(UIView *host);
static void VLMScheduleArrow(UIView *host);

static UICollectionView *VLMFindCollectionView(id view) {
    if ([view isKindOfClass:[UICollectionView class]]) {
        return (UICollectionView *)view;
    }
    for (UIView *sub in [view subviews]) {
        UICollectionView *found = VLMFindCollectionView(sub);
        if (found) {
            return found;
        }
    }
    return nil;
}

static UICollectionView *VLMCollectionViewInHost(id host) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[@"collectionView", @"_collectionView", @"_listCollectionView"];
    });
    for (NSString *key in keys) {
        @try {
            id value = [host valueForKey:key];
            if ([value isKindOfClass:[UICollectionView class]]) {
                return value;
            }
        } @catch (__unused NSException *exception) {
        }
    }
    return VLMFindCollectionView(host);
}

static NSInteger VLMItemCount(UICollectionView *collectionView) {
    if (!collectionView || collectionView.numberOfSections <= 0) {
        return 0;
    }
    return [collectionView numberOfItemsInSection:0];
}

static BOOL VLMFramesClose(CGRect a, CGRect b) {
    return fabs(a.origin.x - b.origin.x) < 0.5
        && fabs(a.origin.y - b.origin.y) < 0.5
        && fabs(a.size.width - b.size.width) < 0.5
        && fabs(a.size.height - b.size.height) < 0.5;
}

static void VLMHideView(UIView *view) {
    if (!view) {
        return;
    }
    view.hidden = YES;
    view.alpha = 0;
    view.userInteractionEnabled = NO;
}

static void VLMHidePagingControls(id host) {
    UIView *hostView = host;
    for (UIView *sub in hostView.subviews) {
        NSString *name = NSStringFromClass(sub.class);
        if ([name containsString:@"PageButton"] || [name containsString:@"PageControl"]) {
            VLMHideView(sub);
        }
    }

    static NSArray<NSString *> *buttonKeys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        buttonKeys = @[
            @"_leftPageButton", @"_rightPageButton",
            @"leftPageButton", @"rightPageButton",
            @"_pageButton", @"pageButton"
        ];
    });
    for (NSString *key in buttonKeys) {
        @try {
            id value = [host valueForKey:key];
            if ([value isKindOfClass:[UIView class]]) {
                VLMHideView(value);
            }
        } @catch (__unused NSException *exception) {
        }
    }
}

static void VLMUnclipAncestors(UIView *view) {
    view.clipsToBounds = NO;
    UIView *current = view.superview;
    for (NSInteger depth = 0; current && depth < 6; depth++) {
        if ([current isKindOfClass:[UIWindow class]]) {
            break;
        }
        current.clipsToBounds = NO;
        current = current.superview;
    }
}

static void VLMClearLayerShadow(CALayer *layer) {
    if (!layer) {
        return;
    }
    layer.shadowOpacity = 0;
    layer.shadowRadius = 0;
    layer.shadowPath = nil;
    layer.shadowOffset = CGSizeZero;
}

static void VLMStripShadowsInView(UIView *view, UIView *host, NSInteger depth) {
    if (!view || depth < 0) {
        return;
    }
    NSString *name = NSStringFromClass(view.class);
    if (view != host && (
            [name localizedCaseInsensitiveContainsString:@"shadow"]
            || [name containsString:@"Dimming"]
            || [name containsString:@"Cutout"])) {
        view.hidden = YES;
        view.alpha = 0;
    }
    VLMClearLayerShadow(view.layer);
    for (UIView *sub in view.subviews) {
        VLMStripShadowsInView(sub, host, depth - 1);
    }
}

static void VLMStripShadows(UIView *view) {
    UIView *current = view;
    for (NSInteger depth = 0; current && depth < 6; depth++) {
        if ([current isKindOfClass:[UIWindow class]]) {
            break;
        }
        VLMStripShadowsInView(current, view, 3);
        current = current.superview;
    }
}

static void VLMSizeBackgroundsToHost(UIView *host) {
    for (UIView *sub in host.subviews) {
        if ([sub isKindOfClass:[UICollectionView class]] || VLMNameLooksLikeArrow(sub)) {
            continue;
        }
        NSString *name = NSStringFromClass(sub.class);
        if ([sub isKindOfClass:[UIVisualEffectView class]]
            || [name containsString:@"Background"]
            || [name containsString:@"Platter"]
            || [name containsString:@"Material"]
            || [name containsString:@"VisualEffect"]) {
            if (!VLMFramesClose(sub.frame, host.bounds)) {
                sub.frame = host.bounds;
            }
        }
    }
}

static BOOL VLMIsOnScreen(UIView *view) {
    UIWindow *window = view.window;
    if (!window) {
        return NO;
    }
    CGRect frame = view.frame;
    if (frame.size.width < 8.0 || frame.size.height < 8.0) {
        return NO;
    }
    CGRect onScreen = [view convertRect:view.bounds toView:window];
    if (CGRectIsEmpty(onScreen) || CGRectIsNull(onScreen)) {
        return NO;
    }
    return CGRectIntersectsRect(onScreen, window.bounds);
}

@interface VLMSelectionAnchorView : UIView
@end

@implementation VLMSelectionAnchorView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        self.contentMode = UIViewContentModeRedraw;
        if (@available(iOS 13.0, *)) {
            self.tintColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *trait) {
                if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
                    return [UIColor colorWithWhite:0.23 alpha:0.96];
                }
                return [UIColor colorWithWhite:1.0 alpha:0.96];
            }];
        } else {
            self.tintColor = [UIColor colorWithWhite:1.0 alpha:0.96];
        }
    }
    return self;
}

- (void)tintColorDidChange {
    [super tintColorDidChange];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect))];
    [path addLineToPoint:CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect))];
    [path addLineToPoint:CGPointMake(CGRectGetMinX(rect), CGRectGetMaxY(rect))];
    [path closePath];
    [(self.tintColor ?: [UIColor whiteColor]) setFill];
    [path fill];
}

@end

static BOOL VLMNameLooksLikeArrow(UIView *view) {
    if ([view isKindOfClass:[VLMSelectionAnchorView class]]) {
        return NO;
    }
    NSString *name = NSStringFromClass(view.class);
    if ([name containsString:@"Page"]) {
        return NO;
    }
    return [name containsString:@"Arrow"] || [name containsString:@"Pointer"] || [name containsString:@"Callout"] || [name containsString:@"Beak"];
}

static UIView *VLMFindArrowNear(UIView *host) {
    UIView *root = host;
    for (NSInteger depth = 0; depth < 3 && root.superview; depth++) {
        if ([root.superview isKindOfClass:[UIWindow class]]) {
            break;
        }
        root = root.superview;
    }

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    for (NSUInteger index = 0; index < queue.count && index < 80; index++) {
        UIView *view = queue[index];
        if (view != host && VLMNameLooksLikeArrow(view) && view.bounds.size.width < 80.0 && view.bounds.size.height < 40.0) {
            return view;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}

static UIView *VLMOutermostEditMenuView(UIView *view) {
    UIView *result = view;
    UIView *current = view.superview;
    for (NSInteger depth = 0; current && depth < 6; depth++) {
        if ([current isKindOfClass:[UIWindow class]]) {
            break;
        }
        NSString *name = NSStringFromClass(current.class);
        if ([name containsString:@"EditMenu"] || [name containsString:@"Callout"] || [name containsString:@"Popover"]) {
            result = current;
        }
        current = current.superview;
    }
    return result;
}

static BOOL VLMShouldGrowDownward(UIView *host) {
    NSNumber *cached = objc_getAssociatedObject(host, kVLMGrowDownKey);
    if (cached) {
        return cached.boolValue;
    }

    BOOL growDown = NO;
    UIView *arrow = VLMFindArrowNear(host);
    UIView *ref = host.superview ?: host;
    if (arrow) {
        CGRect arrowRect = [arrow convertRect:arrow.bounds toView:ref];
        growDown = CGRectGetMidY(arrowRect) <= CGRectGetMidY(ref.bounds) + 4.0;
        VLMLog(@"arrow %@ midY=%.1f refMid=%.1f growDown=%d", NSStringFromClass(arrow.class), CGRectGetMidY(arrowRect), CGRectGetMidY(ref.bounds), growDown);
    } else {
        UIWindow *window = host.window;
        if (window) {
            CGRect onScreen = [host convertRect:host.bounds toView:window];
            CGFloat topBand = MAX(window.safeAreaInsets.top, 20.0) + 96.0;
            growDown = onScreen.origin.y < topBand;
        }
    }

    objc_setAssociatedObject(host, kVLMGrowDownKey, @(growDown), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return growDown;
}

static NSArray<UIWindow *> *VLMAllWindows(UIWindow *preferred) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    void (^addWindow)(UIWindow *) = ^(UIWindow *window) {
        if (window && ![windows containsObject:window]) {
            [windows addObject:window];
        }
    };
    addWindow(preferred);
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (@available(iOS 15.0, *)) {
            addWindow(windowScene.keyWindow);
        }
        for (UIWindow *window in windowScene.windows) {
            addWindow(window);
        }
    }
    return windows;
}

static UIView *VLMFirstResponderInView(UIView *view) {
    if (view.isFirstResponder) {
        return view;
    }
    for (UIView *sub in view.subviews) {
        UIView *found = VLMFirstResponderInView(sub);
        if (found) {
            return found;
        }
    }
    return nil;
}

static CGRect VLMConvertTextRectToWindow(id<UITextInput> input, CGRect rect, UIWindow *window) {
    if (CGRectIsNull(rect) || (rect.size.width <= 0.5 && rect.size.height <= 0.5)) {
        return CGRectNull;
    }
    UIView *view = nil;
    if ([input isKindOfClass:[UIView class]]) {
        view = (UIView *)input;
    } else if ([input respondsToSelector:@selector(textInputView)]) {
        view = input.textInputView;
    }
    if (!view.window) {
        return CGRectNull;
    }
    return [view convertRect:rect toView:window];
}

static UIView *VLMResponderFromWindow(UIWindow *window) {
    if (!window) {
        return nil;
    }
    @try {
        id responder = [window valueForKey:@"firstResponder"];
        if ([responder isKindOfClass:[UIView class]]) {
            return responder;
        }
        if ([responder respondsToSelector:@selector(textInputView)]) {
            UIView *inputView = [responder textInputView];
            if ([inputView isKindOfClass:[UIView class]]) {
                return inputView;
            }
        }
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

static CGRect VLMSelectionRectInWindow(UIWindow *window) {
    if (!window) {
        return CGRectNull;
    }

    UIView *responder = nil;
    UIWindow *ownerWindow = window;
    for (UIWindow *candidate in VLMAllWindows(window)) {
        UIView *found = VLMResponderFromWindow(candidate);
        if (![found conformsToProtocol:@protocol(UITextInput)]) {
            continue;
        }
        id<UITextInput> input = (id<UITextInput>)found;
        BOOL hasSelection = input.selectedTextRange && !input.selectedTextRange.isEmpty;
        if (!responder || hasSelection) {
            responder = found;
            ownerWindow = candidate;
            if (hasSelection) {
                break;
            }
        }
    }
    if (![responder conformsToProtocol:@protocol(UITextInput)]) {
        return CGRectNull;
    }

    id<UITextInput> input = (id<UITextInput>)responder;
    UITextRange *range = input.selectedTextRange;
    if (!range) {
        range = input.markedTextRange;
    }
    if (!range) {
        return CGRectNull;
    }

    CGRect unionRect = CGRectNull;
    if (!range.isEmpty) {
        NSArray<UITextSelectionRect *> *rects = [input selectionRectsForRange:range];
        for (UITextSelectionRect *item in rects) {
            CGRect converted = VLMConvertTextRectToWindow(input, item.rect, ownerWindow);
            if (!CGRectIsNull(converted) && converted.size.height > 0.5) {
                unionRect = CGRectIsNull(unionRect) ? converted : CGRectUnion(unionRect, converted);
            }
        }
        if (CGRectIsNull(unionRect) || CGRectIsEmpty(unionRect)) {
            unionRect = VLMConvertTextRectToWindow(input, [input firstRectForRange:range], ownerWindow);
        }
    }
    if ((CGRectIsNull(unionRect) || CGRectIsEmpty(unionRect)) && range.end) {
        unionRect = VLMConvertTextRectToWindow(input, [input caretRectForPosition:range.end], ownerWindow);
    }
    if ((CGRectIsNull(unionRect) || CGRectIsEmpty(unionRect)) && [responder isKindOfClass:[UIView class]]) {
        for (id<UIInteraction> interaction in ((UIView *)responder).interactions) {
            if (![NSStringFromClass(interaction.class) containsString:@"EditMenu"]) {
                continue;
            }
            if ([interaction respondsToSelector:@selector(locationInView:)]) {
                CGPoint point = [(UIEditMenuInteraction *)interaction locationInView:ownerWindow];
                if (!CGPointEqualToPoint(point, CGPointZero)) {
                    unionRect = CGRectMake(point.x - 8.0, point.y - 11.0, 16.0, 22.0);
                }
            }
        }
    }
    if (CGRectIsNull(unionRect) || CGRectIsEmpty(unionRect)) {
        return CGRectNull;
    }
    if (ownerWindow != window) {
        unionRect = [window convertRect:unionRect fromWindow:ownerWindow];
    }
    return unionRect;
}

static void VLMSetFrameInWindow(UIView *view, CGRect windowFrame) {
    if (!view.superview || !view.window) {
        return;
    }
    CGRect local = [view.superview convertRect:windowFrame fromView:view.window];
    if (VLMFramesClose(view.frame, local) && VLMFramesClose(view.bounds, CGRectMake(0, 0, windowFrame.size.width, windowFrame.size.height))) {
        return;
    }
    view.bounds = CGRectMake(0, 0, windowFrame.size.width, windowFrame.size.height);
    view.frame = local;
}

static void VLMHideLeftoverChrome(UIView *host) {
    UIView *parent = host.superview;
    if (!parent || [parent isKindOfClass:[UIWindow class]]) {
        return;
    }
    for (UIView *sub in parent.subviews) {
        if (sub == host || [sub isKindOfClass:[VLMSelectionAnchorView class]] || VLMNameLooksLikeArrow(sub)) {
            continue;
        }
        NSString *name = NSStringFromClass(sub.class);
        if ([name containsString:@"Page"]
            || [name localizedCaseInsensitiveContainsString:@"shadow"]
            || [name containsString:@"Dimming"]
            || [name containsString:@"Cutout"]) {
            VLMHideView(sub);
            continue;
        }
        if (sub.bounds.size.width > host.bounds.size.width + 8.0
            || sub.bounds.size.height > host.bounds.size.height + 8.0
            || fabs(sub.frame.origin.x - host.frame.origin.x) > 8.0
            || fabs(sub.frame.origin.y - host.frame.origin.y) > 8.0) {
            if (!VLMFramesClose(sub.frame, host.frame)) {
                sub.frame = host.frame;
            }
        }
    }
}

static void VLMFitChromeToHost(UIView *host, CGRect hostWindowRect) {
    if (!host.window || CGRectIsNull(hostWindowRect) || hostWindowRect.size.width < 8.0) {
        return;
    }

    UIView *container = host.superview;
    UIView *current = host.superview;
    for (NSInteger depth = 0; current && depth < 4; depth++) {
        if ([current isKindOfClass:[UIWindow class]]) {
            break;
        }
        NSString *name = NSStringFromClass(current.class);
        if ([name containsString:@"EditMenuContainer"] || [name containsString:@"ContainerView"]) {
            container = current;
            break;
        }
        current = current.superview;
    }

    if (container && container != host && container.superview && ![container isKindOfClass:[UIWindow class]]) {
        VLMDisableConstraints(container);
        container.backgroundColor = [UIColor clearColor];
        VLMClearLayerShadow(container.layer);
        container.clipsToBounds = NO;
        CGRect local = [container.superview convertRect:hostWindowRect fromView:host.window];
        if (!VLMFramesClose(container.frame, local)) {
            container.bounds = CGRectMake(0, 0, local.size.width, local.size.height);
            container.frame = local;
        }
    }

    VLMSetFrameInWindow(host, hostWindowRect);
    VLMHideLeftoverChrome(host);
}

static void VLMHideSystemArrowsNear(UIView *host) {
    if (objc_getAssociatedObject(host, kVLMHidSystemArrowKey)) {
        return;
    }
    objc_setAssociatedObject(host, kVLMHidSystemArrowKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[@"_arrowView", @"arrowView", @"_pointerView", @"pointerView"];
    });
    UIView *current = host;
    for (NSInteger depth = 0; current && depth < 4; depth++) {
        for (NSString *key in keys) {
            @try {
                id value = [current valueForKey:key];
                if ([value isKindOfClass:[UIView class]] && ![value isKindOfClass:[VLMSelectionAnchorView class]]) {
                    VLMHideView(value);
                }
            } @catch (__unused NSException *exception) {
            }
        }
        current = current.superview;
        if ([current isKindOfClass:[UIWindow class]]) {
            break;
        }
    }
    UIView *found = VLMFindArrowNear(host);
    if (found && ![found isKindOfClass:[VLMSelectionAnchorView class]]) {
        VLMHideView(found);
    }
}

static UIView *VLMEnsureCustomArrow(UIView *host) {
    VLMSelectionAnchorView *arrow = objc_getAssociatedObject(host, kVLMCustomArrowKey);
    if (!arrow) {
        arrow = [[VLMSelectionAnchorView alloc] initWithFrame:CGRectMake(0, 0, kVLMArrowWidth, kVLMArrowHeight)];
        objc_setAssociatedObject(host, kVLMCustomArrowKey, arrow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIView *parent = host.superview;
    if (parent && arrow.superview != parent) {
        [parent addSubview:arrow];
    }
    arrow.layer.zPosition = host.layer.zPosition + 10.0;
    return arrow;
}

static void VLMRemoveCustomArrow(UIView *host) {
    UIView *arrow = objc_getAssociatedObject(host, kVLMCustomArrowKey);
    [arrow removeFromSuperview];
}

static void VLMPointArrowAtSelection(UIView *host, CGRect selection, BOOL below) {
    if (!host.superview || !host.window || CGRectIsNull(selection)) {
        return;
    }

    VLMHideSystemArrowsNear(host);
    UIView *arrow = VLMEnsureCustomArrow(host);
    if (!arrow || !arrow.superview) {
        return;
    }

    CGRect hostInParent = host.frame;
    CGFloat targetX = CGRectGetMidX([host.superview convertRect:selection fromView:host.window]);
    CGFloat minX = CGRectGetMinX(hostInParent) + 22.0;
    CGFloat maxX = CGRectGetMaxX(hostInParent) - 22.0;
    if (maxX < minX) {
        minX = CGRectGetMidX(hostInParent);
        maxX = minX;
    }
    CGFloat x = MIN(MAX(targetX, minX), maxX);
    CGPoint newCenter = below
        ? CGPointMake(x, CGRectGetMinY(hostInParent) + 1.0)
        : CGPointMake(x, CGRectGetMaxY(hostInParent) - 1.0);
    CGAffineTransform newTransform = below ? CGAffineTransformIdentity : CGAffineTransformMakeScale(1.0, -1.0);
    CGRect newBounds = CGRectMake(0, 0, kVLMArrowWidth, kVLMArrowHeight);
    if (fabs(arrow.center.x - newCenter.x) < 0.5
        && fabs(arrow.center.y - newCenter.y) < 0.5
        && CGAffineTransformEqualToTransform(arrow.transform, newTransform)
        && !arrow.hidden) {
        return;
    }
    arrow.bounds = newBounds;
    arrow.transform = newTransform;
    arrow.center = newCenter;
    arrow.hidden = NO;
    arrow.alpha = 1;
    VLMLog(@"custom arrow x=%.1f below=%d selection=%@", x, below, NSStringFromCGRect(selection));
}

static void VLMScheduleArrow(UIView *host) {
    if (!host || objc_getAssociatedObject(host, kVLMArrowScheduledKey)) {
        return;
    }
    objc_setAssociatedObject(host, kVLMArrowScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakHost = host;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongHost = weakHost;
        if (!strongHost) {
            return;
        }
        objc_setAssociatedObject(strongHost, kVLMArrowScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        VLMRefreshArrow(strongHost);
    });
}

static void VLMRefreshArrow(UIView *host) {
    if (!host.window) {
        return;
    }
    CGRect selection = VLMSelectionRectInWindow(host.window);
    if (CGRectIsNull(selection) || selection.size.height < 1.0) {
        return;
    }
    CGRect hostInWindow = [host convertRect:host.bounds toView:host.window];
    BOOL below = CGRectGetMidY(selection) <= CGRectGetMidY(hostInWindow);
    VLMPointArrowAtSelection(host, selection, below);
}

static UIView *VLMFindEditMenuList(UIView *view, NSInteger depth) {
    static Class listClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        listClass = objc_getClass("_UIEditMenuListView");
    });
    if (!view || !listClass || depth < 0) {
        return nil;
    }
    if ([view isKindOfClass:listClass]) {
        return view;
    }
    for (UIView *sub in view.subviews) {
        UIView *found = VLMFindEditMenuList(sub, depth - 1);
        if (found) {
            return found;
        }
    }
    return nil;
}

static BOOL VLMPositionHostNearSelection(UIView *host, CGSize fitted) {
    UIWindow *window = host.window;
    CGRect selection = VLMSelectionRectInWindow(window);
    if (!window || CGRectIsNull(selection) || selection.size.height < 1.0) {
        return NO;
    }

    CGFloat topInset = MAX(window.safeAreaInsets.top, 20.0) + 6.0;
    CGFloat bottomInset = window.safeAreaInsets.bottom + kVLMScreenInset;
    CGFloat leftInset = kVLMScreenInset;
    CGFloat rightInset = window.bounds.size.width - kVLMScreenInset;

    CGFloat arrowH = kVLMArrowHeight;
    BOOL below = VLMShouldGrowDownward(host);
    if (selection.origin.y < topInset + 72.0) {
        below = YES;
    }

    CGRect listRect;
    listRect.size = fitted;
    listRect.origin.x = CGRectGetMidX(selection) - fitted.width / 2.0;
    if (listRect.origin.x < leftInset) {
        listRect.origin.x = leftInset;
    }
    if (CGRectGetMaxX(listRect) > rightInset) {
        listRect.origin.x = rightInset - fitted.width;
    }

    if (below) {
        listRect.origin.y = CGRectGetMaxY(selection) + kVLMSelectionGap + arrowH * 0.35;
        if (CGRectGetMaxY(listRect) > window.bounds.size.height - bottomInset) {
            listRect.origin.y = window.bounds.size.height - bottomInset - fitted.height;
        }
    } else {
        listRect.origin.y = selection.origin.y - kVLMSelectionGap - arrowH * 0.35 - fitted.height;
        if (listRect.origin.y < topInset) {
            listRect.origin.y = topInset;
        }
    }

    VLMFitChromeToHost(host, listRect);
    VLMScheduleArrow(host);
    VLMLog(@"pin selection=%@ list=%@ below=%d", NSStringFromCGRect(selection), NSStringFromCGRect(listRect), below);
    return YES;
}

static void VLMKeepOnScreen(UIView *view) {
    UIView *chrome = VLMOutermostEditMenuView(view);
    UIWindow *window = chrome.window;
    if (!window) {
        return;
    }
    CGRect onScreen = [chrome convertRect:chrome.bounds toView:window];
    CGFloat topInset = MAX(window.safeAreaInsets.top, 20.0) + 6.0;
    CGFloat bottomInset = window.safeAreaInsets.bottom + kVLMScreenInset;
    CGFloat dx = 0;
    CGFloat dy = 0;
    if (onScreen.origin.x < kVLMScreenInset) {
        dx = kVLMScreenInset - onScreen.origin.x;
    }
    CGFloat maxX = window.bounds.size.width - kVLMScreenInset;
    if (CGRectGetMaxX(onScreen) + dx > maxX) {
        dx = maxX - CGRectGetMaxX(onScreen);
    }
    if (onScreen.origin.y < topInset) {
        dy = topInset - onScreen.origin.y;
    }
    CGFloat maxY = window.bounds.size.height - bottomInset;
    if (CGRectGetMaxY(onScreen) + dy > maxY) {
        dy = maxY - CGRectGetMaxY(onScreen);
        if (onScreen.origin.y + dy < topInset) {
            dy = topInset - onScreen.origin.y;
        }
    }
    if (dx == 0 && dy == 0) {
        return;
    }
    chrome.frame = CGRectOffset(chrome.frame, dx, dy);
}

static CGSize VLMVerticalFittingSize(id host, CGSize orig) {
    UICollectionView *collectionView = VLMCollectionViewInHost(host);
    NSInteger count = VLMItemCount(collectionView);
    if (count <= 0) {
        CGFloat estimated = orig.width > 1.0 ? round(orig.width / 72.0) : 4.0;
        count = MAX(1, (NSInteger)estimated);
    }

    CGFloat width = kVLMMenuWidth;
    NSInteger visible = MIN(MAX(count, 1), kVLMVisibleRows);
    CGFloat height = visible * kVLMRowHeight + kVLMListInset * 2.0;
    return CGSizeMake(width, height);
}

@interface VLMVerticalListLayout : UICollectionViewLayout
@end

@implementation VLMVerticalListLayout

- (NSInteger)vlm_itemCount {
    UICollectionView *collectionView = self.collectionView;
    if (!collectionView || collectionView.numberOfSections <= 0) {
        return 0;
    }
    return [collectionView numberOfItemsInSection:0];
}

- (CGFloat)vlm_rowWidth {
    CGFloat width = self.collectionView.bounds.size.width;
    if (width < 8.0) {
        width = kVLMMenuWidth;
    }
    return width;
}

- (CGSize)collectionViewContentSize {
    return CGSizeMake([self vlm_rowWidth], kVLMListInset * 2.0 + [self vlm_itemCount] * kVLMRowHeight);
}

- (NSArray<UICollectionViewLayoutAttributes *> *)layoutAttributesForElementsInRect:(CGRect)rect {
    NSMutableArray<UICollectionViewLayoutAttributes *> *attributes = [NSMutableArray array];
    NSInteger count = [self vlm_itemCount];
    for (NSInteger index = 0; index < count; index++) {
        NSIndexPath *path = [NSIndexPath indexPathForItem:index inSection:0];
        UICollectionViewLayoutAttributes *item = [self layoutAttributesForItemAtIndexPath:path];
        if (item && CGRectIntersectsRect(item.frame, rect)) {
            [attributes addObject:item];
        }
    }
    return attributes;
}

- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewLayoutAttributes *attributes = [UICollectionViewLayoutAttributes layoutAttributesForCellWithIndexPath:indexPath];
    CGFloat width = [self vlm_rowWidth];
    attributes.frame = CGRectMake(0, kVLMListInset + indexPath.item * kVLMRowHeight, width, kVLMRowHeight);
    return attributes;
}

- (BOOL)shouldInvalidateLayoutForBoundsChange:(CGRect)newBounds {
    CGRect oldBounds = self.collectionView.bounds;
    return fabs(oldBounds.size.width - newBounds.size.width) > 0.5;
}

@end

static UICollectionViewLayout *VLMEnsureVerticalListLayout(UICollectionView *collectionView) {
    UICollectionViewLayout *current = collectionView.collectionViewLayout;
    if ([current isKindOfClass:[VLMVerticalListLayout class]]) {
        return current;
    }
    VLMVerticalListLayout *replacement = [[VLMVerticalListLayout alloc] init];
    [collectionView setCollectionViewLayout:replacement animated:NO];
    return replacement;
}

static void VLMApplyVerticalCollectionLayout(id hostObj) {
    UIView *host = hostObj;
    if (objc_getAssociatedObject(host, kVLMApplyingKey)) {
        return;
    }
    objc_setAssociatedObject(host, kVLMApplyingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UICollectionView *collectionView = VLMCollectionViewInHost(host);
    if (!collectionView) {
        objc_setAssociatedObject(host, kVLMApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if (!objc_getAssociatedObject(host, kVLMLoggedLayoutKey)) {
        NSLog(@"[VerticalMenu] edit layout %@ items=%ld bounds=%@",
              NSStringFromClass(collectionView.collectionViewLayout.class),
              (long)VLMItemCount(collectionView),
              NSStringFromCGRect(host.bounds));
        objc_setAssociatedObject(host, kVLMLoggedLayoutKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGSize fitted = VLMVerticalFittingSize(host, host.bounds.size);
    if (VLMIsOnScreen(host)) {
        CGRect selection = VLMSelectionRectInWindow(host.window);
        if (!VLMPositionHostNearSelection(host, fitted)) {
            BOOL growDown = VLMShouldGrowDownward(host);
            if (!CGRectIsNull(selection)) {
                CGRect hostInWindow = [host convertRect:host.bounds toView:host.window];
                growDown = CGRectGetMidY(selection) <= CGRectGetMidY(hostInWindow);
            }
            CGRect frame = host.frame;
            CGFloat minX = CGRectGetMinX(frame);
            CGFloat minY = CGRectGetMinY(frame);
            CGFloat maxY = CGRectGetMaxY(frame);
            frame.size = fitted;
            frame.origin.x = minX;
            frame.origin.y = growDown ? minY : (maxY - fitted.height);
            if (!VLMFramesClose(host.frame, frame) || !VLMFramesClose(host.bounds, CGRectMake(0, 0, fitted.width, fitted.height))) {
                host.bounds = CGRectMake(0, 0, fitted.width, fitted.height);
                host.frame = frame;
                VLMKeepOnScreen(host);
            }
            if (host.window) {
                VLMFitChromeToHost(host, [host convertRect:host.bounds toView:host.window]);
            }
            if (!CGRectIsNull(selection)) {
                VLMScheduleArrow(host);
            }
            VLMLog(@"anchor growDown=%d frame=%@", growDown, NSStringFromCGRect(host.frame));
        }
    }

    VLMUnclipAncestors(host);
    VLMStripShadows(host);
    VLMSizeBackgroundsToHost(host);
    if (host.window) {
        VLMFitChromeToHost(host, [host convertRect:host.bounds toView:host.window]);
    }

    collectionView.pagingEnabled = NO;
    collectionView.scrollEnabled = YES;
    collectionView.alwaysBounceHorizontal = NO;
    collectionView.alwaysBounceVertical = (VLMItemCount(collectionView) > kVLMVisibleRows);
    collectionView.showsHorizontalScrollIndicator = NO;
    collectionView.showsVerticalScrollIndicator = (VLMItemCount(collectionView) > kVLMVisibleRows);
    collectionView.clipsToBounds = YES;
    if (@available(iOS 11.0, *)) {
        collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    if (@available(iOS 13.0, *)) {
        collectionView.automaticallyAdjustsScrollIndicatorInsets = NO;
    }
    collectionView.contentInset = UIEdgeInsetsZero;
    collectionView.scrollIndicatorInsets = UIEdgeInsetsZero;
    if (!VLMFramesClose(collectionView.frame, host.bounds)) {
        collectionView.frame = host.bounds;
    }
    if (fabs(collectionView.contentOffset.x) > 0.5) {
        [collectionView setContentOffset:CGPointMake(0, collectionView.contentOffset.y) animated:NO];
    }

    BOOL needsInstall = ![collectionView.collectionViewLayout isKindOfClass:[VLMVerticalListLayout class]];
    VLMEnsureVerticalListLayout(collectionView);
    if (needsInstall) {
        [collectionView layoutIfNeeded];
    }

    VLMHidePagingControls(host);
    VLMScheduleArrow(host);
    objc_setAssociatedObject(host, kVLMApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void VLMDisableConstraints(UIView *view) {
    view.translatesAutoresizingMaskIntoConstraints = YES;
    NSArray<NSLayoutConstraint *> *constraints = [view.constraints copy];
    for (NSLayoutConstraint *constraint in constraints) {
        constraint.active = NO;
    }
}

static void VLMWalkMenuParts(UIView *view, UIView *skipA, UIView *skipB, NSMutableArray<UILabel *> *labels, NSMutableArray<UIImageView *> *images, NSMutableArray<UIButton *> *buttons) {
    if (!view || view == skipA || view == skipB) {
        return;
    }
    if ([view isKindOfClass:[UILabel class]]) {
        [labels addObject:(UILabel *)view];
    }
    if ([view isKindOfClass:[UIImageView class]]) {
        [images addObject:(UIImageView *)view];
    }
    if (buttons && [view isKindOfClass:[UIButton class]]) {
        [buttons addObject:(UIButton *)view];
    }
    for (UIView *sub in view.subviews) {
        VLMWalkMenuParts(sub, skipA, skipB, labels, images, buttons);
    }
}

static NSString *VLMTrimString(NSString *text) {
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *VLMTrimmedText(UILabel *label) {
    NSString *text = VLMTrimString(label.text);
    if (text.length == 0 && label.attributedText.length > 0) {
        text = VLMTrimString(label.attributedText.string);
    }
    return text;
}

static UILabel *VLMBestTitleLabel(NSArray<UILabel *> *labels) {
    UILabel *title = nil;
    for (UILabel *label in labels) {
        NSString *text = VLMTrimmedText(label);
        if (text.length == 0) {
            continue;
        }
        if (!title || text.length > VLMTrimmedText(title).length) {
            title = label;
        }
    }
    return title;
}

static NSString *VLMButtonTitle(UIButton *button) {
    NSString *title = VLMTrimString(button.currentTitle);
    if (title.length > 0) {
        return title;
    }
    title = VLMTrimString(button.titleLabel.text);
    if (title.length > 0) {
        return title;
    }
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *config = button.configuration;
        if (config.attributedTitle.length > 0) {
            return VLMTrimString(config.attributedTitle.string);
        }
        if (config.title.length > 0) {
            return VLMTrimString(config.title);
        }
    }
    return nil;
}

static UIImage *VLMButtonImage(UIButton *button) {
    if (VLMImageIsUsableIcon(button.currentImage)) {
        return button.currentImage;
    }
    if (@available(iOS 15.0, *)) {
        UIImage *image = button.configuration.image;
        if (VLMImageIsUsableIcon(image)) {
            return image;
        }
    }
    return nil;
}

static BOOL VLMIsBackgroundImageView(UIImageView *imageView, UIView *content) {
    CGSize imageSize = imageView.bounds.size;
    CGSize contentSize = content.bounds.size;
    return imageSize.width > contentSize.width * 0.75 && imageSize.height > contentSize.height * 0.75;
}

static BOOL VLMImageIsUsableIcon(UIImage *image) {
    if (!image) {
        return NO;
    }
    CGSize size = image.size;
    return size.width >= 4.0 && size.height >= 4.0;
}

static UIImage *VLMFallbackMenuIcon(void) {
    static UIImage *icon;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:17.0 weight:UIImageSymbolWeightMedium scale:UIImageSymbolScaleMedium];
            UIImage *system = [UIImage systemImageNamed:@"ellipsis.circle" withConfiguration:config];
            if (!system) {
                system = [UIImage systemImageNamed:@"circle" withConfiguration:config];
            }
            icon = [system imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
    });
    return icon;
}

static UIImageView *VLMEnsureFallbackSlot(UIView *content) {
    UIImageView *slot = objc_getAssociatedObject(content, kVLMFallbackIconKey);
    if (!slot) {
        slot = [[UIImageView alloc] init];
        slot.userInteractionEnabled = NO;
        slot.contentMode = UIViewContentModeScaleAspectFit;
        slot.isAccessibilityElement = NO;
        objc_setAssociatedObject(content, kVLMFallbackIconKey, slot, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return slot;
}

static UIView *VLMEnsureCover(UIView *content) {
    UIView *cover = objc_getAssociatedObject(content, kVLMCoverKey);
    if (!cover) {
        cover = [[UIView alloc] init];
        cover.userInteractionEnabled = NO;
        cover.isAccessibilityElement = NO;
        if (@available(iOS 13.0, *)) {
            cover.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *trait) {
                if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
                    return [UIColor colorWithWhite:0.21 alpha:1.0];
                }
                return [UIColor colorWithWhite:1.0 alpha:1.0];
            }];
        } else {
            cover.backgroundColor = [UIColor whiteColor];
        }
        objc_setAssociatedObject(content, kVLMCoverKey, cover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return cover;
}

static UILabel *VLMEnsureTitleSlot(UIView *content) {
    UILabel *slot = objc_getAssociatedObject(content, kVLMTitleSlotKey);
    if (!slot) {
        slot = [[UILabel alloc] init];
        slot.userInteractionEnabled = NO;
        slot.isAccessibilityElement = NO;
        slot.numberOfLines = 1;
        slot.lineBreakMode = NSLineBreakByTruncatingTail;
        slot.textAlignment = NSTextAlignmentLeft;
        slot.adjustsFontSizeToFitWidth = NO;
        objc_setAssociatedObject(content, kVLMTitleSlotKey, slot, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return slot;
}

static UIView *VLMEnclosingCollectionCell(UIView *view) {
    UIView *current = view;
    while (current) {
        if ([current isKindOfClass:[UICollectionViewCell class]]) {
            return current;
        }
        current = current.superview;
    }
    return nil;
}

static void VLMFadeNativeLabels(UIView *view, UIView *skipA, UIView *skipB) {
    if (!view || view == skipA || view == skipB) {
        return;
    }
    if ([view isKindOfClass:[UILabel class]]) {
        view.alpha = 0;
        return;
    }
    for (UIView *sub in view.subviews) {
        VLMFadeNativeLabels(sub, skipA, skipB);
    }
}

static void VLMStripButtonOnce(UIButton *button) {
    if (!button || objc_getAssociatedObject(button, kVLMStrippedButtonKey)) {
        return;
    }
    NSString *label = VLMButtonTitle(button);
    if (label.length > 0 && button.accessibilityLabel.length == 0) {
        button.accessibilityLabel = label;
    }
    objc_setAssociatedObject(button, kVLMStrippedButtonKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *config = button.configuration;
        if (config) {
            UIButtonConfiguration *updated = [config copy];
            updated.title = @"";
            updated.attributedTitle = nil;
            updated.image = nil;
            button.configuration = updated;
        }
    }
    [button setTitle:@"" forState:UIControlStateNormal];
    [button setImage:nil forState:UIControlStateNormal];
    button.titleLabel.alpha = 0;
}

static void VLMSetFrameFromContent(UIView *view, UIView *content, CGRect rectInContent) {
    if (!view) {
        return;
    }
    VLMDisableConstraints(view);
    UIView *parent = view.superview;
    if (!parent || parent == content) {
        view.frame = rectInContent;
        return;
    }
    view.frame = [content convertRect:rectInContent toView:parent];
}

static UIImage *VLMBestIconImage(NSArray<UIImageView *> *images, NSArray<UIButton *> *buttons, UIImageView *slot, UIView *content) {
    UIImage *best = nil;
    CGFloat bestArea = -1.0;
    for (UIImageView *candidate in images) {
        if (candidate == slot || VLMIsBackgroundImageView(candidate, content)) {
            continue;
        }
        if (!VLMImageIsUsableIcon(candidate.image)) {
            continue;
        }
        CGFloat area = candidate.image.size.width * candidate.image.size.height;
        if (area > bestArea) {
            best = candidate.image;
            bestArea = area;
        }
    }
    for (UIButton *button in buttons) {
        UIImage *image = VLMButtonImage(button);
        if (!VLMImageIsUsableIcon(image)) {
            continue;
        }
        CGFloat area = image.size.width * image.size.height;
        if (area > bestArea) {
            best = image;
            bestArea = area;
        }
    }
    return best;
}

static UIColor *VLMBestIconTint(NSArray<UIImageView *> *images, UIImageView *slot, UIView *content, UIColor *fallback) {
    for (UIImageView *candidate in images) {
        if (candidate == slot || VLMIsBackgroundImageView(candidate, content)) {
            continue;
        }
        if (VLMImageIsUsableIcon(candidate.image) && candidate.tintColor) {
            return candidate.tintColor;
        }
    }
    return fallback;
}

static void VLMRelayoutCell(UIView *cell) {
    CGFloat width = cell.bounds.size.width;
    CGFloat height = cell.bounds.size.height;
    if (width < 8.0 || height < 8.0) {
        return;
    }
    if (objc_getAssociatedObject(cell, kVLMCellGuardKey)) {
        return;
    }
    objc_setAssociatedObject(cell, kVLMCellGuardKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *content = cell;
    if ([cell isKindOfClass:[UICollectionViewCell class]]) {
        content = ((UICollectionViewCell *)cell).contentView;
        if (!CGRectEqualToRect(content.frame, cell.bounds)) {
            content.frame = cell.bounds;
        }
        content.clipsToBounds = NO;
        content.layer.zPosition = 0;
    }
    cell.clipsToBounds = NO;

    UIImageView *slot = VLMEnsureFallbackSlot(content);
    UILabel *titleSlot = VLMEnsureTitleSlot(content);
    UIView *cover = VLMEnsureCover(content);

    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    NSMutableArray<UIImageView *> *images = [NSMutableArray array];
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    VLMWalkMenuParts(cell, slot, titleSlot, labels, images, buttons);

    UILabel *title = VLMBestTitleLabel(labels);
    NSString *titleText = title ? VLMTrimmedText(title) : nil;
    UIFont *titleFont = title.font;
    UIColor *titleColor = title.textColor;
    UIImage *iconImage = VLMBestIconImage(images, buttons, slot, content);
    for (UIButton *button in buttons) {
        NSString *buttonTitle = VLMButtonTitle(button);
        if (buttonTitle.length > titleText.length) {
            titleText = buttonTitle;
        }
        if (!titleFont) {
            titleFont = button.titleLabel.font;
        }
        if (!titleColor) {
            titleColor = button.currentTitleColor ?: button.titleLabel.textColor;
        }
        UIImage *buttonImage = VLMButtonImage(button);
        if (!VLMImageIsUsableIcon(iconImage) && VLMImageIsUsableIcon(buttonImage)) {
            iconImage = buttonImage;
        }
    }
    NSString *storedTitle = objc_getAssociatedObject(content, kVLMCapturedTitleKey);
    UIImage *storedImage = objc_getAssociatedObject(content, kVLMCapturedImageKey);
    UIFont *storedFont = objc_getAssociatedObject(content, kVLMCapturedFontKey);
    UIColor *storedColor = objc_getAssociatedObject(content, kVLMCapturedColorKey);
    if (titleText.length == 0) {
        titleText = storedTitle;
    }
    if (titleText.length == 0) {
        titleText = VLMTrimmedText(titleSlot);
    }
    if (!VLMImageIsUsableIcon(iconImage)) {
        iconImage = storedImage;
    }
    if (!titleFont) {
        titleFont = storedFont;
    }
    if (!titleColor) {
        titleColor = storedColor;
    }
    if (titleText.length > 0) {
        objc_setAssociatedObject(content, kVLMCapturedTitleKey, titleText, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    if (VLMImageIsUsableIcon(iconImage)) {
        objc_setAssociatedObject(content, kVLMCapturedImageKey, iconImage, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (titleFont) {
        objc_setAssociatedObject(content, kVLMCapturedFontKey, titleFont, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (titleColor) {
        objc_setAssociatedObject(content, kVLMCapturedColorKey, titleColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIColor *tint = titleColor ?: UIColor.labelColor;
    BOOL usedNativeIcon = VLMImageIsUsableIcon(iconImage);
    if (!usedNativeIcon) {
        iconImage = VLMFallbackMenuIcon();
    }
    UIColor *iconTint = VLMBestIconTint(images, slot, content, tint);

    CGFloat textX = kVLMIconLeft + kVLMIconSize + kVLMIconTextGap;
    CGRect iconRect = CGRectMake(kVLMIconLeft, (content.bounds.size.height - kVLMIconSize) / 2.0, kVLMIconSize, kVLMIconSize);
    CGRect titleRect = CGRectMake(textX, 0, MAX(40.0, content.bounds.size.width - textX - 14.0), content.bounds.size.height);

    objc_setAssociatedObject(cell, kVLMTitleOverlayActiveKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (cover.superview != cell) {
        [cell addSubview:cover];
    }
    if (slot.superview != cell) {
        [cell addSubview:slot];
    }
    if (titleSlot.superview != cell) {
        [cell addSubview:titleSlot];
    }

    cover.frame = cell.bounds;
    cover.hidden = NO;
    cover.alpha = 1;
    cover.layer.zPosition = 999;

    slot.hidden = NO;
    slot.alpha = 1;
    slot.contentMode = UIViewContentModeScaleAspectFit;
    slot.image = iconImage;
    if (usedNativeIcon && iconImage.renderingMode == UIImageRenderingModeAlwaysOriginal) {
        slot.tintColor = nil;
    } else {
        slot.tintColor = iconTint;
    }
    slot.frame = iconRect;
    slot.layer.zPosition = 1001;

    titleSlot.hidden = (titleText.length == 0);
    titleSlot.alpha = titleSlot.hidden ? 0 : 1;
    titleSlot.attributedText = nil;
    titleSlot.textAlignment = NSTextAlignmentLeft;
    titleSlot.numberOfLines = 1;
    titleSlot.lineBreakMode = NSLineBreakByTruncatingTail;
    titleSlot.font = titleFont ?: [UIFont systemFontOfSize:17.0];
    titleSlot.textColor = tint;
    titleSlot.text = titleText;
    titleSlot.frame = titleRect;
    titleSlot.layer.zPosition = 1000;
    objc_setAssociatedObject(cell, kVLMCellGuardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void VLMRelayoutVisibleCells(id host) {
    UICollectionView *collectionView = VLMCollectionViewInHost(host);
    for (UIView *cell in collectionView.visibleCells) {
        VLMRelayoutCell(cell);
    }
}

static BOOL VLMIsInsideEditMenu(id view) {
    static Class listClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        listClass = objc_getClass("_UIEditMenuListView");
    });
    if (!listClass) {
        return NO;
    }
    UIView *current = view;
    for (NSInteger depth = 0; current && depth < 16; depth++) {
        if ([current isKindOfClass:listClass]) {
            return YES;
        }
        current = current.superview;
    }
    return NO;
}

#pragma mark - UIMenu: context menus / palettes / compact rows

%group ContextMenus

%hook UIMenu

- (NSInteger)preferredElementSize {
    NSInteger orig = %orig;
    if (!VLMContextOn()) {
        return orig;
    }
    return kVLMElementSizeLarge;
}

- (void)setPreferredElementSize:(NSInteger)size {
    if (!VLMContextOn()) {
        %orig;
        return;
    }
    %orig(kVLMElementSizeLarge);
}

- (NSUInteger)options {
    NSUInteger opts = %orig;
    if (!VLMContextOn()) {
        return opts;
    }
    return opts & ~kVLMPaletteOption;
}

+ (instancetype)menuWithTitle:(NSString *)title
                        image:(UIImage *)image
                   identifier:(NSString *)identifier
                      options:(NSUInteger)options
                     children:(NSArray *)children {
    if (VLMContextOn()) {
        options = options & ~kVLMPaletteOption;
    }
    UIMenu *menu = %orig;
    if (menu && VLMContextOn()) {
        menu.preferredElementSize = kVLMElementSizeLarge;
    }
    return menu;
}

- (instancetype)initWithTitle:(NSString *)title
                        image:(UIImage *)image
                   identifier:(NSString *)identifier
                      options:(NSUInteger)options
                     children:(NSArray *)children {
    if (VLMContextOn()) {
        options = options & ~kVLMPaletteOption;
    }
    UIMenu *menu = %orig;
    if (menu && VLMContextOn()) {
        menu.preferredElementSize = kVLMElementSizeLarge;
    }
    return menu;
}

- (UIMenu *)menuByReplacingChildren:(NSArray *)newChildren {
    UIMenu *menu = %orig;
    if (menu && VLMContextOn()) {
        menu.preferredElementSize = kVLMElementSizeLarge;
    }
    return menu;
}

%end

%end

#pragma mark - Text edit menu (copy / paste bar)

%group EditMenuList

%hook _UIEditMenuListView

- (CGSize)sizeThatFits:(CGSize)size {
    CGSize orig = %orig;
    if (!VLMEditOn()) {
        return orig;
    }
    CGSize vertical = VLMVerticalFittingSize(self, orig);
    VLMLog(@"sizeThatFits %@ -> %@", NSStringFromCGSize(orig), NSStringFromCGSize(vertical));
    return vertical;
}

- (CGSize)intrinsicContentSize {
    CGSize orig = %orig;
    if (!VLMEditOn()) {
        return orig;
    }
    return VLMVerticalFittingSize(self, orig);
}

- (void)layoutSubviews {
    %orig;
    if (!VLMEditOn() || objc_getAssociatedObject(self, kVLMLayoutGuardKey)) {
        return;
    }
    objc_setAssociatedObject(self, kVLMLayoutGuardKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    VLMApplyVerticalCollectionLayout(self);
    VLMRelayoutVisibleCells(self);
    objc_setAssociatedObject(self, kVLMLayoutGuardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)didMoveToWindow {
    %orig;
    if (!self.window) {
        VLMRemoveCustomArrow(self);
        return;
    }
    if (!VLMEditOn()) {
        return;
    }
    __weak UIView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongSelf = weakSelf;
        if (!strongSelf.window || !VLMEditOn()) {
            return;
        }
        VLMApplyVerticalCollectionLayout(strongSelf);
        VLMRelayoutVisibleCells(strongSelf);
    });
}

%end

%end

%group EditMenuCells

%hook UICollectionViewCell

- (void)layoutSubviews {
    %orig;
    if (VLMEditOn() && VLMIsInsideEditMenu(self)) {
        VLMRelayoutCell(self);
    }
}

- (void)prepareForReuse {
    %orig;
    UIView *content = self.contentView;
    objc_setAssociatedObject(content, kVLMCapturedTitleKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(content, kVLMCapturedImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(content, kVLMCapturedFontKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(content, kVLMCapturedColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kVLMTitleOverlayActiveKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%end

%end

%group EditMenuCollectionView

%hook UICollectionView

- (void)setCollectionViewLayout:(UICollectionViewLayout *)layout animated:(BOOL)animated {
    if (VLMEditOn() && VLMIsInsideEditMenu(self) && ![layout isKindOfClass:[VLMVerticalListLayout class]]) {
        layout = [[VLMVerticalListLayout alloc] init];
    }
    %orig;
}

- (void)setCollectionViewLayout:(UICollectionViewLayout *)layout animated:(BOOL)animated completion:(void (^)(BOOL))completion {
    if (VLMEditOn() && VLMIsInsideEditMenu(self) && ![layout isKindOfClass:[VLMVerticalListLayout class]]) {
        layout = [[VLMVerticalListLayout alloc] init];
    }
    %orig;
}

%end

%end

%group EditMenuPageButton

%hook _UIEditMenuPageButton

- (void)layoutSubviews {
    %orig;
    if (VLMEditOn()) {
        VLMHideView(self);
    }
}

%end

%end

%group EditMenuContainer

%hook _UIEditMenuContainerView

- (void)layoutSubviews {
    %orig;
    if (!VLMEditOn() || objc_getAssociatedObject(self, kVLMContainerGuardKey)) {
        return;
    }
    objc_setAssociatedObject(self, kVLMContainerGuardKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.clipsToBounds = NO;
    self.backgroundColor = [UIColor clearColor];
    VLMClearLayerShadow(self.layer);
    VLMStripShadows(self);
    UIView *list = VLMFindEditMenuList(self, 4);
    if (list && list.window) {
        VLMFitChromeToHost(list, [list convertRect:list.bounds toView:list.window]);
    }
    objc_setAssociatedObject(self, kVLMContainerGuardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%end

%end

#pragma mark - Constructor

static void VLMPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    VLMLoadPrefs();
    NSLog(@"[VerticalMenu] prefs reload enabled=%d context=%d edit=%d debug=%d", gEnabled, gContextMenus, gEditMenus, gDebug);
}

%ctor {
    VLMLoadPrefs();
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        VLMPrefsChanged,
        (__bridge CFStringRef)kVLMReloadNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    %init(ContextMenus);

    BOOL hookedList = NO;
    if (objc_getClass("_UIEditMenuListView")) {
        %init(EditMenuList);
        %init(EditMenuCells);
        %init(EditMenuCollectionView);
        hookedList = YES;
    }
    if (objc_getClass("_UIEditMenuPageButton")) {
        %init(EditMenuPageButton);
    }
    if (objc_getClass("_UIEditMenuContainerView")) {
        %init(EditMenuContainer);
    }

    NSLog(@"[VerticalMenu] loaded in %@ enabled=%d context=%d edit=%d debug=%d list=%d",
          [NSBundle mainBundle].bundleIdentifier ?: @"?",
          gEnabled, gContextMenus, gEditMenus, gDebug, hookedList);
}
