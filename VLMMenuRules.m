#import "VLMMenuRules.h"

NSString * const VLMRulesVisibilityInherit = @"inherit";
NSString * const VLMRulesVisibilityShow = @"show";
NSString * const VLMRulesVisibilityHide = @"hide";
NSString * const VLMRulesOrderModeInherit = @"inherit";
NSString * const VLMRulesOrderModeSystem = @"system";
NSString * const VLMRulesOrderModeCustom = @"custom";

static NSString *VLMRulesExtractItemID(id item) {
    if ([item isKindOfClass:[NSString class]]) {
        return item;
    }
    if ([item isKindOfClass:[NSDictionary class]]) {
        id itemID = item[@"id"];
        return [itemID isKindOfClass:[NSString class]] ? itemID : nil;
    }
    return nil;
}

static NSArray<NSString *> *VLMRulesUniqueIDs(id value) {
    if (![value isKindOfClass:[NSArray class]]) {
        return @[];
    }
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id item in (NSArray *)value) {
        NSString *itemID = VLMRulesExtractItemID(item);
        if (itemID.length == 0 || [seen containsObject:itemID]) {
            continue;
        }
        [seen addObject:itemID];
        [result addObject:itemID];
    }
    return result;
}

NSString *VLMRulesFoldedText(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) {
        return @"";
    }
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    trimmed = [trimmed stringByReplacingOccurrencesOfString:@"…" withString:@""];
    trimmed = [trimmed stringByReplacingOccurrencesOfString:@"..." withString:@""];
    trimmed = [trimmed stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.lowercaseString;
}

BOOL VLMRulesCatalogContainsID(NSArray<NSDictionary *> *catalog, NSString *itemID) {
    if (itemID.length == 0) {
        return NO;
    }
    for (NSDictionary *item in catalog) {
        if ([item[@"id"] isEqualToString:itemID]) {
            return YES;
        }
    }
    return NO;
}

NSString *VLMRulesCatalogIDForTitle(NSArray<NSDictionary *> *catalog, NSString *title) {
    NSString *folded = VLMRulesFoldedText(title);
    if (folded.length == 0) {
        return nil;
    }
    for (NSDictionary *item in catalog) {
        for (NSString *candidate in item[@"titles"]) {
            if ([VLMRulesFoldedText(candidate) isEqualToString:folded]) {
                return item[@"id"];
            }
        }
    }
    return nil;
}

NSString *VLMRulesCatalogIDForSelector(NSArray<NSDictionary *> *catalog, NSString *selectorName) {
    if (selectorName.length == 0) {
        return nil;
    }
    for (NSDictionary *item in catalog) {
        for (NSString *candidate in item[@"sels"]) {
            if ([candidate isEqualToString:selectorName]) {
                return item[@"id"];
            }
        }
    }
    return nil;
}

NSString *VLMRulesCatalogIDForIdentifier(NSArray<NSDictionary *> *catalog, NSString *identifier) {
    if (identifier.length == 0) {
        return nil;
    }
    NSString *last = identifier.lastPathComponent.lowercaseString;
    if (last.length == 0) {
        last = identifier.lowercaseString;
    }
    for (NSDictionary *item in catalog) {
        NSString *itemID = item[@"id"];
        NSString *foldedID = itemID.lowercaseString;
        if ([last isEqualToString:foldedID] || [last hasSuffix:[@"." stringByAppendingString:foldedID]]) {
            return itemID;
        }
        for (NSString *alias in item[@"idents"]) {
            if ([identifier isEqualToString:alias] || [last isEqualToString:alias.lowercaseString]) {
                return itemID;
            }
        }
    }
    return VLMRulesCatalogIDForTitle(catalog, identifier);
}

NSString *VLMRulesCatalogLabelForID(NSArray<NSDictionary *> *catalog, NSString *itemID) {
    if (itemID.length == 0) {
        return nil;
    }
    for (NSDictionary *item in catalog) {
        if ([item[@"id"] isEqualToString:itemID]) {
            return item[@"label"] ?: item[@"title"];
        }
    }
    if ([itemID hasPrefix:@"custom:"]) {
        return [itemID substringFromIndex:7];
    }
    return itemID;
}

