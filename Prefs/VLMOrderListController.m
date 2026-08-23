#import "VLMOrderListController.h"
#import "../VLMMenuOrder.h"
#import <objc/runtime.h>

static const void *kVLMSwitchItemIDKey = &kVLMSwitchItemIDKey;

@implementation VLMOrderListController {
    UITableView *_tableView;
    NSMutableArray<NSString *> *_order;
    NSMutableSet<NSString *> *_hidden;
    NSMutableDictionary<NSString *, NSString *> *_labels;
    NSSet<NSString *> *_globalHidden;
    NSDictionary *_prefsSnapshot;
    BOOL _customOrder;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.title = @"菜单排序";
        _hidden = [NSMutableSet set];
        _labels = [NSMutableDictionary dictionary];
        _order = [NSMutableArray array];
        _globalHidden = [NSSet set];
    }
    return self;
}

- (instancetype)initForContentSize:(CGSize)size {
    return [self init];
}

- (BOOL)isGlobal {
    return self.globalKind.length > 0;
}

- (void)readSpecifierKind {
    if (self.globalKind.length > 0) {
        return;
    }
    id specifier = nil;
    if ([self respondsToSelector:@selector(specifier)]) {
        specifier = [self specifier];
    }
    NSString *key = nil;
    @try {
        if ([specifier respondsToSelector:@selector(propertyForKey:)]) {
            key = [specifier propertyForKey:@"key"];
        }
        if (![key isKindOfClass:[NSString class]] && [specifier respondsToSelector:@selector(identifier)]) {
            key = [specifier identifier];
        }
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
    if (@available(iOS 13.0, *)) {
        style = UITableViewStyleInsetGrouped;
    }
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:style];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.editing = YES;
    _tableView.allowsSelectionDuringEditing = YES;
    _tableView.allowsSelection = YES;
    self.view = _tableView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self readSpecifierKind];
    if ([self isGlobal]) {
        self.title = [NSString stringWithFormat:@"%@ · 全局", VLMKindDisplayName(self.globalKind)];
    }
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"恢复默认"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(resetOrder)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self readSpecifierKind];
    [self reloadFromPrefs];
}

- (NSDictionary *)currentProfile {
    return VLMProfileWithID(_prefsSnapshot[VLMMenuProfilesKey], self.profileID);
}

- (void)reloadFromPrefs {
    NSDictionary *prefs = VLMReadPrefsDictionary();
    _prefsSnapshot = prefs;
    _labels = [NSMutableDictionary dictionary];
    if ([self isGlobal]) {
        NSDictionary *rule = VLMGlobalRuleForKindInPrefs(prefs, self.globalKind);
        _order = [rule[@"order"] mutableCopy] ?: [NSMutableArray array];
        _hidden = [NSMutableSet setWithArray:rule[@"hidden"] ?: @[]];
        _customOrder = [rule[@"customOrder"] boolValue];
        for (NSDictionary *item in rule[@"items"] ?: @[]) {
            NSString *itemID = item[@"id"];
            NSString *title = item[@"title"] ?: VLMLabelForItemID(itemID);
            if (itemID.length > 0 && title.length > 0) {
                _labels[itemID] = title;
            }
        }
        _globalHidden = [NSSet set];
    } else {
        NSDictionary *profile = [self currentProfile];
        _order = [VLMProfileDisplayOrder(profile) mutableCopy];
        _hidden = [NSMutableSet setWithArray:VLMProfileHiddenIDs(profile)];
        for (NSDictionary *item in VLMProfileItems(profile)) {
            NSString *itemID = item[@"id"];
            NSString *title = item[@"title"] ?: VLMLabelForItemID(itemID);
            if (itemID.length > 0 && title.length > 0) {
                _labels[itemID] = title;
            }
        }
        NSString *kind = profile[@"kind"] ?: VLMMenuKindEdit;
        NSDictionary *globalRule = VLMGlobalRuleForKindInPrefs(prefs, kind);
        _globalHidden = [NSSet setWithArray:globalRule[@"hidden"] ?: @[]];
        _customOrder = VLMProfileCustomOrder(profile);
    }
    for (NSString *itemID in _order) {
        if (!_labels[itemID]) {
            _labels[itemID] = VLMLabelForItemID(itemID) ?: itemID;
        }
    }
    [_tableView reloadData];
}

- (void)writePrefsAndEnableCustomSort:(BOOL)enableCustomSort {
    if (enableCustomSort) {
        _customOrder = YES;
    }
    if ([self isGlobal]) {
        NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
        for (NSString *itemID in _order) {
            [items addObject:@{
                @"id": itemID,
                @"title": _labels[itemID] ?: VLMLabelForItemID(itemID) ?: itemID,
            }];
        }
        VLMWriteGlobalRuleAsync(self.globalKind, _order, _hidden.allObjects, items, _customOrder);
        return;
    }
    NSDictionary *existing = [self currentProfile];
    if (!existing) {
        return;
    }
    NSMutableDictionary *updated = [existing mutableCopy];
    updated[@"order"] = [_order copy] ?: @[];
    updated[@"hidden"] = _hidden.allObjects ?: @[];
    updated[@"customOrder"] = @(_customOrder);
    NSArray *profiles = VLMUpsertProfile(_prefsSnapshot[VLMMenuProfilesKey], updated);
    NSMutableDictionary *nextPrefs = [_prefsSnapshot mutableCopy] ?: [NSMutableDictionary dictionary];
    nextPrefs[VLMMenuProfilesKey] = profiles;
    _prefsSnapshot = nextPrefs;
    NSDictionary *profileSnapshot = VLMProfileWithID(profiles, self.profileID) ?: updated;
    VLMWritePrefsValuesAsync(@{VLMMenuProfilesKey: @[profileSnapshot]}, YES);
}

