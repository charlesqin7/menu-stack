#import "VLMMenuOrder.h"

#if __has_include(<rootless.h>)
#import <rootless.h>
#endif
#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

NSString * const VLMPrefsIdentifier = @"com.qins.verticalmenu";
NSString * const VLMReloadNotificationName = @"com.qins.verticalmenu/ReloadPrefs";
NSString * const VLMMenuOrderKey = @"MenuItemOrder";
NSString * const VLMCustomOrderKey = @"CustomOrder";
NSString * const VLMKnownItemsKey = @"KnownMenuItems";
NSString * const VLMHiddenItemsKey = @"HiddenMenuItems";
NSString * const VLMPrefsStampKey = @"PrefsStamp";

static NSArray<NSString *> *VLMPrefsFilePaths(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    void (^add)(NSString *) = ^(NSString *path) {
        if (path.length == 0 || [paths containsObject:path]) {
            return;
        }
        [paths addObject:path];
    };
#if defined(ROOT_PATH_NS)
    add(ROOT_PATH_NS(@"/var/mobile/Library/Preferences/com.qins.verticalmenu.plist"));
#endif
#ifdef THEOS_PACKAGE_INSTALL_PREFIX
    add(@(THEOS_PACKAGE_INSTALL_PREFIX "/var/mobile/Library/Preferences/com.qins.verticalmenu.plist"));
#endif
#if __has_include(<roothide.h>)
    add(jbroot(@"/var/mobile/Library/Preferences/com.qins.verticalmenu.plist"));
#endif
    add(@"/var/jb/var/mobile/Library/Preferences/com.qins.verticalmenu.plist");
    add(@"/var/jb/Library/Preferences/com.qins.verticalmenu.plist");
    add(@"/var/mobile/Library/Preferences/com.qins.verticalmenu.plist");
    return paths;
}

static NSDictionary *VLMCopyCFPrefs(CFStringRef host) {
    CFStringRef ident = (__bridge CFStringRef)VLMPrefsIdentifier;
    CFPreferencesAppSynchronize(ident);
    CFArrayRef keys = CFPreferencesCopyKeyList(ident, kCFPreferencesCurrentUser, host);
    if (!keys) {
        return @{};
    }
    CFDictionaryRef cfDict = CFPreferencesCopyMultiple(keys, ident, kCFPreferencesCurrentUser, host);
    CFRelease(keys);
    return CFBridgingRelease(cfDict) ?: @{};
}