NSString *VLMRulesItemIDForTitle(NSArray<NSDictionary *> *catalog, NSString *title) {
    NSString *catalogID = VLMRulesCatalogIDForTitle(catalog, title);
    if (catalogID.length > 0) {
        return catalogID;
    }
    NSString *clean = [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    clean = [clean stringByReplacingOccurrencesOfString:@"…" withString:@""];
    clean = [clean stringByReplacingOccurrencesOfString:@"..." withString:@""];
    clean = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return clean.length > 0 ? [@"custom:" stringByAppendingString:clean] : nil;
}

BOOL VLMRulesIsCapturedJunkItem(NSString *title, NSString *itemID) {
    NSString *ident = itemID ?: @"";
    NSString *clean = [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([ident isEqualToString:@"showHelp:"]
        || [ident isEqualToString:@"custom:showHelp:"]
        || [ident hasSuffix:@"showHelp:"]
        || [ident isEqualToString:@"help:"]
        || [ident hasPrefix:@"file:"]
        || [ident containsString:@"orderFront"]) {
        return YES;
    }
    if (clean.length == 0) {
        return [ident localizedCaseInsensitiveContainsString:@"showHelp"];
    }
    unichar first = [clean characterAtIndex:0];
    if (first == 0x300C || first == 0x300E || first == 0xFF5B || first == '{' || first == 0x3008) {
        return YES;
    }
    static NSSet<NSString *> *exact;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        exact = [NSSet setWithObjects:
                 @"MD清单", @"MD 清单",
                 @"文件", @"窗口", @"帮助", @"显示", @"服务",
                 @"以下均为示例作为参考", @"以下均为示例",
                 @"脚本框架", @"｛脚本框架｝",
                 @"JSBox",
                 @"换行分割", @"中英排版", @"去除空格", @"反转文字",
                 @"清理剪贴板中商店链接",
                 nil];
    });
    if ([exact containsObject:clean]) {
        return YES;
    }
    if ([clean containsString:@"以下均为示例"]
        || [clean containsString:@"脚本框架"]
        || [clean localizedCaseInsensitiveContainsString:@"jsbox"]
        || [clean containsString:@"作为参考"]
        || [clean containsString:@"可组合变量"]
        || [clean containsString:@"所填即所得"]
        || [clean containsString:@"执行后看看"]) {
        return YES;
    }
    return [clean hasSuffix:@":"] && [clean containsString:@"Help"];
}

NSString *VLMRulesProfileID(NSString *kind, NSString *bundleID) {
    return [NSString stringWithFormat:@"%@|%@", kind ?: @"", bundleID ?: @""];
}

static NSString *VLMRulesNormalizedVisibilityState(id value) {
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }
    if ([value isEqualToString:VLMRulesVisibilityShow]) {
        return VLMRulesVisibilityShow;
    }
    if ([value isEqualToString:VLMRulesVisibilityHide]) {
        return VLMRulesVisibilityHide;
    }
    return nil;
}

static NSString *VLMRulesNormalizedOrderMode(id value, BOOL hasCustomFields) {
    if (![value isKindOfClass:[NSString class]]) {
        return hasCustomFields ? VLMRulesOrderModeCustom : VLMRulesOrderModeInherit;
    }
    if ([value isEqualToString:VLMRulesOrderModeSystem]) {
        return VLMRulesOrderModeSystem;
    }
    if ([value isEqualToString:VLMRulesOrderModeCustom]) {
        return VLMRulesOrderModeCustom;
    }
    if ([value isEqualToString:VLMRulesOrderModeInherit]) {
        return VLMRulesOrderModeInherit;
    }
    return hasCustomFields ? VLMRulesOrderModeCustom : VLMRulesOrderModeInherit;
}

