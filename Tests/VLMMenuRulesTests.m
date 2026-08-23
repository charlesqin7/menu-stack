#import <Foundation/Foundation.h>

#import "VLMMenuOrder.h"
#import "VLMMenuRules.h"
#import "VLMMenuGeometry.h"

static NSUInteger gFailures = 0;

static void VLMAssert(BOOL condition, NSString *message) {
    if (condition) {
        return;
    }
    gFailures += 1;
    NSLog(@"FAIL: %@", message);
}

static void VLMAssertEqual(id actual, id expected, NSString *message) {
    BOOL equal = actual == expected || [actual isEqual:expected];
    VLMAssert(equal, [NSString stringWithFormat:@"%@ (actual=%@ expected=%@)", message, actual, expected]);
}

static void TestCatalogMatching(void) {
    VLMAssertEqual(VLMCatalogIDForTitle(@"拷贝"), @"copy", @"maps a Simplified Chinese title");
    VLMAssertEqual(VLMCatalogIDForTitle(@"Copy"), @"copy", @"maps an English title");
    VLMAssertEqual(VLMCatalogIDForTitle(@"Translate…"), @"translate", @"normalizes ellipsis variants");
    VLMAssertEqual(VLMCatalogIDForSelectorName(@"paste:"), @"paste", @"maps a selector");
    VLMAssertEqual(VLMCatalogIDForIdentifier(@"com.apple.menu.lookup"), @"lookup", @"maps a menu identifier");
}

static void TestCustomItemIDs(void) {
    NSArray *catalog = VLMCatalogItems();
    VLMAssertEqual(VLMRulesItemIDForTitle(catalog, @"  我的操作...  "),
                   @"custom:我的操作",
                   @"creates a stable custom ID");
    VLMAssertEqual(VLMRulesItemIDForTitle(catalog, @"粘贴"), @"paste", @"prefers a catalog ID");
    VLMAssert(VLMRulesItemIDForTitle(catalog, @"   ") == nil, @"rejects an empty custom title");
}

static void TestLegacyRuleItems(void) {
    NSDictionary *rule = VLMRulesNormalizedGlobalRule(@{
        @"items": @[@"我的操作", @"MD清单"],
        @"order": @[@"custom:我的操作", @"copy"],
    }, VLMCatalogItems());
    NSArray<NSString *> *itemIDs = [rule[@"items"] valueForKey:@"id"];
    VLMAssert([itemIDs containsObject:@"custom:我的操作"], @"normalizes a legacy string item");
    VLMAssert(![itemIDs containsObject:@"custom:MD清单"], @"filters a polluted legacy string item");
}

static void TestEffectiveRules(void) {
    NSDictionary *global = @{
        @"order": @[@"copy", @"paste", @"share"],
        @"hidden": @[@"copy", @"paste"],
        @"customOrder": @YES,
    };
    NSDictionary *inheritedProfile = @{
        @"order": @[@"paste", @"copy"],
        @"hidden": @[@"paste", @"share"],
        @"customOrder": @NO,
    };
    VLMAssertEqual(VLMRulesEffectiveOrderIDs(global, inheritedProfile),
                   global[@"order"],
                   @"uses global order without an app override");
    VLMAssertEqual(VLMRulesEffectiveHiddenIDs(global, inheritedProfile),
                   (@[@"copy", @"paste", @"share"]),
                   @"unions global and app hidden IDs without duplicates");
    VLMAssert(VLMRulesEffectiveCustomOrder(global, inheritedProfile), @"inherits global custom ordering");

    NSDictionary *overrideProfile = @{
        @"order": @[@"paste", @"copy"],
        @"hidden": @[],
        @"customOrder": @YES,
    };
    VLMAssertEqual(VLMRulesEffectiveOrderIDs(global, overrideProfile),
                   overrideProfile[@"order"],
                   @"uses an app-specific order override");
}