static id VLMCopyCFPrefValue(NSString *key) {
    CFStringRef ident = (__bridge CFStringRef)VLMPrefsIdentifier;
    CFStringRef cfKey = (__bridge CFStringRef)key;
    CFPreferencesAppSynchronize(ident);
    id appValue = CFBridgingRelease(CFPreferencesCopyAppValue(cfKey, ident));
    if (appValue) {
        return appValue;
    }
    id anyHost = CFBridgingRelease(CFPreferencesCopyValue(cfKey, ident, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    if (anyHost) {
        return anyHost;
    }
    return CFBridgingRelease(CFPreferencesCopyValue(cfKey, ident, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost));
}

static NSArray<NSDictionary *> *VLMPrefsSources(void) {
    NSMutableArray<NSDictionary *> *sources = [NSMutableArray array];
    NSDictionary *anyHost = VLMCopyCFPrefs(kCFPreferencesAnyHost);
    if (anyHost.count > 0) {
        [sources addObject:anyHost];
    }
    NSDictionary *currentHost = VLMCopyCFPrefs(kCFPreferencesCurrentHost);
    if (currentHost.count > 0) {
        [sources addObject:currentHost];
    }
    for (NSString *path in VLMPrefsFilePaths()) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (dict.count > 0) {
            [sources addObject:dict];
        }
    }
    return sources;
}

static id VLMPickPrefValue(NSArray<NSDictionary *> *sources, NSString *key) {
    id chosen = nil;
    NSTimeInterval chosenStamp = -1;
    for (NSDictionary *dict in sources) {
        id value = dict[key];
        if (!value) {
            continue;
        }
        NSTimeInterval stamp = [dict[VLMPrefsStampKey] doubleValue];
        if (!chosen || stamp >= chosenStamp) {
            chosen = value;
            chosenStamp = stamp;
        }
    }
    if (chosen) {
        return chosen;
    }
    return VLMCopyCFPrefValue(key);
}

NSDictionary<NSString *, id> *VLMReadPrefsDictionary(void) {
    NSArray<NSDictionary *> *sources = VLMPrefsSources();
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    for (NSDictionary *dict in sources) {
        [keys addObjectsFromArray:dict.allKeys];
    }
    [keys addObject:VLMHiddenItemsKey];
    [keys addObject:VLMMenuOrderKey];
    [keys addObject:VLMCustomOrderKey];
    [keys addObject:VLMKnownItemsKey];

    NSMutableDictionary<NSString *, id> *merged = [NSMutableDictionary dictionary];
    for (NSString *key in keys) {
        id value = VLMPickPrefValue(sources, key);
        if (value) {
            merged[key] = value;
        }
    }
    return merged;
}

static void VLMWriteCFPrefValue(NSString *key, id value) {
    CFStringRef ident = (__bridge CFStringRef)VLMPrefsIdentifier;
    CFStringRef cfKey = (__bridge CFStringRef)key;
    CFPropertyListRef cfValue = (__bridge CFPropertyListRef)value;
    CFPreferencesSetAppValue(cfKey, cfValue, ident);
    CFPreferencesSetValue(cfKey, cfValue, ident, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSetValue(cfKey, cfValue, ident, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
}

void VLMWritePrefsValues(NSDictionary<NSString *, id> *updates, BOOL bumpStamp) {
    if (updates.count == 0 && !bumpStamp) {
        return;
    }
    NSMutableDictionary<NSString *, id> *changes = [updates mutableCopy] ?: [NSMutableDictionary dictionary];
    if (bumpStamp) {
        changes[VLMPrefsStampKey] = @((NSTimeInterval)[[NSDate date] timeIntervalSince1970]);
    }
    for (NSString *key in changes) {
        VLMWriteCFPrefValue(key, changes[key]);
    }
    CFPreferencesAppSynchronize((__bridge CFStringRef)VLMPrefsIdentifier);

    for (NSString *path in VLMPrefsFilePaths()) {
        NSString *directory = [path stringByDeletingLastPathComponent];
        BOOL isDirectory = NO;
        BOOL directoryExists = [[NSFileManager defaultManager] fileExistsAtPath:directory isDirectory:&isDirectory];
        if (!directoryExists || !isDirectory) {
            continue;
        }
        if (![[NSFileManager defaultManager] isWritableFileAtPath:directory] &&
            ![[NSFileManager defaultManager] isWritableFileAtPath:path]) {
            continue;
        }
        NSMutableDictionary *fileDict = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy] ?: [NSMutableDictionary dictionary];
        [fileDict addEntriesFromDictionary:changes];
        [fileDict writeToFile:path atomically:YES];
    }

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)VLMReloadNotificationName,
        NULL,
        NULL,
        true
    );
}

