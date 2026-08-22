#import "VLMRootListController.h"
#import <spawn.h>

extern char **environ;

@implementation VLMRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)respring {
    pid_t pid;
    NSArray<NSString *> *candidates = @[
        @"/var/jb/usr/bin/sbreload",
        @"/usr/bin/sbreload",
        @"/var/jb/usr/bin/killall",
        @"/usr/bin/killall",
    ];

    for (NSString *path in candidates) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
            if ([path.lastPathComponent isEqualToString:@"killall"]) {
                const char *args[] = { "killall", "-9", "SpringBoard", NULL };
                posix_spawn(&pid, path.fileSystemRepresentation, NULL, NULL, (char *const *)args, environ);
            } else {
                const char *args[] = { "sbreload", NULL };
                posix_spawn(&pid, path.fileSystemRepresentation, NULL, NULL, (char *const *)args, environ);
            }
            return;
        }
    }
}

@end
