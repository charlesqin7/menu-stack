#import "VLMMenuListController.h"
#import "VLMOrderListController.h"
#import "../VLMMenuOrder.h"

@interface VLMMenuListController ()
- (void)rebuildProfileDisplayCache;
@end

@implementation VLMMenuListController {
    UITableView *_tableView;
    NSArray<NSDictionary *> *_profiles;
    NSArray<NSString *> *_profileTitles;
    NSArray<NSString *> *_profileSubtitles;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.title = @"按 App 例外";
        _profiles = @[];
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
    self.view = _tableView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemEdit
                                                                                           target:self
                                                                                           action:@selector(toggleEditing)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadFromPrefs];
}

- (void)toggleEditing {
    [_tableView setEditing:!_tableView.isEditing animated:YES];
}

- (void)reloadFromPrefs {
    NSDictionary *prefs = VLMReadPrefsDictionary();
    _profiles = [prefs[VLMMenuRegistryKey] isKindOfClass:[NSArray class]] ? prefs[VLMMenuRegistryKey] : @[];
    [self rebuildProfileDisplayCache];
    [_tableView reloadData];
}

- (void)writeProfiles {
    VLMReplacePrefsValuesAsync(@{VLMMenuRegistryKey: _profiles ?: @[]}, YES);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _profiles.count > 0 ? (NSInteger)_profiles.count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @"已记录的 App 与菜单类型";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"这里汇总每个 App 曾经出现过的菜单项，不会被下一次不同菜单覆盖。可为项目选择继承、显示或隐藏，并单独设置该 App 的顺序。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_profiles.count == 0) {
        static NSString *emptyID = @"VLMEmptyProfileCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:emptyID];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:emptyID];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        cell.textLabel.text = @"还没有记录到菜单";
        cell.detailTextLabel.text = @"请先在 App 里长按弹出一次，再回到这里";
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    static NSString *identifier = @"VLMMenuProfileCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.textLabel.text = _profileTitles[indexPath.row];
    cell.detailTextLabel.text = _profileSubtitles[indexPath.row];
    cell.detailTextLabel.numberOfLines = 2;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)_profiles.count) {
        return;
    }
    NSDictionary *profile = _profiles[indexPath.row];
    VLMOrderListController *controller = [[VLMOrderListController alloc] init];
    controller.profileID = profile[@"id"];
    controller.title = VLMProfileDisplayTitle(profile);
    if ([controller respondsToSelector:@selector(setRootController:)]) {
        [controller setRootController:[self rootController]];
    }
    if ([controller respondsToSelector:@selector(setParentController:)]) {
        [controller setParentController:self];
    }
    [self.navigationController pushViewController:controller animated:YES];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return _profiles.count > 0;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) {
        return;
    }
    NSString *profileID = _profiles[indexPath.row][@"id"];
    NSDictionary *record = _profiles[indexPath.row];
    VLMWriteAppPolicyAsync(record[@"bundle"], record[@"kind"], @{@"orderMode": VLMRulesOrderModeInherit});
    _profiles = VLMRemoveRegistryRecord(_profiles, profileID);
    [self rebuildProfileDisplayCache];
    [self writeProfiles];
    [tableView reloadData];
}

- (void)rebuildProfileDisplayCache {
    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithCapacity:_profiles.count];
    NSMutableArray<NSString *> *subtitles = [NSMutableArray arrayWithCapacity:_profiles.count];
    for (NSDictionary *profile in _profiles) {
        [titles addObject:VLMProfileDisplayTitle(profile) ?: @""];
        [subtitles addObject:VLMProfileSubtitle(profile) ?: @""];
    }
    _profileTitles = titles;
    _profileSubtitles = subtitles;
}

@end