static NSString *VLMFold(NSString *text) {
    if (text.length == 0) {
        return @"";
    }
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    trimmed = [trimmed stringByReplacingOccurrencesOfString:@"…" withString:@""];
    trimmed = [trimmed stringByReplacingOccurrencesOfString:@"..." withString:@""];
    trimmed = [trimmed stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.lowercaseString;
}

static NSArray<NSDictionary *> *VLMCatalog(void) {
    static NSArray<NSDictionary *> *items;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        items = @[
            @{
                @"id": @"cut",
                @"label": @"剪切",
                @"titles": @[@"剪切", @"剪下", @"Cut"],
                @"sels": @[@"cut:"],
            },
            @{
                @"id": @"copy",
                @"label": @"拷贝",
                @"titles": @[@"拷贝", @"拷貝", @"复制", @"複製", @"Copy"],
                @"sels": @[@"copy:"],
            },
            @{
                @"id": @"paste",
                @"label": @"粘贴",
                @"titles": @[@"粘贴", @"貼上", @"Paste"],
                @"sels": @[@"paste:"],
            },
            @{
                @"id": @"select",
                @"label": @"选择",
                @"titles": @[@"选择", @"選擇", @"Select"],
                @"sels": @[@"select:"],
            },
            @{
                @"id": @"selectAll",
                @"label": @"全选",
                @"titles": @[@"全选", @"全選", @"Select All"],
                @"sels": @[@"selectAll:"],
            },
            @{
                @"id": @"lookup",
                @"label": @"查询",
                @"titles": @[@"查询", @"查詢", @"Look Up", @"Look up"],
                @"sels": @[@"_lookup:", @"lookup:", @"_lookupDefinition:", @"lookupDefinition:"],
                @"idents": @[@"lookup", @"com.apple.menu.lookup"],
            },
            @{
                @"id": @"findSelection",
                @"label": @"查找所选内容",
                @"titles": @[@"查找所选内容", @"查找所選內容", @"Find Selection", @"Find Selected", @"Find"],
                @"sels": @[@"_findSelected:", @"findSelected:", @"find:", @"_find:", @"findInPage:"],
                @"idents": @[@"findSelection", @"find", @"com.apple.menu.find"],
            },
            @{
                @"id": @"searchWeb",
                @"label": @"搜索网页",
                @"titles": @[@"搜索网页", @"搜尋網頁", @"Search Web", @"Search the Web"],
                @"sels": @[@"_searchWeb:", @"searchWeb:", @"_searchTheWeb:", @"searchTheWeb:"],
                @"idents": @[@"searchWeb", @"com.apple.menu.searchTheWeb"],
            },
            @{
                @"id": @"translate",
                @"label": @"翻译",
                @"titles": @[@"翻译", @"翻譯", @"Translate"],
                @"sels": @[@"_translate:", @"translate:", @"_translateSelection:", @"translateSelection:"],
                @"idents": @[@"translate", @"com.apple.menu.translate"],
            },
            @{
                @"id": @"share",
                @"label": @"共享",
                @"titles": @[@"分享", @"共享", @"Share"],
                @"sels": @[@"_share:", @"share:", @"_shareSelection:", @"shareSelection:"],
                @"idents": @[@"share", @"com.apple.menu.share"],
            },
            @{
                @"id": @"quickNote",
                @"label": @"新建快速备忘录",
                @"titles": @[@"新建快速备忘录", @"新增快速備忘錄", @"New Quick Note", @"Add to Quick Note"],
                @"sels": @[@"_addToQuickNote:", @"addToQuickNote:", @"_quickNote:", @"newQuickNote:"],
                @"idents": @[@"quickNote", @"com.apple.menu.quickNote"],
            },
            @{
                @"id": @"replace",
                @"label": @"替换",
                @"titles": @[@"替换", @"取代", @"Replace"],
                @"sels": @[@"_promptForReplace:", @"replace:"],
            },
            @{
                @"id": @"delete",
                @"label": @"删除",
                @"titles": @[@"删除", @"刪除", @"Delete"],
                @"sels": @[@"delete:"],
            },
            @{
                @"id": @"scan",
                @"label": @"扫描",
                @"titles": @[@"扫描", @"掃描", @"Scan", @"Scan Documents"],
                @"sels": @[@"scan:"],
            },
            @{
                @"id": @"pin",
                @"label": @"置顶",
                @"titles": @[@"置顶", @"置頂", @"Pin"],
                @"sels": @[@"pin:"],
            },
            @{
                @"id": @"lock",
                @"label": @"锁定",
                @"titles": @[@"锁定", @"鎖定", @"Lock"],
                @"sels": @[@"lock:"],
            },
            @{
                @"id": @"bold",
                @"label": @"粗体",
                @"titles": @[@"粗体", @"粗體", @"Bold"],
                @"sels": @[@"toggleBoldface:"],
            },
            @{
                @"id": @"italic",
                @"label": @"斜体",
                @"titles": @[@"斜体", @"斜體", @"Italic"],
                @"sels": @[@"toggleItalics:"],
            },
            @{
                @"id": @"underline",
                @"label": @"下划线",
                @"titles": @[@"下划线", @"底線", @"Underline"],
                @"sels": @[@"toggleUnderline:"],
            },
            @{
                @"id": @"define",
                @"label": @"定义",
                @"titles": @[@"定义", @"定義", @"Define"],
                @"sels": @[@"_define:", @"define:"],
            },
            @{
                @"id": @"speak",
                @"label": @"朗读",
                @"titles": @[@"朗读", @"朗讀", @"Speak"],
                @"sels": @[@"_speak:", @"speak:"],
            },
            @{
                @"id": @"copyLink",
                @"label": @"拷贝链接",
                @"titles": @[@"拷贝链接", @"拷貝連結", @"复制链接", @"Copy Link"],
                @"sels": @[@"copyLink:", @"_copyLink:"],
            },
            @{
                @"id": @"openLink",
                @"label": @"打开",
                @"titles": @[@"打开", @"打開", @"打开链接", @"Open", @"Open Link"],
                @"sels": @[@"openURL:", @"openLink:"],
            },
            @{
                @"id": @"readingList",
                @"label": @"添加到阅读列表",
                @"titles": @[@"添加到阅读列表", @"加入閱讀列表", @"Add to Reading List"],
                @"sels": @[@"addToReadingList:"],
            },
            @{
                @"id": @"autofill",
                @"label": @"自动填充",
                @"titles": @[@"自动填充", @"自動填寫", @"AutoFill", @"Autofill"],
                @"sels": @[@"_autofill:", @"autofill:"],
            },
        ];
    });
    return items;
}