NSDictionary *VLMRulesNormalizedPolicy(NSDictionary *policy) {
    NSDictionary *source = [policy isKindOfClass:[NSDictionary class]] ? policy : @{};
    NSMutableDictionary<NSString *, NSString *> *visibility = [NSMutableDictionary dictionary];
    NSDictionary *rawVisibility = [source[@"visibility"] isKindOfClass:[NSDictionary class]] ? source[@"visibility"] : @{};
    for (id rawID in rawVisibility) {
        if (![rawID isKindOfClass:[NSString class]] || [rawID length] == 0) {
            continue;
        }
        NSString *state = VLMRulesNormalizedVisibilityState(rawVisibility[rawID]);
        if (state) {
            visibility[rawID] = state;
        }
    }
    for (NSString *itemID in VLMRulesUniqueIDs(source[@"hidden"])) {
        if (!visibility[itemID]) {
            visibility[itemID] = VLMRulesVisibilityHide;
        }
    }

    NSArray<NSString *> *first = VLMRulesUniqueIDs(source[@"first"]);
    NSArray<NSString *> *relative = VLMRulesUniqueIDs(source[@"relative"] ?: source[@"order"]);
    NSArray<NSString *> *last = VLMRulesUniqueIDs(source[@"last"]);
    BOOL hasCustomFields = first.count > 0 || relative.count > 0 || last.count > 0;
    NSString *orderMode = VLMRulesNormalizedOrderMode(source[@"orderMode"], hasCustomFields);
    if ([orderMode isEqualToString:VLMRulesOrderModeCustom] && relative.count == 0 && first.count == 0 && last.count == 0) {
        orderMode = VLMRulesOrderModeSystem;
    }
    return @{
        @"visibility": visibility,
        @"first": first,
        @"relative": relative,
        @"last": last,
        @"orderMode": orderMode,
    };
}

NSDictionary *VLMRulesPolicyFromLegacyRule(NSDictionary *rule, BOOL appScoped) {
    NSDictionary *source = [rule isKindOfClass:[NSDictionary class]] ? rule : @{};
    NSMutableDictionary<NSString *, NSString *> *visibility = [NSMutableDictionary dictionary];
    for (NSString *itemID in VLMRulesUniqueIDs(source[@"hidden"])) {
        visibility[itemID] = VLMRulesVisibilityHide;
    }
    id rawCustom = source[@"customOrder"];
    BOOL custom = [rawCustom respondsToSelector:@selector(boolValue)] && [rawCustom boolValue];
    return VLMRulesNormalizedPolicy(@{
        @"visibility": visibility,
        @"relative": custom ? VLMRulesUniqueIDs(source[@"order"]) : @[],
        @"orderMode": custom ? VLMRulesOrderModeCustom : (appScoped ? VLMRulesOrderModeInherit : VLMRulesOrderModeSystem),
    });
}

NSDictionary *VLMRulesResolvedPolicy(NSDictionary *globalPolicy, NSDictionary *appPolicy) {
    NSDictionary *global = VLMRulesNormalizedPolicy(globalPolicy);
    NSDictionary *app = VLMRulesNormalizedPolicy(appPolicy);
    NSMutableDictionary<NSString *, NSString *> *visibility = [global[@"visibility"] mutableCopy] ?: [NSMutableDictionary dictionary];
    [app[@"visibility"] enumerateKeysAndObjectsUsingBlock:^(NSString *itemID, NSString *state, BOOL *stop) {
        (void)stop;
        visibility[itemID] = state;
    }];

    NSString *appMode = app[@"orderMode"];
    NSDictionary *ordering = global;
    if ([appMode isEqualToString:VLMRulesOrderModeCustom]) {
        ordering = app;
    } else if ([appMode isEqualToString:VLMRulesOrderModeSystem]) {
        ordering = VLMRulesNormalizedPolicy(@{@"orderMode": VLMRulesOrderModeSystem});
    }
    NSString *resolvedMode = ordering[@"orderMode"];
    if (![resolvedMode isEqualToString:VLMRulesOrderModeCustom]) {
        resolvedMode = VLMRulesOrderModeSystem;
    }
    return @{
        @"visibility": visibility,
        @"first": ordering[@"first"] ?: @[],
        @"relative": ordering[@"relative"] ?: @[],
        @"last": ordering[@"last"] ?: @[],
        @"orderMode": resolvedMode,
    };
}