static void TestV2PolicyResolution(void) {
    NSDictionary *global = VLMRulesNormalizedPolicy(@{
        @"visibility": @{@"translate": VLMRulesVisibilityHide, @"share": VLMRulesVisibilityHide},
        @"first": @[@"copy"],
        @"relative": @[@"paste", @"copy"],
        @"last": @[@"delete"],
        @"orderMode": VLMRulesOrderModeCustom,
    });
    NSDictionary *app = VLMRulesNormalizedPolicy(@{
        @"visibility": @{@"translate": VLMRulesVisibilityShow, @"lookup": VLMRulesVisibilityHide},
        @"orderMode": VLMRulesOrderModeInherit,
    });
    NSDictionary *resolved = VLMRulesResolvedPolicy(global, app);
    VLMAssertEqual(VLMRulesVisibilityForItem(resolved, @"translate"),
                   VLMRulesVisibilityShow,
                   @"allows an app to restore a globally hidden action");
    VLMAssertEqual(VLMRulesVisibilityForItem(resolved, @"share"),
                   VLMRulesVisibilityHide,
                   @"inherits an unrelated global hidden action");
    VLMAssertEqual(VLMRulesVisibilityForItem(resolved, @"lookup"),
                   VLMRulesVisibilityHide,
                   @"applies an app-only hidden action");
    VLMAssert(VLMRulesPolicyHasOrdering(resolved), @"inherits global sparse ordering");

    NSArray *visible = VLMRulesApplyPolicyToItems((@[@"translate", @"share", @"lookup"]),
                                                   resolved,
                                                   ^NSString *(id item) { return item; });
    VLMAssertEqual(visible,
                   @[@"translate"],
                   @"applies the resolved app show override and both inherited/app hides");

    NSDictionary *systemApp = VLMRulesResolvedPolicy(global, @{@"orderMode": VLMRulesOrderModeSystem});
    VLMAssert(!VLMRulesPolicyHasOrdering(systemApp), @"lets an app restore system ordering");
}

static void TestV2SparseOrdering(void) {
    NSDictionary *relative = @{
        @"relative": @[@"paste", @"copy"],
        @"orderMode": VLMRulesOrderModeCustom,
    };
    NSArray *source = @[@"copy", @"dynamic", @"paste", @"share"];
    NSArray *rewritten = VLMRulesApplyPolicyToItems(source, relative, ^NSString *(id item) {
        return item;
    });
    VLMAssertEqual(rewritten,
                   (@[@"paste", @"dynamic", @"copy", @"share"]),
                   @"reorders configured actions without moving an unknown dynamic action out of its slot");

    rewritten = VLMRulesApplyPolicyToItems(source, relative, ^NSString *(id item) {
        return [item isEqual:@"dynamic"] ? nil : item;
    });
    VLMAssertEqual(rewritten,
                   (@[@"paste", @"dynamic", @"copy", @"share"]),
                   @"keeps an unidentifiable dynamic element in place without crashing");

    NSDictionary *pinned = @{
        @"first": @[@"paste", @"copy"],
        @"last": @[@"delete"],
        @"orderMode": VLMRulesOrderModeCustom,
    };
    rewritten = VLMRulesApplyPolicyToItems((@[@"delete", @"copy", @"share", @"paste"]), pinned, ^NSString *(id item) {
        return item;
    });
    VLMAssertEqual(rewritten,
                   (@[@"paste", @"copy", @"share", @"delete"]),
                   @"supports ordered first and last pins");
}

static void TestV2PolicySanitizing(void) {
    NSDictionary *policy = VLMRulesNormalizedPolicy(@{
        @"visibility": @{@"copy": @42, @42: VLMRulesVisibilityHide},
        @"relative": @[@42, @{@"id": @42}, @"paste"],
        @"orderMode": @42,
    });
    VLMAssertEqual(policy[@"visibility"], @{}, @"drops malformed visibility keys and values");
    VLMAssertEqual(policy[@"relative"], @[@"paste"], @"drops malformed ordering IDs");
    VLMAssertEqual(policy[@"orderMode"],
                   VLMRulesOrderModeCustom,
                   @"infers custom mode from a valid sparse ordering field");
}

static NSDictionary *TestProfile(NSString *profileID,
                                 NSArray<NSDictionary *> *items,
                                 NSArray<NSString *> *order,
                                 NSArray<NSString *> *hidden,
                                 BOOL customOrder,
                                 NSTimeInterval seenAt) {
    return @{
        @"id": profileID,
        @"kind": VLMMenuKindEdit,
        @"bundle": @"com.example.reader",
        @"appName": @"Reader",
        @"items": items,
        @"order": order,
        @"hidden": hidden,
        @"customOrder": @(customOrder),
        @"seenAt": @(seenAt),
    };
}

static void TestLegacyProfileMerge(void) {
    NSDictionary *older = TestProfile(@"edit|com.example.reader|old-a",
                                      (@[@{@"id": @"copy", @"title": @"拷贝"},
                                         @{@"id": @"paste", @"title": @"粘贴"}]),
                                      @[@"paste", @"copy"],
                                      @[@"copy"],
                                      YES,
                                      1);
    NSDictionary *newer = TestProfile(@"edit|com.example.reader|old-b",
                                      (@[@{@"id": @"cut", @"title": @"剪切"},
                                         @{@"id": @"copy", @"title": @"拷贝"}]),
                                      @[@"cut", @"copy"],
                                      @[@"paste"],
                                      NO,
                                      2);
    NSArray<NSDictionary *> *profiles = VLMSanitizeProfiles(@[older, newer]);
    VLMAssertEqual(@(profiles.count), @1, @"merges legacy fingerprint profiles");
    NSDictionary *merged = profiles.firstObject;
    VLMAssertEqual(merged[@"id"], @"edit|com.example.reader", @"uses the canonical profile ID");
    VLMAssertEqual([NSSet setWithArray:VLMProfileHiddenIDs(merged)],
                   [NSSet setWithArray:@[@"copy", @"paste"]],
                   @"preserves hidden IDs from both legacy profiles");
    VLMAssert(VLMProfileCustomOrder(merged), @"preserves an existing app order override");
}

