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
    VLMAssert(allHidden == original, @"keeps the original menu when every item is hidden");

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
        TestLegacyProfileMerge();
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
