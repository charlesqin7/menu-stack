#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "VLMMenuOrder.h"

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
// UIMenuOptionsDisplayInline = 1 << 3
static const NSUInteger kVLMMenuDisplayInline = (1 << 3);

// UIMenuElementSizeLarge (iOS 16+) = 2
static const NSInteger kVLMElementSizeLarge = 2;

static const CGFloat kVLMMenuWidth = 250.0;
static const CGFloat kVLMRowHeight = 44.0;
static const NSInteger kVLMVisibleRows = 5;
static const CGFloat kVLMListInset = 16.0;
static const CGFloat kVLMScreenInset = 16.0;
static const CGFloat kVLMSelectionGap = 6.0;
static const CGFloat kVLMIconSize = 22.0;
static const CGFloat kVLMIconLeft = 16.0;
// iOS 16.5 keeps a 22pt gutter for _UIEditMenuPageButton when the
// copy-mode bar has multiple pages. Edit mode often has no gutter, so
// rows would sit 22pt closer to the platter edge unless we compensate.
static const CGFloat kVLMPageGutter = 22.0;
static const CGFloat kVLMIconTextGap = 10.0;
static const CGFloat kVLMArrowWidth = 20.0;
static const CGFloat kVLMArrowHeight = 11.0;

#pragma mark - Prefs

static BOOL gEnabled = YES;
static BOOL gContextMenus = YES;
static BOOL gEditMenus = YES;
static BOOL gDebug = NO;
static NSArray<NSDictionary *> *gProfiles;
static NSSet<NSString *> *gLegacyHidden;
static NSInteger gVLMReadingOriginalMenu = 0;

#define VLMLog(fmt, ...) do { \
    if (gDebug) NSLog(@"[VerticalMenu] " fmt, ##__VA_ARGS__); \
} while (0)

static NSDictionary *VLMPrefsDictionary(void) {
    return VLMReadPrefsDictionary();
}

static BOOL VLMBool(NSDictionary *dict, NSString *key, BOOL fallback) {
    id value = dict[key];
    if (!value) {
        return fallback;
    }
    return [value boolValue];
}

static void VLMLoadPrefs(void) {
    static BOOL persistingProfiles;
    NSDictionary *dict = VLMPrefsDictionary();
    gEnabled = VLMBool(dict, @"Enabled", YES);
    gContextMenus = VLMBool(dict, @"ContextMenus", YES);
    gEditMenus = VLMBool(dict, @"EditMenus", YES);
    gDebug = VLMBool(dict, @"Debug", NO);
    id rawProfiles = dict[VLMMenuProfilesKey];
    gProfiles = [VLMSanitizeProfiles(rawProfiles) copy];
    gLegacyHidden = [NSSet setWithArray:VLMSanitizeHiddenIDs(dict[VLMHiddenItemsKey])];
    if (!persistingProfiles && VLMProfilesNeedRewrite(rawProfiles)) {
        persistingProfiles = YES;
        VLMWritePrefsValues(@{VLMMenuProfilesKey: gProfiles ?: @[]}, YES);
        persistingProfiles = NO;
    }
}

static BOOL VLMContextOn(void) {
    return gEnabled && gContextMenus;
}

static BOOL VLMEditOn(void) {
    return gEnabled && gEditMenus;
}

static NSString *VLMTrimTitle(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) {
        return @"";
    }
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    trimmed = [trimmed stringByReplacingOccurrencesOfString:@"…" withString:@""];
    trimmed = [trimmed stringByReplacingOccurrencesOfString:@"..." withString:@""];
    return [trimmed stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL VLMTitleLooksLikeIdentifier(NSString *title) {
    if (title.length < 5) {
        return NO;
    }
    return [title hasPrefix:@"com."]
        || [title hasPrefix:@"_UI"]
        || [title containsString:@".menu."];
}

static NSString *VLMStringProperty(id object, NSString *key) {
    if (!object || key.length == 0) {
        return nil;
    }
    @try {
        id value = [object valueForKey:key];
        if ([value isKindOfClass:[NSAttributedString class]]) {
            value = [(NSAttributedString *)value string];
        }
        if (![value isKindOfClass:[NSString class]]) {
            return nil;
        }
        return VLMTrimTitle(value).length ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *VLMTitleFromObject(id object) {
    if (!object || [object isKindOfClass:[NSNull class]]) {
        return nil;
    }
    if ([object isKindOfClass:[NSString class]]) {
        NSString *clean = VLMTrimTitle(object);
        return clean.length ? clean : nil;
    }
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"title",
            @"attributedTitle",
            @"discoverabilityTitle",
            @"localizedTitle",
            @"accessibilityLabel",
            @"_title",
        ];
    });
    for (NSString *key in keys) {
        NSString *value = VLMStringProperty(object, key);
        NSString *clean = VLMTrimTitle(value);
        if (clean.length == 0 || VLMTitleLooksLikeIdentifier(clean)) {
            continue;
        }
        return clean;
    }
    return nil;
}

static NSString *VLMCustomItemIDForTitle(NSString *title) {
    NSString *fromCatalog = VLMCatalogIDForTitle(title);
    if (fromCatalog) {
        return fromCatalog;
    }
    NSString *clean = VLMTrimTitle(title);
    if (clean.length == 0) {
        return nil;
    }
    return [@"custom:" stringByAppendingString:clean];
}

static BOOL VLMObjectIsMenu(id object) {
    static Class menuClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        menuClass = [UIMenu class];
    });
    return menuClass && object && [object isKindOfClass:menuClass];
}

static BOOL VLMMenuShouldFlatten(id menu) {
    if (!VLMObjectIsMenu(menu)) {
        return NO;
    }
    NSUInteger options = 0;
    if ([menu respondsToSelector:@selector(options)]) {
        options = ((NSUInteger (*)(id, SEL))objc_msgSend)(menu, @selector(options));
    }
    return VLMTitleFromObject(menu).length == 0 || (options & kVLMMenuDisplayInline) != 0;
}

static NSArray *VLMChildrenOfMenu(id menu) {
    if (!VLMObjectIsMenu(menu) || ![menu respondsToSelector:@selector(children)]) {
        return @[];
    }
    gVLMReadingOriginalMenu += 1;
    NSArray *children = ((NSArray *(*)(id, SEL))objc_msgSend)(menu, @selector(children));
    gVLMReadingOriginalMenu -= 1;
    return [children isKindOfClass:[NSArray class]] ? children : @[];
}

static void VLMAppendExpandedElements(NSArray *elements, NSMutableArray *out, BOOL includeNestedSubmenus) {
    for (id element in elements) {
        if (VLMObjectIsMenu(element)) {
            NSArray *kids = VLMChildrenOfMenu(element);
            if (VLMMenuShouldFlatten(element) && kids.count > 0) {
                VLMAppendExpandedElements(kids, out, includeNestedSubmenus);
                continue;
            }
            [out addObject:element];
            if (includeNestedSubmenus && kids.count > 0) {
                VLMAppendExpandedElements(kids, out, includeNestedSubmenus);
            }
            continue;
        }
        if (element) {
            [out addObject:element];
        }
    }
}

static NSArray *VLMExpandedMenuElements(NSArray *elements, BOOL includeNestedSubmenus) {
    if (![elements isKindOfClass:[NSArray class]] || elements.count == 0) {
        return elements ?: @[];
    }
    NSMutableArray *out = [NSMutableArray array];
    VLMAppendExpandedElements(elements, out, includeNestedSubmenus);
    return out;
}

static BOOL VLMObjectLooksLikeMenuElement(id object) {
    if (!object || [object isKindOfClass:[NSNull class]]) {
        return NO;
    }
    static Class elementClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        elementClass = objc_getClass("UIMenuElement");
    });
    if (elementClass && [object isKindOfClass:elementClass]) {
        return YES;
    }
    if ([object isKindOfClass:[NSString class]]) {
        return [(NSString *)object length] > 0;
    }
    return [object respondsToSelector:@selector(title)] || [object respondsToSelector:@selector(action)];
}

static BOOL VLMArrayLooksLikeMenuElements(NSArray *array) {
    if (![array isKindOfClass:[NSArray class]] || array.count < 2) {
        return NO;
    }
    NSInteger hits = 0;
    NSInteger limit = MIN((NSInteger)array.count, 8);
    for (NSInteger index = 0; index < limit; index++) {
        if (VLMObjectLooksLikeMenuElement(array[index])) {
            hits += 1;
        }
    }
    return hits >= 2;
}

static NSArray *VLMDiscoverMenuElements(id object, NSInteger depth) {
    if (!object || depth < 0) {
        return nil;
    }
    if ([object isKindOfClass:[NSString class]] || [object isKindOfClass:[NSNumber class]] || [object isKindOfClass:[NSNull class]]) {
        return nil;
    }
    if ([object isKindOfClass:[NSArray class]]) {
        return VLMArrayLooksLikeMenuElements(object) ? VLMExpandedMenuElements(object, YES) : nil;
    }

    NSMutableArray<NSArray *> *candidates = [NSMutableArray array];
    void (^consider)(NSArray *) = ^(NSArray *elements) {
        NSArray *expanded = VLMExpandedMenuElements(elements, YES);
        if (expanded.count >= 2) {
            [candidates addObject:expanded];
        }
    };

    if (VLMObjectIsMenu(object)) {
        consider(VLMChildrenOfMenu(object));
    }

    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"commands", @"_commands",
            @"displayedCommands", @"_displayedCommands",
            @"elements", @"_elements",
            @"menuElements", @"_menuElements",
            @"displayedMenuElements", @"_displayedMenuElements",
            @"actions", @"_actions",
            @"items", @"_items",
            @"menu", @"_menu",
            @"displayedMenu", @"_displayedMenu",
            @"editMenu", @"_editMenu",
            @"session", @"_session",
            @"presentation", @"_presentation",
        ];
    });
    for (NSString *key in keys) {
        @try {
            NSArray *found = VLMDiscoverMenuElements([object valueForKey:key], depth - 1);
            if (found.count >= 2) {
                [candidates addObject:found];
            }
        } @catch (__unused NSException *exception) {
        }
    }

    if (depth >= 1) {
        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(object_getClass(object), &ivarCount);
        for (unsigned int index = 0; ivars && index < ivarCount && index < 48; index++) {
            const char *encoding = ivar_getTypeEncoding(ivars[index]);
            if (!encoding || encoding[0] != '@') {
                continue;
            }
            id value = object_getIvar(object, ivars[index]);
            if (!value || value == object || [value isKindOfClass:[UIView class]] || [value isKindOfClass:[UIImage class]]) {
                continue;
            }
            if ([value isKindOfClass:[NSArray class]] && VLMArrayLooksLikeMenuElements(value)) {
                consider(value);
            } else if (VLMObjectIsMenu(value)) {
                consider(VLMChildrenOfMenu(value));
            }
        }
        free(ivars);
    }

    NSArray *best = nil;
    for (NSArray *candidate in candidates) {
        if (candidate.count > best.count) {
            best = candidate;
        }
    }
    return best;
}