NSArray<NSDictionary *> *VLMCatalogItems(void) {
    return VLMCatalog();
}

static BOOL VLMIsCatalogID(NSString *itemID) {
    if (itemID.length == 0) {
        return NO;
    }
    for (NSDictionary *item in VLMCatalog()) {
        if ([item[@"id"] isEqualToString:itemID]) {
            return YES;
        }
    }
    return NO;
}

NSArray<NSString *> *VLMCoreOrderIDs(void) {
    static NSArray<NSString *> *ids;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ids = @[
            @"cut",
            @"copy",
            @"paste",
            @"select",
            @"selectAll",
            @"findSelection",
            @"lookup",
            @"translate",
            @"searchWeb",
            @"share",
            @"quickNote",
            @"replace",
            @"speak",
        ];
    });
    return ids;
}

NSArray<NSString *> *VLMDefaultOrderIDs(void) {
    return VLMCoreOrderIDs();
}

NSString *VLMLabelForItemID(NSString *itemID) {
    if (itemID.length == 0) {
        return nil;
    }
    for (NSDictionary *item in VLMCatalog()) {
        if ([item[@"id"] isEqualToString:itemID]) {
            return item[@"label"];
        }
    }
    if ([itemID hasPrefix:@"custom:"]) {
        return [itemID substringFromIndex:7];
    }
    return itemID;
}

NSString *VLMCatalogIDForTitle(NSString *title) {
    NSString *folded = VLMFold(title);
    if (folded.length == 0) {
        return nil;
    }
    for (NSDictionary *item in VLMCatalog()) {
        for (NSString *candidate in item[@"titles"]) {
            if ([VLMFold(candidate) isEqualToString:folded]) {
                return item[@"id"];
            }
        }
    }
    return nil;
}

NSString *VLMCatalogIDForSelectorName(NSString *selectorName) {
    if (selectorName.length == 0) {
        return nil;
    }
    for (NSDictionary *item in VLMCatalog()) {
        for (NSString *sel in item[@"sels"]) {
            if ([sel isEqualToString:selectorName]) {
                return item[@"id"];
            }
        }
    }
    return nil;
}

NSString *VLMCatalogIDForIdentifier(NSString *identifier) {
    if (identifier.length == 0) {
        return nil;
    }
    NSString *last = identifier.lastPathComponent.lowercaseString;
    if (last.length == 0) {
        last = identifier.lowercaseString;
    }
    for (NSDictionary *item in VLMCatalog()) {
        NSString *itemID = item[@"id"];
        if ([last isEqualToString:itemID.lowercaseString]) {
            return itemID;
        }
        if ([last hasSuffix:[@"." stringByAppendingString:itemID.lowercaseString]]) {
            return itemID;
        }
        for (NSString *alias in item[@"idents"]) {
            if ([identifier isEqualToString:alias] || [last isEqualToString:alias.lowercaseString]) {
                return itemID;
            }
        }
    }
    NSString *fromTitle = VLMCatalogIDForTitle(identifier);
    if (fromTitle) {
        return fromTitle;
    }
    return nil;
}

