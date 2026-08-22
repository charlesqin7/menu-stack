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
static const CGFloat kVLMScreenInset = 8.0;

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
    VLMLog(@"prefs enabled=%d context=%d edit=%d", gEnabled, gContextMenus, gEditMenus);
}

static BOOL VLMContextOn(void) {
    return gEnabled && gContextMenus;
}

static BOOL VLMEditOn(void) {
    return gEnabled && gEditMenus;
}

#pragma mark - View helpers

static const void *kVLMApplyingKey = &kVLMApplyingKey;
static const void *kVLMReplacedLayoutKey = &kVLMReplacedLayoutKey;
static const void *kVLMLayoutGuardKey = &kVLMLayoutGuardKey;
static const void *kVLMFrameGuardKey = &kVLMFrameGuardKey;

static CGSize VLMVerticalFittingSize(id host, CGSize orig);

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

static BOOL VLMNameContains(id object, NSString *token) {
    return [NSStringFromClass([object class]) containsString:token];
}

static void VLMHideView(UIView *view) {
    if (!view) {
        return;
    }
    view.hidden = YES;
    view.alpha = 0;
    view.userInteractionEnabled = NO;
}

static BOOL VLMIsBackgroundChrome(UIView *view) {
    if ([view isKindOfClass:[UIVisualEffectView class]]) {
        return YES;
    }
    NSString *name = NSStringFromClass(view.class);
    return [name containsString:@"VisualEffect"]
        || [name containsString:@"Background"]
        || [name containsString:@"Material"]
        || [name containsString:@"Platter"]
        || [name containsString:@"Shadow"];
}

static BOOL VLMIsCalloutArrow(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    if ([name containsString:@"Page"]) {
        return NO;
    }
    return [name containsString:@"Arrow"]
        || [name containsString:@"Pointer"]
        || [name containsString:@"Callout"];
}