static BOOL VLMItemHiddenInSet(NSString *itemID, NSSet<NSString *> *hidden) {
    if (itemID.length == 0 || hidden.count == 0) {
        return NO;
    }
    if ([hidden containsObject:itemID]) {
        return YES;
    }
    if ([itemID hasPrefix:@"custom:"]) {
        NSString *catalog = VLMCatalogIDForTitle([itemID substringFromIndex:7]);
        return catalog.length > 0 && [hidden containsObject:catalog];
    }
    for (NSString *hiddenID in hidden) {
        if (![hiddenID hasPrefix:@"custom:"]) {
            continue;
        }
        NSString *catalog = VLMCatalogIDForTitle([hiddenID substringFromIndex:7]);
        if (catalog.length > 0 && [catalog isEqualToString:itemID]) {
            return YES;
        }
    }
    return NO;
}

static BOOL VLMTitleHiddenInSet(NSString *title, NSSet<NSString *> *hidden) {
    return VLMItemHiddenInSet(VLMCustomItemIDForTitle(title), hidden);
}

static NSString *VLMCatalogIDForElement(id element) {
    if (!element || [element isKindOfClass:[NSNull class]]) {
        return nil;
    }
    if ([element isKindOfClass:[NSString class]]) {
        return VLMCustomItemIDForTitle(element);
    }

    NSString *selectorName = nil;
    if ([element respondsToSelector:@selector(action)]) {
        SEL action = ((SEL (*)(id, SEL))objc_msgSend)(element, @selector(action));
        if (action) {
            selectorName = NSStringFromSelector(action);
            NSString *fromSel = VLMCatalogIDForSelectorName(selectorName);
            if (fromSel) {
                return fromSel;
            }
        }
    }

    if ([element respondsToSelector:@selector(identifier)]) {
        id identifier = ((id (*)(id, SEL))objc_msgSend)(element, @selector(identifier));
        if ([identifier isKindOfClass:[NSString class]]) {
            NSString *fromIdent = VLMCatalogIDForIdentifier(identifier);
            if (fromIdent) {
                return fromIdent;
            }
        }
    }

    NSString *title = VLMTitleFromObject(element);
    if (title.length > 0) {
        return VLMCustomItemIDForTitle(title);
    }

    return VLMCustomItemIDForTitle(selectorName);
}

static NSInteger VLMRankForItemID(NSString *itemID, NSArray<NSString *> *orderIDs) {
    if (itemID.length == 0 || orderIDs.count == 0) {
        return NSIntegerMax;
    }
    NSUInteger index = [orderIDs indexOfObject:itemID];
    if (index == NSNotFound) {
        return NSIntegerMax - 1;
    }
    return (NSInteger)index;
}

static NSArray<NSDictionary *> *VLMItemRecordsFromElements(NSArray *elements) {
    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id element in VLMExpandedMenuElements(elements, YES)) {
        NSString *itemID = VLMCatalogIDForElement(element);
        if (itemID.length == 0 || [seen containsObject:itemID]) {
            continue;
        }
        if ([itemID hasPrefix:@"custom:"] && VLMTitleLooksLikeIdentifier([itemID substringFromIndex:7])) {
            continue;
        }
        NSString *title = VLMTitleFromObject(element);
        if (title.length == 0) {
            title = VLMLabelForItemID(itemID);
        }
        if (title.length == 0) {
            continue;
        }
        [seen addObject:itemID];
        [records addObject:@{
            @"id": itemID,
            @"title": title,
        }];
    }
    return records;
}

static NSDictionary *VLMProfileForKind(NSString *kind) {
    return VLMProfileWithID(gProfiles, VLMProfileIDForMenu(kind, VLMCurrentBundleID(), nil));
}

static NSSet<NSString *> *VLMHiddenSetForProfile(NSDictionary *profile) {
    if (profile) {
        return [NSSet setWithArray:VLMProfileHiddenIDs(profile)];
    }
    return gLegacyHidden;
}

static NSArray *VLMFilteredElements(NSArray *elements, NSSet<NSString *> *hidden) {
    if (!gEnabled || hidden.count == 0 || elements.count == 0) {
        return elements;
    }
    NSMutableArray *visible = [NSMutableArray array];
    for (id element in elements) {
        NSString *itemID = VLMCatalogIDForElement(element);
        if (VLMItemHiddenInSet(itemID, hidden) ||
            ([element isKindOfClass:[NSString class]] && VLMTitleHiddenInSet(element, hidden))) {
            continue;
        }
        [visible addObject:element];
    }
    if (visible.count == 0 || visible.count == elements.count) {
        return elements;
    }
    return visible;
}

static NSArray *VLMSortedElements(NSArray *elements, NSArray<NSString *> *orderIDs) {
    if (elements.count < 2 || orderIDs.count == 0) {
        return elements;
    }
    NSArray *sorted = [elements sortedArrayUsingComparator:^NSComparisonResult(id left, id right) {
        NSInteger leftRank = VLMRankForItemID(VLMCatalogIDForElement(left), orderIDs);
        NSInteger rightRank = VLMRankForItemID(VLMCatalogIDForElement(right), orderIDs);
        if (leftRank < rightRank) {
            return NSOrderedAscending;
        }
        if (leftRank > rightRank) {
            return NSOrderedDescending;
        }
        NSUInteger leftIndex = [elements indexOfObjectIdenticalTo:left];
        NSUInteger rightIndex = [elements indexOfObjectIdenticalTo:right];
        if (leftIndex < rightIndex) {
            return NSOrderedAscending;
        }
        if (leftIndex > rightIndex) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
    BOOL changed = NO;
    for (NSUInteger index = 0; index < elements.count; index++) {
        if (elements[index] != sorted[index]) {
            changed = YES;
            break;
        }
    }
    return changed ? sorted : elements;
}

static NSArray *VLMRewrittenElementsForKind(NSArray *elements, NSString *kind) {
    if (!gEnabled || elements.count == 0) {
        return elements;
    }
    BOOL flatten = NO;
    for (id element in elements) {
        if (VLMMenuShouldFlatten(element) && VLMChildrenOfMenu(element).count > 0) {
            flatten = YES;
            break;
        }
    }
    NSArray *working = flatten ? VLMExpandedMenuElements(elements, NO) : elements;
    NSDictionary *profile = VLMProfileForKind(kind);
    NSSet<NSString *> *hidden = VLMHiddenSetForProfile(profile);
    NSArray *filtered = VLMFilteredElements(working, hidden);
    if (profile && VLMProfileCustomOrder(profile)) {
        return VLMSortedElements(filtered, VLMProfileDisplayOrder(profile));
    }
    return filtered;
}

static BOOL VLMCurrentProcessShouldRememberMenus(void) {
    NSString *bundle = VLMCurrentBundleID();
    if ([bundle isEqualToString:@"com.apple.Preferences"] || [bundle hasPrefix:@"com.apple.Preferences"]) {
        return NO;
    }
    return YES;
}

static void VLMRememberMenuProfile(NSString *kind, NSArray<NSDictionary *> *items) {
    if (!gEnabled || items.count < 2 || !VLMCurrentProcessShouldRememberMenus()) {
        return;
    }
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (NSDictionary *item in items) {
        NSString *itemID = item[@"id"];
        if (itemID.length > 0) {
            [ids addObject:itemID];
        }
    }
    if (ids.count < 2) {
        return;
    }
    NSDictionary *existing = VLMProfileForKind(kind);
    if (existing) {
        NSMutableSet<NSString *> *have = [NSMutableSet set];
        for (NSDictionary *item in VLMProfileItems(existing)) {
            if (item[@"id"]) {
                [have addObject:item[@"id"]];
            }
        }
        BOOL hasNew = NO;
        for (NSString *itemID in ids) {
            if (![have containsObject:itemID]) {
                hasNew = YES;
                break;
            }
        }
        if (!hasNew) {
            return;
        }
    }
    NSLog(@"[VerticalMenu] remember %@ in %@ items=%lu", kind, VLMCurrentBundleID(), (unsigned long)ids.count);
    NSDictionary *built = VLMBuildProfile(
        kind,
        VLMCurrentBundleID(),
        VLMGuessAppName(VLMCurrentBundleID()),
        items,
        existing,
        gLegacyHidden.allObjects
    );
    if (!built) {
        return;
    }
    NSArray *updated = VLMUpsertProfile(gProfiles, built);
    gProfiles = [updated copy];
    NSDictionary *payload = @{
        VLMMenuProfilesKey: updated,
        VLMPrefsStampKey: @((NSTimeInterval)[[NSDate date] timeIntervalSince1970]),
    };
    VLMWriteIncomingSnapshot(payload);
    static BOOL scheduledWrite = NO;
    if (scheduledWrite) {
        return;
    }
    scheduledWrite = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        scheduledWrite = NO;
        VLMWritePrefsValues(@{VLMMenuProfilesKey: gProfiles ?: @[]}, YES);
    });
}

