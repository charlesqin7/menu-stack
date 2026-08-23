#import "VLMOrderListController.h"
#import "../VLMMenuOrder.h"
#import <objc/runtime.h>

static const void *kVLMSwitchItemIDKey = &kVLMSwitchItemIDKey;

@implementation VLMOrderListController {
    UITableView *_tableView;
    NSMutableArray<NSString *> *_order;
    NSMutableSet<NSString *> *_hidden;
    NSMutableDictionary<NSString *, NSString *> *_labels;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.title = @"菜单排序";
        _hidden = [NSMutableSet set];
        _labels = [NSMutableDictionary dictionary];
        _order = [NSMutableArray array];
    }
    return self;
}

- (instancetype)initForContentSize:(CGSize)size {
    return [self init];
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
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"恢复默认"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(resetOrder)];
    [self reloadFromPrefs];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadFromPrefs];
}

- (NSDictionary *)currentProfile {
    NSDictionary *prefs = VLMReadPrefsDictionary();
    return VLMProfileWithID(prefs[VLMMenuProfilesKey], self.profileID);
}

- (void)reloadFromPrefs {
    NSDictionary *profile = [self currentProfile];
    _order = [VLMProfileDisplayOrder(profile) mutableCopy];
    _hidden = [NSMutableSet setWithArray:VLMProfileHiddenIDs(profile)];
    _labels = [NSMutableDictionary dictionary];
    for (NSDictionary *item in VLMProfileItems(profile)) {
        NSString *itemID = item[@"id"];
        NSString *title = item[@"title"] ?: VLMLabelForItemID(itemID);
        if (itemID.length > 0 && title.length > 0) {
            _labels[itemID] = title;
        }
    }
    for (NSString *itemID in _order) {
        if (!_labels[itemID]) {
            _labels[itemID] = VLMLabelForItemID(itemID) ?: itemID;
        }
    }
    [_tableView reloadData];
}

- (void)writePrefsAndEnableCustomSort:(BOOL)enableCustomSort {
    NSDictionary *prefs = VLMReadPrefsDictionary();
    NSDictionary *existing = VLMProfileWithID(prefs[VLMMenuProfilesKey], self.profileID);
    if (!existing) {
        return;
    }
    NSMutableDictionary *updated = [existing mutableCopy];
    updated[@"order"] = [_order copy] ?: @[];
    updated[@"hidden"] = _hidden.allObjects ?: @[];
    if (enableCustomSort) {
        updated[@"customOrder"] = @YES;
    }
    NSArray *profiles = VLMUpsertProfile(prefs[VLMMenuProfilesKey], updated);
    VLMWritePrefsValues(@{VLMMenuProfilesKey: profiles}, YES);
}

- (void)resetOrder {
    NSDictionary *profile = [self currentProfile];
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (NSDictionary *item in VLMProfileItems(profile)) {
        if (item[@"id"]) {
            [ids addObject:item[@"id"]];
        }
    }
    _order = ids;
    [_hidden removeAllObjects];
    NSDictionary *prefs = VLMReadPrefsDictionary();
    NSMutableDictionary *updated = [profile mutableCopy] ?: [NSMutableDictionary dictionary];
    updated[@"order"] = [_order copy] ?: @[];
    updated[@"hidden"] = @[];
    updated[@"customOrder"] = @NO;
    NSArray *profiles = VLMUpsertProfile(prefs[VLMMenuProfilesKey], updated);
    VLMWritePrefsValues(@{VLMMenuProfilesKey: profiles}, YES);
    [_tableView reloadData];
}

- (void)toggleHiddenForItemID:(NSString *)itemID {
    if (itemID.length == 0) {
        return;
    }
    if ([_hidden containsObject:itemID]) {
        [_hidden removeObject:itemID];
    } else {
        [_hidden addObject:itemID];
    }
    [self writePrefsAndEnableCustomSort:NO];
    [_tableView reloadData];
}

- (void)visibilitySwitchChanged:(UISwitch *)toggle {
    NSString *itemID = objc_getAssociatedObject(toggle, kVLMSwitchItemIDKey);
    if (itemID.length == 0) {
        return;
    }
    if (toggle.on) {
        [_hidden removeObject:itemID];
    } else {
        [_hidden addObject:itemID];
    }
    [self writePrefsAndEnableCustomSort:NO];
    [_tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_order.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"这里列出这个 App 里这类菜单出现过的全部项。选中文字、空白处、格式子菜单等组合会合并在一起，某次弹出没有的项会被跳过。关闭右边开关即可隐藏，不必打开自定义排序。按住右边横条拖动后，只有这一类菜单会按你的顺序排列。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"VLMOrderCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSString *itemID = _order[indexPath.row];
    BOOL hidden = [_hidden containsObject:itemID];
    cell.textLabel.text = _labels[itemID] ?: VLMLabelForItemID(itemID) ?: itemID;
    cell.detailTextLabel.text = hidden ? @"已隐藏，弹出菜单中不显示" : @"显示";
    cell.textLabel.textColor = hidden ? [UIColor secondaryLabelColor] : [UIColor labelColor];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = !hidden;
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