NSString *VLMRulesVisibilityForItem(NSDictionary *policy, NSString *itemID) {
    if (itemID.length == 0) {
        return VLMRulesVisibilityInherit;
    }
    NSDictionary *normalized = VLMRulesNormalizedPolicy(policy);
    return normalized[@"visibility"][itemID] ?: VLMRulesVisibilityInherit;
}

BOOL VLMRulesPolicyHasOrdering(NSDictionary *policy) {
    NSDictionary *normalized = VLMRulesNormalizedPolicy(policy);
    return [normalized[@"orderMode"] isEqualToString:VLMRulesOrderModeCustom]
        && ([normalized[@"first"] count] > 0 || [normalized[@"relative"] count] > 0 || [normalized[@"last"] count] > 0);
}

static NSInteger VLMRulesIndexInOrder(NSString *itemID, NSArray<NSString *> *order) {
    NSUInteger index = itemID.length > 0 ? [order indexOfObject:itemID] : NSNotFound;
    return index == NSNotFound ? NSIntegerMax : (NSInteger)index;
}

static NSArray *VLMRulesItemsSortedByOrder(NSArray *items,
                                           NSArray<NSString *> *order,
                                           NSString *(^itemID)(id item)) {
    if (items.count < 2 || order.count == 0 || !itemID) {
        return items;
    }
    NSMutableArray<NSDictionary *> *ranked = [NSMutableArray arrayWithCapacity:items.count];
    [items enumerateObjectsUsingBlock:^(id item, NSUInteger index, BOOL *stop) {
        (void)stop;
        [ranked addObject:@{@"item": item, @"rank": @(VLMRulesIndexInOrder(itemID(item), order)), @"index": @(index)}];
    }];
    [ranked sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSInteger leftRank = [left[@"rank"] integerValue];
        NSInteger rightRank = [right[@"rank"] integerValue];
        if (leftRank < rightRank) return NSOrderedAscending;
        if (leftRank > rightRank) return NSOrderedDescending;
        return [left[@"index"] compare:right[@"index"]];
    }];
    return [ranked valueForKey:@"item"];
}