static BOOL VLMElementsLookLikeActionMenu(NSArray *elements) {
    NSArray *expanded = VLMExpandedMenuElements(elements, YES);
    if (expanded.count < 2) {
        return NO;
    }
    NSInteger hits = 0;
    for (id element in expanded) {
        NSString *itemID = VLMCatalogIDForElement(element);
        if (itemID.length > 0 && ![itemID hasPrefix:@"custom:"]) {
            hits += 1;
        }
    }
    return hits >= 2;
}

static UIResponder *VLMFindFirstResponder(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    }
    SEL sel = NSSelectorFromString(@"firstResponder");
    for (UIWindow *window in windows) {
        if (![window respondsToSelector:sel]) {
            continue;
        }
        UIResponder *responder = ((id (*)(id, SEL))objc_msgSend)(window, sel);
        if ([responder isKindOfClass:[UIResponder class]]) {
            return responder;
        }
    }
    return nil;
}

static BOOL VLMResponderIsTextInput(UIResponder *responder) {
    while (responder) {
        if ([responder isKindOfClass:[UITextView class]] ||
            [responder isKindOfClass:[UITextField class]]) {
            return YES;
        }
        if ([responder conformsToProtocol:@protocol(UITextInput)]) {
            return YES;
        }
        NSString *name = NSStringFromClass(responder.class);
        if ([name containsString:@"TextView"] ||
            [name containsString:@"TextField"] ||
            [name containsString:@"WKContent"]) {
            return YES;
        }
        responder = responder.nextResponder;
    }
    return NO;
}

static BOOL VLMElementsHaveCatalogHit(NSArray *elements) {
    for (id element in VLMExpandedMenuElements(elements, YES)) {
        NSString *itemID = VLMCatalogIDForElement(element);
        if (itemID.length > 0 && ![itemID hasPrefix:@"custom:"]) {
            return YES;
        }
    }
    return NO;
}

static void VLMRememberUIMenuElements(NSArray *orig, NSString *fallbackKind) {
    if (orig.count == 0) {
        return;
    }
    NSArray *expanded = VLMExpandedMenuElements(orig, YES);
    NSArray<NSDictionary *> *records = VLMItemRecordsFromElements(expanded);
    if (records.count < 2) {
        return;
    }
    BOOL looks = VLMElementsLookLikeActionMenu(expanded) || VLMElementsLookLikeActionMenu(orig);
    BOOL textInput = VLMResponderIsTextInput(VLMFindFirstResponder());
    BOOL catalog = VLMElementsHaveCatalogHit(expanded);
    if (textInput || catalog) {
        VLMRememberMenuProfile(VLMMenuKindEdit, records);
        return;
    }
    if (looks) {
        VLMRememberMenuProfile(fallbackKind, records);
    }
}

static NSArray *VLMFindEditMenuCommands(id host, NSString **outKey) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"commands", @"_commands",
            @"displayedCommands", @"_displayedCommands",
            @"elements", @"_elements",
            @"menuElements", @"_menuElements",
            @"displayedMenuElements", @"_displayedMenuElements",
            @"actions", @"_actions",
            @"items", @"_items",
            @"menu", @"_menu",
            @"displayedMenu", @"_displayedMenu",
        ];
    });
    NSArray *fallback = nil;
    NSString *fallbackKey = nil;
    for (NSString *key in keys) {
        @try {
            id value = [host valueForKey:key];
            if (VLMObjectIsMenu(value)) {
                NSArray *children = VLMChildrenOfMenu(value);
                if (children.count > 0) {
                    if (outKey) {
                        *outKey = nil;
                    }
                    return children;
                }
            }
            if ([value isKindOfClass:[NSArray class]] && [value count] > 0) {
                if (VLMArrayLooksLikeMenuElements(value)) {
                    if (outKey) {
                        *outKey = key;
                    }
                    return value;
                }
                if (!fallback && ([key.lowercaseString containsString:@"command"]
                    || [key.lowercaseString containsString:@"element"]
                    || [key.lowercaseString containsString:@"action"])) {
                    fallback = value;
                    fallbackKey = key;
                }
            }
        } @catch (__unused NSException *exception) {
        }
    }
    if (outKey) {
        *outKey = fallbackKey;
    }
    return fallback;
}

static void VLMRememberEditMenuFromHost(id host, NSArray *commands, NSArray<NSDictionary *> *extraRecords, BOOL searchHost) {
    NSMutableArray<NSDictionary *> *records = [VLMItemRecordsFromElements(commands) mutableCopy] ?: [NSMutableArray array];
    if (searchHost) {
        NSArray *discovered = VLMDiscoverMenuElements(host, 2);
        for (NSDictionary *item in VLMItemRecordsFromElements(discovered)) {
            BOOL exists = NO;
            for (NSDictionary *seen in records) {
                if ([seen[@"id"] isEqualToString:item[@"id"]]) {
                    exists = YES;
                    break;
                }
            }
            if (!exists) {
                [records addObject:item];
            }
        }
    }
    for (NSDictionary *item in extraRecords) {
        NSString *itemID = item[@"id"];
        if (itemID.length == 0) {
            continue;
        }
        BOOL exists = NO;
        for (NSDictionary *seen in records) {
            if ([seen[@"id"] isEqualToString:itemID]) {
                exists = YES;
                break;
            }
        }
        if (!exists) {
            [records addObject:item];
        }
    }
    if (records.count >= 2) {
        VLMRememberMenuProfile(VLMMenuKindEdit, records);
    }
}

static void VLMSortEditMenuHost(id host) {
    NSString *key = nil;
    NSArray *commands = VLMFindEditMenuCommands(host, &key);
    VLMRememberEditMenuFromHost(host, commands, nil, YES);
    if (commands.count == 0 || !key) {
        return;
    }
    NSArray *sorted = VLMRewrittenElementsForKind(commands, VLMMenuKindEdit);
    if (sorted == commands) {
        return;
    }
    @try {
        [host setValue:sorted forKey:key];
        VLMLog(@"rewrote edit commands via %@", key);
    } @catch (__unused NSException *exception) {
    }
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
static const void *kVLMChromeMaskKey = &kVLMChromeMaskKey;
static const void *kVLMStrippedButtonKey = &kVLMStrippedButtonKey;
static const void *kVLMCapturedTitleKey = &kVLMCapturedTitleKey;
static const void *kVLMCapturedImageKey = &kVLMCapturedImageKey;
static const void *kVLMCapturedFontKey = &kVLMCapturedFontKey;
static const void *kVLMCapturedColorKey = &kVLMCapturedColorKey;
static const void *kVLMIndexMapKey = &kVLMIndexMapKey;
static const void *kVLMCapturedTitlesKey = &kVLMCapturedTitlesKey;
static const void *kVLMMapFrozenKey = &kVLMMapFrozenKey;
static const void *kVLMHiddenSetKey = &kVLMHiddenSetKey;
static const void *kVLMRefreshingKey = &kVLMRefreshingKey;
static const void *kVLMSetupDoneKey = &kVLMSetupDoneKey;
static const void *kVLMLastCellSizeKey = &kVLMLastCellSizeKey;
static const void *kVLMDumpedKey = &kVLMDumpedKey;
static const void *kVLMDumpedVisibleKey = &kVLMDumpedVisibleKey;
static const void *kVLMRememberDebounceKey = &kVLMRememberDebounceKey;
static const void *kVLMFrameGuardKey = &kVLMFrameGuardKey;
static const void *kVLMRepairScheduledKey = &kVLMRepairScheduledKey;
static const void *kVLMEffectMaskViewKey = &kVLMEffectMaskViewKey;

static CGRect gKeyboardFrameEnd = {{0, 0}, {0, 0}};
static BOOL gKeyboardVisible = NO;

static BOOL VLMNameLooksLikeArrow(UIView *view);
static void VLMDisableConstraints(UIView *view);
static BOOL VLMImageIsUsableIcon(UIImage *image);
static void VLMRefreshArrow(UIView *host);
static void VLMScheduleArrow(UIView *host);
static void VLMConcealStaleChrome(UIView *host);
static void VLMHideStrayBackdrops(UIView *host);
static void VLMRepairEditMenuChrome(UIView *host);
static void VLMScheduleChromeRepair(UIView *host);
static CGRect VLMClampFrameInSuperview(UIView *view, CGRect frame);
static BOOL VLMCollectionViewIsScrolling(UIScrollView *scrollView);

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
    view.clipsToBounds = YES;
    view.layer.cornerRadius = 14.0;
    view.layer.masksToBounds = YES;
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

static UIColor *VLMMenuBackgroundColor(void) {
    static UIColor *color;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (@available(iOS 13.0, *)) {
            color = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *trait) {
                if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
                    return [UIColor colorWithWhite:0.17 alpha:1.0];
                }
                return [UIColor colorWithWhite:0.98 alpha:1.0];
            }];
        } else {
            color = [UIColor colorWithWhite:0.98 alpha:1.0];
        }
    });
    return color;
}

