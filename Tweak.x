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
static const CGFloat kVLMMenuPadding = 8.0;
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

static CGRect VLMSelectionRectInWindow(UIWindow *window) {
    if (!window) {
        return CGRectNull;
    }

    UIView *responder = VLMFirstResponderInView(window);
    if (![responder conformsToProtocol:@protocol(UITextInput)] && window.windowScene) {
        for (UIWindow *other in window.windowScene.windows) {
            responder = VLMFirstResponderInView(other);
            if ([responder conformsToProtocol:@protocol(UITextInput)]) {
                window = other;
                break;
            }
        }
    }
    if (![responder conformsToProtocol:@protocol(UITextInput)]) {
        return CGRectNull;
    }

    id<UITextInput> input = (id<UITextInput>)responder;
    UITextRange *range = input.selectedTextRange;
    if (!range || range.isEmpty) {
        return CGRectNull;
    }

    CGRect unionRect = CGRectNull;
    NSArray<UITextSelectionRect *> *rects = [input selectionRectsForRange:range];
    for (UITextSelectionRect *item in rects) {
        CGRect converted = VLMConvertTextRectToWindow(input, item.rect, window);
        if (!CGRectIsNull(converted) && converted.size.height > 0.5) {
            unionRect = CGRectIsNull(unionRect) ? converted : CGRectUnion(unionRect, converted);
        }
    }
    if (CGRectIsNull(unionRect) || CGRectIsEmpty(unionRect)) {
        unionRect = VLMConvertTextRectToWindow(input, [input firstRectForRange:range], window);
    }
    if ((CGRectIsNull(unionRect) || CGRectIsEmpty(unionRect)) && range.end) {
        unionRect = VLMConvertTextRectToWindow(input, [input caretRectForPosition:range.end], window);
    }
    if ((CGRectIsNull(unionRect) || CGRectIsEmpty(unionRect)) && [responder isKindOfClass:[UIView class]]) {
        for (id<UIInteraction> interaction in ((UIView *)responder).interactions) {
            if (![NSStringFromClass(interaction.class) containsString:@"EditMenu"]) {
                continue;
            }
            if ([interaction respondsToSelector:@selector(locationInView:)]) {
                CGPoint point = [(UIEditMenuInteraction *)interaction locationInView:window];
                if (!CGPointEqualToPoint(point, CGPointZero)) {
                    unionRect = CGRectMake(point.x - 8.0, point.y - 11.0, 16.0, 22.0);
                }
            }
        }
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
    arrow.hidden = NO;
    arrow.alpha = 1;
    arrow.frame = arrowFrame;
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
    CGFloat height = visible * kVLMRowHeight + kVLMMenuPadding;
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
    return CGSizeMake([self vlm_rowWidth], [self vlm_itemCount] * kVLMRowHeight);
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
    attributes.frame = CGRectMake(0, indexPath.item * kVLMRowHeight, width, kVLMRowHeight);
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
        if (!VLMPositionHostNearSelection(host, fitted)) {
            BOOL growDown = VLMShouldGrowDownward(host);
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
            VLMLog(@"anchor growDown=%d frame=%@", growDown, NSStringFromCGRect(host.frame));
        }
    }

    VLMUnclipAncestors(host);

    collectionView.pagingEnabled = NO;
    collectionView.scrollEnabled = YES;
    collectionView.alwaysBounceHorizontal = NO;
    collectionView.alwaysBounceVertical = (VLMItemCount(collectionView) > kVLMVisibleRows);
    collectionView.showsHorizontalScrollIndicator = NO;
    collectionView.showsVerticalScrollIndicator = (VLMItemCount(collectionView) > kVLMVisibleRows);
    collectionView.clipsToBounds = YES;
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

static void VLMEnumerateLabelsAndImages(UIView *view, NSMutableArray<UILabel *> *labels, NSMutableArray<UIImageView *> *images) {
    if ([view isKindOfClass:[UILabel class]]) {
        [labels addObject:(UILabel *)view];
    } else if ([view isKindOfClass:[UIImageView class]]) {
        [images addObject:(UIImageView *)view];
    }
    for (UIView *sub in view.subviews) {
        VLMEnumerateLabelsAndImages(sub, labels, images);
    }
}

static void VLMRelayoutCell(UIView *cell) {
    CGFloat width = cell.bounds.size.width;
    CGFloat height = cell.bounds.size.height;
    if (width < 80.0 || height < 8.0) {
        return;
    }

    UIView *content = cell;
    if ([cell isKindOfClass:[UICollectionViewCell class]]) {
        content = ((UICollectionViewCell *)cell).contentView;
        content.frame = cell.bounds;
        content.clipsToBounds = NO;
    }
    cell.clipsToBounds = NO;

    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    NSMutableArray<UIImageView *> *images = [NSMutableArray array];
    VLMEnumerateLabelsAndImages(content, labels, images);

    UILabel *title = nil;
    for (UILabel *label in labels) {
        if (!title || label.text.length > title.text.length) {
            title = label;
        }
    }

    UIImageView *imageView = nil;
    for (UIImageView *candidate in images) {
        if (candidate.image) {
            imageView = candidate;
            break;
        }
    }
    if (!imageView) {
        imageView = images.firstObject;
    }

    for (UIView *sub in content.subviews) {
        if ([sub isKindOfClass:[UIStackView class]]) {
            UIStackView *stack = (UIStackView *)sub;
            stack.axis = UILayoutConstraintAxisHorizontal;
            stack.alignment = UIStackViewAlignmentCenter;
            stack.distribution = UIStackViewDistributionFill;
            stack.spacing = 10;
            stack.frame = UIEdgeInsetsInsetRect(content.bounds, UIEdgeInsetsMake(0, 12, 0, 12));
        }
    }

    CGFloat icon = 22.0;
    CGFloat left = 14.0;
    CGFloat gap = 10.0;
    CGFloat textX = left + icon + gap;

    if (imageView && imageView.image) {
        VLMDisableConstraints(imageView);
        imageView.hidden = NO;
        imageView.alpha = 1;
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        if (imageView.image.renderingMode != UIImageRenderingModeAlwaysOriginal) {
            imageView.tintColor = UIColor.labelColor;
        }
        imageView.frame = CGRectMake(left, (height - icon) / 2.0, icon, icon);
    } else if (imageView) {
        imageView.hidden = YES;
    }

    if (title) {
        VLMDisableConstraints(title);
        title.hidden = NO;
        title.alpha = 1;
        title.textAlignment = NSTextAlignmentLeft;
        title.numberOfLines = 1;
        title.lineBreakMode = NSLineBreakByTruncatingTail;
        title.frame = CGRectMake(textX, 0, MAX(40.0, width - textX - 14.0), height);
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
