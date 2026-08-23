#import "VLMOrderListController.h"
#import "../VLMMenuOrder.h"
#import <objc/runtime.h>

static NSString * const kVLMPrefsID = @"com.qins.verticalmenu";
static NSString * const kVLMReloadNotification = @"com.qins.verticalmenu/ReloadPrefs";
static const void *kVLMSwitchItemIDKey = &kVLMSwitchItemIDKey;

@implementation VLMOrderListController {
    UITableView *_tableView;
    NSMutableArray<NSString *> *_order;
    NSMutableSet<NSString *> *_hidden;
    NSDictionary<NSString *, NSString *> *_labels;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.title = @"菜单排序";
        _hidden = [NSMutableSet set];
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
    _hidden = [NSMutableSet setWithArray:VLMSanitizeHiddenIDs(prefs[VLMHiddenItemsKey])];

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

- (void)writePrefsAndEnableCustomSort:(BOOL)enableCustomSort {
    CFStringRef ident = (__bridge CFStringRef)kVLMPrefsID;
    CFPreferencesSetAppValue((__bridge CFStringRef)VLMMenuOrderKey, (__bridge CFArrayRef)_order, ident);
    CFPreferencesSetAppValue((__bridge CFStringRef)VLMHiddenItemsKey, (__bridge CFArrayRef)_hidden.allObjects, ident);
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
    [_hidden removeAllObjects];
    [self writePrefsAndEnableCustomSort:NO];
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
    [self writePrefsAndEnableCustomSort:YES];
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
    [self writePrefsAndEnableCustomSort:YES];
    [_tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_order.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"按住右边横条拖动调整顺序。关闭某项右边的开关即可隐藏，隐藏的项不会出现在弹出菜单里。列表包含常用项；弹出过但这里没有的项目，下次打开本页时会补上。改完后请注销或划掉正在用的 App 再打开。";
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
    cell.accessoryView = toggle;
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