static void TestV2RegistryUnion(void) {
    NSArray *records = VLMSanitizeRegistryRecords(@[
        @{
            @"kind": VLMMenuKindContext,
            @"bundle": @"com.example.reader",
            @"appName": @"Reader",
            @"items": @[@{@"id": @"copy", @"title": @"拷贝"},
                         @{@"id": @"custom:Open chapter", @"title": @"Open chapter"}],
            @"seenAt": @1,
        },
        @{
            @"kind": VLMMenuKindContext,
            @"bundle": @"com.example.reader",
            @"appName": @"Reader",
            @"items": @[@{@"id": @"paste", @"title": @"粘贴"},
                         @{@"id": @"copy", @"title": @"Copy"}],
            @"seenAt": @2,
        },
    ]);
    VLMAssertEqual(@(records.count), @1, @"keeps one registry record per app and menu kind");
    NSDictionary *record = records.firstObject;
    NSArray *ids = [VLMProfileItems(record) valueForKey:@"id"];
    VLMAssert([ids containsObject:@"copy"] && [ids containsObject:@"paste"],
              @"unions actions observed in different menus of the same app");
    VLMAssert([ids containsObject:@"title:com.example.reader:open chapter"],
              @"scopes a title-only fallback identity to its app");

    records = VLMRemoveRegistryRecord(records, record[@"id"]);
    VLMAssertEqual(records, @[], @"removes an observed app/menu record without touching policy data");
}

static void TestV2RegistryBounds(void) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    for (NSUInteger index = 0; index < 160; index++) {
        [items addObject:@{
            @"id": [NSString stringWithFormat:@"action:%lu", (unsigned long)index],
            @"title": [NSString stringWithFormat:@"Action %lu", (unsigned long)index],
        }];
    }
    NSArray *records = VLMSanitizeRegistryRecords(@[@{
        @"kind": VLMMenuKindContext,
        @"bundle": @"com.example.dynamic",
        @"items": items,
        @"seenAt": @1,
    }]);
    VLMAssertEqual(@([VLMProfileItems(records.firstObject) count]),
                   @64,
                   @"bounds dynamic observations so Registry size cannot grow forever");

    NSMutableArray<NSDictionary *> *manyRecords = [NSMutableArray array];
    for (NSUInteger index = 0; index < 260; index++) {
        [manyRecords addObject:@{
            @"kind": VLMMenuKindEdit,
            @"bundle": [NSString stringWithFormat:@"com.example.app%lu", (unsigned long)index],
            @"items": @[@{@"id": @"copy", @"title": @"Copy"}],
            @"seenAt": @(index),
        }];
    }
    records = VLMSanitizeRegistryRecords(manyRecords);
    VLMAssertEqual(@(records.count), @240, @"bounds the total number of observed app/menu records");
    NSDictionary *newestRecord = records.firstObject;
    VLMAssertEqual(newestRecord[@"bundle"],
                   @"com.example.app259",
                   @"retains the most recently observed records when pruning");
}

static void TestMigration(void) {
    NSArray *profiles = VLMSanitizeProfiles(@[
        TestProfile(@"legacy-edit",
                    (@[@{@"id": @"copy", @"title": @"拷贝"},
                       @{@"id": @"paste", @"title": @"粘贴"}]),
                    @[@"paste", @"copy"],
                    @[@"share"],
                    YES,
                    10),
        @{
            @"id": @"legacy-context",
            @"kind": VLMMenuKindContext,
            @"bundle": @"com.example.reader",
            @"appName": @"Reader",
            @"items": @[@{@"id": @"copy", @"title": @"拷贝"},
                         @{@"id": @"openLink", @"title": @"打开"}],
            @"order": @[@"copy", @"openLink"],
            @"hidden": @[@"copy"],
            @"customOrder": @NO,
            @"seenAt": @11,
        },
    ]);
    NSDictionary *migrated = VLMRulesMigratedGlobalRules(nil,
                                                          profiles,
                                                          @[@"lookup"],
                                                          VLMCatalogItems(),
                                                          VLMDefaultOrderIDs(),
                                                          VLMMenuKindEdit,
                                                          VLMMenuKindContext);
    VLMAssert([migrated[@"migrated"] boolValue], @"marks global rules as migrated");
    NSDictionary *edit = migrated[VLMMenuKindEdit];
    NSDictionary *context = migrated[VLMMenuKindContext];
    VLMAssertEqual([edit[@"order"] firstObject], @"paste", @"migrates the newest custom edit order");
    VLMAssertEqual([NSSet setWithArray:edit[@"hidden"]],
                   [NSSet setWithArray:@[@"share", @"lookup"]],
                   @"migrates app and legacy edit hidden IDs");
    VLMAssertEqual(context[@"hidden"], @[@"copy"], @"does not leak legacy edit hiding into context menus");
}

