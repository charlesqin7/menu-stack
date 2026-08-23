#import "VLMMenuListController.h"
#import "VLMOrderListController.h"
#import "../VLMMenuOrder.h"

@implementation VLMMenuListController {
    UITableView *_tableView;
    NSArray<NSDictionary *> *_profiles;
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
    VLMMigrateToGlobalRulesIfNeeded();
    [self reloadFromPrefs];
}

- (void)toggleEditing {
    [_tableView setEditing:!_tableView.isEditing animated:YES];
}

- (void)reloadFromPrefs {
    NSDictionary *prefs = VLMReadPrefsDictionary();
    _profiles = VLMSanitizeProfiles(prefs[VLMMenuProfilesKey]);
    [_tableView reloadData];
}

- (void)writeProfiles {
    VLMReplacePrefsValues(@{VLMMenuProfilesKey: _profiles ?: @[]}, YES);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _profiles.count > 0 ? (NSInteger)_profiles.count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @"最近弹出过的 App";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"每条是某个 App 最近一次弹出时菜单条上的项。这里只能再多藏几项，或拖动后覆盖该 App 的顺序。全局隐藏不能在这里打开。";
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
    NSDictionary *profile = _profiles[indexPath.row];
    cell.textLabel.text = VLMProfileDisplayTitle(profile);
    cell.detailTextLabel.text = VLMProfileSubtitle(profile);
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
    _profiles = VLMRemoveProfile(_profiles, profileID);
    [self writeProfiles];
    [tableView reloadData];
}

@end
