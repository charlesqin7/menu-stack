#import "VLMOrderListController.h"
#import "../VLMMenuOrder.h"

static NSString * const kVLMPrefsID = @"com.qins.verticalmenu";
static NSString * const kVLMReloadNotification = @"com.qins.verticalmenu/ReloadPrefs";

@implementation VLMOrderListController {
    UITableView *_tableView;
    NSMutableArray<NSString *> *_order;
    NSDictionary<NSString *, NSString *> *_labels;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.title = @"菜单排序";
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
    _tableView.allowsSelectionDuringEditing = NO;
    _tableView.allowsSelection = NO;
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

- (NSDictionary *)prefsDictionary {
    CFStringRef ident = (__bridge CFStringRef)kVLMPrefsID;
    CFPreferencesAppSynchronize(ident);
    CFArrayRef keys = CFPreferencesCopyKeyList(ident, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys) {
        CFDictionaryRef cfDict = CFPreferencesCopyMultiple(keys, ident, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFRelease(keys);
        NSDictionary *dict = CFBridgingRelease(cfDict);
        if (dict.count > 0) {
            return dict;
        }
    }
    NSArray<NSString *> *paths = @[
        @"/var/jb/var/mobile/Library/Preferences/com.qins.verticalmenu.plist",
        @"/var/jb/Library/Preferences/com.qins.verticalmenu.plist",
        @"/var/mobile/Library/Preferences/com.qins.verticalmenu.plist",
    ];
    for (NSString *path in paths) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (dict.count > 0) {
            return dict;
        }
    }
    return @{};
}

- (void)reloadFromPrefs {
    NSDictionary *prefs = [self prefsDictionary];
    _order = [VLMSanitizeOrderIDs(prefs[VLMMenuOrderKey]) mutableCopy];

    NSMutableDictionary<NSString *, NSString *> *labels = [NSMutableDictionary dictionary];
    for (NSString *itemID in VLMDefaultOrderIDs()) {
        labels[itemID] = VLMLabelForItemID(itemID);
    }
    id known = prefs[VLMKnownItemsKey];
    if ([known isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)known) {
            if (![item isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSString *itemID = item[@"id"];
            NSString *title = item[@"title"] ?: item[@"label"];
            if (itemID.length == 0) {
                continue;
            }
            if (![_order containsObject:itemID]) {
                [_order addObject:itemID];
            }
            if (title.length > 0) {
                labels[itemID] = title;
            }
        }
    }
    _labels = labels;
    [_tableView reloadData];
}

- (void)writeOrderAndEnableCustomSort:(BOOL)enableCustomSort {
    CFStringRef ident = (__bridge CFStringRef)kVLMPrefsID;
    CFPreferencesSetAppValue((__bridge CFStringRef)VLMMenuOrderKey, (__bridge CFArrayRef)_order, ident);
    if (enableCustomSort) {
        CFPreferencesSetAppValue((__bridge CFStringRef)VLMCustomOrderKey, kCFBooleanTrue, ident);
    }
    CFPreferencesAppSynchronize(ident);
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kVLMReloadNotification,
        NULL,
        NULL,
        true
    );
}

- (void)resetOrder {
    _order = [VLMDefaultOrderIDs() mutableCopy];
    [self writeOrderAndEnableCustomSort:NO];
    [_tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_order.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"按住右边横条拖动调整顺序。弹出菜单时按这个顺序排列；当前没出现的项目会被跳过，未列出的项目排在后面。改完后请注销或划掉正在用的 App 再打开。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"VLMOrderCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSString *itemID = _order[indexPath.row];
    cell.textLabel.text = _labels[itemID] ?: VLMLabelForItemID(itemID) ?: itemID;
    return cell;
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
    [self writeOrderAndEnableCustomSort:YES];
}

@end