static void VLMMaskViewToRect(UIView *view, CGRect rectInView) {
    if (!view || rectInView.size.width < 8.0 || rectInView.size.height < 8.0) {
        return;
    }
    CAShapeLayer *mask = objc_getAssociatedObject(view, kVLMChromeMaskKey);
    if (![mask isKindOfClass:[CAShapeLayer class]]) {
        mask = [CAShapeLayer layer];
        mask.fillColor = [UIColor blackColor].CGColor;
        objc_setAssociatedObject(view, kVLMChromeMaskKey, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (view.layer.mask != mask) {
        view.layer.mask = mask;
    }
    CGRect inset = CGRectInset(rectInView, -2.0, -2.0);
    mask.path = [UIBezierPath bezierPathWithRoundedRect:inset cornerRadius:14.0].CGPath;
}

static UIView *VLMContainerAncestor(UIView *host) __attribute__((unused));
static UIView *VLMContainerAncestor(UIView *host) {
    UIView *current = host.superview;
    for (NSInteger depth = 0; current && depth < 8; depth++) {
        if ([current isKindOfClass:[UIWindow class]]) {
            return nil;
        }
        if ([NSStringFromClass(current.class) containsString:@"EditMenuContainer"]) {
            return current;
        }
        current = current.superview;
    }
    return nil;
}

static void VLMConcealStaleChrome(UIView *host) {
    (void)host;
}

static BOOL VLMNameLooksLikeBackdrop(NSString *name) {
    return [name containsString:@"VisualEffect"]
        || [name containsString:@"Backdrop"]
        || [name containsString:@"Platter"]
        || [name containsString:@"Material"]
        || [name containsString:@"Portal"]
        || [name containsString:@"Replicat"]
        || [name containsString:@"Snapshot"]
        || [name containsString:@"Background"]
        || [name localizedCaseInsensitiveContainsString:@"shadow"]
        || [name containsString:@"Dimming"]
        || [name containsString:@"Cutout"];
}

static void VLMHideStrayBackdrops(UIView *host) {
    if (!host.window) {
        return;
    }
    CGRect hostInWindow = [host convertRect:host.bounds toView:host.window];

    UIView *current = host.superview;
    for (NSInteger depth = 0; current && depth < 6; depth++) {
        if ([current isKindOfClass:[UIWindow class]]) {
            break;
        }
        for (UIView *sub in [current.subviews copy]) {
            if (sub == host
                || [host isDescendantOfView:sub]
                || [sub isKindOfClass:[VLMSelectionAnchorView class]]
                || VLMNameLooksLikeArrow(sub)
                || [sub isKindOfClass:[UICollectionView class]]) {
                continue;
            }
            NSString *name = NSStringFromClass(sub.class);
            BOOL backdropLike = [sub isKindOfClass:[UIVisualEffectView class]] || VLMNameLooksLikeBackdrop(name);
            if (!backdropLike) {
                continue;
            }
            CGRect subInWindow = [sub convertRect:sub.bounds toView:sub.window];
            BOOL matchesHost = fabs(subInWindow.origin.x - hostInWindow.origin.x) < 3.0
                && fabs(subInWindow.origin.y - hostInWindow.origin.y) < 3.0
                && fabs(subInWindow.size.width - hostInWindow.size.width) < 6.0
                && fabs(subInWindow.size.height - hostInWindow.size.height) < 6.0;
            if (!matchesHost && !sub.hidden) {
                VLMHideView(sub);
                VLMLog(@"hide backdrop %@ frame=%@", name, NSStringFromCGRect(subInWindow));
            }
        }
        current = current.superview;
    }
}

static void VLMKillSystemBackdrop(UIView *view, NSInteger depth) {
    if (!view || depth < 0) {
        return;
    }
    if ([view isKindOfClass:[UICollectionView class]] || [view isKindOfClass:[UICollectionViewCell class]]) {
        return;
    }
    NSString *name = NSStringFromClass(view.class);
    if ([name containsString:@"PageButton"]
        || [name containsString:@"PageControl"]
        || [name containsString:@"Shadow"]
        || [name containsString:@"Dimming"]
        || [name containsString:@"Cutout"]
        || [name containsString:@"Backdrop"]) {
        VLMHideView(view);
        view.layer.hidden = YES;
        return;
    }
    if ([view isKindOfClass:[UIVisualEffectView class]]) {
        UIVisualEffectView *effectView = (UIVisualEffectView *)view;
        if (effectView.maskView) {
            effectView.maskView = nil;
        }
        if (effectView.effect) {
            effectView.effect = nil;
        }
        effectView.clipsToBounds = YES;
        effectView.layer.cornerRadius = 14.0;
        effectView.layer.masksToBounds = YES;
        effectView.backgroundColor = [UIColor clearColor];
    }
    for (UIView *sub in view.subviews) {
        VLMKillSystemBackdrop(sub, depth - 1);
    }
}

static void VLMFitSystemPlatterToHost(UIView *host) {
    if (!host) {
        return;
    }
    for (UIView *sub in host.subviews) {
        if (![sub isKindOfClass:[UIVisualEffectView class]]) {
            NSString *name = NSStringFromClass(sub.class);
            if ([name containsString:@"Shadow"] || [name containsString:@"PageButton"]) {
                VLMHideView(sub);
            }
            continue;
        }
        if (sub.bounds.size.width >= 8.0 && sub.bounds.size.height >= 8.0) {
            continue;
        }
        VLMDisableConstraints(sub);
        sub.clipsToBounds = YES;
        sub.layer.cornerRadius = 14.0;
        sub.layer.masksToBounds = YES;
        if (!VLMFramesClose(sub.frame, host.bounds)) {
            sub.frame = host.bounds;
        }
    }
}

static void VLMRepairEditMenuChrome(UIView *host) {
    if (!host) {
        return;
    }
    host.clipsToBounds = YES;
    host.layer.cornerRadius = 14.0;
    host.layer.masksToBounds = YES;
    VLMHidePagingControls(host);
    VLMKillSystemBackdrop(host, 6);
    VLMFitSystemPlatterToHost(host);
    VLMHideStrayBackdrops(host);
}

static void VLMScheduleChromeRepair(UIView *host) {
    if (!host || objc_getAssociatedObject(host, kVLMRepairScheduledKey)) {
        return;
    }
    objc_setAssociatedObject(host, kVLMRepairScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakHost = host;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongHost = weakHost;
        if (!strongHost) {
            return;
        }
        objc_setAssociatedObject(strongHost, kVLMRepairScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UICollectionView *collectionView = VLMCollectionViewInHost(strongHost);
        if (VLMCollectionViewIsScrolling(collectionView)) {
            return;
        }
        VLMRepairEditMenuChrome(strongHost);
    });
}

static NSString *VLMHierarchyExtra(UIView *view) {
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *text = ((UILabel *)view).text;
        if (text.length > 40) {
            text = [[text substringToIndex:40] stringByAppendingString:@"..."];
        }
        return text.length ? [NSString stringWithFormat:@" text=%@", text] : @"";
    }
    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *scroll = (UIScrollView *)view;
        return [NSString stringWithFormat:@" offset=%@ content=%@",
                NSStringFromCGPoint(scroll.contentOffset),
                NSStringFromCGSize(scroll.contentSize)];
    }
    return @"";
}

static void VLMAppendHierarchy(UIView *view, UIView *host, NSInteger depth, NSMutableString *out) {
    if (!view || depth > 10 || out.length > 20000) {
        return;
    }
    NSString *pad = [@"" stringByPaddingToLength:MIN(depth * 2, 20) withString:@" " startingAtIndex:0];
    [out appendFormat:@"%@%@%@ frame=%@ hidden=%d alpha=%.2f mask=%d%@\n",
        pad,
        view == host ? @"* " : @"",
        NSStringFromClass(view.class),
        NSStringFromCGRect(view.frame),
        view.hidden,
        view.alpha,
        view.layer.mask != nil,
        VLMHierarchyExtra(view)];
    for (UIView *sub in view.subviews) {
        VLMAppendHierarchy(sub, host, depth + 1, out);
    }
}