- (void)resetOrder {
    if ([self isGlobal]) {
        NSMutableArray<NSString *> *ids = [VLMDefaultOrderIDs() mutableCopy];
        NSMutableSet<NSString *> *seen = [NSMutableSet setWithArray:ids];
        for (NSString *itemID in _order) {
            if (itemID.length && ![seen containsObject:itemID]) {
                [ids addObject:itemID];
                [seen addObject:itemID];
            }
        }
        _order = ids;
        [_hidden removeAllObjects];
        NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
        for (NSString *itemID in _order) {
            [items addObject:@{
                @"id": itemID,
                @"title": _labels[itemID] ?: VLMLabelForItemID(itemID) ?: itemID,
            }];
        }
        _customOrder = NO;
        VLMWriteGlobalRuleAsync(self.globalKind, _order, @[], items, NO);
        [_tableView reloadData];
        return;
    }
    NSDictionary *profile = [self currentProfile];
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (NSDictionary *item in VLMProfileItems(profile)) {
        if (item[@"id"]) {
            [ids addObject:item[@"id"]];
        }
    }
    _order = ids;
    [_hidden removeAllObjects];
    NSMutableDictionary *updated = [profile mutableCopy] ?: [NSMutableDictionary dictionary];
    updated[@"order"] = [_order copy] ?: @[];
    updated[@"hidden"] = @[];
    updated[@"customOrder"] = @NO;
    _customOrder = NO;
    NSArray *profiles = VLMUpsertProfile(_prefsSnapshot[VLMMenuProfilesKey], updated);
    NSMutableDictionary *nextPrefs = [_prefsSnapshot mutableCopy] ?: [NSMutableDictionary dictionary];
    nextPrefs[VLMMenuProfilesKey] = profiles;
    _prefsSnapshot = nextPrefs;
    NSDictionary *profileSnapshot = VLMProfileWithID(profiles, self.profileID) ?: updated;
    VLMWritePrefsValuesAsync(@{VLMMenuProfilesKey: @[profileSnapshot]}, YES);
    [_tableView reloadData];
}

- (void)toggleHiddenForItemID:(NSString *)itemID {
    if (itemID.length == 0) {
        return;
    }
    if ([_globalHidden containsObject:itemID]) {
        return;
    }
    if ([_hidden containsObject:itemID]) {
        [_hidden removeObject:itemID];
    } else {
        [_hidden addObject:itemID];
    }
    [self writePrefsAndEnableCustomSort:NO];
    NSUInteger row = [_order indexOfObject:itemID];
    if (row != NSNotFound) {
        [_tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:(NSInteger)row inSection:0]]
                          withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)visibilitySwitchChanged:(UISwitch *)toggle {
    NSString *itemID = objc_getAssociatedObject(toggle, kVLMSwitchItemIDKey);
    if (itemID.length == 0) {
        return;
    }
    if ([_globalHidden containsObject:itemID]) {
        toggle.on = NO;
        return;
    }
    if (toggle.on) {
        [_hidden removeObject:itemID];
    } else {
        [_hidden addObject:itemID];
    }
    [self writePrefsAndEnableCustomSort:NO];
    NSUInteger row = [_order indexOfObject:itemID];
    if (row != NSNotFound) {
        [_tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:(NSInteger)row inSection:0]]
                          withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_order.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if ([self isGlobal]) {
        return @"对所有 App 生效。某次弹出没有的项会被跳过。关闭开关即隐藏；拖动右边横条后按这个全局顺序排列。某个 App 还要多藏几项时，用上一页的「按 App 例外」。";
    }
    return @"这里是这个 App 最近一次弹出时出现的项。关闭开关会在这个 App 里额外隐藏该项。拖动右边横条后才会覆盖全局顺序。全局已经隐藏的项不能在这里打开。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"VLMOrderCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSString *itemID = _order[indexPath.row];
    BOOL globallyHidden = [_globalHidden containsObject:itemID];
    BOOL hidden = globallyHidden || [_hidden containsObject:itemID];
    cell.textLabel.text = _labels[itemID] ?: VLMLabelForItemID(itemID) ?: itemID;
    if (globallyHidden) {
        cell.detailTextLabel.text = @"全局已隐藏，不能在这个 App 里打开";
    } else {
        cell.detailTextLabel.text = hidden ? @"已隐藏，弹出菜单中不显示" : @"显示";
    }
    cell.textLabel.textColor = hidden ? [UIColor secondaryLabelColor] : [UIColor labelColor];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = !hidden;
    toggle.enabled = !globallyHidden;
    objc_setAssociatedObject(toggle, kVLMSwitchItemIDKey, itemID, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [toggle addTarget:self action:@selector(visibilitySwitchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.editingAccessoryView = toggle;
    cell.accessoryView = nil;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self toggleHiddenForItemID:_order[indexPath.row]];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (sourceIndexPath.row == destinationIndexPath.row) {
        return;
    }
    NSString *itemID = _order[sourceIndexPath.row];
    [_order removeObjectAtIndex:sourceIndexPath.row];
    [_order insertObject:itemID atIndex:destinationIndexPath.row];
    [self writePrefsAndEnableCustomSort:YES];
}

@end
