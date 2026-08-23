#import "VLMMenuOrder.h"

NSString * const VLMMenuOrderKey = @"MenuItemOrder";
NSString * const VLMCustomOrderKey = @"CustomOrder";
NSString * const VLMKnownItemsKey = @"KnownMenuItems";
NSString * const VLMHiddenItemsKey = @"HiddenMenuItems";

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
                @"sels": @[@"_lookup:", @"lookup:"],
            },
            @{
                @"id": @"findSelection",
                @"label": @"查找所选内容",
                @"titles": @[@"查找所选内容", @"查找所選內容", @"Find Selection", @"Find Selected"],
                @"sels": @[@"_findSelected:", @"findSelected:", @"find:"],
            },
            @{
                @"id": @"searchWeb",
                @"label": @"搜索网页",
                @"titles": @[@"搜索网页", @"搜尋網頁", @"Search Web", @"Search the Web"],
                @"sels": @[@"_searchWeb:", @"searchWeb:"],
            },
            @{
                @"id": @"translate",
                @"label": @"翻译",
                @"titles": @[@"翻译", @"翻譯", @"Translate"],
                @"sels": @[@"_translate:", @"translate:"],
            },
            @{
                @"id": @"share",
                @"label": @"分享",
                @"titles": @[@"分享", @"共享", @"Share"],
                @"sels": @[@"_share:", @"share:", @"share:"],
            },
            @{
                @"id": @"quickNote",
                @"label": @"新建快速备忘录",
                @"titles": @[@"新建快速备忘录", @"新增快速備忘錄", @"New Quick Note", @"Add to Quick Note"],
                @"sels": @[@"_addToQuickNote:", @"addToQuickNote:"],
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

NSArray<NSString *> *VLMDefaultOrderIDs(void) {
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (NSDictionary *item in VLMCatalog()) {
        [ids addObject:item[@"id"]];
    }
    return ids;
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
    }
    NSString *fromTitle = VLMCatalogIDForTitle(identifier);
    if (fromTitle) {
        return fromTitle;
    }
    return nil;
}

NSArray<NSString *> *VLMSanitizeOrderIDs(id value) {
    if (![value isKindOfClass:[NSArray class]]) {
        return VLMDefaultOrderIDs();
    }
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id item in (NSArray *)value) {
        NSString *itemID = nil;
        if ([item isKindOfClass:[NSString class]]) {
            itemID = item;
        } else if ([item isKindOfClass:[NSDictionary class]]) {
            itemID = item[@"id"];
        }
        if (itemID.length == 0 || [seen containsObject:itemID]) {
            continue;
        }
        [seen addObject:itemID];
        [ids addObject:itemID];
    }
    for (NSString *itemID in VLMDefaultOrderIDs()) {
        if (![seen containsObject:itemID]) {
            [ids addObject:itemID];
        }
    }
    return ids;
}

NSArray<NSString *> *VLMSanitizeHiddenIDs(id value) {
    if (![value isKindOfClass:[NSArray class]]) {
        return @[];
    }
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id item in (NSArray *)value) {
        NSString *itemID = nil;
        if ([item isKindOfClass:[NSString class]]) {
            itemID = item;
        } else if ([item isKindOfClass:[NSDictionary class]]) {
            itemID = item[@"id"];
        }
        if (itemID.length == 0 || [seen containsObject:itemID]) {
            continue;
        }
        [seen addObject:itemID];
        [ids addObject:itemID];
    }
    return ids;
}

NSArray<NSDictionary *> *VLMMergedKnownItems(NSArray *stored, NSArray *extra) {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    void (^append)(id) = ^(id item) {
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
    };

    for (NSDictionary *item in VLMCatalog()) {
        append(@{@"id": item[@"id"], @"title": item[@"label"]});
    }
    for (id item in stored) {
        append(item);
    }
    for (id item in extra) {
        append(item);
    }
    return result;
}