NSArray *VLMRulesApplyPolicyToItems(NSArray *items,
                                    NSDictionary *policy,
                                    NSString *(^itemID)(id item)) {
    if (items.count == 0) {
        return items ?: @[];
    }
    NSDictionary *normalized = VLMRulesNormalizedPolicy(policy);
    NSDictionary<NSString *, NSString *> *visibility = normalized[@"visibility"];
    NSMutableArray *visible = [NSMutableArray arrayWithCapacity:items.count];
    for (id item in items) {
        NSString *identifier = itemID ? itemID(item) : nil;
        NSString *state = identifier.length > 0 ? visibility[identifier] : nil;
        if ([state isEqualToString:VLMRulesVisibilityHide]) {
            continue;
        }
        [visible addObject:item];
    }
    if (!VLMRulesPolicyHasOrdering(normalized) || visible.count < 2 || !itemID) {
        if (visible.count == items.count) {
            return items;
        }
        return visible;
    }

    NSArray<NSString *> *firstOrder = normalized[@"first"];
    NSArray<NSString *> *relativeOrder = normalized[@"relative"];
    NSArray<NSString *> *lastOrder = normalized[@"last"];
    NSSet<NSString *> *firstIDs = [NSSet setWithArray:firstOrder];
    NSSet<NSString *> *lastIDs = [NSSet setWithArray:lastOrder];
    NSMutableArray *first = [NSMutableArray array];
    NSMutableArray *middle = [NSMutableArray array];
    NSMutableArray *last = [NSMutableArray array];
    for (id item in visible) {
        NSString *identifier = itemID(item);
        if (identifier.length > 0 && [firstIDs containsObject:identifier]) {
            [first addObject:item];
        } else if (identifier.length > 0 && [lastIDs containsObject:identifier]) {
            [last addObject:item];
        } else {
            [middle addObject:item];
        }
    }
    first = [VLMRulesItemsSortedByOrder(first, firstOrder, itemID) mutableCopy];
    last = [VLMRulesItemsSortedByOrder(last, lastOrder, itemID) mutableCopy];

    if (relativeOrder.count > 0 && middle.count > 1) {
        NSSet<NSString *> *relativeIDs = [NSSet setWithArray:relativeOrder];
        NSMutableArray<NSNumber *> *slots = [NSMutableArray array];
        NSMutableArray *matched = [NSMutableArray array];
        [middle enumerateObjectsUsingBlock:^(id item, NSUInteger index, BOOL *stop) {
            (void)stop;
            NSString *identifier = itemID(item);
            if (identifier.length > 0 && [relativeIDs containsObject:identifier]) {
                [slots addObject:@(index)];
                [matched addObject:item];
            }
        }];
        NSArray *sortedMatched = VLMRulesItemsSortedByOrder(matched, relativeOrder, itemID);
        [slots enumerateObjectsUsingBlock:^(NSNumber *slot, NSUInteger index, BOOL *stop) {
            (void)stop;
            middle[slot.unsignedIntegerValue] = sortedMatched[index];
        }];
    }

    NSMutableArray *result = [NSMutableArray arrayWithCapacity:visible.count];
    [result addObjectsFromArray:first];
    [result addObjectsFromArray:middle];
    [result addObjectsFromArray:last];
    BOOL unchanged = result.count == items.count;
    for (NSUInteger index = 0; unchanged && index < result.count; index++) {
        unchanged = result[index] == items[index];
    }
    return unchanged ? items : result;
}

NSArray<NSNumber *> *VLMRulesVisibleOriginalIndexes(NSArray<NSString *> *itemIDs,
                                                     NSDictionary *policy) {
    if (![itemIDs isKindOfClass:[NSArray class]] || itemIDs.count == 0) {
        return @[];
    }
    NSMutableArray<NSDictionary *> *uniqueItems = [NSMutableArray arrayWithCapacity:itemIDs.count];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    [itemIDs enumerateObjectsUsingBlock:^(id rawID, NSUInteger index, BOOL *stop) {
        (void)stop;
        NSString *itemID = [rawID isKindOfClass:[NSString class]] ? rawID : @"";
        // A known semantic action may be exposed twice by UIKit (for example,
        // two Paste commands backed by different internal objects). Keep the
        // first real action. Empty identities remain distinct and visible.
        if (itemID.length > 0 && [seen containsObject:itemID]) {
            return;
        }
        if (itemID.length > 0) {
            [seen addObject:itemID];
        }
        [uniqueItems addObject:@{
            @"id": itemID,
            @"index": @(index),
        }];
    }];
    NSArray<NSDictionary *> *visible = VLMRulesApplyPolicyToItems(uniqueItems, policy, ^NSString *(id rawItem) {
        return [rawItem isKindOfClass:[NSDictionary class]] ? rawItem[@"id"] : nil;
    });
    return [visible valueForKey:@"index"] ?: @[];
}

static NSInteger VLMRulesRank(NSString *itemID, NSArray<NSString *> *orderIDs) {
    if (itemID.length == 0 || orderIDs.count == 0) {
        return NSIntegerMax;
    }
    NSUInteger index = [orderIDs indexOfObject:itemID];
    return index == NSNotFound ? NSIntegerMax - 1 : (NSInteger)index;
}

