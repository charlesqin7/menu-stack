#import "VLMOrderListController.h"
#import "../VLMMenuOrder.h"
#import <objc/runtime.h>

static const void *kVLMVisibilityItemIDKey = &kVLMVisibilityItemIDKey;

@implementation VLMOrderListController {
    UITableView *_tableView;
    NSMutableArray<NSString *> *_first;
    NSMutableArray<NSString *> *_middle;
    NSMutableArray<NSString *> *_last;
    NSMutableDictionary<NSString *, NSString *> *_visibility;
    NSMutableDictionary<NSString *, NSString *> *_labels;
    NSDictionary *_prefsSnapshot;
    NSDictionary *_globalPolicy;
    NSDictionary *_registryRecord;
    NSString *_bundleID;
    NSString *_kind;
    NSString *_orderMode;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.title = @"菜单规则";
        _first = [NSMutableArray array];
        _middle = [NSMutableArray array];
        _last = [NSMutableArray array];
        _visibility = [NSMutableDictionary dictionary];
        _labels = [NSMutableDictionary dictionary];
        _orderMode = VLMRulesOrderModeInherit;
    }
    return self;
}

- (instancetype)initForContentSize:(CGSize)size {
    (void)size;
    return [self init];
}

- (BOOL)isGlobal {
    return self.globalKind.length > 0;
}

- (void)readSpecifierKind {
    if (self.globalKind.length > 0) return;
    id specifier = nil;
    if ([self respondsToSelector:@selector(specifier)]) specifier = [self specifier];
    NSString *key = nil;
    @try {
        if ([specifier respondsToSelector:@selector(propertyForKey:)]) key = [specifier propertyForKey:@"key"];
        if (![key isKindOfClass:[NSString class]] && [specifier respondsToSelector:@selector(identifier)]) key = [specifier identifier];
    } @catch (__unused NSException *exception) {
    }
    if ([key isEqualToString:@"GlobalEdit"] || [key isEqualToString:VLMMenuKindEdit]) {
        self.globalKind = VLMMenuKindEdit;
    } else if ([key isEqualToString:@"GlobalContext"] || [key isEqualToString:VLMMenuKindContext]) {
        self.globalKind = VLMMenuKindContext;
    }
}

- (void)loadView {
    UITableViewStyle style = UITableViewStyleGrouped;
    if (@available(iOS 13.0, *)) style = UITableViewStyleInsetGrouped;
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:style];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.editing = YES;
    _tableView.allowsSelectionDuringEditing = YES;
    self.view = _tableView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self readSpecifierKind];
    if ([self isGlobal]) self.title = [NSString stringWithFormat:@"%@ · 全局", VLMKindDisplayName(self.globalKind)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"重置"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(resetPolicy)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self readSpecifierKind];
    [self reloadFromPrefs];
}

- (NSMutableArray<NSString *> *)itemsForSection:(NSInteger)section {
    if (section == 1) return _first;
    if (section == 2) return _middle;
    if (section == 3) return _last;
    return nil;
}

- (NSArray<NSString *> *)allKnownIDsForPrefs:(NSDictionary *)prefs policy:(NSDictionary *)policy {
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    void (^appendItem)(NSDictionary *) = ^(NSDictionary *item) {
        NSString *itemID = item[@"id"];
        NSString *title = item[@"title"] ?: item[@"label"] ?: VLMLabelForItemID(itemID);
        if (itemID.length == 0) return;
        if (title.length > 0) self->_labels[itemID] = title;
        if (![seen containsObject:itemID]) {
            [seen addObject:itemID];
            [ids addObject:itemID];
        }
    };
    if ([self isGlobal]) {
        for (NSDictionary *item in VLMCatalogItems()) appendItem(item);
        NSArray<NSDictionary *> *registry = [prefs[VLMMenuRegistryKey] isKindOfClass:[NSArray class]]
            ? prefs[VLMMenuRegistryKey] : @[];
        for (NSDictionary *record in registry) {
            if (![record[@"kind"] isEqualToString:_kind]) continue;
            NSArray<NSDictionary *> *items = [record[@"items"] isKindOfClass:[NSArray class]] ? record[@"items"] : @[];
            for (NSDictionary *item in items) {
                // Title-only IDs are intentionally scoped to one App. Listing
                // them as global rules would be misleading and can create a
                // very large global page on devices with many dynamic menus.
                if (![item[@"id"] hasPrefix:@"title:"]) appendItem(item);
            }
        }
    } else {
        NSArray<NSDictionary *> *items = [_registryRecord[@"items"] isKindOfClass:[NSArray class]]
            ? _registryRecord[@"items"] : @[];
        for (NSDictionary *item in items) appendItem(item);
    }
    for (NSString *field in @[@"first", @"relative", @"last"]) {
        for (NSString *itemID in policy[field] ?: @[]) {
            if (![seen containsObject:itemID]) {
                [seen addObject:itemID];
                [ids addObject:itemID];
            }
        }
    }
    return ids;
}

