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

    CGSize fitted = VLMVerticalFittingSize(host, host.bounds.size);

    if (VLMIsOnScreen(host)) {
        CGPoint bottomCenter = CGPointMake(CGRectGetMidX(host.frame), CGRectGetMaxY(host.frame));
        CGRect bounds = host.bounds;
        bounds.size = fitted;
        host.bounds = bounds;
        CGRect frame = host.frame;
        frame.size = fitted;
        frame.origin.x = bottomCenter.x - fitted.width / 2.0;
        frame.origin.y = bottomCenter.y - fitted.height;
        host.frame = frame;
        VLMKeepOnScreen(host);
    }

    VLMUnclipAncestors(host);

    UICollectionViewLayout *layout = collectionView.collectionViewLayout;
    if ([layout isKindOfClass:[UICollectionViewFlowLayout class]]) {
        UICollectionViewFlowLayout *flow = (UICollectionViewFlowLayout *)layout;
        CGFloat rowWidth = MAX(host.bounds.size.width, 80.0);
        CGSize itemSize = CGSizeMake(MAX(rowWidth - 16.0, 80.0), kVLMRowHeight);
        flow.scrollDirection = UICollectionViewScrollDirectionVertical;
        flow.itemSize = itemSize;
        flow.minimumLineSpacing = 0;
        flow.minimumInteritemSpacing = 0;
        flow.sectionInset = UIEdgeInsetsMake(4, 8, 4, 8);
        [flow invalidateLayout];
    } else if (layout) {
        @try {
            [layout setValue:@(UICollectionViewScrollDirectionVertical) forKey:@"scrollDirection"];
        } @catch (__unused NSException *exception) {
        }
    }

    collectionView.pagingEnabled = NO;
    collectionView.alwaysBounceHorizontal = NO;
    collectionView.alwaysBounceVertical = YES;
    collectionView.showsHorizontalScrollIndicator = NO;
    collectionView.clipsToBounds = YES;
    collectionView.frame = host.bounds;
    [collectionView setContentOffset:CGPointZero animated:NO];

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
    if (width < 100.0 || height < 8.0) {
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