NSArray *VLMRulesApplyToItems(NSArray *items,
                              BOOL (^isHidden)(id item),
                              NSArray<NSString *> *orderIDs,
                              BOOL customOrder,
                              NSString *(^itemID)(id item)) {
    if (items.count == 0) {
        return items ?: @[];
    }
    if (!isHidden && (!customOrder || orderIDs.count == 0 || !itemID)) {
        return items;
    }
    NSMutableArray *visible = [NSMutableArray arrayWithCapacity:items.count];
    for (id item in items) {
        if (isHidden && isHidden(item)) {
            continue;
        }
        [visible addObject:item];
    }
    if (visible.count == 0) {
        return @[];
    }
    NSArray *working = visible.count == items.count ? items : visible;
    if (!customOrder || orderIDs.count == 0 || !itemID || working.count < 2) {
        return working;
    }
    NSArray *sorted = [working sortedArrayUsingComparator:^NSComparisonResult(id left, id right) {
        NSInteger leftRank = VLMRulesRank(itemID(left), orderIDs);
        NSInteger rightRank = VLMRulesRank(itemID(right), orderIDs);
        if (leftRank < rightRank) {
            return NSOrderedAscending;
        }
        if (leftRank > rightRank) {
            return NSOrderedDescending;
        }
        NSUInteger leftIndex = [working indexOfObjectIdenticalTo:left];
        NSUInteger rightIndex = [working indexOfObjectIdenticalTo:right];
        return leftIndex < rightIndex ? NSOrderedAscending : (leftIndex > rightIndex ? NSOrderedDescending : NSOrderedSame);
    }];
    for (NSUInteger index = 0; index < working.count; index++) {
        if (working[index] != sorted[index]) {
            return sorted;
        }
    }
    return working;
}

static void VLMRulesAppendItem(NSMutableArray<NSDictionary *> *items,
                               NSMutableSet<NSString *> *seen,
                               id value,
                               NSArray<NSDictionary *> *catalog) {
    NSString *itemID = nil;
    NSString *title = nil;
    if ([value isKindOfClass:[NSDictionary class]]) {
        itemID = value[@"id"];
        title = value[@"title"] ?: value[@"label"];
    } else if ([value isKindOfClass:[NSString class]]) {
        title = value;
        itemID = VLMRulesCatalogIDForTitle(catalog, title) ?: [@"custom:" stringByAppendingString:title];
    }
    if (itemID.length == 0 || [seen containsObject:itemID] || VLMRulesIsCapturedJunkItem(title, itemID)) {
        return;
    }
    [seen addObject:itemID];
    [items addObject:@{
        @"id": itemID,
        @"title": title.length > 0 ? title : itemID,
    }];
}

NSDictionary *VLMRulesNormalizedGlobalRule(NSDictionary *rule, NSArray<NSDictionary *> *catalog) {
    NSDictionary *source = [rule isKindOfClass:[NSDictionary class]] ? rule : @{};
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSDictionary *item in catalog) {
        VLMRulesAppendItem(items, seen, item, catalog);
    }
    for (id item in [source[@"items"] isKindOfClass:[NSArray class]] ? source[@"items"] : @[]) {
        VLMRulesAppendItem(items, seen, item, catalog);
    }

    NSMutableArray<NSString *> *order = [NSMutableArray array];
    NSMutableSet<NSString *> *seenOrder = [NSMutableSet set];
    for (NSString *itemID in VLMRulesUniqueIDs(source[@"order"])) {
        if ([seen containsObject:itemID]) {
            [seenOrder addObject:itemID];
            [order addObject:itemID];
        }
    }
    for (NSDictionary *item in items) {
        NSString *itemID = item[@"id"];
        if (![seenOrder containsObject:itemID]) {
            [seenOrder addObject:itemID];
            [order addObject:itemID];
        }
    }
    return @{
        @"items": items,
        @"order": order,
        @"hidden": VLMRulesUniqueIDs(source[@"hidden"]),
        @"customOrder": @([source[@"customOrder"] boolValue]),
    };
}

