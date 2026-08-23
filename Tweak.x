#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "VLMMenuOrder.h"
#import "VLMMenuGeometry.h"

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
static const CGFloat kVLMArrowWidth = 18.0;
static const CGFloat kVLMArrowHeight = 9.0;
static const CGFloat kVLMArrowOverlap = 1.5;

#pragma mark - Prefs

static BOOL gEnabled = YES;
static BOOL gContextMenus = YES;
static BOOL gEditMenus = YES;
static BOOL gDebug = NO;
static NSArray<NSDictionary *> *gRegistry;
static NSDictionary<NSString *, NSDictionary *> *gRegistryByID;
static NSDictionary *gResolvedEditPolicy;
static NSDictionary *gResolvedContextPolicy;
static const void *kVLMDeferredKindKey = &kVLMDeferredKindKey;

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
    NSDictionary *dict = VLMPrefsDictionary();
    gEnabled = VLMBool(dict, @"Enabled", YES);
    gContextMenus = VLMBool(dict, @"ContextMenus", YES);
    gEditMenus = VLMBool(dict, @"EditMenus", YES);
    gDebug = VLMBool(dict, @"Debug", NO);
    VLMSetDebugLoggingEnabled(gDebug);
    gRegistry = [dict[VLMMenuRegistryKey] isKindOfClass:[NSArray class]]
        ? [dict[VLMMenuRegistryKey] copy] : @[];
    NSMutableDictionary<NSString *, NSDictionary *> *registryIndex = [NSMutableDictionary dictionaryWithCapacity:gRegistry.count];
    for (NSDictionary *record in gRegistry) {
        NSString *recordID = record[@"id"];
        if (recordID.length > 0) {
            registryIndex[recordID] = record;
        }
    }
    gRegistryByID = [registryIndex copy];
    NSString *bundleID = VLMCurrentBundleID();
    gResolvedEditPolicy = [VLMResolvedPolicyForKindInPrefs(dict, bundleID, VLMMenuKindEdit) copy];
    gResolvedContextPolicy = [VLMResolvedPolicyForKindInPrefs(dict, bundleID, VLMMenuKindContext) copy];
}

static BOOL VLMContextOn(void) {
    return gEnabled && gContextMenus;
}

static BOOL VLMEditOn(void) {
    return gEnabled && gEditMenus;
}

static BOOL VLMKindOn(NSString *kind) {
    return [kind isEqualToString:VLMMenuKindContext] ? VLMContextOn() : VLMEditOn();
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
    return VLMRulesItemIDForTitle(VLMCatalogItems(), title);
}

static NSString *VLMWeakItemIDForTitle(NSString *title) {
    NSString *catalogID = VLMCatalogIDForTitle(title);
    if (catalogID.length > 0) {
        return catalogID;
    }
    NSString *folded = VLMRulesFoldedText(title);
    if (folded.length == 0) {
        return nil;
    }
    return [NSString stringWithFormat:@"title:%@:%@", VLMCurrentBundleID(), folded];
}

static BOOL VLMIdentifierLooksGenerated(NSString *identifier) {
    if (identifier.length == 0) return NO;
    return [[NSUUID alloc] initWithUUIDString:identifier] != nil;
}

static NSString *VLMPropertyListToken(id propertyList) {
    NSString *value = nil;
    if ([propertyList isKindOfClass:[NSString class]]) value = propertyList;
    else if ([propertyList isKindOfClass:[NSNumber class]]) value = [propertyList stringValue];
    if (value.length == 0) return nil;
    const char *bytes = value.UTF8String;
    uint64_t hash = 14695981039346656037ULL;
    for (const unsigned char *cursor = (const unsigned char *)bytes; cursor && *cursor; cursor++) {
        hash ^= *cursor;
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"%016llx", (unsigned long long)hash];
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
    NSArray *children = ((NSArray *(*)(id, SEL))objc_msgSend)(menu, @selector(children));
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

static NSString *VLMCatalogIDForElement(id element) {
    if (!element || [element isKindOfClass:[NSNull class]]) {
        return nil;
    }
    if ([element isKindOfClass:[NSString class]]) {
        return VLMWeakItemIDForTitle(element);
    }

    if ([element isKindOfClass:[UIAction class]] && [element respondsToSelector:@selector(identifier)]) {
        id identifier = ((id (*)(id, SEL))objc_msgSend)(element, @selector(identifier));
        if ([identifier isKindOfClass:[NSString class]] && [identifier length] > 0
            && !VLMIdentifierLooksGenerated(identifier)) {
            NSString *catalog = VLMCatalogIDForIdentifier(identifier);
            return catalog ?: [@"action:" stringByAppendingString:identifier];
        }
        return VLMWeakItemIDForTitle(VLMTitleFromObject(element));
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
            id propertyList = nil;
            if ([element respondsToSelector:@selector(propertyList)]) {
                propertyList = ((id (*)(id, SEL))objc_msgSend)(element, @selector(propertyList));
            }
            NSString *propertyToken = VLMPropertyListToken(propertyList);
            if (propertyToken.length > 0) {
                return [NSString stringWithFormat:@"command:%@:pl-%@", selectorName, propertyToken];
            }
            return [@"command:" stringByAppendingString:selectorName];
        }
    }

    if ([element respondsToSelector:@selector(identifier)]) {
        id identifier = ((id (*)(id, SEL))objc_msgSend)(element, @selector(identifier));
        if ([identifier isKindOfClass:[NSString class]] && [identifier length] > 0
            && !VLMIdentifierLooksGenerated(identifier)) {
            NSString *fromIdent = VLMCatalogIDForIdentifier(identifier);
            if (fromIdent) {
                return fromIdent;
            }
            Class deferredClass = objc_getClass("UIDeferredMenuElement");
            NSString *prefix = VLMObjectIsMenu(element) ? @"menu:"
                : (deferredClass && [element isKindOfClass:deferredClass] ? @"deferred:" : @"element:");
            return [prefix stringByAppendingString:identifier];
        }
    }

    NSString *title = VLMTitleFromObject(element);
    if (title.length > 0) {
        return VLMWeakItemIDForTitle(title);
    }

    return selectorName.length ? [@"command:" stringByAppendingString:selectorName] : nil;
}

static NSArray<NSDictionary *> *VLMItemRecordsFromElements(NSArray *elements) {
    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id element in VLMExpandedMenuElements(elements, YES)) {
        NSString *itemID = VLMCatalogIDForElement(element);
        if (itemID.length == 0 || [seen containsObject:itemID]) {
            continue;
        }
        NSString *title = VLMTitleFromObject(element);
        if (([itemID hasPrefix:@"custom:"] || [itemID hasPrefix:@"title:"])
            && VLMTitleLooksLikeIdentifier(title)) {
            continue;
        }
        if (title.length == 0) {
            title = VLMLabelForItemID(itemID) ?: itemID;
        }
        if (VLMIsCapturedJunkItem(title, itemID)) {
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

static NSDictionary *VLMRegistryRecordForKind(NSString *kind) {
    return gRegistryByID[VLMProfileIDForMenu(kind, VLMCurrentBundleID(), nil)];
}

static NSDictionary *VLMPolicyForKind(NSString *kind) {
    return [kind isEqualToString:VLMMenuKindContext]
        ? (gResolvedContextPolicy ?: VLMRulesNormalizedPolicy(nil))
        : (gResolvedEditPolicy ?: VLMRulesNormalizedPolicy(nil));
}

static NSArray<NSString *> *VLMOrderByReplacingLegacyID(NSArray<NSString *> *order,
                                                         NSString *legacyID,
                                                         NSString *stableID) {
    if (legacyID.length == 0 || stableID.length == 0 || [legacyID isEqualToString:stableID] || ![order containsObject:legacyID]) {
        return order;
    }
    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:order.count];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *itemID in order) {
        NSString *next = [itemID isEqualToString:legacyID] ? stableID : itemID;
        if (next.length > 0 && ![seen containsObject:next]) {
            [seen addObject:next];
            [result addObject:next];
        }
    }
    return result;
}