- (void)reloadFromPrefs {
    _prefsSnapshot = VLMReadPrefsDictionary();
    _labels = [NSMutableDictionary dictionary];
    if ([self isGlobal]) {
        _kind = self.globalKind ?: VLMMenuKindEdit;
        _bundleID = nil;
        _globalPolicy = VLMGlobalPolicyForKindInPrefs(_prefsSnapshot, _kind);
        _registryRecord = nil;
    } else {
        _registryRecord = VLMRegistryRecordWithID(_prefsSnapshot[VLMMenuRegistryKey], self.profileID);
        if (!_registryRecord) {
            [self.navigationController popViewControllerAnimated:YES];
            return;
        }
        _kind = _registryRecord[@"kind"] ?: VLMMenuKindEdit;
        _bundleID = _registryRecord[@"bundle"] ?: @"";
        _globalPolicy = VLMGlobalPolicyForKindInPrefs(_prefsSnapshot, _kind);
    }
    NSDictionary *policy = [self isGlobal]
        ? _globalPolicy
        : VLMAppPolicyForKindInPrefs(_prefsSnapshot, _bundleID, _kind);
    policy = VLMRulesNormalizedPolicy(policy);
    _visibility = [policy[@"visibility"] mutableCopy] ?: [NSMutableDictionary dictionary];
    _orderMode = policy[@"orderMode"] ?: ([self isGlobal] ? VLMRulesOrderModeSystem : VLMRulesOrderModeInherit);
    NSArray<NSString *> *all = [self allKnownIDsForPrefs:_prefsSnapshot policy:policy];

    NSDictionary *displayPolicy = policy;
    if (![_orderMode isEqualToString:VLMRulesOrderModeCustom]) {
        displayPolicy = VLMRulesNormalizedPolicy(@{@"orderMode": VLMRulesOrderModeSystem});
    } else {
        NSMutableDictionary *withoutVisibility = [policy mutableCopy];
        withoutVisibility[@"visibility"] = @{};
        displayPolicy = withoutVisibility;
    }
    NSArray<NSString *> *displayOrder = VLMRulesApplyPolicyToItems(all, displayPolicy, ^NSString *(id item) { return item; });
    NSSet *firstIDs = [_orderMode isEqualToString:VLMRulesOrderModeCustom] ? [NSSet setWithArray:policy[@"first"] ?: @[]] : [NSSet set];
    NSSet *lastIDs = [_orderMode isEqualToString:VLMRulesOrderModeCustom] ? [NSSet setWithArray:policy[@"last"] ?: @[]] : [NSSet set];
    _first = [NSMutableArray array];
    _middle = [NSMutableArray array];
    _last = [NSMutableArray array];
    for (NSString *itemID in displayOrder) {
        if ([firstIDs containsObject:itemID]) [_first addObject:itemID];
        else if ([lastIDs containsObject:itemID]) [_last addObject:itemID];
        else [_middle addObject:itemID];
        if (!_labels[itemID]) _labels[itemID] = VLMLabelForItemID(itemID) ?: itemID;
    }
    [_tableView reloadData];
}