NSArray<NSString *> *VLMRulesEffectiveOrderIDs(NSDictionary *globalRule, NSDictionary *profile) {
    if ([profile[@"customOrder"] boolValue]) {
        NSArray<NSString *> *profileOrder = VLMRulesUniqueIDs(profile[@"order"]);
        if (profileOrder.count > 0) {
            return profileOrder;
        }
    }
    return VLMRulesUniqueIDs(globalRule[@"order"]);
}

NSArray<NSString *> *VLMRulesEffectiveHiddenIDs(NSDictionary *globalRule, NSDictionary *profile) {
    return VLMRulesUniqueIDs([VLMRulesUniqueIDs(globalRule[@"hidden"])
                              arrayByAddingObjectsFromArray:VLMRulesUniqueIDs(profile[@"hidden"])]);
}

BOOL VLMRulesEffectiveCustomOrder(NSDictionary *globalRule, NSDictionary *profile) {
    return [profile[@"customOrder"] boolValue] || [globalRule[@"customOrder"] boolValue];
}

static NSDictionary *VLMRulesRuleByMergingProfiles(NSString *kind,
                                                    NSArray<NSDictionary *> *profiles,
                                                    NSArray<NSString *> *legacyHidden,
                                                    NSArray<NSDictionary *> *catalog,
                                                    NSArray<NSString *> *defaultOrder) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableArray<NSString *> *hidden = [NSMutableArray array];
    NSMutableSet<NSString *> *seenHidden = [NSMutableSet set];
    NSDictionary *customSource = nil;
    NSTimeInterval newest = -1;
    for (NSDictionary *item in catalog) {
        VLMRulesAppendItem(items, seen, item, catalog);
    }
    for (NSDictionary *profile in profiles) {
        if (![profile[@"kind"] isEqualToString:kind]) {
            continue;
        }
        for (NSDictionary *item in [profile[@"items"] isKindOfClass:[NSArray class]] ? profile[@"items"] : @[]) {
            VLMRulesAppendItem(items, seen, item, catalog);
        }
        for (NSString *itemID in VLMRulesUniqueIDs(profile[@"hidden"])) {
            if (![seenHidden containsObject:itemID]) {
                [seenHidden addObject:itemID];
                [hidden addObject:itemID];
            }
        }
        NSTimeInterval seenAt = [profile[@"seenAt"] doubleValue];
        if ([profile[@"customOrder"] boolValue] && seenAt >= newest) {
            newest = seenAt;
            customSource = profile;
        }
    }
    for (NSString *itemID in legacyHidden) {
        if (itemID.length > 0 && ![seenHidden containsObject:itemID]) {
            [seenHidden addObject:itemID];
            [hidden addObject:itemID];
        }
    }
    NSArray<NSString *> *order = customSource ? VLMRulesUniqueIDs(customSource[@"order"]) : defaultOrder;
    return VLMRulesNormalizedGlobalRule(@{
        @"items": items,
        @"order": order ?: @[],
        @"hidden": hidden,
        @"customOrder": @(customSource != nil),
    }, catalog);
}

NSDictionary *VLMRulesMigratedGlobalRules(NSDictionary *existingRules,
                                           NSArray<NSDictionary *> *profiles,
                                           NSArray<NSString *> *legacyHidden,
                                           NSArray<NSDictionary *> *catalog,
                                           NSArray<NSString *> *defaultOrder,
                                           NSString *editKind,
                                           NSString *contextKind) {
    NSMutableDictionary *result = [existingRules isKindOfClass:[NSDictionary class]]
        ? [existingRules mutableCopy]
        : [NSMutableDictionary dictionary];
    result[editKind] = VLMRulesRuleByMergingProfiles(editKind, profiles, legacyHidden, catalog, defaultOrder);
    result[contextKind] = VLMRulesRuleByMergingProfiles(contextKind, profiles, @[], catalog, defaultOrder);
    result[@"migrated"] = @YES;
    return result;
}