static BOOL VLMPolicyContainsLegacyTitleIDs(NSDictionary *policy) {
    for (id itemID in [policy[@"visibility"] allKeys]) {
        if ([itemID isKindOfClass:[NSString class]] && [itemID hasPrefix:@"custom:"]) return YES;
    }
    for (NSString *field in @[@"first", @"relative", @"last"]) {
        NSArray *order = [policy[field] isKindOfClass:[NSArray class]] ? policy[field] : @[];
        for (id itemID in order) {
            if ([itemID isKindOfClass:[NSString class]] && [itemID hasPrefix:@"custom:"]) return YES;
        }
    }
    return NO;
}

static NSDictionary *VLMPolicyWithLegacyAliases(NSDictionary *policy, NSArray *elements) {
    if (!VLMPolicyContainsLegacyTitleIDs(policy)) {
        return policy;
    }
    NSMutableDictionary *result = [VLMRulesNormalizedPolicy(policy) mutableCopy];
    NSMutableDictionary *visibility = [result[@"visibility"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSArray *first = result[@"first"] ?: @[];
    NSArray *relative = result[@"relative"] ?: @[];
    NSArray *last = result[@"last"] ?: @[];
    for (id element in elements) {
        NSString *title = VLMTitleFromObject(element);
        NSString *legacyID = VLMCustomItemIDForTitle(title);
        NSString *stableID = VLMCatalogIDForElement(element);
        if (legacyID.length == 0 || stableID.length == 0 || [legacyID isEqualToString:stableID]) continue;
        if (!visibility[stableID] && visibility[legacyID]) visibility[stableID] = visibility[legacyID];
        first = VLMOrderByReplacingLegacyID(first, legacyID, stableID);
        relative = VLMOrderByReplacingLegacyID(relative, legacyID, stableID);
        last = VLMOrderByReplacingLegacyID(last, legacyID, stableID);
    }
    result[@"visibility"] = visibility;
    result[@"first"] = first;
    result[@"relative"] = relative;
    result[@"last"] = last;
    return VLMRulesNormalizedPolicy(result);
}

static UIMenu *VLMRewrittenMenuForKind(UIMenu *menu, NSString *kind);

static NSArray *VLMRewrittenElementsForKind(NSArray *elements, NSString *kind) {
    if (!VLMKindOn(kind) || elements.count == 0) {
        return elements;
    }
    NSMutableArray *tree = [NSMutableArray arrayWithCapacity:elements.count];
    BOOL treeChanged = NO;
    for (id element in elements) {
        if (!VLMObjectIsMenu(element)) {
            Class deferredClass = objc_getClass("UIDeferredMenuElement");
            if (deferredClass && [element isKindOfClass:deferredClass]) {
                objc_setAssociatedObject(element, kVLMDeferredKindKey, kind, OBJC_ASSOCIATION_COPY_NONATOMIC);
            }
            [tree addObject:element];
            continue;
        }
        NSArray *originalChildren = VLMChildrenOfMenu(element);
        UIMenu *rewrittenMenu = VLMRewrittenMenuForKind(element, kind);
        NSArray *rewrittenChildren = VLMChildrenOfMenu(rewrittenMenu);
        if (originalChildren.count > 0 && rewrittenChildren.count == 0) {
            treeChanged = YES;
            continue;
        }
        [tree addObject:rewrittenMenu];
        treeChanged = treeChanged || rewrittenMenu != element;
    }
    NSArray *working = treeChanged ? tree : elements;
    NSDictionary *policy = VLMPolicyWithLegacyAliases(VLMPolicyForKind(kind), working);
    return VLMRulesApplyPolicyToItems(working, policy, ^NSString *(id element) {
        return VLMCatalogIDForElement(element);
    });
}

static UIMenu *VLMRewrittenMenuForKind(UIMenu *menu, NSString *kind) {
    if (!menu) return nil;
    NSArray *children = VLMChildrenOfMenu(menu);
    NSArray *rewritten = VLMRewrittenElementsForKind(children, kind);
    if (rewritten == children) return menu;
    return [menu menuByReplacingChildren:rewritten];
}

static BOOL VLMCurrentProcessShouldRememberMenus(void) {
    NSString *bundle = VLMCurrentBundleID();
    if ([bundle isEqualToString:@"com.apple.Preferences"] || [bundle hasPrefix:@"com.apple.Preferences"]) {
        return NO;
    }
    return YES;
}

static void VLMRememberMenuProfile(NSString *kind, NSArray<NSDictionary *> *items) {
    if (![NSThread isMainThread]) {
        NSString *kindSnapshot = [kind copy];
        NSArray<NSDictionary *> *itemsSnapshot = [items copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            VLMRememberMenuProfile(kindSnapshot, itemsSnapshot);
        });
        return;
    }
    if (!gEnabled || items.count < 2 || !VLMCurrentProcessShouldRememberMenus()) {
        return;
    }
    NSDictionary *existing = VLMRegistryRecordForKind(kind);
    NSMutableDictionary<NSString *, NSString *> *knownTitles = [NSMutableDictionary dictionary];
    for (NSDictionary *item in VLMProfileItems(existing)) {
        if ([item[@"id"] length] > 0) knownTitles[item[@"id"]] = item[@"title"] ?: @"";
    }
    BOOL changed = existing == nil;
    for (NSDictionary *item in items) {
        NSString *itemID = item[@"id"];
        if (itemID.length == 0) continue;
        NSString *title = item[@"title"] ?: @"";
        if (!knownTitles[itemID] || ![knownTitles[itemID] isEqualToString:title]) {
            changed = YES;
            break;
        }
    }
    if (!changed) return;
    VLMLog(@"remember %@ in %@ items=%lu", kind, VLMCurrentBundleID(), (unsigned long)items.count);
    NSDictionary *built = VLMBuildRegistryRecord(
        kind,
        VLMCurrentBundleID(),
        VLMGuessAppName(VLMCurrentBundleID()),
        items,
        existing
    );
    if (!built) {
        return;
    }
    NSArray *updated = VLMUpsertRegistryRecord(gRegistry, built);
    gRegistry = [updated copy];
    NSMutableDictionary<NSString *, NSDictionary *> *nextIndex = [gRegistryByID mutableCopy] ?: [NSMutableDictionary dictionary];
    NSDictionary *storedRecord = VLMRegistryRecordWithID(updated, built[@"id"]);
    if (storedRecord) {
        nextIndex[built[@"id"]] = storedRecord;
    }
    gRegistryByID = [nextIndex copy];
    static BOOL scheduledWrite = NO;
    static NSMutableSet<NSString *> *pendingRecordIDs = nil;
    if (!pendingRecordIDs) {
        pendingRecordIDs = [NSMutableSet set];
    }
    [pendingRecordIDs addObject:built[@"id"]];
    if (scheduledWrite) {
        return;
    }
    scheduledWrite = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   ^{
        scheduledWrite = NO;
        NSArray<NSString *> *recordIDs = pendingRecordIDs.allObjects;
        [pendingRecordIDs removeAllObjects];
        NSMutableArray<NSDictionary *> *records = [NSMutableArray arrayWithCapacity:recordIDs.count];
        for (NSString *recordID in recordIDs) {
            NSDictionary *record = VLMRegistryRecordWithID(gRegistry, recordID);
            if (record) [records addObject:record];
        }
        if (records.count > 0) {
            VLMWritePrefsValuesAsync(@{VLMMenuRegistryKey: records}, YES);
        }
    });
}

