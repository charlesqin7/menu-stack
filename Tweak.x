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
static const void *kVLMTitleOverlayActiveKey = &kVLMTitleOverlayActiveKey;

static BOOL VLMNameLooksLikeArrow(UIView *view);
static void VLMDisableConstraints(UIView *view);

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
    view.clipsToBounds = YES;
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
    if (view != host && [name localizedCaseInsensitiveContainsString:@"shadow"]) {
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
            sub.frame = host.bounds;
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

static BOOL VLMNameLooksLikeArrow(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    if ([name containsString:@"Page"]) {
        return NO;
    }
    return [name containsString:@"Arrow"] || [name containsString:@"Pointer"] || [name containsString:@"Callout"];
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
    for (NSUInteger index = 0; index < queue.count && index < 48; index++) {
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
    } @catch (__unused NSException *exception) {
    }
    return VLMFirstResponderInView(window);
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
    view.bounds = CGRectMake(0, 0, windowFrame.size.width, windowFrame.size.height);
    view.frame = [view.superview convertRect:windowFrame fromView:view.window];
}

static void VLMPointArrowAtSelection(UIView *host, CGRect selection, BOOL below) {
    UIView *arrow = VLMFindArrowNear(host);
    if (!arrow || !arrow.superview || !host.window) {
        return;
    }

    CGRect listInSuper = [arrow.superview convertRect:host.bounds fromView:host];
    CGFloat targetX = CGRectGetMidX([arrow.superview convertRect:selection fromView:host.window]);
    CGRect arrowFrame = arrow.frame;
    CGFloat minX = CGRectGetMinX(listInSuper) + 18.0;
    CGFloat maxX = CGRectGetMaxX(listInSuper) - 18.0 - arrowFrame.size.width;
    if (maxX < minX) {
        minX = CGRectGetMidX(listInSuper) - arrowFrame.size.width / 2.0;
        maxX = minX;
    }
    arrowFrame.origin.x = MIN(MAX(targetX - arrowFrame.size.width / 2.0, minX), maxX);
    if (below) {
        arrowFrame.origin.y = CGRectGetMinY(listInSuper) - arrowFrame.size.height + 2.0;
    } else {
        arrowFrame.origin.y = CGRectGetMaxY(listInSuper) - 2.0;
    }
    VLMDisableConstraints(arrow);
    arrow.hidden = NO;
    arrow.alpha = 1;
    arrow.frame = arrowFrame;
    arrow.transform = below ? CGAffineTransformIdentity : CGAffineTransformMakeScale(1.0, -1.0);
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

    UIView *arrow = VLMFindArrowNear(host);
    CGFloat arrowH = arrow ? MAX(CGRectGetHeight(arrow.bounds), 8.0) : 8.0;
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

    VLMSetFrameInWindow(host, listRect);
    VLMPointArrowAtSelection(host, selection, below);
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
    return YES;
}

@end

static UICollectionViewLayout *VLMEnsureVerticalListLayout(UICollectionView *collectionView) {
    UICollectionViewLayout *current = collectionView.collectionViewLayout;
    if ([current isKindOfClass:[VLMVerticalListLayout class]]) {
        [current invalidateLayout];
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
            host.bounds = CGRectMake(0, 0, fitted.width, fitted.height);
            frame.size = fitted;
            frame.origin.x = minX;
            frame.origin.y = growDown ? minY : (maxY - fitted.height);
            host.frame = frame;
            VLMKeepOnScreen(host);
            if (!CGRectIsNull(selection)) {
                CGRect hostInWindow = [host convertRect:host.bounds toView:host.window];
                BOOL below = CGRectGetMidY(selection) <= CGRectGetMidY(hostInWindow);
                VLMPointArrowAtSelection(host, selection, below);
            }
            VLMLog(@"anchor growDown=%d frame=%@", growDown, NSStringFromCGRect(host.frame));
        }
    }

    VLMUnclipAncestors(host);
    VLMStripShadows(host);
    VLMSizeBackgroundsToHost(host);

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
    collectionView.frame = host.bounds;
    if (fabs(collectionView.contentOffset.x) > 0.5) {
        [collectionView setContentOffset:CGPointMake(0, collectionView.contentOffset.y) animated:NO];
    }

    VLMEnsureVerticalListLayout(collectionView);
    [collectionView.collectionViewLayout invalidateLayout];
    [collectionView layoutIfNeeded];

    VLMHidePagingControls(host);
    objc_setAssociatedObject(host, kVLMApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void VLMDisableConstraints(UIView *view) {
    view.translatesAutoresizingMaskIntoConstraints = YES;
    NSArray<NSLayoutConstraint *> *constraints = [view.constraints copy];
    for (NSLayoutConstraint *constraint in constraints) {
        constraint.active = NO;
    }
}

static void VLMWalkMenuParts(UIView *view, UIView *skipA, UIView *skipB, NSMutableArray<UILabel *> *labels, NSMutableArray<UIImageView *> *images) {
    if (!view || view == skipA || view == skipB) {
        return;
    }
    if ([view isKindOfClass:[UILabel class]]) {
        [labels addObject:(UILabel *)view];
    }
    if ([view isKindOfClass:[UIImageView class]]) {
        [images addObject:(UIImageView *)view];
    }
    for (UIView *sub in view.subviews) {
        VLMWalkMenuParts(sub, skipA, skipB, labels, images);
    }
}

static NSString *VLMTrimmedText(UILabel *label) {
    return [label.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
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

static UILabel *VLMEnsureTitleSlot(UIView *content) {
    UILabel *slot = objc_getAssociatedObject(content, kVLMTitleSlotKey);
    if (!slot) {
        slot = [[UILabel alloc] init];
        slot.userInteractionEnabled = NO;
        slot.isAccessibilityElement = NO;
        slot.numberOfLines = 1;
        slot.lineBreakMode = NSLineBreakByTruncatingTail;
        slot.textAlignment = NSTextAlignmentLeft;
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

static void VLMHideNativeTitleViews(UIView *view, UIView *skipA, UIView *skipB) {
    if (!view || view == skipA || view == skipB) {
        return;
    }
    if ([view isKindOfClass:[UILabel class]]) {
        view.hidden = YES;
        view.alpha = 0;
    }
    for (UIView *sub in view.subviews) {
        VLMHideNativeTitleViews(sub, skipA, skipB);
    }
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

static UIImageView *VLMBestNativeIcon(NSArray<UIImageView *> *images, UIImageView *slot, UIView *content) {
    UIImageView *best = nil;
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
            best = candidate;
            bestArea = area;
        }
    }
    return best;
}

static void VLMCopyTitleAppearance(UILabel *from, UILabel *to) {
    if (!from || !to) {
        return;
    }
    to.font = from.font ?: [UIFont systemFontOfSize:17.0];
    to.textColor = from.textColor ?: UIColor.labelColor;
    if (from.attributedText.length > 0) {
        to.attributedText = from.attributedText;
    } else {
        to.text = from.text;
    }
}

static void VLMRelayoutCell(UIView *cell) {
    CGFloat width = cell.bounds.size.width;
    CGFloat height = cell.bounds.size.height;
    if (width < 8.0 || height < 8.0) {
        return;
    }

    UIView *content = cell;
    if ([cell isKindOfClass:[UICollectionViewCell class]]) {
        content = ((UICollectionViewCell *)cell).contentView;
        content.frame = cell.bounds;
        content.clipsToBounds = NO;
    }
    cell.clipsToBounds = NO;

    UIImageView *slot = VLMEnsureFallbackSlot(content);
    UILabel *titleSlot = objc_getAssociatedObject(content, kVLMTitleSlotKey);

    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    NSMutableArray<UIImageView *> *images = [NSMutableArray array];
    VLMWalkMenuParts(cell, slot, titleSlot, labels, images);

    UILabel *title = VLMBestTitleLabel(labels);
    UIImageView *nativeIcon = VLMBestNativeIcon(images, slot, content);

    CGFloat icon = 22.0;
    CGFloat left = 16.0;
    CGFloat gap = 10.0;
    CGFloat textX = left + icon + gap;
    CGRect iconRect = CGRectMake(left, (content.bounds.size.height - icon) / 2.0, icon, icon);
    CGRect titleRect = CGRectMake(textX, 0, MAX(40.0, content.bounds.size.width - textX - 14.0), content.bounds.size.height);
    UIColor *tint = title.textColor ?: UIColor.labelColor;

    for (UIImageView *candidate in images) {
        if (candidate == slot || VLMIsBackgroundImageView(candidate, content)) {
            continue;
        }
        candidate.hidden = YES;
        candidate.alpha = 0;
    }

    if (slot.superview != cell) {
        [cell addSubview:slot];
    }
    slot.hidden = NO;
    slot.alpha = 1;
    slot.contentMode = UIViewContentModeScaleAspectFit;
    if (nativeIcon && VLMImageIsUsableIcon(nativeIcon.image)) {
        slot.image = nativeIcon.image;
        if (nativeIcon.image.renderingMode == UIImageRenderingModeAlwaysOriginal) {
            slot.tintColor = nil;
        } else {
            slot.tintColor = nativeIcon.tintColor ?: tint;
        }
    } else {
        slot.image = VLMFallbackMenuIcon();
        slot.tintColor = tint;
    }
    slot.frame = iconRect;

    BOOL usedFallback = !(nativeIcon && VLMImageIsUsableIcon(nativeIcon.image));
    BOOL overlayActive = usedFallback && (title || (titleSlot && VLMTrimmedText(titleSlot).length > 0));
    objc_setAssociatedObject(cell, kVLMTitleOverlayActiveKey, overlayActive ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (overlayActive) {
        titleSlot = VLMEnsureTitleSlot(content);
        if (titleSlot.superview != cell) {
            [cell addSubview:titleSlot];
        }
        if (title) {
            VLMCopyTitleAppearance(title, titleSlot);
        }
        titleSlot.hidden = NO;
        titleSlot.alpha = 1;
        titleSlot.frame = titleRect;
        VLMHideNativeTitleViews(cell, slot, titleSlot);
        [cell bringSubviewToFront:titleSlot];
        [cell bringSubviewToFront:slot];
        return;
    }

    if (titleSlot) {
        titleSlot.hidden = YES;
        titleSlot.alpha = 0;
    }
    [cell bringSubviewToFront:slot];

    NSString *titleText = title ? VLMTrimmedText(title) : nil;
    for (UILabel *label in labels) {
        NSString *text = VLMTrimmedText(label);
        if (label == title) {
            label.hidden = NO;
            label.alpha = 1;
            label.textAlignment = NSTextAlignmentLeft;
            label.numberOfLines = 1;
            label.lineBreakMode = NSLineBreakByTruncatingTail;
            VLMSetFrameFromContent(label, content, titleRect);
            continue;
        }
        if (titleText.length > 0 && [text isEqualToString:titleText]) {
            label.hidden = YES;
            label.alpha = 0;
        }
    }
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
    for (NSInteger depth = 0; current && depth < 8; depth++) {
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
    if (!VLMEditOn() || !self.window) {
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

- (void)applyLayoutAttributes:(UICollectionViewLayoutAttributes *)layoutAttributes {
    %orig;
    if (VLMEditOn() && VLMIsInsideEditMenu(self)) {
        VLMRelayoutCell(self);
    }
}

%end

%end

%group EditMenuButtons

%hook UIButton

- (void)layoutSubviews {
    %orig;
    if (!VLMEditOn() || !VLMIsInsideEditMenu(self)) {
        return;
    }
    UIView *cell = VLMEnclosingCollectionCell(self);
    if (!cell || !objc_getAssociatedObject(cell, kVLMTitleOverlayActiveKey)) {
        return;
    }
    UIView *content = cell;
    if ([cell isKindOfClass:[UICollectionViewCell class]]) {
        content = ((UICollectionViewCell *)cell).contentView;
    }
    UIView *slot = objc_getAssociatedObject(content, kVLMFallbackIconKey);
    UIView *titleSlot = objc_getAssociatedObject(content, kVLMTitleSlotKey);
    self.titleLabel.hidden = YES;
    self.titleLabel.alpha = 0;
    VLMHideNativeTitleViews(self, slot, titleSlot);
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
    if (!VLMEditOn()) {
        return;
    }
    self.clipsToBounds = NO;
    VLMStripShadows(self);
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
        %init(EditMenuButtons);
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