static void VLMDumpMenuHierarchy(UIView *host) {
    BOOL visible = host.alpha >= 0.9;
    const void *key = visible ? kVLMDumpedVisibleKey : kVLMDumpedKey;
    if (objc_getAssociatedObject(host, key)) {
        return;
    }
    objc_setAssociatedObject(host, key, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *root = host;
    for (NSInteger depth = 0; root.superview && depth < 10; depth++) {
        if ([root.superview isKindOfClass:[UIWindow class]]) {
            break;
        }
        root = root.superview;
    }

    UIWindow *window = host.window;
    NSString *tmp = NSTemporaryDirectory();
    BOOL incoming = NO;
    if (gProfiles.count > 0) {
        incoming = VLMWriteIncomingSnapshot(@{
            VLMMenuProfilesKey: gProfiles,
            VLMPrefsStampKey: @((NSTimeInterval)[[NSDate date] timeIntervalSince1970]),
        });
    }
    NSMutableString *out = [NSMutableString stringWithFormat:@"[VerticalMenu] hierarchy dump %@ bundle=%@ alpha=%.2f tmp=%@ incoming=%d safe=%@ frame=%@\n",
                            [NSDate date],
                            VLMCurrentBundleID(),
                            host.alpha,
                            tmp,
                            incoming,
                            window ? NSStringFromUIEdgeInsets(window.safeAreaInsets) : @"",
                            NSStringFromCGRect(host.frame)];
    VLMAppendHierarchy(root, host, 0, out);
    NSString *sandboxPath = [tmp stringByAppendingPathComponent:@"VerticalMenu-menu.txt"];
    [out writeToFile:sandboxPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSString *sharedPath = @"/var/tmp/VerticalMenu-menu.txt";
    BOOL shared = [out writeToFile:sharedPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSLog(@"[VerticalMenu] hierarchy -> %@%@ incoming=%d (%@)", sandboxPath, shared ? [NSString stringWithFormat:@" and %@", sharedPath] : @"", incoming, VLMCurrentBundleID());
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

static UIView *VLMFindInputSetHost(UIView *view, NSInteger depth) {
    if (!view || depth < 0) {
        return nil;
    }
    NSString *name = NSStringFromClass(view.class);
    if (([name containsString:@"InputSetHost"] || [name containsString:@"InputSetContainer"] || [name containsString:@"KeyboardAutomatic"])
        && view.bounds.size.height >= 50.0
        && view.bounds.size.width >= 80.0) {
        return view;
    }
    for (UIView *sub in view.subviews) {
        UIView *found = VLMFindInputSetHost(sub, depth - 1);
        if (found) {
            return found;
        }
    }
    return nil;
}

static CGFloat VLMLiveKeyboardMinY(UIWindow *window) {
    if (!window) {
        return CGFLOAT_MAX;
    }
    CGFloat minY = CGFLOAT_MAX;
    CGFloat windowHeight = window.bounds.size.height;
    if (gKeyboardVisible) {
        CGRect keyboard = [window convertRect:gKeyboardFrameEnd fromWindow:nil];
        CGFloat top = CGRectGetMinY(keyboard);
        if (CGRectGetHeight(keyboard) >= 50.0 && top > 80.0 && top < windowHeight - 20.0) {
            minY = MIN(minY, top);
        }
    }
    for (UIWindow *candidate in VLMAllWindows(window)) {
        if (!candidate || candidate.hidden || candidate.alpha < 0.05) {
            continue;
        }
        UIView *host = VLMFindInputSetHost(candidate, 6);
        if (host) {
            CGRect rect = [host convertRect:host.bounds toView:window];
            CGFloat top = CGRectGetMinY(rect);
            if (rect.size.height >= 50.0 && top > 80.0 && top < windowHeight - 20.0) {
                minY = MIN(minY, top);
            }
            continue;
        }
        NSString *name = NSStringFromClass(candidate.class);
        if (![name containsString:@"Keyboard"] && ![name containsString:@"TextEffects"]) {
            continue;
        }
        for (UIView *sub in candidate.subviews) {
            CGRect rect = [sub convertRect:sub.bounds toView:window];
            CGFloat top = CGRectGetMinY(rect);
            if (rect.size.height >= 80.0 && rect.size.height < windowHeight * 0.75 && top > 100.0 && top < windowHeight - 20.0) {
                minY = MIN(minY, top);
            }
        }
    }
    UIView *responder = VLMFirstResponderInView(window);
    if (!responder) {
        responder = VLMResponderFromWindow(window);
    }
    UIView *accessory = responder.inputAccessoryView;
    if (accessory.window) {
        CGRect rect = [accessory convertRect:accessory.bounds toView:window];
        CGFloat top = CGRectGetMinY(rect);
        if (rect.size.height >= 1.0 && top > 80.0 && top < windowHeight) {
            minY = MIN(minY, top);
        }
    }
    return minY;
}

static CGRect VLMClampRectToSafeArea(CGRect frame, UIWindow *window) {
    if (!window) {
        return frame;
    }
    UIEdgeInsets insets = window.safeAreaInsets;
    CGFloat top = MAX(insets.top, 47.0) + kVLMArrowHeight + 6.0;
    CGFloat left = MAX(insets.left, kVLMScreenInset);
    CGFloat right = MAX(insets.right, kVLMScreenInset);
    CGFloat bottomPad = MAX(insets.bottom, 8.0) + kVLMArrowHeight;
    CGFloat maxY = window.bounds.size.height - bottomPad;
    CGFloat keyboardTop = VLMLiveKeyboardMinY(window);
    if (keyboardTop < maxY) {
        maxY = keyboardTop - 6.0;
    }
    CGRect safe = CGRectMake(
        left,
        top,
        MAX(8.0, window.bounds.size.width - left - right),
        MAX(44.0, maxY - top)
    );
    if (frame.size.width > safe.size.width) {
        frame.size.width = safe.size.width;
    }
    if (frame.size.height > safe.size.height) {
        frame.size.height = safe.size.height;
    }
    if (frame.origin.x < safe.origin.x) {
        frame.origin.x = safe.origin.x;
    }
    if (CGRectGetMaxX(frame) > CGRectGetMaxX(safe)) {
        frame.origin.x = CGRectGetMaxX(safe) - frame.size.width;
    }
    if (frame.origin.y < safe.origin.y) {
        frame.origin.y = safe.origin.y;
    }
    if (CGRectGetMaxY(frame) > CGRectGetMaxY(safe)) {
        frame.origin.y = CGRectGetMaxY(safe) - frame.size.height;
    }
    return frame;
}

static CGRect VLMClampFrameInSuperview(UIView *view, CGRect frame) {
    UIWindow *window = view.window;
    UIView *parent = view.superview;
    if (!window || !parent) {
        return frame;
    }
    CGRect inWindow = [parent convertRect:frame toView:window];
    CGRect clamped = VLMClampRectToSafeArea(inWindow, window);
    if (VLMFramesClose(inWindow, clamped)) {
        return frame;
    }
    return [parent convertRect:clamped fromView:window];
}

static BOOL VLMPositionHostNearSelection(UIView *host, CGSize fitted) {
    UIWindow *window = host.window;
    CGRect selection = VLMSelectionRectInWindow(window);
    if (!window || CGRectIsNull(selection) || selection.size.height < 1.0) {
        return NO;
    }

    CGFloat topInset = MAX(window.safeAreaInsets.top, 47.0) + kVLMArrowHeight + 6.0;
    CGFloat leftInset = MAX(window.safeAreaInsets.left, kVLMScreenInset);
    CGFloat rightInset = window.bounds.size.width - MAX(window.safeAreaInsets.right, kVLMScreenInset);

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
    } else {
        listRect.origin.y = selection.origin.y - kVLMSelectionGap - arrowH * 0.35 - fitted.height;
    }
    listRect = VLMClampRectToSafeArea(listRect, window);

    VLMSetFrameInWindow(host, listRect);
    VLMRepairEditMenuChrome(host);
    VLMScheduleArrow(host);
    VLMLog(@"pin selection=%@ list=%@ below=%d", NSStringFromCGRect(selection), NSStringFromCGRect(listRect), below);
    return YES;
}

static void VLMKeepOnScreen(UIView *view) {
    if (!view.window || !view.superview) {
        return;
    }
    CGRect clamped = VLMClampFrameInSuperview(view, view.frame);
    if (VLMFramesClose(view.frame, clamped)) {
        return;
    }
    objc_setAssociatedObject(view, kVLMFrameGuardKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.frame = clamped;
    objc_setAssociatedObject(view, kVLMFrameGuardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSInteger VLMVisibleMappedCount(UICollectionView *collectionView, NSInteger fallback) {
    NSArray<NSNumber *> *map = objc_getAssociatedObject(collectionView, kVLMIndexMapKey);
    if (map.count == 0) {
        return fallback;
    }
    NSInteger visible = 0;
    for (NSNumber *value in map) {
        if (value.integerValue >= 0) {
            visible += 1;
        }
    }
    return visible;
}

static CGSize VLMVerticalFittingSize(id host, CGSize orig) {
    UICollectionView *collectionView = VLMCollectionViewInHost(host);
    NSInteger count = VLMVisibleMappedCount(collectionView, VLMItemCount(collectionView));
    if (count <= 0) {
        CGFloat estimated = orig.width > 1.0 ? round(orig.width / 72.0) : 4.0;
        count = MAX(1, (NSInteger)estimated);
    }

    CGFloat width = kVLMMenuWidth;
    NSInteger visible = MIN(MAX(count, 1), kVLMVisibleRows);
    CGFloat height = visible * kVLMRowHeight + kVLMListInset * 2.0;
    return CGSizeMake(width, height);
}

static void VLMRepositionVisibleEditMenus(void) {
    for (UIWindow *window in VLMAllWindows(nil)) {
        UIView *list = VLMFindEditMenuList(window, 8);
        if (!list || list.alpha < 0.2 || !list.window) {
            continue;
        }
        CGSize fitted = VLMVerticalFittingSize(list, list.bounds.size);
        VLMPositionHostNearSelection(list, fitted);
        VLMKeepOnScreen(list);
        VLMRepairEditMenuChrome(list);
    }
}

static NSInteger VLMDisplayIndexForItem(UICollectionView *collectionView, NSInteger originalIndex) {
    NSArray<NSNumber *> *map = objc_getAssociatedObject(collectionView, kVLMIndexMapKey);
    if (!map || originalIndex < 0 || originalIndex >= (NSInteger)map.count) {
        return originalIndex;
    }
    return map[originalIndex].integerValue;
}

static NSArray<NSNumber *> *VLMIndexMapFromPairedIdentities(NSArray *primary, NSArray *_Nullable secondary, NSSet<NSString *> *hiddenIDs, NSArray<NSString *> *orderIDs, BOOL customOrder) {
    NSInteger count = (NSInteger)primary.count;
    if (count < 1) {
        return nil;
    }

    NSMutableArray<NSNumber *> *ranks = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    NSMutableIndexSet *hidden = [NSMutableIndexSet indexSet];
    for (NSInteger index = 0; index < count; index++) {
        NSString *firstID = VLMCatalogIDForElement(primary[index]);
        NSString *secondID = nil;
        if (index < (NSInteger)secondary.count) {
            secondID = VLMCatalogIDForElement(secondary[index]);
        }
        NSString *title = VLMTitleFromObject(primary[index]);
        if (title.length == 0 && index < (NSInteger)secondary.count) {
            title = VLMTitleFromObject(secondary[index]);
        }
        NSString *itemID = firstID.length ? firstID : secondID;
        if (VLMItemHiddenInSet(firstID, hiddenIDs) || VLMItemHiddenInSet(secondID, hiddenIDs) || VLMTitleHiddenInSet(title, hiddenIDs)) {
            [hidden addIndex:(NSUInteger)index];
        }
        [ranks addObject:@(customOrder ? VLMRankForItemID(itemID, orderIDs) : index)];
    }
    if (hidden.count == 0 && !customOrder) {
        return nil;
    }

    NSMutableArray<NSNumber *> *order = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (NSInteger index = 0; index < count; index++) {
        if (![hidden containsIndex:(NSUInteger)index]) {
            [order addObject:@(index)];
        }
    }
    if (customOrder) {
        [order sortUsingComparator:^NSComparisonResult(NSNumber *left, NSNumber *right) {
            NSInteger leftRank = ranks[left.integerValue].integerValue;
            NSInteger rightRank = ranks[right.integerValue].integerValue;
            if (leftRank < rightRank) {
                return NSOrderedAscending;
            }
            if (leftRank > rightRank) {
                return NSOrderedDescending;
            }
            if (left.integerValue < right.integerValue) {
                return NSOrderedAscending;
            }
            if (left.integerValue > right.integerValue) {
                return NSOrderedDescending;
            }
            return NSOrderedSame;
        }];
    }

    NSMutableArray<NSNumber *> *map = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (NSInteger index = 0; index < count; index++) {
        [map addObject:@(-1)];
    }
    BOOL changed = hidden.count > 0;
    for (NSInteger display = 0; display < (NSInteger)order.count; display++) {
        NSInteger original = order[display].integerValue;
        if (original != display) {
            changed = YES;
        }
        map[original] = @(display);
    }
    return changed ? map : nil;
}

static NSString *VLMTitleFromCell(UICollectionViewCell *cell) {
    if (!cell) {
        return nil;
    }
    NSString *stored = objc_getAssociatedObject(cell.contentView, kVLMCapturedTitleKey);
    NSString *clean = VLMTrimTitle(stored);
    if (clean.length > 0) {
        return clean;
    }
    NSString *fromObject = VLMTitleFromObject(cell);
    if (fromObject.length > 0) {
        return fromObject;
    }
    fromObject = VLMTitleFromObject(cell.contentView);
    if (fromObject.length > 0) {
        return fromObject;
    }
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"command", @"_command",
            @"menuElement", @"_menuElement",
            @"representedObject",
            @"element", @"_element",
            @"item", @"_item",
        ];
    });
    for (NSString *key in keys) {
        @try {
            NSString *title = VLMTitleFromObject([cell valueForKey:key]);
            if (title.length > 0) {
                return title;
            }
        } @catch (__unused NSException *exception) {
        }
    }
    clean = VLMTrimTitle(cell.accessibilityLabel);
    return clean.length > 0 ? clean : nil;
}

static void VLMRefreshCollectionSortMap(id host, UICollectionView *collectionView) {
    if (!collectionView) {
        return;
    }
    if (objc_getAssociatedObject(collectionView, kVLMRefreshingKey)) {
        return;
    }
    objc_setAssociatedObject(collectionView, kVLMRefreshingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL frozen = objc_getAssociatedObject(collectionView, kVLMMapFrozenKey) != nil;

    NSInteger count = VLMItemCount(collectionView);
    NSMutableArray *storedTitles = [objc_getAssociatedObject(collectionView, kVLMCapturedTitlesKey) mutableCopy];
    if (![storedTitles isKindOfClass:[NSMutableArray class]] || (NSInteger)storedTitles.count != count) {
        NSMutableArray *resized = [NSMutableArray array];
        for (NSInteger index = 0; index < count; index++) {
            NSString *previous = (index < (NSInteger)storedTitles.count) ? storedTitles[index] : @"";
            [resized addObject:[previous isKindOfClass:[NSString class]] ? previous : @""];
        }
        storedTitles = resized;
    }

    NSArray *commands = VLMFindEditMenuCommands(host, NULL);
    NSInteger titled = 0;
    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    for (NSInteger index = 0; index < count; index++) {
        NSIndexPath *path = [NSIndexPath indexPathForItem:index inSection:0];
        UICollectionViewCell *cell = [collectionView cellForItemAtIndexPath:path];
        NSString *title = VLMTitleFromCell(cell);
        if (title.length == 0 && index < (NSInteger)commands.count) {
            title = VLMTitleFromObject(commands[index]);
        }
        if (title.length > 0) {
            storedTitles[index] = title;
        }
        NSString *current = storedTitles[index];
        if ([current isKindOfClass:[NSString class]] && VLMTrimTitle(current).length > 0) {
            titled += 1;
            NSString *itemID = VLMCustomItemIDForTitle(current);
            if (itemID.length > 0) {
                [records addObject:@{@"id": itemID, @"title": VLMTrimTitle(current)}];
            }
        }
    }
    objc_setAssociatedObject(collectionView, kVLMCapturedTitlesKey, storedTitles, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    VLMRememberEditMenuFromHost(host, commands, records, records.count < count);

    if (frozen) {
        objc_setAssociatedObject(collectionView, kVLMRefreshingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    NSDictionary *profile = VLMProfileForKind(VLMMenuKindEdit);
    NSSet<NSString *> *hidden = VLMHiddenSetForProfile(profile);
    BOOL customOrder = profile ? VLMProfileCustomOrder(profile) : NO;
    NSArray<NSString *> *orderIDs = profile ? VLMProfileDisplayOrder(profile) : @[];
    objc_setAssociatedObject(collectionView, kVLMHiddenSetKey, hidden, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSArray<NSNumber *> *map = nil;
    if (titled > 0) {
        map = VLMIndexMapFromPairedIdentities(storedTitles, commands, hidden, orderIDs, customOrder);
    }
    if (!map && commands.count > 0) {
        map = VLMIndexMapFromPairedIdentities(commands, nil, hidden, orderIDs, customOrder);
    }

    NSArray<NSNumber *> *current = objc_getAssociatedObject(collectionView, kVLMIndexMapKey);
    if (!((map && [map isEqualToArray:current]) || (!map && !current))) {
        objc_setAssociatedObject(collectionView, kVLMIndexMapKey, map, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [collectionView.collectionViewLayout invalidateLayout];
    }

    if (titled >= 2 && titled >= count) {
        objc_setAssociatedObject(collectionView, kVLMMapFrozenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(collectionView, kVLMRefreshingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL VLMCollectionViewIsScrolling(UIScrollView *scrollView) {
    return scrollView.tracking || scrollView.dragging || scrollView.decelerating;
}

static void VLMScheduleRememberFromList(UIView *host) {
    if (!host) {
        return;
    }
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSNumber *last = objc_getAssociatedObject(host, kVLMRememberDebounceKey);
    if ([last isKindOfClass:[NSNumber class]] && now - last.doubleValue < 0.25) {
        return;
    }
    objc_setAssociatedObject(host, kVLMRememberDebounceKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakHost = host;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   ^{
        UIView *strongHost = weakHost;
        if (!strongHost.window) {
            return;
        }
        UICollectionView *collectionView = VLMCollectionViewInHost(strongHost);
        if (VLMCollectionViewIsScrolling(collectionView)) {
            objc_setAssociatedObject(strongHost, kVLMRememberDebounceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            VLMScheduleRememberFromList(strongHost);
            return;
        }
        VLMRefreshCollectionSortMap(strongHost, collectionView);
    });
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
    NSInteger count = VLMVisibleMappedCount(self.collectionView, [self vlm_itemCount]);
    return CGSizeMake([self vlm_rowWidth], kVLMListInset * 2.0 + MAX(count, 0) * kVLMRowHeight);
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
    NSInteger displayIndex = VLMDisplayIndexForItem(self.collectionView, indexPath.item);
    if (displayIndex < 0) {
        attributes.hidden = YES;
        attributes.frame = CGRectZero;
        return attributes;
    }
    attributes.hidden = NO;
    attributes.frame = CGRectMake(0, kVLMListInset + displayIndex * kVLMRowHeight, width, kVLMRowHeight);
    return attributes;
}

- (BOOL)shouldInvalidateLayoutForBoundsChange:(CGRect)newBounds {
    CGRect oldBounds = self.collectionView.bounds;
    return fabs(oldBounds.size.width - newBounds.size.width) > 0.5;
}

- (CGPoint)targetContentOffsetForProposedContentOffset:(CGPoint)proposedContentOffset withScrollingVelocity:(CGPoint)velocity {
    proposedContentOffset.x = 0;
    return proposedContentOffset;
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

static void VLMExpandCollectionChain(UIView *host, UICollectionView *collectionView) {
    UIView *current = collectionView;
    for (NSInteger depth = 0; current && current != host && depth < 8; depth++) {
        UIView *parent = current.superview;
        if (!parent) {
            break;
        }
        NSString *name = NSStringFromClass(current.class);
        BOOL managedByEffectView = [current isKindOfClass:[UIVisualEffectView class]]
            || [name containsString:@"Backdrop"]
            || [name containsString:@"Shadow"];
        if (!managedByEffectView) {
            CGRect target = (parent == host) ? host.bounds : [parent convertRect:host.bounds fromView:host];
            if (target.size.width < 8.0 || target.size.height < 8.0) {
                target = parent.bounds;
            }
            if (!VLMFramesClose(current.frame, target)) {
                VLMDisableConstraints(current);
                current.frame = target;
            }
        }
        current = parent;
    }
}

static void VLMMatchCollectionFrame(UIView *host, UICollectionView *collectionView) {
    UIView *chainParent = collectionView.superview;
    CGRect targetFrame = host.bounds;
    if (chainParent && chainParent != host) {
        targetFrame = [chainParent convertRect:host.bounds fromView:host];
        if (targetFrame.size.width < 8.0 || targetFrame.size.height < 8.0) {
            targetFrame = chainParent.bounds;
        }
    }
    if (!VLMFramesClose(collectionView.frame, targetFrame)) {
        collectionView.frame = targetFrame;
    }
}

static void VLMStripSizeAnimations(UIView *view) {
    if (!view) {
        return;
    }
    [view.layer removeAnimationForKey:@"bounds"];
    [view.layer removeAnimationForKey:@"bounds.size"];
    [view.layer removeAnimationForKey:@"position"];
    [view.layer removeAnimationForKey:@"position.y"];
    [view.layer removeAnimationForKey:@"transform"];
    [view.layer removeAnimationForKey:@"frame"];
}

static CGRect VLMCoercedListFrame(UIView *host, CGRect frame) {
    CGSize fitted = VLMVerticalFittingSize(host, frame.size);
    frame.size = fitted;
    return frame;
}

static void VLMConfigureCollectionPhysics(UICollectionView *collectionView, NSInteger visibleCount) {
    collectionView.pagingEnabled = NO;
    collectionView.scrollEnabled = YES;
    collectionView.directionalLockEnabled = YES;
    collectionView.alwaysBounceHorizontal = NO;
    collectionView.alwaysBounceVertical = (visibleCount > kVLMVisibleRows);
    collectionView.decelerationRate = UIScrollViewDecelerationRateNormal;
    collectionView.delaysContentTouches = NO;
    collectionView.canCancelContentTouches = YES;
    collectionView.showsHorizontalScrollIndicator = NO;
    collectionView.showsVerticalScrollIndicator = (visibleCount > kVLMVisibleRows);
    collectionView.clipsToBounds = YES;
    collectionView.backgroundColor = VLMMenuBackgroundColor();
    collectionView.layer.cornerRadius = 14.0;
    collectionView.layer.masksToBounds = YES;
    if (@available(iOS 10.0, *)) {
        collectionView.prefetchingEnabled = NO;
    }
    if (@available(iOS 11.0, *)) {
        collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    if (@available(iOS 13.0, *)) {
        collectionView.automaticallyAdjustsScrollIndicatorInsets = NO;
    }
    collectionView.contentInset = UIEdgeInsetsZero;
    collectionView.scrollIndicatorInsets = UIEdgeInsetsZero;
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

    BOOL scrolling = VLMCollectionViewIsScrolling(collectionView);
    BOOL setupDone = objc_getAssociatedObject(host, kVLMSetupDoneKey) != nil;
    if (setupDone && scrolling) {
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

    NSInteger visibleCount = VLMVisibleMappedCount(collectionView, VLMItemCount(collectionView));
    if (setupDone) {
        VLMConfigureCollectionPhysics(collectionView, visibleCount);
        VLMScheduleChromeRepair(host);
        if (!objc_getAssociatedObject(collectionView, kVLMMapFrozenKey)) {
            VLMScheduleRememberFromList(host);
        }
        objc_setAssociatedObject(host, kVLMApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    CGSize fitted = VLMVerticalFittingSize(host, host.bounds.size);
    CGRect coerced = host.frame;
    coerced.size = fitted;
    coerced = VLMClampFrameInSuperview(host, coerced);
    if (!VLMFramesClose(host.bounds, CGRectMake(0, 0, fitted.width, fitted.height))
        || !VLMFramesClose(host.frame, coerced)) {
        objc_setAssociatedObject(host, kVLMFrameGuardKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        host.bounds = CGRectMake(0, 0, fitted.width, fitted.height);
        host.frame = coerced;
        objc_setAssociatedObject(host, kVLMFrameGuardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        VLMStripSizeAnimations(host);
    }

    BOOL onScreen = VLMIsOnScreen(host);
    if (onScreen) {
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
            frame = VLMClampFrameInSuperview(host, frame);
            if (!VLMFramesClose(host.frame, frame)) {
                objc_setAssociatedObject(host, kVLMFrameGuardKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                host.bounds = CGRectMake(0, 0, fitted.width, fitted.height);
                host.frame = frame;
                objc_setAssociatedObject(host, kVLMFrameGuardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                VLMKeepOnScreen(host);
                VLMStripSizeAnimations(host);
            }
            if (!CGRectIsNull(selection)) {
                VLMScheduleArrow(host);
            }
            VLMLog(@"anchor growDown=%d frame=%@", growDown, NSStringFromCGRect(host.frame));
        }
        VLMKeepOnScreen(host);
    }

    VLMUnclipAncestors(host);
    VLMStripShadows(host);
    VLMExpandCollectionChain(host, collectionView);
    VLMRepairEditMenuChrome(host);

    VLMConfigureCollectionPhysics(collectionView, visibleCount);
    VLMMatchCollectionFrame(host, collectionView);

    BOOL needsInstall = ![collectionView.collectionViewLayout isKindOfClass:[VLMVerticalListLayout class]];
    VLMEnsureVerticalListLayout(collectionView);
    if (needsInstall) {
        [collectionView layoutIfNeeded];
    }

    VLMScheduleArrow(host);
    VLMSortEditMenuHost(host);
    VLMRefreshCollectionSortMap(host, collectionView);
    VLMScheduleRememberFromList(host);
    VLMDumpMenuHierarchy(host);
    if (onScreen) {
        objc_setAssociatedObject(host, kVLMSetupDoneKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
        cover.backgroundColor = VLMMenuBackgroundColor();
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

static UIView *VLMEnclosingEditMenuList(UIView *view) {
    static Class listClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        listClass = objc_getClass("_UIEditMenuListView");
    });
    if (!listClass) {
        return nil;
    }
    UIView *current = view;
    for (NSInteger depth = 0; current && depth < 16; depth++) {
        if ([current isKindOfClass:listClass]) {
            return current;
        }
        current = current.superview;
    }
    return nil;
}

// Place the icon so its left edge is always page-gutter + icon inset
// from the list platter, whether or not UIKit reserved space for the
// hidden page buttons. Copy mode (wrapper at x=22) keeps icon-at-16;
// edit mode (flush) shifts the icon by that same 22pt.
static CGFloat VLMAlignedIconLeft(UIView *cell) {
    UIView *list = VLMEnclosingEditMenuList(cell);
    if (!list) {
        return kVLMIconLeft + kVLMPageGutter;
    }
    CGFloat cellMinX = [cell convertPoint:CGPointZero toView:list].x;
    if (cellMinX != cellMinX || fabs(cellMinX) > 500.0) {
        return kVLMIconLeft + kVLMPageGutter;
    }
    CGFloat iconLeft = (kVLMPageGutter + kVLMIconLeft) - cellMinX;
    if (iconLeft < 8.0) {
        return 8.0;
    }
    if (iconLeft > 48.0) {
        return 48.0;
    }
    return iconLeft;
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
    NSValue *lastSize = objc_getAssociatedObject(cell, kVLMLastCellSizeKey);
    if (objc_getAssociatedObject(cell, kVLMTitleOverlayActiveKey)
        && [lastSize isKindOfClass:[NSValue class]]
        && CGSizeEqualToSize(lastSize.CGSizeValue, cell.bounds.size)) {
        UIView *content = [cell isKindOfClass:[UICollectionViewCell class]] ? ((UICollectionViewCell *)cell).contentView : cell;
        UIView *cover = objc_getAssociatedObject(content, kVLMCoverKey);
        if (cover && !CGRectEqualToRect(cover.frame, cell.bounds)) {
            cover.frame = cell.bounds;
        }
        if (!CGRectEqualToRect(content.frame, cell.bounds)) {
            content.frame = cell.bounds;
        }
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
        titleText = VLMTitleFromObject(cell);
    }
    if (titleText.length == 0) {
        titleText = VLMTrimTitle(cell.accessibilityLabel);
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
        NSString *cleanTitle = VLMTrimTitle(titleText);
        BOOL isNew = cleanTitle.length > 0 && ![VLMTrimTitle(storedTitle) isEqualToString:cleanTitle];
        objc_setAssociatedObject(content, kVLMCapturedTitleKey, cleanTitle.length ? cleanTitle : titleText, OBJC_ASSOCIATION_COPY_NONATOMIC);
        if (isNew) {
            VLMScheduleRememberFromList(VLMEnclosingEditMenuList(cell));
        }
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

    if (@available(iOS 11.0, *)) {
        cell.insetsLayoutMarginsFromSafeArea = NO;
        content.insetsLayoutMarginsFromSafeArea = NO;
    }
    cell.layoutMargins = UIEdgeInsetsZero;
    content.layoutMargins = UIEdgeInsetsZero;

    CGFloat iconLeft = VLMAlignedIconLeft(cell);
    CGFloat textX = iconLeft + kVLMIconSize + kVLMIconTextGap;
    CGRect iconRect = CGRectMake(iconLeft, (content.bounds.size.height - kVLMIconSize) / 2.0, kVLMIconSize, kVLMIconSize);
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

    cell.backgroundColor = VLMMenuBackgroundColor();
    if ([cell isKindOfClass:[UICollectionViewCell class]]) {
        ((UICollectionViewCell *)cell).contentView.backgroundColor = VLMMenuBackgroundColor();
    }
    cover.backgroundColor = VLMMenuBackgroundColor();
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
    objc_setAssociatedObject(cell, kVLMLastCellSizeKey, [NSValue valueWithCGSize:cell.bounds.size], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

- (NSArray *)children {
    NSArray *orig = %orig;
    if (gVLMReadingOriginalMenu > 0) {
        return orig;
    }
    if (!gEnabled || orig.count == 0) {
        return orig;
    }
    VLMRememberUIMenuElements(orig, VLMMenuKindContext);
    NSArray *sorted = VLMRewrittenElementsForKind(orig, VLMMenuKindContext);
    if (sorted != orig) {
        VLMLog(@"rewrote UIMenu children %lu -> %lu", (unsigned long)orig.count, (unsigned long)sorted.count);
    }
    return sorted;
}

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
    if (VLMContextOn()) {
        children = VLMRewrittenElementsForKind(children, VLMMenuKindContext);
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
    if (VLMContextOn()) {
        children = VLMRewrittenElementsForKind(children, VLMMenuKindContext);
    }
    UIMenu *menu = %orig;
    if (menu && VLMContextOn()) {
        menu.preferredElementSize = kVLMElementSizeLarge;
    }
    return menu;
}

- (UIMenu *)menuByReplacingChildren:(NSArray *)newChildren {
    if (gEnabled && newChildren.count > 0) {
        VLMRememberUIMenuElements(newChildren, VLMMenuKindContext);
    }
    if (VLMContextOn()) {
        newChildren = VLMRewrittenElementsForKind(newChildren, VLMMenuKindContext);
    }
    UIMenu *menu = %orig;
    if (menu && VLMContextOn()) {
        menu.preferredElementSize = kVLMElementSizeLarge;
    }
    return menu;
}

+ (instancetype)menuWithChildren:(NSArray *)children {
    if (VLMContextOn()) {
        children = VLMRewrittenElementsForKind(children, VLMMenuKindContext);
    }
    return %orig;
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

- (void)setFrame:(CGRect)frame {
    if (VLMEditOn() && !objc_getAssociatedObject(self, kVLMFrameGuardKey)) {
        CGRect coerced = VLMCoercedListFrame(self, frame);
        frame.size = coerced.size;
        if (self.window && self.superview) {
            frame = VLMClampFrameInSuperview(self, frame);
        }
        VLMStripSizeAnimations(self);
    }
    %orig(frame);
}

- (void)setBounds:(CGRect)bounds {
    if (VLMEditOn() && !objc_getAssociatedObject(self, kVLMFrameGuardKey)) {
        CGSize fitted = VLMVerticalFittingSize(self, bounds.size);
        if (fabs(bounds.size.width - fitted.width) > 0.5
            || fabs(bounds.size.height - fitted.height) > 0.5) {
            bounds.size = fitted;
            bounds.origin = CGPointZero;
            VLMStripSizeAnimations(self);
        }
    }
    %orig(bounds);
}

- (void)setAlpha:(CGFloat)alpha {
    CGFloat previous = self.alpha;
    %orig;
    if (!VLMEditOn()) {
        return;
    }
    if (previous < 0.9 && alpha >= 0.9) {
        CGSize fitted = VLMVerticalFittingSize(self, self.bounds.size);
        VLMPositionHostNearSelection(self, fitted);
        VLMKeepOnScreen(self);
        VLMRepairEditMenuChrome(self);
        VLMDumpMenuHierarchy(self);
    }
}

- (void)layoutSubviews {
    %orig;
    if (!VLMEditOn() || objc_getAssociatedObject(self, kVLMLayoutGuardKey)) {
        return;
    }
    objc_setAssociatedObject(self, kVLMLayoutGuardKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UICollectionView *collectionView = VLMCollectionViewInHost(self);
    BOOL scrolling = VLMCollectionViewIsScrolling(collectionView);
    [UIView performWithoutAnimation:^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        VLMApplyVerticalCollectionLayout(self);
        if (!scrolling) {
            VLMRelayoutVisibleCells(self);
        }
        [CATransaction commit];
    }];
    objc_setAssociatedObject(self, kVLMLayoutGuardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)didMoveToWindow {
    %orig;
    if (!self.window) {
        VLMRemoveCustomArrow(self);
        UICollectionView *collectionView = VLMCollectionViewInHost(self);
        objc_setAssociatedObject(collectionView, kVLMMapFrozenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(collectionView, kVLMCapturedTitlesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(collectionView, kVLMIndexMapKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(self, kVLMSetupDoneKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kVLMDumpedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kVLMDumpedVisibleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kVLMRememberDebounceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (!VLMEditOn()) {
        return;
    }
    [UIView performWithoutAnimation:^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        VLMApplyVerticalCollectionLayout(self);
        VLMRelayoutVisibleCells(self);
        [CATransaction commit];
    }];
}

%end

%end

%group EditMenuCells

%hook UICollectionViewCell

- (void)layoutSubviews {
    %orig;
    if (!VLMEditOn()) {
        return;
    }
    NSString *name = NSStringFromClass(self.class);
    if (![name containsString:@"EditMenu"]) {
        return;
    }
    VLMRelayoutCell(self);
}

- (void)prepareForReuse {
    %orig;
    NSString *name = NSStringFromClass(self.class);
    if (![name containsString:@"EditMenu"]) {
        return;
    }
    UIView *content = self.contentView;
    objc_setAssociatedObject(content, kVLMCapturedTitleKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(content, kVLMCapturedImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(content, kVLMCapturedFontKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(content, kVLMCapturedColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kVLMTitleOverlayActiveKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kVLMLastCellSizeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.hidden = NO;
    self.alpha = 1;
    self.userInteractionEnabled = YES;
}

%end

%end

%group EditMenuCollectionView

%hook UICollectionView

- (void)setPagingEnabled:(BOOL)paging {
    if (VLMEditOn() && [self.collectionViewLayout isKindOfClass:[VLMVerticalListLayout class]]) {
        paging = NO;
    }
    %orig(paging);
}

- (BOOL)isPagingEnabled {
    if (VLMEditOn() && [self.collectionViewLayout isKindOfClass:[VLMVerticalListLayout class]]) {
        return NO;
    }
    return %orig;
}

- (void)setAlwaysBounceHorizontal:(BOOL)bounce {
    if (VLMEditOn() && [self.collectionViewLayout isKindOfClass:[VLMVerticalListLayout class]]) {
        bounce = NO;
    }
    %orig(bounce);
}

- (void)setContentOffset:(CGPoint)offset {
    if (VLMEditOn() && fabs(offset.x) > 0.01
        && VLMIsInsideEditMenu(self)
        && [self.collectionViewLayout isKindOfClass:[VLMVerticalListLayout class]]) {
        offset.x = 0;
    }
    %orig(offset);
    if (VLMEditOn()
        && VLMIsInsideEditMenu(self)
        && [self.collectionViewLayout isKindOfClass:[VLMVerticalListLayout class]]
        && !VLMCollectionViewIsScrolling(self)) {
        VLMScheduleChromeRepair(VLMEnclosingEditMenuList(self));
    }
}

- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated {
    if (VLMEditOn() && fabs(offset.x) > 0.01
        && VLMIsInsideEditMenu(self)
        && [self.collectionViewLayout isKindOfClass:[VLMVerticalListLayout class]]) {
        offset.x = 0;
    }
    %orig(offset, animated);
}

- (void)setBounds:(CGRect)bounds {
    if (VLMEditOn() && fabs(bounds.origin.x) > 0.01
        && VLMIsInsideEditMenu(self)
        && [self.collectionViewLayout isKindOfClass:[VLMVerticalListLayout class]]) {
        bounds.origin.x = 0;
    }
    %orig(bounds);
}

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

- (void)didMoveToSuperview {
    %orig;
    if (VLMEditOn()) {
        VLMHideView(self);
    }
}

- (void)setHidden:(BOOL)hidden {
    %orig(VLMEditOn() ? YES : hidden);
}

- (void)setAlpha:(CGFloat)alpha {
    %orig(VLMEditOn() ? 0 : alpha);
}

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
    self.opaque = NO;
    VLMClearLayerShadow(self.layer);
    UIView *list = VLMFindEditMenuList(self, 4);
    if (list && !VLMCollectionViewIsScrolling(VLMCollectionViewInHost(list))) {
        VLMScheduleChromeRepair(list);
    }
    objc_setAssociatedObject(self, kVLMContainerGuardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%end

%end

static void VLMRememberSuggestedEditActions(id menuOrNil, NSArray *suggested) {
    NSArray *source = nil;
    if ([menuOrNil isKindOfClass:[UIMenu class]]) {
        source = ((UIMenu *)menuOrNil).children;
    }
    if (source.count < 2) {
        source = suggested;
    }
    if (source.count >= 2) {
        VLMRememberUIMenuElements(source, VLMMenuKindEdit);
    }
}

%group TextInputEditMenu

%hook UITextView

- (id)editMenuInteraction:(id)interaction menuForConfiguration:(id)config suggestedActions:(NSArray *)actions {
    id menu = %orig;
    VLMRememberSuggestedEditActions(menu, actions);
    return menu;
}

%end

%hook UITextField

- (id)editMenuInteraction:(id)interaction menuForConfiguration:(id)config suggestedActions:(NSArray *)actions {
    id menu = %orig;
    VLMRememberSuggestedEditActions(menu, actions);
    return menu;
}

%end

%end

%group EditMenuInteractionHook

%hook UIEditMenuInteraction

- (void)presentEditMenuWithConfiguration:(id)configuration {
    %orig;
    NSArray *actions = nil;
    @try {
        id value = [configuration valueForKey:@"suggestedActions"];
        if ([value isKindOfClass:[NSArray class]]) {
            actions = value;
        }
    } @catch (__unused NSException *exception) {
    }
    if (actions.count >= 2) {
        VLMRememberUIMenuElements(actions, VLMMenuKindEdit);
    }
}

%end

%end

#pragma mark - Constructor

static void VLMPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    VLMLoadPrefs();
    NSLog(@"[VerticalMenu] prefs reload enabled=%d context=%d edit=%d debug=%d profiles=%lu hidden=%lu", gEnabled, gContextMenus, gEditMenus, gDebug, (unsigned long)gProfiles.count, (unsigned long)gLegacyHidden.count);
}

static void VLMIncomingPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NSString *bundle = [NSBundle mainBundle].bundleIdentifier ?: @"";
    BOOL canIngest = [bundle isEqualToString:@"com.apple.springboard"]
        || [bundle isEqualToString:@"com.apple.Preferences"]
        || [bundle hasPrefix:@"com.apple.Preferences"];
    if (!canIngest) {
        return;
    }
    VLMIngestIncomingPrefs();
    VLMLoadPrefs();
}

%ctor {
    VLMLoadPrefs();
    VLMStartPrefsWriterIfNeeded();
    VLMStartIncomingObserverIfNeeded();
    static id keyboardObserver;
    keyboardObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillChangeFrameNotification
                                                                         object:nil
                                                                          queue:[NSOperationQueue mainQueue]
                                                                     usingBlock:^(NSNotification *note) {
        NSValue *value = note.userInfo[UIKeyboardFrameEndUserInfoKey];
        if (![value isKindOfClass:[NSValue class]]) {
            return;
        }
        gKeyboardFrameEnd = [value CGRectValue];
        gKeyboardVisible = CGRectGetHeight(gKeyboardFrameEnd) >= 50.0;
        VLMRepositionVisibleEditMenus();
    }];
    (void)keyboardObserver;
    static id keyboardHideObserver;
    keyboardHideObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillHideNotification
                                                                             object:nil
                                                                              queue:[NSOperationQueue mainQueue]
                                                                         usingBlock:^(NSNotification *note) {
        (void)note;
        gKeyboardVisible = NO;
        VLMRepositionVisibleEditMenus();
    }];
    (void)keyboardHideObserver;
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        VLMPrefsChanged,
        (__bridge CFStringRef)kVLMReloadNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        VLMIncomingPrefsChanged,
        (__bridge CFStringRef)VLMIncomingNotificationName,
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
    SEL editMenuSel = @selector(editMenuInteraction:menuForConfiguration:suggestedActions:);
    if ([UITextView instancesRespondToSelector:editMenuSel] || [UITextField instancesRespondToSelector:editMenuSel]) {
        %init(TextInputEditMenu);
    }
    if (objc_getClass("UIEditMenuInteraction")) {
        %init(EditMenuInteractionHook);
    }

    NSLog(@"[VerticalMenu] loaded in %@ enabled=%d context=%d edit=%d debug=%d list=%d profiles=%lu",
          [NSBundle mainBundle].bundleIdentifier ?: @"?",
          gEnabled, gContextMenus, gEditMenus, gDebug, hookedList, (unsigned long)gProfiles.count);
}