static void VLMRememberUIMenuElements(NSArray *orig, NSString *fallbackKind) {
    if (orig.count == 0) {
        return;
    }
    NSArray<NSDictionary *> *records = VLMItemRecordsFromElements(orig);
    if (records.count < 2) {
        return;
    }
    if (records.count > 64) records = [records subarrayWithRange:NSMakeRange(0, 64)];
    VLMRememberMenuProfile(fallbackKind, records);
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
    (void)host;
    (void)searchHost;
    NSArray<NSDictionary *> *commandRecords = VLMItemRecordsFromElements(commands);
    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    void (^addRecord)(NSString *, NSString *) = ^(NSString *itemID, NSString *title) {
        if (itemID.length == 0 || [seen containsObject:itemID]) {
            return;
        }
        if (VLMIsCapturedJunkItem(title, itemID)) {
            return;
        }
        [seen addObject:itemID];
        [records addObject:@{
            @"id": itemID,
            @"title": title.length ? title : (VLMLabelForItemID(itemID) ?: itemID),
        }];
    };

    if (extraRecords.count >= 2) {
        for (NSDictionary *cell in extraRecords) {
            NSString *title = VLMTrimTitle(cell[@"title"]);
            if (title.length == 0) {
                continue;
            }
            NSString *itemID = VLMCatalogIDForTitle(title) ?: cell[@"id"];
            for (NSDictionary *command in commandRecords) {
                if ([VLMTrimTitle(command[@"title"]) isEqualToString:title]) {
                    itemID = command[@"id"];
                    break;
                }
            }
            if (itemID.length == 0) {
                itemID = VLMWeakItemIDForTitle(title);
            }
            addRecord(itemID, title);
        }
    }
    if (records.count >= 2) {
        VLMRememberMenuProfile(VLMMenuKindEdit, records);
    }
}

static void VLMSortEditMenuHost(id host) {
    NSArray *commands = VLMFindEditMenuCommands(host, NULL);
    VLMRememberEditMenuFromHost(host, commands, nil, NO);
}

#pragma mark - View helpers