static void TestJunkFiltering(void) {
    VLMAssert(VLMIsCapturedJunkItem(@"MD清单", @"custom:MD清单"), @"filters a known polluted item");
    VLMAssert(VLMIsCapturedJunkItem(nil, @"custom:showHelp:"), @"filters a help selector");
    VLMAssert(!VLMIsCapturedJunkItem(@"共享", @"share"), @"keeps a valid action");
}

static void TestSafeFilteringAndSorting(void) {
    NSArray *original = @[@"copy", @"paste"];
    NSArray *noOp = VLMRulesApplyToItems(original, nil, @[], NO, nil);
    VLMAssert(noOp == original, @"returns the original array for an inactive rule");
    NSArray *allHidden = VLMRulesApplyToItems(original,
                                              ^BOOL(id item) {
        (void)item;
        return YES;
    },
                                              @[@"paste", @"copy"],
                                              YES,
                                              ^NSString *(id item) {
        return item;
    });
    VLMAssertEqual(allHidden, @[], @"returns an empty menu when every item is hidden");

    NSArray *items = @[@"copy", @"paste", @"share"];
    NSArray *rewritten = VLMRulesApplyToItems(items,
                                              ^BOOL(id item) {
        return [item isEqualToString:@"share"];
    },
                                              @[@"paste", @"copy"],
                                              YES,
                                              ^NSString *(id item) {
        return item;
    });
    VLMAssertEqual(rewritten, (@[@"paste", @"copy"]), @"filters and sorts visible items");
}

static void TestSafeAreaPlacement(void) {
    CGRect safe = CGRectMake(8.0, 55.0, 374.0, 673.0);
    CGSize desired = CGSizeMake(250.0, 252.0);

    VLMMenuPlacement nearTop = VLMMenuPlaceNearAnchor(safe,
                                                       CGRectMake(170.0, 70.0, 40.0, 22.0),
                                                       desired,
                                                       6.0,
                                                       3.0,
                                                       76.0);
    VLMAssert(nearTop.belowAnchor, @"places a top selection below the anchor");
    VLMAssert(CGRectContainsRect(safe, nearTop.frame), @"keeps the top placement inside the safe rect");

    VLMMenuPlacement nearBottom = VLMMenuPlaceNearAnchor(safe,
                                                          CGRectMake(170.0, 680.0, 40.0, 22.0),
                                                          desired,
                                                          6.0,
                                                          3.0,
                                                          76.0);
    VLMAssert(!nearBottom.belowAnchor, @"places a bottom selection above the anchor");
    VLMAssert(CGRectContainsRect(safe, nearBottom.frame), @"keeps the bottom placement inside the safe rect");

    CGRect keyboardSafe = CGRectMake(8.0, 55.0, 374.0, 250.0);
    VLMMenuPlacement constrained = VLMMenuPlaceNearAnchor(keyboardSafe,
                                                           CGRectMake(170.0, 170.0, 40.0, 22.0),
                                                           desired,
                                                           6.0,
                                                           3.0,
                                                           76.0);
    VLMAssert(CGRectContainsRect(keyboardSafe, constrained.frame), @"shrinks a keyboard-constrained menu inside the safe rect");
    VLMAssert(CGRectGetHeight(constrained.frame) < desired.height, @"reduces viewport height instead of overflowing");
}

int main(void) {
    @autoreleasepool {
        TestCatalogMatching();
        TestCustomItemIDs();
        TestLegacyRuleItems();
        TestEffectiveRules();
        TestV2PolicyResolution();
        TestV2SparseOrdering();
        TestV2PolicySanitizing();
        TestLegacyProfileMerge();
        TestV2RegistryUnion();
        TestV2RegistryBounds();
        TestMigration();
        TestJunkFiltering();
        TestSafeFilteringAndSorting();
        TestSafeAreaPlacement();
        if (gFailures > 0) {
            NSLog(@"%lu VerticalMenu rule test(s) failed", (unsigned long)gFailures);
            return 1;
        }
        NSLog(@"All VerticalMenu rule tests passed");
    }
    return 0;
}
