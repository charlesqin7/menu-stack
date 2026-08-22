#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface _UIEditMenuListView : UIView
@end

#pragma mark - Constants

static NSString * const kVLMPrefsID = @"com.qins.verticalmenu";
static NSString * const kVLMReloadNotification = @"com.qins.verticalmenu/ReloadPrefs";

// UIMenuOptionsDisplayAsPalette (iOS 17) = 1 << 7
static const NSUInteger kVLMPaletteOption = (1 << 7);

// UIMenuElementSizeLarge (iOS 16+) = 2
static const NSInteger kVLMElementSizeLarge = 2;

static const CGFloat kVLMMenuWidth = 236.0;
static const CGFloat kVLMRowHeight = 44.0;

#pragma mark - Prefs

static BOOL gEnabled = YES;
static BOOL gContextMenus = YES;
static BOOL gEditMenus = YES;
static BOOL gDebug = NO;

#define VLMLog(fmt, ...) do { \
    if (gDebug) NSLog(@"[VerticalMenu] " fmt, ##__VA_ARGS__); \
} while (0)

static NSDictionary *VLMPrefsDictionary(void) {
    NSArray<NSString *> *paths = @[
        @"/var/jb/var/mobile/Library/Preferences/com.qins.verticalmenu.plist",
        @"/var/mobile/Library/Preferences/com.qins.verticalmenu.plist",
    ];
    for (NSString *path in paths) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (dict.count > 0) {
            return dict;
        }
    }

    CFStringRef ident = (__bridge CFStringRef)kVLMPrefsID;
    CFPreferencesAppSynchronize(ident);
    CFArrayRef keys = CFPreferencesCopyKeyList(ident, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (!keys) {
        return @{};
    }
    CFDictionaryRef cfDict = CFPreferencesCopyMultiple(keys, ident, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFRelease(keys);
    return CFBridgingRelease(cfDict) ?: @{};
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

static void VLMHidePagingControls(id host) {
    for (UIView *sub in [host subviews]) {
        NSString *name = NSStringFromClass(sub.class);
        if ([name containsString:@"PageButton"] || [name containsString:@"PageControl"]) {
            sub.hidden = YES;
            sub.alpha = 0;
            sub.userInteractionEnabled = NO;
        }
    }
}

static void VLMApplyVerticalCollectionLayout(id host) {
    if (objc_getAssociatedObject(host, kVLMApplyingKey)) {
        return;
    }
    objc_setAssociatedObject(host, kVLMApplyingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UICollectionView *collectionView = VLMCollectionViewInHost(host);
    if (!collectionView) {
        objc_setAssociatedObject(host, kVLMApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    CGFloat width = host.bounds.size.width;
    if (width < 8.0) {
        width = kVLMMenuWidth;
    }

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
            UICollectionViewFlowLayout *replacement = [[UICollectionViewFlowLayout alloc] init];
            replacement.scrollDirection = UICollectionViewScrollDirectionVertical;
            replacement.minimumLineSpacing = 0;
            replacement.minimumInteritemSpacing = 0;
            replacement.sectionInset = UIEdgeInsetsMake(4, 4, 4, 4);
            replacement.itemSize = CGSizeMake(MAX(width - 8.0, 80.0), kVLMRowHeight);
            [collectionView setCollectionViewLayout:replacement animated:NO];
            objc_setAssociatedObject(host, kVLMReplacedLayoutKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            flow = replacement;
            VLMLog(@"replaced custom layout on %@", host);
        }
    }

    if (flow) {
        CGSize itemSize = CGSizeMake(MAX(width - 8.0, 80.0), kVLMRowHeight);
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
        if (dirty) {
            [flow invalidateLayout];
        }
    }

    collectionView.alwaysBounceHorizontal = NO;
    collectionView.alwaysBounceVertical = YES;
    collectionView.showsHorizontalScrollIndicator = NO;
    collectionView.showsVerticalScrollIndicator = (VLMItemCount(collectionView) > 8);
    collectionView.clipsToBounds = YES;

    VLMHidePagingControls(host);
    objc_setAssociatedObject(host, kVLMApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void VLMEnumerateLabelsAndImages(UIView *view, UILabel **outLabel, UIImageView **outImage) {
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UILabel class]] && !(*outLabel)) {
            UILabel *label = (UILabel *)sub;
            if (label.text.length > 0 || label.attributedText.length > 0) {
                *outLabel = label;
            }
        } else if ([sub isKindOfClass:[UIImageView class]] && !(*outImage)) {
            UIImageView *imageView = (UIImageView *)sub;
            if (imageView.image) {
                *outImage = imageView;
            }
        }
        if (*outLabel && *outImage) {
            return;
        }
        VLMEnumerateLabelsAndImages(sub, outLabel, outImage);
        if (*outLabel && *outImage) {
            return;
        }
    }
}

static void VLMRelayoutCell(UIView *cell) {
    CGFloat width = cell.bounds.size.width;
    CGFloat height = cell.bounds.size.height;
    if (width < 120.0 || height < 8.0) {
        return;
    }

    for (UIView *sub in cell.subviews) {
        if ([sub isKindOfClass:[UIStackView class]]) {
            UIStackView *stack = (UIStackView *)sub;
            stack.axis = UILayoutConstraintAxisHorizontal;
            stack.alignment = UIStackViewAlignmentCenter;
            stack.spacing = 10;
            stack.layoutMargins = UIEdgeInsetsMake(0, 12, 0, 12);
            stack.layoutMarginsRelativeArrangement = YES;
        }
    }

    UILabel *title = nil;
    UIImageView *imageView = nil;
    VLMEnumerateLabelsAndImages(cell, &title, &imageView);

    if (title) {
        title.textAlignment = NSTextAlignmentLeft;
        title.numberOfLines = 1;
        title.lineBreakMode = NSLineBreakByTruncatingTail;
    }

    if (title && imageView && imageView.translatesAutoresizingMaskIntoConstraints) {
        CGFloat icon = 22.0;
        imageView.frame = CGRectMake(14.0, (height - icon) / 2.0, icon, icon);
        title.frame = CGRectMake(44.0, 0, width - 58.0, height);
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
    VLMApplyVerticalCollectionLayout(self);
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
    if (!VLMEditOn()) {
        return;
    }
    VLMApplyVerticalCollectionLayout(self);
    VLMRelayoutVisibleCells(self);
}

- (void)setBounds:(CGRect)bounds {
    if (VLMEditOn() && bounds.size.height < 60.0 && bounds.size.width > 80.0) {
        CGSize fitted = VLMVerticalFittingSize(self, bounds.size);
        bounds.size.height = fitted.height;
        bounds.size.width = fitted.width;
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

    VLMLog(@"loaded in %@", [NSBundle mainBundle].bundleIdentifier ?: @"?");
}
