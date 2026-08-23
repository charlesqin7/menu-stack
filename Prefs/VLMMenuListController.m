#import "VLMMenuListController.h"
#import "VLMOrderListController.h"
#import "../VLMMenuOrder.h"
#import <CoreFoundation/CoreFoundation.h>

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
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)VLMIncomingNotificationName,
        NULL,
        NULL,
        true
    );
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   ^{
        [weakSelf reloadFromPrefs];
    });
}

- (void)toggleEditing {
    [_tableView setEditing:!_tableView.isEditing animated:YES];
}

- (void)reloadFromPrefs {
    VLMIngestIncomingPrefs();
    NSDictionary *prefs = VLMReadPrefsDictionary();
    id raw = prefs[VLMMenuProfilesKey];
    _profiles = VLMSanitizeProfiles(raw);
    if (VLMProfilesNeedRewrite(raw)) {
        [self writeProfiles];
    }
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
    return @"已出现过的菜单";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"每个 App 只显示两条：文本选择（拷贝粘贴条）和上下文菜单（长按后的动作列表）。列表按该 App 实际弹出过的项记录，不会写死某个按钮。某次弹出没有的项会被跳过。";
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