- (NSDictionary *)currentPolicy {
    BOOL customOrder = [_orderMode isEqualToString:VLMRulesOrderModeCustom];
    return VLMRulesNormalizedPolicy(@{
        @"visibility": _visibility ?: @{},
        @"first": customOrder ? (_first ?: @[]) : @[],
        @"relative": customOrder ? (_middle ?: @[]) : @[],
        @"last": customOrder ? (_last ?: @[]) : @[],
        @"orderMode": _orderMode ?: ([self isGlobal] ? VLMRulesOrderModeSystem : VLMRulesOrderModeInherit),
    });
}

- (void)writePolicy {
    NSDictionary *policy = [self currentPolicy];
    if ([self isGlobal]) VLMWriteGlobalPolicyAsync(_kind, policy);
    else VLMWriteAppPolicyAsync(_bundleID, _kind, policy);
}

- (void)resetPolicy {
    _visibility = [NSMutableDictionary dictionary];
    _first = [NSMutableArray array];
    _last = [NSMutableArray array];
    _orderMode = [self isGlobal] ? VLMRulesOrderModeSystem : VLMRulesOrderModeInherit;
    _middle = [[self allKnownIDsForPrefs:_prefsSnapshot policy:@{}] mutableCopy];
    [self writePolicy];
    [_tableView reloadData];
}

- (void)orderModeChanged:(UISegmentedControl *)control {
    if ([self isGlobal]) {
        _orderMode = control.selectedSegmentIndex == 0 ? VLMRulesOrderModeSystem : VLMRulesOrderModeCustom;
    } else {
        _orderMode = control.selectedSegmentIndex == 0 ? VLMRulesOrderModeInherit
            : (control.selectedSegmentIndex == 1 ? VLMRulesOrderModeSystem : VLMRulesOrderModeCustom);
    }
    if (![_orderMode isEqualToString:VLMRulesOrderModeCustom]) {
        _first = [NSMutableArray array];
        _middle = [[self allKnownIDsForPrefs:_prefsSnapshot policy:@{}] mutableCopy];
        _last = [NSMutableArray array];
    }
    [self writePolicy];
    [_tableView reloadData];
}

- (void)visibilityChanged:(UISegmentedControl *)control {
    NSString *itemID = objc_getAssociatedObject(control, kVLMVisibilityItemIDKey);
    if (itemID.length == 0) return;
    if ([self isGlobal]) {
        if (control.selectedSegmentIndex == 1) _visibility[itemID] = VLMRulesVisibilityHide;
        else [_visibility removeObjectForKey:itemID];
    } else {
        if (control.selectedSegmentIndex == 0) [_visibility removeObjectForKey:itemID];
        else if (control.selectedSegmentIndex == 1) _visibility[itemID] = VLMRulesVisibilityShow;
        else _visibility[itemID] = VLMRulesVisibilityHide;
    }
    [self writePolicy];
    [_tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return 1;
    return MAX(1, (NSInteger)[[self itemsForSection:section] count]);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return @"顺序策略";
    if (section == 1) return @"固定到前面";
    if (section == 2) return @"跟随系统 / 相对顺序";
    return @"固定到后面";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) {
        return [self isGlobal]
            ? @"“系统”保留 App 原顺序；“自定义”只调整已记录项目，新出现的动态项目保留系统位置。"
            : @"可继承全局、恢复此 App 的系统顺序，或建立此 App 自己的顺序。";
    }
    if (section == 2) return @"拖动只改变同一菜单层级内已知项目的相对次序；系统后来加入的项目不会被统一挤到末尾。";
    return nil;
}