static const void *kVLMApplyingKey = &kVLMApplyingKey;
static const void *kVLMLayoutGuardKey = &kVLMLayoutGuardKey;
static const void *kVLMLoggedLayoutKey = &kVLMLoggedLayoutKey;
static const void *kVLMGrowDownKey = &kVLMGrowDownKey;
static const void *kVLMFallbackIconKey = &kVLMFallbackIconKey;
static const void *kVLMTitleSlotKey = &kVLMTitleSlotKey;
static const void *kVLMCoverKey = &kVLMCoverKey;
static const void *kVLMHadTitleKey = &kVLMHadTitleKey;
static const void *kVLMContainerGuardKey = &kVLMContainerGuardKey;
static const void *kVLMCellGuardKey = &kVLMCellGuardKey;
static const void *kVLMChromeMaskKey = &kVLMChromeMaskKey;
static const void *kVLMStrippedButtonKey = &kVLMStrippedButtonKey;
static const void *kVLMCapturedTitleKey = &kVLMCapturedTitleKey;
static const void *kVLMCapturedImageKey = &kVLMCapturedImageKey;
static const void *kVLMCapturedFontKey = &kVLMCapturedFontKey;
static const void *kVLMCapturedColorKey = &kVLMCapturedColorKey;
static const void *kVLMCapturedTitlesKey = &kVLMCapturedTitlesKey;
static const void *kVLMRefreshingKey = &kVLMRefreshingKey;
static const void *kVLMSetupDoneKey = &kVLMSetupDoneKey;
static const void *kVLMLastCellSizeKey = &kVLMLastCellSizeKey;
static const void *kVLMLastCellIdentityKey = &kVLMLastCellIdentityKey;
static const void *kVLMManagedCellKey = &kVLMManagedCellKey;
static const void *kVLMCellRetryKey = &kVLMCellRetryKey;
static const void *kVLMAlignedIconLeftKey = &kVLMAlignedIconLeftKey;
static const void *kVLMCollectionKey = &kVLMCollectionKey;
static const void *kVLMViewportSizeKey = &kVLMViewportSizeKey;
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
static UIColor *VLMMenuBackgroundColor(void);
static CGRect VLMSelectionRectInWindow(UIWindow *window);
static void VLMSetSystemArrowDirection(UIView *host, BOOL below);
static void VLMAttachSystemArrows(UIView *host, BOOL below);
static void VLMConcealStaleChrome(UIView *host);
static void VLMHideStrayBackdrops(UIView *host);
static void VLMRepairEditMenuChrome(UIView *host);
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
    UICollectionView *cached = objc_getAssociatedObject(host, kVLMCollectionKey);
    if (cached && [cached isDescendantOfView:host]) {
        return cached;
    }
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[@"collectionView", @"_collectionView", @"_listCollectionView"];
    });
    for (NSString *key in keys) {
        @try {
            id value = [host valueForKey:key];
            if ([value isKindOfClass:[UICollectionView class]]) {
                objc_setAssociatedObject(host, kVLMCollectionKey, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                return value;
            }
        } @catch (__unused NSException *exception) {
        }
    }
    UICollectionView *found = VLMFindCollectionView(host);
    if (found) {
        objc_setAssociatedObject(host, kVLMCollectionKey, found, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return found;
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
    view.layer.masksToBounds = NO;
    UIView *current = view.superview;
    for (NSInteger depth = 0; current && depth < 6; depth++) {
        if ([current isKindOfClass:[UIWindow class]]) {
            break;
        }
        current.clipsToBounds = NO;
        current.layer.masksToBounds = NO;
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

static BOOL VLMNameLooksLikeArrow(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    if ([name containsString:@"Page"]
        || [name containsString:@"Collection"]
        || [name containsString:@"Cell"]
        || [name containsString:@"Image"]
        || [name containsString:@"Label"]
        || [name containsString:@"Button"]) {
        return NO;
    }
    return [name containsString:@"Arrow"]
        || [name containsString:@"Pointer"]
        || [name containsString:@"Beak"]
        || [name containsString:@"PopoverShape"]
        || [name containsString:@"MenuPointer"];
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
    UIWindow *window = host.window;
    CGRect selection = VLMSelectionRectInWindow(window);
    if (window && !CGRectIsNull(selection) && selection.size.height >= 1.0) {
        CGRect onScreen = [host convertRect:host.bounds toView:window];
        growDown = CGRectGetMidY(selection) <= CGRectGetMidY(onScreen);
        VLMLog(@"selection midY=%.1f hostMid=%.1f growDown=%d", CGRectGetMidY(selection), CGRectGetMidY(onScreen), growDown);
    } else if (window) {
        CGRect onScreen = [host convertRect:host.bounds toView:window];
        CGFloat topBand = MAX(window.safeAreaInsets.top, 20.0) + 96.0;
        growDown = onScreen.origin.y < topBand;
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

static void VLMCollectSelectionHandles(UIView *view, NSMutableArray<UIView *> *handles, NSInteger depth) {
    if (!view || depth < 0 || handles.count > 8) {
        return;
    }
    NSString *name = NSStringFromClass(view.class);
    if ([name containsString:@"Grabber"] || [name containsString:@"SelectionHandle"] || [name containsString:@"TextRangeView"]) {
        if (view.bounds.size.width > 1.0 && view.bounds.size.height > 1.0) {
            [handles addObject:view];
        }
    }
    for (UIView *sub in view.subviews) {
        VLMCollectSelectionHandles(sub, handles, depth - 1);
    }
}

static CGRect VLMTightestSelectionRect(NSArray<UITextSelectionRect *> *rects, id<UITextInput> input, UIWindow *window) {
    CGRect first = CGRectNull;
    CGRect tight = CGRectNull;
    CGFloat tightArea = CGFLOAT_MAX;
    for (UITextSelectionRect *item in rects) {
        CGRect converted = VLMConvertTextRectToWindow(input, item.rect, window);
        if (CGRectIsNull(converted) || converted.size.height < 0.5) {
            continue;
        }
        if (CGRectIsNull(first)) {
            first = converted;
        }
        CGFloat area = converted.size.width * converted.size.height;
        if (converted.size.width >= 6.0 && converted.size.width <= 160.0 && area < tightArea) {
            tight = converted;
            tightArea = area;
        }
    }
    if (!CGRectIsNull(tight)) {
        return tight;
    }
    return first;
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
        CGRect firstRect = VLMConvertTextRectToWindow(input, [input firstRectForRange:range], ownerWindow);
        CGRect tight = VLMTightestSelectionRect(rects, input, ownerWindow);
        if (!CGRectIsNull(tight) && tight.size.width <= 160.0) {
            unionRect = tight;
        } else if (!CGRectIsNull(firstRect) && firstRect.size.width <= 220.0 && firstRect.size.height > 0.5) {
            unionRect = firstRect;
        } else {
            for (UITextSelectionRect *item in rects) {
                CGRect converted = VLMConvertTextRectToWindow(input, item.rect, ownerWindow);
                if (!CGRectIsNull(converted) && converted.size.height > 0.5) {
                    unionRect = CGRectIsNull(unionRect) ? converted : CGRectUnion(unionRect, converted);
                }
            }
            if (!CGRectIsNull(unionRect) && unionRect.size.width > 180.0 && !CGRectIsNull(firstRect) && firstRect.size.width < unionRect.size.width) {
                unionRect = firstRect;
            }
        }
    }
    if ([responder isKindOfClass:[UIView class]]) {
        NSMutableArray<UIView *> *handles = [NSMutableArray array];
        VLMCollectSelectionHandles(responder, handles, 8);
        if (handles.count >= 2) {
            CGFloat minX = CGFLOAT_MAX;
            CGFloat maxX = -CGFLOAT_MAX;
            CGFloat minY = CGFLOAT_MAX;
            CGFloat maxY = -CGFLOAT_MAX;
            for (UIView *handle in handles) {
                CGRect handleRect = [handle convertRect:handle.bounds toView:ownerWindow];
                minX = MIN(minX, CGRectGetMidX(handleRect));
                maxX = MAX(maxX, CGRectGetMidX(handleRect));
                minY = MIN(minY, CGRectGetMinY(handleRect));
                maxY = MAX(maxY, CGRectGetMaxY(handleRect));
            }
            if (maxX > minX) {
                CGRect handleRect = CGRectMake(minX, minY, MAX(8.0, maxX - minX), MAX(16.0, maxY - minY));
                if (CGRectIsNull(unionRect) || unionRect.size.width > handleRect.size.width + 24.0) {
                    unionRect = handleRect;
                }
            }
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

static void VLMFitSystemPlatterToHost(UIView *host) {
    if (!host) {
        return;
    }
    for (UIView *sub in host.subviews) {
        NSString *name = NSStringFromClass(sub.class);
        if ([name containsString:@"Shadow"]
            || [name containsString:@"PageButton"]
            || [name containsString:@"PageControl"]
            || [name containsString:@"Dimming"]
            || [name containsString:@"Cutout"]) {
            VLMHideView(sub);
            continue;
        }
        BOOL platter = [sub isKindOfClass:[UIVisualEffectView class]]
            || [name containsString:@"Backdrop"]
            || [name containsString:@"Platter"]
            || [name containsString:@"Material"];
        if (!platter) {
            continue;
        }
        if ([sub isKindOfClass:[UIVisualEffectView class]]) {
            UIVisualEffectView *effectView = (UIVisualEffectView *)sub;
            if (effectView.maskView) {
                effectView.maskView = nil;
            }
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

static void VLMSetSystemArrowDirection(UIView *host, BOOL below) {
    if (!host) {
        return;
    }
    // UIEditMenuArrowDirection: 0 automatic, 1 up (arrow on top), 2 down (arrow on bottom).
    NSInteger direction = below ? 1 : 2;
    SEL setArrow = NSSelectorFromString(@"setArrowDirection:");
    SEL setPreferred = NSSelectorFromString(@"setPreferredArrowDirection:");
    UIView *current = host;
    for (NSInteger depth = 0; current && depth < 5; depth++) {
        if ([current respondsToSelector:setArrow]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(current, setArrow, direction);
        }
        if ([current respondsToSelector:setPreferred]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(current, setPreferred, direction);
        }
        current = current.superview;
        if ([current isKindOfClass:[UIWindow class]]) {
            break;
        }
    }
}

static void VLMAttachSystemArrows(UIView *host, BOOL below) {
    UIView *parent = host.superview;
    if (!parent || !host.window) {
        return;
    }
    CGRect hostFrame = host.frame;
    CGRect selection = VLMSelectionRectInWindow(host.window);
    CGFloat targetX = CGRectGetMidX(hostFrame);
    if (!CGRectIsNull(selection)) {
        targetX = CGRectGetMidX([parent convertRect:selection fromView:host.window]);
    }
    CGFloat minX = CGRectGetMinX(hostFrame) + 18.0;
    CGFloat maxX = CGRectGetMaxX(hostFrame) - 18.0;
    if (maxX < minX) {
        minX = CGRectGetMidX(hostFrame);
        maxX = minX;
    }
    CGFloat x = MIN(MAX(targetX, minX), maxX);
    for (UIView *sibling in parent.subviews) {
        if (sibling == host || !VLMNameLooksLikeArrow(sibling)) {
            continue;
        }
        sibling.hidden = NO;
        sibling.alpha = 1;
        sibling.userInteractionEnabled = NO;
        CGFloat height = MAX(sibling.bounds.size.height, 8.0);
        CGFloat y = below
            ? (CGRectGetMinY(hostFrame) - height / 2.0 + 1.0)
            : (CGRectGetMaxY(hostFrame) + height / 2.0 - 1.0);
        sibling.center = CGPointMake(x, y);
    }
}

static void VLMRepairEditMenuChrome(UIView *host) {
    if (!host) {
        return;
    }
    host.clipsToBounds = NO;
    host.layer.masksToBounds = NO;
    VLMHidePagingControls(host);
    VLMFitSystemPlatterToHost(host);
    VLMHideStrayBackdrops(host);
    BOOL below = VLMShouldGrowDownward(host);
    VLMSetSystemArrowDirection(host, below);
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
    if (!gDebug) {
        return;
    }

    UIView *root = host;
    for (NSInteger depth = 0; root.superview && depth < 10; depth++) {
        if ([root.superview isKindOfClass:[UIWindow class]]) {
            break;
        }
        root = root.superview;
    }

    UIWindow *window = host.window;
    NSString *tmp = NSTemporaryDirectory();
    NSMutableString *out = [NSMutableString stringWithFormat:@"[VerticalMenu] hierarchy dump %@ bundle=%@ alpha=%.2f tmp=%@ safe=%@ frame=%@\n",
                            [NSDate date],
                            VLMCurrentBundleID(),
                            host.alpha,
                            tmp,
                            window ? NSStringFromUIEdgeInsets(window.safeAreaInsets) : @"",
                            NSStringFromCGRect(host.frame)];
    VLMAppendHierarchy(root, host, 0, out);
    NSString *sandboxPath = [tmp stringByAppendingPathComponent:@"VerticalMenu-menu.txt"];
    [out writeToFile:sandboxPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSString *sharedPath = @"/var/tmp/VerticalMenu-menu.txt";
    BOOL shared = [out writeToFile:sharedPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSLog(@"[VerticalMenu] hierarchy -> %@%@ (%@)", sandboxPath, shared ? [NSString stringWithFormat:@" and %@", sharedPath] : @"", VLMCurrentBundleID());
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
    if (!gKeyboardVisible) {
        return CGFLOAT_MAX;
    }
    CGRect keyboard = [window convertRect:gKeyboardFrameEnd fromWindow:nil];
    CGFloat top = CGRectGetMinY(keyboard);
    return (CGRectGetHeight(keyboard) >= 50.0 && top > CGRectGetMinY(window.bounds)) ? top : CGFLOAT_MAX;
}

static CGRect VLMSafeLayoutRect(UIWindow *window) {
    if (!window) {
        return CGRectNull;
    }
    CGRect safe = window.safeAreaLayoutGuide.layoutFrame;
    if (CGRectIsEmpty(safe)) {
        safe = UIEdgeInsetsInsetRect(window.bounds, window.safeAreaInsets);
    }
    safe = CGRectInset(safe, 8.0, 8.0);
    CGFloat keyboardTop = VLMLiveKeyboardMinY(window);
    if (keyboardTop < CGRectGetMaxY(safe)) {
        safe.size.height = MAX(0.0, keyboardTop - kVLMSelectionGap - CGRectGetMinY(safe));
    }
    return safe;
}

static CGRect VLMClampRectToSafeArea(CGRect frame, UIWindow *window) {
    if (!window) {
        return frame;
    }
    return VLMMenuClampFrame(frame, VLMSafeLayoutRect(window));
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

    VLMMenuPlacement placement = VLMMenuPlaceNearAnchor(VLMSafeLayoutRect(window),
                                                         selection,
                                                         fitted,
                                                         kVLMSelectionGap,
                                                         kVLMArrowHeight * 0.35,
                                                         kVLMRowHeight + kVLMListInset * 2.0);
    BOOL below = placement.belowAnchor;
    CGRect listRect = placement.frame;
    objc_setAssociatedObject(host, kVLMGrowDownKey, @(below), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(host, kVLMViewportSizeKey, [NSValue valueWithCGSize:listRect.size], OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    VLMSetFrameInWindow(host, listRect);
    VLMRepairEditMenuChrome(host);
    VLMAttachSystemArrows(host, below);
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
    BOOL below = VLMShouldGrowDownward(view);
    VLMSetSystemArrowDirection(view, below);
    VLMAttachSystemArrows(view, below);
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
    CGSize desired = CGSizeMake(width, height);
    NSValue *viewportValue = objc_getAssociatedObject(host, kVLMViewportSizeKey);
    if ([viewportValue isKindOfClass:[NSValue class]]) {
        CGSize viewport = viewportValue.CGSizeValue;
        desired.width = MIN(desired.width, viewport.width);
        desired.height = MIN(desired.height, viewport.height);
    }
    return desired;
}

static void VLMRepositionVisibleEditMenus(void) {
    for (UIWindow *window in VLMAllWindows(nil)) {
        UIView *list = VLMFindEditMenuList(window, 8);
        if (!list || list.alpha < 0.2 || !list.window) {
            continue;
        }
        objc_setAssociatedObject(list, kVLMGrowDownKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(list, kVLMViewportSizeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGSize fitted = VLMVerticalFittingSize(list, list.bounds.size);
        VLMPositionHostNearSelection(list, fitted);
        VLMKeepOnScreen(list);
        VLMRepairEditMenuChrome(list);
    }
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

static void VLMRefreshCollectionObservation(id host, UICollectionView *collectionView) {
    if (!collectionView) {
        return;
    }
    if (objc_getAssociatedObject(collectionView, kVLMRefreshingKey)) {
        return;
    }
    objc_setAssociatedObject(collectionView, kVLMRefreshingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
            NSString *itemID = VLMWeakItemIDForTitle(current);
            if (itemID.length > 0) {
                [records addObject:@{@"id": itemID, @"title": VLMTrimTitle(current)}];
            }
        }
    }
    objc_setAssociatedObject(collectionView, kVLMCapturedTitlesKey, storedTitles, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    VLMRememberEditMenuFromHost(host, commands, records, NO);

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
            return;
        }
        VLMRefreshCollectionObservation(strongHost, collectionView);
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
    NSInteger count = [self vlm_itemCount];
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
    attributes.hidden = NO;
    attributes.frame = CGRectMake(0, kVLMListInset + indexPath.item * kVLMRowHeight, width, kVLMRowHeight);
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
    collectionView.bounces = NO;
    collectionView.alwaysBounceHorizontal = NO;
    collectionView.alwaysBounceVertical = NO;
    collectionView.decelerationRate = UIScrollViewDecelerationRateNormal;
    collectionView.delaysContentTouches = NO;
    collectionView.canCancelContentTouches = YES;
    collectionView.showsHorizontalScrollIndicator = NO;
    collectionView.showsVerticalScrollIndicator = (visibleCount > kVLMVisibleRows);
    collectionView.clipsToBounds = YES;
    collectionView.backgroundColor = [UIColor clearColor];
    collectionView.layer.cornerRadius = 14.0;
    collectionView.layer.masksToBounds = YES;
    if (@available(iOS 11.0, *)) {
        collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    if (@available(iOS 13.0, *)) {
        collectionView.automaticallyAdjustsScrollIndicatorInsets = NO;
    }
    collectionView.contentInset = UIEdgeInsetsZero;
    collectionView.scrollIndicatorInsets = UIEdgeInsetsMake(4.0, 0.0, 4.0, 1.0);
    if (@available(iOS 13.0, *)) {
        collectionView.verticalScrollIndicatorInsets = UIEdgeInsetsMake(4.0, 0.0, 4.0, 1.0);
    }
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
        VLMLog(@"edit layout %@ items=%ld bounds=%@",
               NSStringFromClass(collectionView.collectionViewLayout.class),
               (long)VLMItemCount(collectionView),
               NSStringFromCGRect(host.bounds));
        objc_setAssociatedObject(host, kVLMLoggedLayoutKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSInteger visibleCount = VLMItemCount(collectionView);
    if (setupDone) {
        if (!scrolling) {
            VLMMatchCollectionFrame(host, collectionView);
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
                BOOL below = VLMShouldGrowDownward(host);
                VLMSetSystemArrowDirection(host, below);
                VLMAttachSystemArrows(host, below);
            }
            VLMLog(@"anchor growDown=%d frame=%@", growDown, NSStringFromCGRect(host.frame));
        }
        VLMKeepOnScreen(host);
    }

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

    BOOL below = VLMShouldGrowDownward(host);
    VLMSetSystemArrowDirection(host, below);
    VLMAttachSystemArrows(host, below);
    VLMSortEditMenuHost(host);
    VLMRefreshCollectionObservation(host, collectionView);
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

static UIImage *VLMMenuIconForTitle(NSString *title) {
    if (@available(iOS 13.0, *)) {
        NSString *itemID = VLMCatalogIDForTitle(title);
        static NSDictionary<NSString *, NSString *> *symbols;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            symbols = @{
                @"cut": @"scissors",
                @"copy": @"doc.on.doc",
                @"paste": @"doc.on.clipboard",
                @"select": @"selection.pin.in.out",
                @"selectAll": @"selection.pin.in.out",
                @"lookup": @"magnifyingglass",
                @"translate": @"character.book.closed",
                @"share": @"square.and.arrow.up",
                @"replace": @"arrow.triangle.2.circlepath",
                @"speak": @"speaker.wave.2",
            };
        });
        NSString *symbolName = symbols[itemID];
        if (symbolName.length > 0) {
            UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:17.0
                                                                                                    weight:UIImageSymbolWeightMedium
                                                                                                     scale:UIImageSymbolScaleMedium];
            UIImage *image = [UIImage systemImageNamed:symbolName withConfiguration:config];
            if (image) {
                return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            }
        }
    }
    return VLMFallbackMenuIcon();
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
    NSNumber *cached = objc_getAssociatedObject(list, kVLMAlignedIconLeftKey);
    if ([cached isKindOfClass:[NSNumber class]]) {
        return cached.doubleValue;
    }
    CGFloat cellMinX = [cell convertPoint:CGPointZero toView:list].x;
    if (cellMinX != cellMinX || fabs(cellMinX) > 500.0) {
        return kVLMIconLeft + kVLMPageGutter;
    }
    CGFloat iconLeft = (kVLMPageGutter + kVLMIconLeft) - cellMinX;
    if (iconLeft < 8.0) {
        iconLeft = 8.0;
    }
    if (iconLeft > 48.0) {
        iconLeft = 48.0;
    }
    UICollectionView *collectionView = VLMCollectionViewInHost(list);
    BOOL settled = objc_getAssociatedObject(list, kVLMSetupDoneKey) != nil;
    if (settled && !VLMCollectionViewIsScrolling(collectionView)) {
        objc_setAssociatedObject(list, kVLMAlignedIconLeftKey, @(iconLeft), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return iconLeft;
}

static void VLMConcealNativeCellParts(UIView *cell,
                                      UIView *content,
                                      UIImageView *slot,
                                      UILabel *titleSlot) {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    NSMutableArray<UIImageView *> *images = [NSMutableArray array];
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    VLMWalkMenuParts(cell, slot, titleSlot, labels, images, buttons);
    for (UILabel *label in labels) {
        label.alpha = 0;
    }
    for (UIImageView *imageView in images) {
        if (!VLMIsBackgroundImageView(imageView, content)) {
            imageView.alpha = 0;
        }
    }
    for (UIButton *button in buttons) {
        button.titleLabel.alpha = 0;
        button.imageView.alpha = 0;
    }
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

static UIImageView *VLMBestNativeIconView(NSArray<UIImageView *> *images, UIImageView *slot, UIView *content) {
    UIImageView *best = nil;
    CGFloat bestScore = -1.0;
    for (UIImageView *candidate in images) {
        if (candidate == slot || VLMIsBackgroundImageView(candidate, content)) {
            continue;
        }
        if (!VLMImageIsUsableIcon(candidate.image)) {
            continue;
        }
        CGSize size = candidate.bounds.size;
        if (size.width < 4.0) {
            size = candidate.image.size;
        }
        CGFloat area = size.width * size.height;
        CGFloat delta = fabs(size.width - kVLMIconSize) + fabs(size.height - kVLMIconSize);
        CGFloat score = area - delta * 8.0;
        if (score > bestScore) {
            best = candidate;
            bestScore = score;
        }
    }
    return best;
}

static void VLMHideLeftoverCover(UIView *content, UIView *cell) {
    UIView *cover = objc_getAssociatedObject(content, kVLMCoverKey);
    if (!cover) {
        cover = objc_getAssociatedObject(cell, kVLMCoverKey);
    }
    if (cover) {
        cover.hidden = YES;
        cover.alpha = 0;
        [cover removeFromSuperview];
    }
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
        content.backgroundColor = [UIColor clearColor];
    }
    cell.clipsToBounds = NO;
    cell.backgroundColor = [UIColor clearColor];
    VLMHideLeftoverCover(content, cell);

    UIImageView *slot = VLMEnsureFallbackSlot(content);
    UILabel *titleSlot = VLMEnsureTitleSlot(content);
    // UIKit may materialize or restore a button's native label after the first
    // cell pass. Enforce concealment before the cached fast path as well, so
    // the native title cannot reappear beside the overlay title.
    VLMConcealNativeCellParts(cell, content, slot, titleSlot);

    NSValue *lastSizeValue = objc_getAssociatedObject(cell, kVLMLastCellSizeKey);
    NSString *lastIdentity = objc_getAssociatedObject(cell, kVLMLastCellIdentityKey);
    NSString *cachedTitle = objc_getAssociatedObject(content, kVLMCapturedTitleKey);
    if (lastIdentity.length > 0
        && cachedTitle.length > 0
        && [lastSizeValue isKindOfClass:[NSValue class]]
        && CGSizeEqualToSize(lastSizeValue.CGSizeValue, content.bounds.size)
        && slot.superview == content
        && titleSlot.superview == content) {
        CGFloat iconLeft = VLMAlignedIconLeft(cell);
        CGFloat textX = iconLeft + kVLMIconSize + kVLMIconTextGap;
        slot.frame = CGRectMake(iconLeft, (content.bounds.size.height - kVLMIconSize) / 2.0, kVLMIconSize, kVLMIconSize);
        titleSlot.frame = CGRectMake(textX, 0, MAX(40.0, content.bounds.size.width - textX - 14.0), content.bounds.size.height);
        slot.layer.zPosition = 20;
        titleSlot.layer.zPosition = 20;
        objc_setAssociatedObject(cell, kVLMCellGuardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    NSMutableArray<UIImageView *> *images = [NSMutableArray array];
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    VLMWalkMenuParts(cell, slot, titleSlot, labels, images, buttons);

    UILabel *title = VLMBestTitleLabel(labels);
    NSString *titleText = title ? VLMTrimmedText(title) : nil;
    UIFont *titleFont = title.font;
    UIColor *titleColor = title.textColor;
    UIImageView *nativeIcon = VLMBestNativeIconView(images, slot, content);
    UIImage *iconImage = nativeIcon.image;
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
        objc_setAssociatedObject(content, kVLMCapturedTitleKey, cleanTitle.length ? cleanTitle : titleText, OBJC_ASSOCIATION_COPY_NONATOMIC);
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
    BOOL hasTitle = VLMTrimTitle(titleText).length > 0;
    if (hasTitle) {
        objc_setAssociatedObject(cell, kVLMHadTitleKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

    for (UIImageView *imageView in images) {
        if (imageView == slot || VLMIsBackgroundImageView(imageView, content)) {
            continue;
        }
        imageView.alpha = 0;
    }
    for (UILabel *label in labels) {
        if (label == titleSlot) {
            continue;
        }
        label.alpha = 0;
    }

    if (hasTitle) {
        if (slot.superview != content) {
            [content addSubview:slot];
        }
        slot.hidden = NO;
        slot.alpha = 1;
        slot.contentMode = UIViewContentModeScaleAspectFit;
        slot.image = VLMImageIsUsableIcon(iconImage) ? iconImage : VLMMenuIconForTitle(titleText);
        slot.tintColor = iconTint;
        slot.frame = iconRect;
        slot.layer.zPosition = 20;
    } else if (slot.superview) {
        slot.hidden = YES;
        slot.alpha = 0;
    }

    if (hasTitle) {
        if (titleSlot.superview != content) {
            [content addSubview:titleSlot];
        }
        titleSlot.hidden = NO;
        titleSlot.alpha = 1;
        titleSlot.attributedText = nil;
        titleSlot.textAlignment = NSTextAlignmentLeft;
        titleSlot.numberOfLines = 1;
        titleSlot.lineBreakMode = NSLineBreakByTruncatingTail;
        titleSlot.font = titleFont ?: [UIFont systemFontOfSize:17.0];
        titleSlot.textColor = tint;
        titleSlot.text = titleText;
        titleSlot.frame = titleRect;
        titleSlot.layer.zPosition = 20;
    } else if (titleSlot.superview) {
        titleSlot.hidden = YES;
        titleSlot.alpha = 0;
    }

    NSString *identity = hasTitle ? [NSString stringWithFormat:@"%@|%d", VLMTrimTitle(titleText), VLMImageIsUsableIcon(iconImage)] : nil;
    objc_setAssociatedObject(cell, kVLMLastCellIdentityKey, identity, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cell, kVLMLastCellSizeKey, [NSValue valueWithCGSize:content.bounds.size], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (hasTitle && !VLMImageIsUsableIcon(iconImage) && !objc_getAssociatedObject(cell, kVLMCellRetryKey)) {
        objc_setAssociatedObject(cell, kVLMCellRetryKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIView *weakCell = cell;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *strongCell = weakCell;
            if (!strongCell) {
                return;
            }
            objc_setAssociatedObject(strongCell, kVLMCellRetryKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (!strongCell.window || !objc_getAssociatedObject(strongCell, kVLMManagedCellKey)) {
                return;
            }
            UIView *host = VLMEnclosingEditMenuList(strongCell);
            UICollectionView *collectionView = VLMCollectionViewInHost(host);
            if (VLMCollectionViewIsScrolling(collectionView)) {
                return;
            }
            objc_setAssociatedObject(strongCell, kVLMLastCellIdentityKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
            VLMRelayoutCell(strongCell);
        });
    }

    objc_setAssociatedObject(cell, kVLMCellGuardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void VLMRelayoutVisibleCells(id host) {
    UICollectionView *collectionView = VLMCollectionViewInHost(host);
    for (UIView *cell in collectionView.visibleCells) {
        objc_setAssociatedObject(cell, kVLMManagedCellKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

static const void *kVLMEditDelegateProxyKey = &kVLMEditDelegateProxyKey;

@interface VLMEditMenuDelegateProxy : NSObject <UIEditMenuInteractionDelegate>
@property (nonatomic, weak) id originalDelegate;
@end

@implementation VLMEditMenuDelegateProxy

- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.originalDelegate respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:(SEL)selector {
    if ([self.originalDelegate respondsToSelector:selector]) {
        return self.originalDelegate;
    }
    return [super forwardingTargetForSelector:selector];
}

- (UIMenu *)editMenuInteraction:(UIEditMenuInteraction *)interaction
            menuForConfiguration:(UIEditMenuConfiguration *)configuration
               suggestedActions:(NSArray<UIMenuElement *> *)suggestedActions {
    UIMenu *menu = nil;
    SEL selector = @selector(editMenuInteraction:menuForConfiguration:suggestedActions:);
    if ([self.originalDelegate respondsToSelector:selector]) {
        menu = ((id (*)(id, SEL, id, id, id))objc_msgSend)(self.originalDelegate,
                                                            selector,
                                                            interaction,
                                                            configuration,
                                                            suggestedActions);
    }
    if (!VLMEditOn()) {
        return menu;
    }
    if (!menu) {
        menu = [UIMenu menuWithChildren:suggestedActions ?: @[]];
    }
    VLMRememberUIMenuElements(VLMChildrenOfMenu(menu), VLMMenuKindEdit);
    return VLMRewrittenMenuForKind(menu, VLMMenuKindEdit);
}

@end

#pragma mark - UIMenu: context menus / palettes / compact rows

%group ContextMenus

%hook UIMenu

- (NSArray *)children {
    return %orig;
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

+ (instancetype)menuWithChildren:(NSArray *)children {
    return %orig;
}

%end

%hook UIContextMenuConfiguration

+ (instancetype)configurationWithIdentifier:(id)identifier
                              previewProvider:(id)previewProvider
                               actionProvider:(id)actionProvider {
    if (!actionProvider) {
        return %orig;
    }
    UIMenu *(^originalProvider)(NSArray *) = [actionProvider copy];
    UIMenu *(^wrappedProvider)(NSArray *) = ^UIMenu *(NSArray *suggestedActions) {
        UIMenu *menu = originalProvider(suggestedActions ?: @[]);
        if (!VLMContextOn() || !menu) {
            return menu;
        }
        VLMRememberUIMenuElements(VLMChildrenOfMenu(menu), VLMMenuKindContext);
        return VLMRewrittenMenuForKind(menu, VLMMenuKindContext);
    };
    id configuration = %orig(identifier, previewProvider, wrappedProvider);
    if (VLMContextOn() && VLMRulesPolicyHasOrdering(VLMPolicyForKind(VLMMenuKindContext))
        && [configuration respondsToSelector:@selector(setPreferredMenuElementOrder:)]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(configuration,
                                                      @selector(setPreferredMenuElementOrder:),
                                                      (NSInteger)UIContextMenuConfigurationElementOrderFixed);
    }
    return configuration;
}

%end

%hook UIButton

- (void)setMenu:(UIMenu *)menu {
    if (VLMContextOn() && menu) {
        VLMRememberUIMenuElements(VLMChildrenOfMenu(menu), VLMMenuKindContext);
        menu = VLMRewrittenMenuForKind(menu, VLMMenuKindContext);
    }
    %orig(menu);
    if (VLMContextOn() && VLMRulesPolicyHasOrdering(VLMPolicyForKind(VLMMenuKindContext))
        && [self respondsToSelector:@selector(setPreferredMenuElementOrder:)]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(self,
                                                      @selector(setPreferredMenuElementOrder:),
                                                      (NSInteger)UIContextMenuConfigurationElementOrderFixed);
    }
}

%end

%hook UIBarButtonItem

- (void)setMenu:(UIMenu *)menu {
    if (VLMContextOn() && menu) {
        VLMRememberUIMenuElements(VLMChildrenOfMenu(menu), VLMMenuKindContext);
        menu = VLMRewrittenMenuForKind(menu, VLMMenuKindContext);
    }
    %orig(menu);
    if (VLMContextOn() && VLMRulesPolicyHasOrdering(VLMPolicyForKind(VLMMenuKindContext))
        && [self respondsToSelector:@selector(setPreferredMenuElementOrder:)]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(self,
                                                      @selector(setPreferredMenuElementOrder:),
                                                      (NSInteger)UIContextMenuConfigurationElementOrderFixed);
    }
}

%end

%end

%group EditMenuModel

%hook UIEditMenuInteraction

- (instancetype)initWithDelegate:(id)delegate {
    if ([delegate isKindOfClass:[VLMEditMenuDelegateProxy class]]) {
        return %orig;
    }
    VLMEditMenuDelegateProxy *proxy = [VLMEditMenuDelegateProxy new];
    proxy.originalDelegate = delegate;
    UIEditMenuInteraction *interaction = %orig(proxy);
    if (interaction) {
        objc_setAssociatedObject(interaction, kVLMEditDelegateProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return interaction;
}

%end

%end

%group DeferredMenus

%hook UIDeferredMenuElement

+ (instancetype)elementWithProvider:(id)elementProvider {
    if (!elementProvider) return %orig;
    __block __weak UIDeferredMenuElement *deferred = nil;
    void (^originalProvider)(void (^)(NSArray *)) = [elementProvider copy];
    void (^wrappedProvider)(void (^)(NSArray *)) = ^(void (^completion)(NSArray *)) {
        originalProvider(^(NSArray *elements) {
            NSString *kind = objc_getAssociatedObject(deferred, kVLMDeferredKindKey);
            NSArray *result = elements ?: @[];
            if (kind.length > 0 && VLMKindOn(kind)) {
                VLMRememberUIMenuElements(result, kind);
                result = VLMRewrittenElementsForKind(result, kind);
            }
            completion(result);
        });
    };
    deferred = %orig(wrappedProvider);
    return deferred;
}

+ (instancetype)elementWithUncachedProvider:(id)elementProvider {
    if (!elementProvider) return %orig;
    __block __weak UIDeferredMenuElement *deferred = nil;
    void (^originalProvider)(void (^)(NSArray *)) = [elementProvider copy];
    void (^wrappedProvider)(void (^)(NSArray *)) = ^(void (^completion)(NSArray *)) {
        originalProvider(^(NSArray *elements) {
            NSString *kind = objc_getAssociatedObject(deferred, kVLMDeferredKindKey);
            NSArray *result = elements ?: @[];
            if (kind.length > 0 && VLMKindOn(kind)) {
                VLMRememberUIMenuElements(result, kind);
                result = VLMRewrittenElementsForKind(result, kind);
            }
            completion(result);
        });
    };
    deferred = %orig(wrappedProvider);
    return deferred;
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
        objc_setAssociatedObject(self, kVLMGrowDownKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kVLMViewportSizeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kVLMAlignedIconLeftKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
        UICollectionView *collectionView = VLMCollectionViewInHost(self);
        objc_setAssociatedObject(collectionView, kVLMCapturedTitlesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kVLMSetupDoneKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kVLMCollectionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kVLMViewportSizeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kVLMAlignedIconLeftKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

- (void)didMoveToWindow {
    %orig;
    if (!VLMEditOn() || !self.window) {
        return;
    }
    NSString *name = NSStringFromClass(self.class);
    if ([name containsString:@"EditMenu"] && VLMIsInsideEditMenu(self)) {
        objc_setAssociatedObject(self, kVLMManagedCellKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        VLMRelayoutCell(self);
    }
}

- (void)layoutSubviews {
    %orig;
    if (!VLMEditOn() || !objc_getAssociatedObject(self, kVLMManagedCellKey)) {
        return;
    }
    UIView *host = VLMEnclosingEditMenuList(self);
    BOOL configured = [objc_getAssociatedObject(self, kVLMLastCellIdentityKey) length] > 0;
    if (configured && VLMCollectionViewIsScrolling(VLMCollectionViewInHost(host))) {
        return;
    }
    VLMRelayoutCell(self);
}

- (void)prepareForReuse {
    %orig;
    if (!objc_getAssociatedObject(self, kVLMManagedCellKey)) {
        return;
    }
    UIView *content = self.contentView;
    objc_setAssociatedObject(content, kVLMCapturedTitleKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(content, kVLMCapturedImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(content, kVLMCapturedFontKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(content, kVLMCapturedColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kVLMHadTitleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kVLMLastCellSizeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kVLMLastCellIdentityKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(self, kVLMCellRetryKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.hidden = NO;
    self.alpha = 1;
    self.userInteractionEnabled = YES;
}

%end

%end

%group EditMenuCollectionView

%hook UICollectionView

- (void)setBounces:(BOOL)bounces {
    if (VLMEditOn() && [self.collectionViewLayout isKindOfClass:[VLMVerticalListLayout class]]) {
        bounces = NO;
    }
    %orig(bounces);
}

- (void)setAlwaysBounceVertical:(BOOL)bounce {
    if (VLMEditOn() && [self.collectionViewLayout isKindOfClass:[VLMVerticalListLayout class]]) {
        bounce = NO;
    }
    %orig(bounce);
}

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
    objc_setAssociatedObject(self, kVLMContainerGuardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%end

%end

#pragma mark - Constructor

static void VLMPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        VLMLoadPrefs();
        VLMLog(@"prefs reload enabled=%d context=%d edit=%d debug=%d registry=%lu", gEnabled, gContextMenus, gEditMenus, gDebug, (unsigned long)gRegistry.count);
    });
}

static void VLMIncomingPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NSString *bundle = [NSBundle mainBundle].bundleIdentifier ?: @"";
    if (![bundle isEqualToString:@"com.apple.springboard"]) {
        return;
    }
    VLMIngestIncomingPrefs();
}

%ctor {
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier ?: @"";
    BOOL isSpringBoard = [bundleID isEqualToString:@"com.apple.springboard"];
    VLMLoadPrefs();
    VLMStartPrefsWriterIfNeeded();
    VLMStartIncomingObserverIfNeeded();
    if (isSpringBoard) {
        VLMMigrateToPolicyV2IfNeededAsync();
    }
    BOOL hookedList = NO;

    %init(ContextMenus);
    if (objc_getClass("UIDeferredMenuElement")) {
        %init(DeferredMenus);
    }

    if (!isSpringBoard && objc_getClass("UIEditMenuInteraction")) {
        %init(EditMenuModel);
    }

    if (!isSpringBoard && objc_getClass("_UIEditMenuListView")) {
        %init(EditMenuList);
        %init(EditMenuCells);
        %init(EditMenuCollectionView);
        hookedList = YES;
    }
    if (!isSpringBoard && objc_getClass("_UIEditMenuPageButton")) {
        %init(EditMenuPageButton);
    }
    if (!isSpringBoard && objc_getClass("_UIEditMenuContainerView")) {
        %init(EditMenuContainer);
    }

    if (hookedList) {
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
    }
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        VLMPrefsChanged,
        (__bridge CFStringRef)kVLMReloadNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
    if (isSpringBoard) {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            VLMIncomingPrefsChanged,
            (__bridge CFStringRef)VLMIncomingNotificationName,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );
    }
    VLMLog(@"loaded in %@ enabled=%d context=%d edit=%d debug=%d list=%d registry=%lu",
           bundleID, gEnabled, gContextMenus, gEditMenus, gDebug, hookedList, (unsigned long)gRegistry.count);
}
