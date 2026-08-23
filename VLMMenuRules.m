#import "VLMMenuRules.h"

static NSString *VLMRulesExtractItemID(id item) {
    if ([item isKindOfClass:[NSString class]]) {
        return item;
    }
    if ([item isKindOfClass:[NSDictionary class]]) {
        return item[@"id"];
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
    NSMutableArray *visible = [NSMutableArray arrayWithCapacity:items.count];
    for (id item in items) {
        if (isHidden && isHidden(item)) {
            continue;
        }
        [visible addObject:item];
    }
    if (visible.count == 0) {
        return items;
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