- (UITableViewCell *)orderModeCellForTableView:(UITableView *)tableView {
    static NSString *identifier = @"VLMPolicyModeCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSArray *titles = [self isGlobal] ? @[@"系统", @"自定义"] : @[@"继承", @"系统", @"自定义"];
    UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:titles];
    if ([self isGlobal]) control.selectedSegmentIndex = [_orderMode isEqualToString:VLMRulesOrderModeCustom] ? 1 : 0;
    else control.selectedSegmentIndex = [_orderMode isEqualToString:VLMRulesOrderModeCustom] ? 2
        : ([_orderMode isEqualToString:VLMRulesOrderModeSystem] ? 1 : 0);
    [control addTarget:self action:@selector(orderModeChanged:) forControlEvents:UIControlEventValueChanged];
    cell.textLabel.text = @"菜单顺序";
    cell.accessoryView = control;
    cell.editingAccessoryView = control;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return [self orderModeCellForTableView:tableView];
    NSArray<NSString *> *sectionItems = [self itemsForSection:indexPath.section];
    if (sectionItems.count == 0) {
        static NSString *placeholderIdentifier = @"VLMPolicyDropPlaceholderCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:placeholderIdentifier];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:placeholderIdentifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = @"拖到这里";
        cell.textLabel.textColor = [UIColor tertiaryLabelColor];
        cell.accessoryView = nil;
        cell.editingAccessoryView = nil;
        return cell;
    }
    static NSString *identifier = @"VLMPolicyItemCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSString *itemID = sectionItems[indexPath.row];
    NSString *state = _visibility[itemID] ?: VLMRulesVisibilityInherit;
    NSString *effectiveGlobal = VLMRulesVisibilityForItem(_globalPolicy, itemID);
    cell.textLabel.text = _labels[itemID] ?: VLMLabelForItemID(itemID) ?: itemID;
    if ([self isGlobal]) {
        cell.detailTextLabel.text = [state isEqualToString:VLMRulesVisibilityHide] ? @"全局隐藏" : @"系统提供时显示";
    } else if ([state isEqualToString:VLMRulesVisibilityShow]) {
        cell.detailTextLabel.text = @"此 App 显示（系统提供时）";
    } else if ([state isEqualToString:VLMRulesVisibilityHide]) {
        cell.detailTextLabel.text = @"此 App 隐藏";
    } else {
        cell.detailTextLabel.text = [effectiveGlobal isEqualToString:VLMRulesVisibilityHide] ? @"继承全局：隐藏" : @"继承全局：显示";
    }
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.textLabel.textColor = ([state isEqualToString:VLMRulesVisibilityHide]
        || ([state isEqualToString:VLMRulesVisibilityInherit] && [effectiveGlobal isEqualToString:VLMRulesVisibilityHide]))
        ? [UIColor secondaryLabelColor] : [UIColor labelColor];

    NSArray *segments = [self isGlobal] ? @[@"显示", @"隐藏"] : @[@"继承", @"显示", @"隐藏"];
    UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:segments];
    if ([self isGlobal]) control.selectedSegmentIndex = [state isEqualToString:VLMRulesVisibilityHide] ? 1 : 0;
    else control.selectedSegmentIndex = [state isEqualToString:VLMRulesVisibilityShow] ? 1
        : ([state isEqualToString:VLMRulesVisibilityHide] ? 2 : 0);
    control.transform = CGAffineTransformMakeScale(0.82, 0.82);
    objc_setAssociatedObject(control, kVLMVisibilityItemIDKey, itemID, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [control addTarget:self action:@selector(visibilityChanged:) forControlEvents:UIControlEventValueChanged];
    cell.editingAccessoryView = control;
    cell.accessoryView = control;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    NSArray *items = [self itemsForSection:indexPath.section];
    return indexPath.section >= 1 && indexPath.row < (NSInteger)items.count;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return NO;
}

- (NSIndexPath *)tableView:(UITableView *)tableView
targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath
       toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath {
    (void)tableView;
    (void)sourceIndexPath;
    if (proposedDestinationIndexPath.section < 1) {
        return [NSIndexPath indexPathForRow:0 inSection:1];
    }
    return proposedDestinationIndexPath;
}

- (void)tableView:(UITableView *)tableView
moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath
       toIndexPath:(NSIndexPath *)destinationIndexPath {
    (void)tableView;
    NSMutableArray *source = [self itemsForSection:sourceIndexPath.section];
    NSMutableArray *destination = [self itemsForSection:destinationIndexPath.section];
    if (!source || !destination) return;
    NSString *itemID = source[sourceIndexPath.row];
    [source removeObjectAtIndex:sourceIndexPath.row];
    NSInteger row = MIN(destinationIndexPath.row, (NSInteger)destination.count);
    [destination insertObject:itemID atIndex:(NSUInteger)row];
    _orderMode = VLMRulesOrderModeCustom;
    [self writePolicy];
    [_tableView reloadData];
}

@end
