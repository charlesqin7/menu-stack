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
        self.title = @"按菜单设置";
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
    _profiles = VLMSanitizeProfiles(prefs[VLMMenuProfilesKey]);
    [_tableView reloadData];
}

- (void)writeProfiles {
    VLMWritePrefsValues(@{VLMMenuProfilesKey: _profiles ?: @[]}, YES);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _profiles.count > 0 ? (NSInteger)_profiles.count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @"已出现过的菜单";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"每个 App、每种长按菜单分开设置顺序和隐藏，互不影响。请先在对应 App 里弹出一次菜单，这里就会出现。隐藏不必打开自定义排序；只有拖动顺序才会按你的排列显示。改完后请注销或划掉正在用的 App。";
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