static NSString *VLMExtractItemID(id item) {
    if ([item isKindOfClass:[NSString class]]) {
        return item;
    }
    if ([item isKindOfClass:[NSDictionary class]]) {
        return item[@"id"];
    }
    return nil;
}

static BOOL VLMKnownItemsLookPolluted(NSArray *stored) {
    if (stored.count == 0) {
        return NO;
    }
    NSInteger catalogHits = 0;
    for (id item in stored) {
        if (VLMIsCatalogID(VLMExtractItemID(item))) {
            catalogHits += 1;
        }
    }
    return catalogHits >= (NSInteger)VLMCatalog().count - 1;
}

NSArray<NSString *> *VLMDisplayOrderIDs(id orderValue, id knownValue) {
    NSArray<NSString *> *core = VLMCoreOrderIDs();
    NSMutableSet<NSString *> *allowed = [NSMutableSet setWithArray:core];
    NSMutableArray<NSString *> *knownIDs = [NSMutableArray array];
    for (NSDictionary *item in VLMSanitizeKnownItems(knownValue)) {
        NSString *itemID = item[@"id"];
        if (itemID.length == 0) {
            continue;
        }
        [allowed addObject:itemID];
        [knownIDs addObject:itemID];
    }

    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    if ([orderValue isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)orderValue) {
            NSString *itemID = VLMExtractItemID(item);
            if (itemID.length == 0 || [seen containsObject:itemID] || ![allowed containsObject:itemID]) {
                continue;
            }
            [seen addObject:itemID];
            [ids addObject:itemID];
        }
    }
    for (NSString *itemID in core) {
        if (![seen containsObject:itemID]) {
            [ids addObject:itemID];
        }
    }
    for (NSString *itemID in knownIDs) {
        if (![seen containsObject:itemID]) {
            [ids addObject:itemID];
        }
    }
    return ids;
}

NSArray<NSString *> *VLMSanitizeOrderIDs(id value) {
    return VLMDisplayOrderIDs(value, nil);
}

NSArray<NSString *> *VLMSanitizeHiddenIDs(id value) {
    if (![value isKindOfClass:[NSArray class]]) {
        return @[];
    }
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id item in (NSArray *)value) {
        NSString *itemID = VLMExtractItemID(item);
        if (itemID.length == 0 || [seen containsObject:itemID]) {
            continue;
        }
        [seen addObject:itemID];
        [ids addObject:itemID];
    }
    return ids;
}

static void VLMAppendKnownItem(NSMutableArray<NSDictionary *> *result, NSMutableSet<NSString *> *seen, id item) {
    NSString *itemID = nil;
    NSString *title = nil;
    if ([item isKindOfClass:[NSDictionary class]]) {
        itemID = item[@"id"];
        title = item[@"title"] ?: item[@"label"];
    } else if ([item isKindOfClass:[NSString class]]) {
        itemID = VLMCatalogIDForTitle(item) ?: [@"custom:" stringByAppendingString:item];
        title = item;
    }
    if (itemID.length == 0 || [seen containsObject:itemID]) {
        return;
    }
    [seen addObject:itemID];
    [result addObject:@{
        @"id": itemID,
        @"title": title.length ? title : (VLMLabelForItemID(itemID) ?: itemID),
    }];
}

NSArray<NSDictionary *> *VLMSanitizeKnownItems(id value) {
    if (![value isKindOfClass:[NSArray class]] || VLMKnownItemsLookPolluted(value)) {
        return @[];
    }
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSSet<NSString *> *core = [NSSet setWithArray:VLMCoreOrderIDs()];
    for (id item in (NSArray *)value) {
        NSString *itemID = VLMExtractItemID(item);
        if ([core containsObject:itemID]) {
            continue;
        }
        VLMAppendKnownItem(result, seen, item);
    }
    return result;
}

NSArray<NSDictionary *> *VLMMergedKnownItems(NSArray *stored, NSArray *extra) {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id item in VLMSanitizeKnownItems(stored)) {
        VLMAppendKnownItem(result, seen, item);
    }
    for (id item in extra) {
        VLMAppendKnownItem(result, seen, item);
    }
    return result;
}
