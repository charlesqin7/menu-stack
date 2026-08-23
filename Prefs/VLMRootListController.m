#import "VLMRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <spawn.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "../VLMMenuOrder.h"

extern char **environ;

#ifndef VLM_VERSION
#define VLM_VERSION "1.0.43"
#endif

@interface VLMMenuListController : UIViewController
@end
@interface VLMOrderListController : UIViewController
@end

@interface SBSRelaunchAction : NSObject
+ (instancetype)actionWithReason:(NSString *)reason options:(NSUInteger)options targetURL:(id)url;
@end

@interface FBSSystemService : NSObject
+ (instancetype)sharedService;
- (void)sendActions:(NSSet *)actions withResult:(id)result;
@end

@interface FBSystemService : NSObject
+ (instancetype)sharedInstance;
- (void)exitAndRelaunch:(BOOL)relaunch;
@end

@implementation VLMRootListController

+ (void)load {
    (void)[VLMMenuListController class];
    (void)[VLMOrderListController class];
    VLMStartIncomingObserverIfNeeded();
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        for (PSSpecifier *specifier in _specifiers) {
            if ([[specifier propertyForKey:@"action"] isEqualToString:@"respring"] ||
                [[specifier propertyForKey:@"id"] isEqualToString:@"respring"]) {
                [specifier setButtonAction:@selector(respring)];
            }
        }
    }
    return _specifiers;
}

- (NSString *)getVersion:(id)specifier {
    return @VLM_VERSION;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = nil;
    if ([self respondsToSelector:@selector(specifierAtIndexPath:)]) {
        specifier = [self specifierAtIndexPath:indexPath];
    }
    NSString *action = [specifier propertyForKey:@"action"];
    NSString *identifier = [specifier propertyForKey:@"id"];
    if ([action isEqualToString:@"respring"] || [identifier isEqualToString:@"respring"]) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [self respring];
        return;
    }
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

- (void)respring {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"注销 SpringBoard"
                                                                   message:@"注销后桌面会重新加载，设置页会关闭。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"注销" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self performRespring];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performRespring {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard", RTLD_LAZY);
    });

    Class relaunchClass = objc_getClass("SBSRelaunchAction");
    Class serviceClass = objc_getClass("FBSSystemService");
    if (relaunchClass && serviceClass &&
        [relaunchClass respondsToSelector:@selector(actionWithReason:options:targetURL:)] &&
        [serviceClass respondsToSelector:@selector(sharedService)]) {
        id action = [relaunchClass actionWithReason:@"RestartRenderServer" options:4 targetURL:nil];
        id service = [serviceClass sharedService];
        if (action && service && [service respondsToSelector:@selector(sendActions:withResult:)]) {
            [service sendActions:[NSSet setWithObject:action] withResult:nil];
            return;
        }
    }

    Class fbClass = objc_getClass("FBSystemService");
    if (fbClass && [fbClass respondsToSelector:@selector(sharedInstance)]) {
        id fb = [fbClass sharedInstance];
        if (fb && [fb respondsToSelector:@selector(exitAndRelaunch:)]) {
            [fb exitAndRelaunch:YES];
            return;
        }
    }

    NSArray<NSString *> *commands = @[
        @"/var/jb/usr/bin/sbreload",
        @"/usr/bin/sbreload",
        @"/var/jb/usr/bin/killall",
        @"/usr/bin/killall",
        @"/var/jb/bin/killall",
        @"/bin/killall",
    ];
    for (NSString *path in commands) {
        pid_t pid = 0;
        int status = -1;
        if ([path.lastPathComponent isEqualToString:@"killall"]) {
            const char *args[] = { "killall", "-9", "SpringBoard", NULL };
            status = posix_spawn(&pid, path.fileSystemRepresentation, NULL, NULL, (char *const *)args, environ);
        } else {
            const char *args[] = { "sbreload", NULL };
            status = posix_spawn(&pid, path.fileSystemRepresentation, NULL, NULL, (char *const *)args, environ);
        }
        if (status == 0) {
            return;
        }
    }
}

@end