static void VLMHidePagingControls(id host) {
    UIView *hostView = host;
    for (UIView *sub in hostView.subviews) {
        if ([sub isKindOfClass:[UICollectionView class]] || VLMIsBackgroundChrome(sub) || VLMIsCalloutArrow(sub)) {
            continue;
        }
        VLMHideView(sub);
        for (UIView *inner in sub.subviews) {
            if ([inner isKindOfClass:[UIButton class]] || VLMNameContains(inner, @"Page")) {
                VLMHideView(inner);
            }
        }
    }

    static NSArray<NSString *> *buttonKeys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        buttonKeys = @[
            @"_leftPageButton", @"_rightPageButton",
            @"leftPageButton", @"rightPageButton",
            @"_pageButton", @"pageButton",
            @"_nextPageButton", @"_previousPageButton"
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

static UICollectionViewFlowLayout *VLMMakeVerticalFlow(CGFloat width) {
    UICollectionViewFlowLayout *flow = [[UICollectionViewFlowLayout alloc] init];
    flow.scrollDirection = UICollectionViewScrollDirectionVertical;
    flow.minimumLineSpacing = 0;
    flow.minimumInteritemSpacing = 0;
    flow.sectionInset = UIEdgeInsetsMake(4, 8, 4, 8);
    flow.itemSize = CGSizeMake(MAX(width - 16.0, 120.0), kVLMRowHeight);
    flow.estimatedItemSize = CGSizeZero;
    return flow;
}

static void VLMKeepOnScreen(UIView *view) {
    UIWindow *window = view.window;
    if (!window) {
        return;
    }
    CGRect onScreen = [view convertRect:view.bounds toView:window];
    CGFloat dx = 0;
    CGFloat dy = 0;
    if (onScreen.origin.x < kVLMScreenInset) {
        dx = kVLMScreenInset - onScreen.origin.x;
    }
    CGFloat maxX = window.bounds.size.width - kVLMScreenInset;
    if (CGRectGetMaxX(onScreen) + dx > maxX) {
        dx = maxX - CGRectGetMaxX(onScreen);
    }
    if (onScreen.origin.y < kVLMScreenInset) {
        dy = kVLMScreenInset - onScreen.origin.y;
    }
    if (dx == 0 && dy == 0) {
        return;
    }
    CGRect frame = view.frame;
    frame.origin.x += dx;
    frame.origin.y += dy;
    view.frame = frame;
}

static void VLMResizeViewKeepingBottomCenter(UIView *view, CGSize size) {
    if (size.width < 8.0 || size.height < 8.0) {
        return;
    }
    if (fabs(view.bounds.size.width - size.width) < 0.5 && fabs(view.bounds.size.height - size.height) < 0.5) {
        return;
    }
    CGPoint bottomCenter = CGPointMake(CGRectGetMidX(view.frame), CGRectGetMaxY(view.frame));
    view.bounds = CGRectMake(0, 0, size.width, size.height);
    CGRect frame = view.frame;
    frame.size = size;
    frame.origin.x = bottomCenter.x - size.width / 2.0;
    frame.origin.y = bottomCenter.y - size.height;
    view.frame = frame;
}

static void VLMExpandEditMenuAncestors(UIView *list, CGSize size) {
    list.clipsToBounds = YES;
    VLMResizeViewKeepingBottomCenter(list, size);

    UIView *view = list.superview;
    for (NSInteger depth = 0; view && depth < 8; depth++) {
        if ([view isKindOfClass:[UIWindow class]]) {
            break;
        }
        NSString *name = NSStringFromClass(view.class);
        BOOL chrome = [name containsString:@"EditMenu"]
            || [name containsString:@"Callout"]
            || [name containsString:@"Popover"];
        view.clipsToBounds = NO;
        if (chrome) {
            VLMHidePagingControls(view);
            CGSize need = CGSizeMake(MAX(view.bounds.size.width, size.width), MAX(view.bounds.size.height, size.height));
            VLMResizeViewKeepingBottomCenter(view, need);
        }
        view = view.superview;
    }
    VLMKeepOnScreen(list);
}

static void VLMApplyVerticalCollectionLayout(id hostObj, BOOL resizeChrome) {
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

    CGSize fitted = VLMVerticalFittingSize(host, host.bounds.size);
    CGFloat width = fitted.width;

    UICollectionViewLayout *layout = collectionView.collectionViewLayout;
    UICollectionViewFlowLayout *flow = nil;

    if ([layout isKindOfClass:[UICollectionViewFlowLayout class]]) {
        flow = (UICollectionViewFlowLayout *)layout;
    } else if (layout) {
        @try {
            [layout setValue:@(UICollectionViewScrollDirectionVertical) forKey:@"scrollDirection"];
        } @catch (__unused NSException *exception) {
        }
        if (!objc_getAssociatedObject(host, kVLMReplacedLayoutKey)) {
            flow = VLMMakeVerticalFlow(width);
            [collectionView setCollectionViewLayout:flow animated:NO];
            objc_setAssociatedObject(host, kVLMReplacedLayoutKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            VLMLog(@"replaced custom layout on %@", host);
        }
    }

    if (flow) {
        CGSize itemSize = CGSizeMake(MAX(width - 16.0, 120.0), kVLMRowHeight);
        BOOL dirty = NO;
        if (flow.scrollDirection != UICollectionViewScrollDirectionVertical) {
            flow.scrollDirection = UICollectionViewScrollDirectionVertical;
            dirty = YES;
        }
        if (!CGSizeEqualToSize(flow.itemSize, itemSize)) {
            flow.itemSize = itemSize;
            dirty = YES;
        }
        flow.minimumLineSpacing = 0;
        flow.minimumInteritemSpacing = 0;
        flow.sectionInset = UIEdgeInsetsMake(4, 8, 4, 8);
        flow.estimatedItemSize = CGSizeZero;
        if (dirty) {
            [flow invalidateLayout];
        }
    }

    collectionView.pagingEnabled = NO;
    collectionView.alwaysBounceHorizontal = NO;
    collectionView.alwaysBounceVertical = YES;
    collectionView.showsHorizontalScrollIndicator = NO;
    collectionView.showsVerticalScrollIndicator = (VLMItemCount(collectionView) > 8);
    collectionView.clipsToBounds = YES;
    if (@available(iOS 11.0, *)) {
        collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    collectionView.contentInset = UIEdgeInsetsZero;
    collectionView.frame = CGRectMake(0, 0, fitted.width, fitted.height);
    [collectionView setContentOffset:CGPointZero animated:NO];

    VLMHidePagingControls(host);
    if (resizeChrome) {
        VLMExpandEditMenuAncestors(host, fitted);
    }
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
    if (width < 40.0 || height < 8.0) {
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

    if (imageView) {
        VLMDisableConstraints(imageView);
        imageView.hidden = NO;
        imageView.alpha = 1;
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        if (imageView.image.renderingMode != UIImageRenderingModeAlwaysOriginal) {
            imageView.tintColor = UIColor.labelColor;
        }
        imageView.frame = CGRectMake(left, (height - icon) / 2.0, icon, icon);
        left += icon + gap;
    }

    if (title) {
        VLMDisableConstraints(title);
        title.hidden = NO;
        title.alpha = 1;
        title.textAlignment = NSTextAlignmentLeft;
        title.numberOfLines = 1;
        title.lineBreakMode = NSLineBreakByTruncatingTail;
        title.frame = CGRectMake(left, 0, MAX(40.0, width - left - 14.0), height);
    }
}

static void VLMRelayoutVisibleCells(id host) {
    UICollectionView *collectionView = VLMCollectionViewInHost(host);
    for (UIView *cell in collectionView.visibleCells) {
        VLMRelayoutCell(cell);
    }
}

static CGSize VLMVerticalFittingSize(id host, CGSize orig) {
    UICollectionView *collectionView = VLMCollectionViewInHost(host);
    NSInteger count = VLMItemCount(collectionView);
    if (count <= 0) {
        CGFloat estimated = orig.width > 1.0 ? round(orig.width / 72.0) : 4.0;
        count = MAX(1, (NSInteger)estimated);
    }

    CGFloat width = kVLMMenuWidth;
    CGFloat height = count * kVLMRowHeight + 8.0;
    CGFloat maxHeight = MIN(UIScreen.mainScreen.bounds.size.height * 0.48, 440.0);
    height = MIN(MAX(height, kVLMRowHeight + 8.0), maxHeight);
    return CGSizeMake(width, height);
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
    VLMApplyVerticalCollectionLayout(self, NO);
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
    objc_setAssociatedObject(self, kVLMFrameGuardKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    VLMApplyVerticalCollectionLayout(self, YES);
    VLMRelayoutVisibleCells(self);
    objc_setAssociatedObject(self, kVLMFrameGuardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kVLMLayoutGuardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)setBounds:(CGRect)bounds {
    if (VLMEditOn() && !objc_getAssociatedObject(self, kVLMFrameGuardKey)) {
        CGSize fitted = VLMVerticalFittingSize(self, bounds.size);
        bounds.origin = CGPointZero;
        bounds.size = fitted;
    }
    %orig;
}

- (void)setFrame:(CGRect)frame {
    if (VLMEditOn() && !objc_getAssociatedObject(self, kVLMFrameGuardKey)) {
        CGSize fitted = VLMVerticalFittingSize(self, frame.size);
        CGFloat midX = CGRectGetMidX(frame);
        CGFloat maxY = CGRectGetMaxY(frame);
        frame.size = fitted;
        frame.origin.x = midX - fitted.width / 2.0;
        frame.origin.y = maxY - fitted.height;
    }
    %orig;
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

%group EditMenuPageButton

%hook _UIEditMenuPageButton

- (void)didMoveToWindow {
    %orig;
    if (VLMEditOn()) {
        VLMHideView(self);
    }
}

- (void)layoutSubviews {
    %orig;
    if (VLMEditOn()) {
        VLMHideView(self);
    }
}

- (CGSize)sizeThatFits:(CGSize)size {
    if (VLMEditOn()) {
        return CGSizeZero;
    }
    return %orig;
}

- (CGSize)intrinsicContentSize {
    if (VLMEditOn()) {
        return CGSizeZero;
    }
    return %orig;
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
    UIView *list = nil;
    for (UIView *sub in self.subviews) {
        if (VLMNameContains(sub, @"ListView") || VLMIsCalloutArrow(sub) || VLMIsBackgroundChrome(sub)) {
            list = VLMNameContains(sub, @"ListView") ? sub : list;
            continue;
        }
        VLMHideView(sub);
    }
    if (!list) {
        return;
    }
    CGSize need = VLMVerticalFittingSize(list, list.bounds.size);
    objc_setAssociatedObject(self, kVLMFrameGuardKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    VLMResizeViewKeepingBottomCenter(self, need);
    list.frame = self.bounds;
    objc_setAssociatedObject(self, kVLMFrameGuardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    VLMKeepOnScreen(self);
}

%end

%end

#pragma mark - Constructor

static void VLMPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    VLMLoadPrefs();
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

    if (objc_getClass("_UIEditMenuListView")) {
        %init(EditMenuList);
        %init(EditMenuCells);
        VLMLog(@"hooked _UIEditMenuListView");
    } else {
        VLMLog(@"_UIEditMenuListView missing — skip edit-menu hooks");
    }

    if (objc_getClass("_UIEditMenuPageButton")) {
        %init(EditMenuPageButton);
        VLMLog(@"hooked _UIEditMenuPageButton");
    }
    if (objc_getClass("_UIEditMenuContainerView")) {
        %init(EditMenuContainer);
        VLMLog(@"hooked _UIEditMenuContainerView");
    }

    VLMLog(@"loaded in %@", [NSBundle mainBundle].bundleIdentifier ?: @"?");
}
