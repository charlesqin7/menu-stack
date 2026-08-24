#import "VLMMenuOrder.h"

#import <dlfcn.h>
#import <glob.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import <unistd.h>

extern int64_t sandbox_extension_consume(const char *extension_token);

#if __has_include(<Foundation/NSDistributedNotificationCenter.h>)
#import <Foundation/NSDistributedNotificationCenter.h>
#else
@interface NSDistributedNotificationCenter : NSNotificationCenter
+ (NSDistributedNotificationCenter *)defaultCenter;
- (void)postNotificationName:(NSNotificationName)name object:(NSString *)object userInfo:(NSDictionary *)userInfo deliverImmediately:(BOOL)deliverImmediately;
@end
#endif

#if __has_include(<rootless.h>)
#import <rootless.h>
#endif
#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

NSString * const VLMPrefsIdentifier = @"com.qins.verticalmenu";
NSString * const VLMReloadNotificationName = @"com.qins.verticalmenu/ReloadPrefs";
NSString * const VLMMenuOrderKey = @"MenuItemOrder";
NSString * const VLMCustomOrderKey = @"CustomOrder";
NSString * const VLMKnownItemsKey = @"KnownMenuItems";
NSString * const VLMHiddenItemsKey = @"HiddenMenuItems";
NSString * const VLMPrefsStampKey = @"PrefsStamp";
NSString * const VLMMenuProfilesKey = @"MenuProfiles";
NSString * const VLMGlobalRulesKey = @"GlobalRules";
NSString * const VLMMenuPoliciesKey = @"MenuPoliciesV2";
NSString * const VLMMenuRegistryKey = @"MenuRegistryV2";
NSString * const VLMPolicyV1BackupKey = @"MenuPolicyV1Backup";
NSString * const VLMMenuKindEdit = @"edit";
NSString * const VLMMenuKindContext = @"context";
NSString * const VLMIncomingNotificationName = @"com.qins.verticalmenu/IncomingPrefs";

static BOOL gApplyingRemotePrefs = NO;
static BOOL gReplaceProfiles = NO;
static BOOL gReplaceRegistry = NO;
static BOOL gUnsandboxed = NO;
static BOOL gDebugLoggingEnabled = NO;

#define VLMStorageLog(fmt, ...) do { \
    if (gDebugLoggingEnabled) NSLog(@"[VerticalMenu] " fmt, ##__VA_ARGS__); \
} while (0)

static void VLMTryUnsandbox(void);
static dispatch_queue_t VLMBackgroundIngestQueue(void);
static dispatch_queue_t VLMPrefsWriteQueue(void);

static BOOL VLMIsSpringBoardProcess(void) {
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [bundle isEqualToString:@"com.apple.springboard"];
}

static BOOL VLMCurrentProcessIsPreferences(void) {
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [bundle isEqualToString:@"com.apple.Preferences"] || [bundle hasPrefix:@"com.apple.Preferences"];
}

static NSArray<NSString *> *VLMIncomingDirectories(void) {
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    void (^add)(NSString *) = ^(NSString *path) {
        if (path.length && ![dirs containsObject:path]) {
            [dirs addObject:path];
        }
    };
    add(NSTemporaryDirectory());
    add([NSHomeDirectory() stringByAppendingPathComponent:@"tmp"]);
    add([NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]);
    add([NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/tmp"]);
    add([NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences"]);
    add(@"/var/tmp");
    add(@"/tmp");
    add(@"/var/jb/var/tmp");
    add(@"/var/jb/tmp");
    add(@"/var/jb/Library/Application Support/VerticalMenu/inbox");
    add(@"/var/mobile/Library/VerticalMenu/inbox");
#ifdef THEOS_PACKAGE_INSTALL_PREFIX
    add(@(THEOS_PACKAGE_INSTALL_PREFIX "/Library/Application Support/VerticalMenu/inbox"));
#endif
    return dirs;
}

static void VLMAddGlobMatches(NSMutableArray<NSString *> *paths, const char *pattern) {
    if (!pattern) {
        return;
    }
    glob_t matches;
    memset(&matches, 0, sizeof(matches));
    if (glob(pattern, 0, NULL, &matches) == 0) {
        for (size_t index = 0; index < matches.gl_pathc; index++) {
            NSString *path = [NSString stringWithUTF8String:matches.gl_pathv[index]];
            if (path.length > 0 && ![paths containsObject:path]) {
                [paths addObject:path];
            }
        }
    }
    globfree(&matches);
}

static NSArray<NSString *> *VLMIncomingPlistPaths(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *directory in VLMIncomingDirectories()) {
        NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:directory error:nil];
        for (NSString *file in files) {
            BOOL match = [file isEqualToString:@"com.qins.verticalmenu.incoming.plist"]
                || [file isEqualToString:@"VerticalMenu-incoming.plist"]
                || ([file hasPrefix:@"com.qins.verticalmenu.incoming"] && [file.pathExtension isEqualToString:@"plist"]);
            if (match) {
                [paths addObject:[directory stringByAppendingPathComponent:file]];
            }
        }
        NSString *stable = [directory stringByAppendingPathComponent:@"com.qins.verticalmenu.incoming.plist"];
        if ([fm fileExistsAtPath:stable] && ![paths containsObject:stable]) {
            [paths addObject:stable];
        }
    }
    static const char *sharedPatterns[] = {
        "/var/tmp/com.qins.verticalmenu.incoming*.plist",
        "/tmp/com.qins.verticalmenu.incoming*.plist",
        "/var/jb/var/tmp/com.qins.verticalmenu.incoming*.plist",
        "/var/jb/Library/Application Support/VerticalMenu/inbox/*.plist",
        "/var/mobile/Library/VerticalMenu/inbox/*.plist",
        NULL,
    };
    for (const char **pattern = sharedPatterns; *pattern; pattern++) {
        VLMAddGlobMatches(paths, *pattern);
    }
    return paths;
}

static NSArray<NSString *> *VLMIncomingPlistPathsForIngest(void) {
    return VLMIncomingPlistPaths();
}

static NSArray<NSString *> *VLMPrefsFilePaths(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    void (^add)(NSString *) = ^(NSString *path) {
        if (path.length == 0 || [paths containsObject:path]) {
            return;
        }
        [paths addObject:path];
    };
#if defined(ROOT_PATH_NS)
    add(ROOT_PATH_NS(@"/var/mobile/Library/Preferences/com.qins.verticalmenu.plist"));
#endif
#ifdef THEOS_PACKAGE_INSTALL_PREFIX
    add(@(THEOS_PACKAGE_INSTALL_PREFIX "/var/mobile/Library/Preferences/com.qins.verticalmenu.plist"));
#endif
#if __has_include(<roothide.h>)
    add(jbroot(@"/var/mobile/Library/Preferences/com.qins.verticalmenu.plist"));
#endif
    add(@"/var/jb/var/mobile/Library/Preferences/com.qins.verticalmenu.plist");
    add(@"/var/jb/Library/Preferences/com.qins.verticalmenu.plist");
    add(@"/var/mobile/Library/Preferences/com.qins.verticalmenu.plist");
    return paths;
}

void VLMSetDebugLoggingEnabled(BOOL enabled) {
    gDebugLoggingEnabled = enabled;
}

static NSDictionary *VLMCopyCFPrefs(CFStringRef host) {
    CFStringRef ident = (__bridge CFStringRef)VLMPrefsIdentifier;
    CFArrayRef keys = CFPreferencesCopyKeyList(ident, kCFPreferencesCurrentUser, host);
    if (!keys) {
        return @{};
    }
    CFDictionaryRef cfDict = CFPreferencesCopyMultiple(keys, ident, kCFPreferencesCurrentUser, host);
    CFRelease(keys);
    return CFBridgingRelease(cfDict) ?: @{};
}

static NSArray<NSDictionary *> *VLMPrefsSources(void) {
    NSMutableArray<NSDictionary *> *sources = [NSMutableArray array];
    NSDictionary *anyHost = VLMCopyCFPrefs(kCFPreferencesAnyHost);
    if (anyHost.count > 0) {
        [sources addObject:anyHost];
    }
    NSDictionary *currentHost = VLMCopyCFPrefs(kCFPreferencesCurrentHost);
    if (currentHost.count > 0) {
        [sources addObject:currentHost];
    }
    for (NSString *path in VLMPrefsFilePaths()) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (dict.count > 0) {
            [sources addObject:dict];
        }
    }
    return sources;
}

static NSTimeInterval VLMPrefsStamp(NSDictionary *dict) {
    id raw = dict[VLMPrefsStampKey];
    return [raw respondsToSelector:@selector(doubleValue)] ? [raw doubleValue] : 0;
}

static id VLMPickPrefValue(NSArray<NSDictionary *> *sources, NSString *key) {
    id chosen = nil;
    NSTimeInterval chosenStamp = -1;
    for (NSDictionary *dict in sources) {
        id value = dict[key];
        if (!value) {
            continue;
        }
        NSTimeInterval stamp = VLMPrefsStamp(dict);
        if (!chosen || stamp >= chosenStamp) {
            chosen = value;
            chosenStamp = stamp;
        }
    }
    return chosen;
}

static NSArray<NSDictionary *> *VLMMergedProfilesFromSources(NSArray<NSDictionary *> *sources) {
    NSMutableArray<NSDictionary *> *ordered = [sources mutableCopy] ?: [NSMutableArray array];
    [ordered sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSTimeInterval leftStamp = VLMPrefsStamp(left);
        NSTimeInterval rightStamp = VLMPrefsStamp(right);
        if (leftStamp < rightStamp) {
            return NSOrderedAscending;
        }
        if (leftStamp > rightStamp) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
    NSMutableDictionary<NSString *, NSDictionary *> *profilesByID = [NSMutableDictionary dictionary];
    for (NSDictionary *dict in ordered) {
        for (NSDictionary *profile in VLMSanitizeProfiles(dict[VLMMenuProfilesKey])) {
            NSString *profileID = profile[@"id"];
            if (profileID.length > 0) {
                profilesByID[profileID] = profile;
            }
        }
    }
    return VLMSanitizeProfiles(profilesByID.allValues);
}

static NSArray<NSDictionary *> *VLMMergedRegistryFromSources(NSArray<NSDictionary *> *sources) {
    NSMutableArray<NSDictionary *> *ordered = [sources mutableCopy] ?: [NSMutableArray array];
    [ordered sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSTimeInterval leftStamp = VLMPrefsStamp(left);
        NSTimeInterval rightStamp = VLMPrefsStamp(right);
        if (leftStamp < rightStamp) return NSOrderedAscending;
        if (leftStamp > rightStamp) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSArray<NSDictionary *> *records = @[];
    for (NSDictionary *dict in ordered) {
        for (NSDictionary *record in VLMSanitizeRegistryRecords(dict[VLMMenuRegistryKey])) {
            records = VLMUpsertRegistryRecord(records, record);
        }
    }
    return VLMSanitizeRegistryRecords(records);
}

// Normal preference stores contain complete Registry snapshots. Selecting the
// newest snapshot (instead of unioning every stale CF/file copy) makes an
// explicit deletion durable. Incoming runtime observations still use the
// update merger above before SpringBoard persists the next full snapshot.
static NSArray<NSDictionary *> *VLMLatestRegistryFromSources(NSArray<NSDictionary *> *sources) {
    NSArray<NSDictionary *> *chosen = @[];
    NSTimeInterval chosenStamp = -1;
    BOOL found = NO;
    for (NSDictionary *dict in sources) {
        if (!dict[VLMMenuRegistryKey]) {
            continue;
        }
        NSTimeInterval stamp = VLMPrefsStamp(dict);
        if (!found || stamp >= chosenStamp) {
            chosen = VLMSanitizeRegistryRecords(dict[VLMMenuRegistryKey]);
            chosenStamp = stamp;
            found = YES;
        }
    }
    return chosen;
}

static NSArray<NSDictionary *> *VLMProfilesByReplacingProfiles(NSArray *base, NSArray *updates) {
    NSMutableDictionary<NSString *, NSDictionary *> *profilesByID = [NSMutableDictionary dictionary];
    for (NSDictionary *profile in VLMSanitizeProfiles(base)) {
        profilesByID[profile[@"id"]] = profile;
    }
    for (NSDictionary *profile in VLMSanitizeProfiles(updates)) {
        profilesByID[profile[@"id"]] = profile;
    }
    return VLMSanitizeProfiles(profilesByID.allValues);
}

static NSArray<NSDictionary *> *VLMRegistryByReplacingRecords(NSArray *base, NSArray *updates) {
    NSMutableDictionary<NSString *, NSDictionary *> *recordsByID = [NSMutableDictionary dictionary];
    for (NSDictionary *record in VLMSanitizeRegistryRecords(base)) {
        recordsByID[record[@"id"]] = record;
    }
    for (NSDictionary *record in VLMSanitizeRegistryRecords(updates)) {
        recordsByID[record[@"id"]] = record;
    }
    return VLMSanitizeRegistryRecords(recordsByID.allValues);
}

NSDictionary<NSString *, id> *VLMReadPrefsDictionary(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)VLMPrefsIdentifier);
    NSArray<NSDictionary *> *sources = VLMPrefsSources();
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    for (NSDictionary *dict in sources) {
        [keys addObjectsFromArray:dict.allKeys];
    }
    [keys addObject:VLMHiddenItemsKey];
    [keys addObject:VLMMenuOrderKey];
    [keys addObject:VLMCustomOrderKey];
    [keys addObject:VLMKnownItemsKey];
    [keys addObject:VLMMenuProfilesKey];
    [keys addObject:VLMGlobalRulesKey];
    [keys addObject:VLMMenuPoliciesKey];
    [keys addObject:VLMMenuRegistryKey];

    NSMutableDictionary<NSString *, id> *merged = [NSMutableDictionary dictionary];
    for (NSString *key in keys) {
        if ([key isEqualToString:VLMMenuProfilesKey] || [key isEqualToString:VLMMenuRegistryKey]) {
            continue;
        }
        id value = VLMPickPrefValue(sources, key);
        if (value) {
            merged[key] = value;
        }
    }
    NSDictionary *policyRoot = [merged[VLMMenuPoliciesKey] isKindOfClass:[NSDictionary class]]
        ? merged[VLMMenuPoliciesKey] : nil;
    id rawSchema = policyRoot[@"schema"];
    NSInteger schema = [rawSchema respondsToSelector:@selector(integerValue)] ? [rawSchema integerValue] : 0;
    if (schema < 2) {
        NSArray *profiles = VLMMergedProfilesFromSources(sources);
        if (profiles.count > 0) {
            merged[VLMMenuProfilesKey] = profiles;
        }
    }
    NSArray *registry = VLMLatestRegistryFromSources(sources);
    merged[VLMMenuRegistryKey] = registry;
    return merged;
}

static void VLMWriteCFPrefValue(NSString *key, id value) {
    CFStringRef ident = (__bridge CFStringRef)VLMPrefsIdentifier;
    CFStringRef cfKey = (__bridge CFStringRef)key;
    CFPropertyListRef cfValue = (__bridge CFPropertyListRef)value;
    CFPreferencesSetAppValue(cfKey, cfValue, ident);
    CFPreferencesSetValue(cfKey, cfValue, ident, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSetValue(cfKey, cfValue, ident, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
}

static void VLMTryUnsandbox(void) {
    if (gUnsandboxed) {
        return;
    }
    static const char *libs[] = {
        "/var/jb/basebin/jbclient.dylib",
        "/var/jb/basebin/libjailbreak.dylib",
        "/var/jb/usr/lib/libjailbreak.dylib",
        "/var/jb/usr/lib/libSandy.dylib",
        "/usr/lib/libjailbreak.dylib",
        "/usr/lib/libSandy.dylib",
        NULL,
    };
    for (const char **path = libs; *path; path++) {
        void *handle = dlopen(*path, RTLD_NOW);
        if (!handle) {
            continue;
        }
        int (*unsandbox)(void) = dlsym(handle, "jbclient_unsandbox");
        if (!unsandbox) {
            unsandbox = dlsym(handle, "unsandbox");
        }
        if (!unsandbox) {
            unsandbox = dlsym(handle, "jbclient_process_unsandbox");
        }
        if (unsandbox) {
            unsandbox();
            gUnsandboxed = YES;
            return;
        }
        int (*sandy)(const char *) = dlsym(handle, "libSandy_applyProfile");
        if (sandy && sandy("SkipSandbox") == 0) {
            gUnsandboxed = YES;
            return;
        }
        int (*checkin)(char **, char **, char **, bool *) = dlsym(handle, "jbclient_process_checkin");
        if (checkin) {
            char *root = NULL;
            char *uuid = NULL;
            char *extensions = NULL;
            bool debugged = false;
            if (checkin(&root, &uuid, &extensions, &debugged) == 0 && extensions) {
                char *cursor = extensions;
                while (cursor && *cursor) {
                    char *next = strchr(cursor, '|');
                    if (next) {
                        *next = '\0';
                    }
                    if (*cursor) {
                        sandbox_extension_consume(cursor);
                    }
                    cursor = next ? next + 1 : NULL;
                }
                gUnsandboxed = YES;
                return;
            }
        }
    }
}

static BOOL VLMWritePrefsFiles(NSDictionary<NSString *, id> *changes) {
    BOOL wrote = NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in VLMPrefsFilePaths()) {
        NSString *directory = [path stringByDeletingLastPathComponent];
        BOOL isDirectory = NO;
        BOOL exists = [fm fileExistsAtPath:directory isDirectory:&isDirectory];
        if (!exists || !isDirectory) {
            if (![fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]) {
                continue;
            }
        }
        if (![fm isWritableFileAtPath:directory] && ![fm isWritableFileAtPath:path]) {
            continue;
        }
        NSMutableDictionary *fileDict = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy] ?: [NSMutableDictionary dictionary];
        [fileDict addEntriesFromDictionary:changes];
        if ([fileDict writeToFile:path atomically:YES]) {
            wrote = YES;
        }
    }
    return wrote;
}

static CFDataRef VLMPrefsPortCallback(CFMessagePortRef port, SInt32 msgid, CFDataRef data, void *info) {
    (void)port;
    (void)msgid;
    (void)info;
    if (!data) {
        return NULL;
    }
    NSDictionary *updates = [NSPropertyListSerialization propertyListWithData:(__bridge NSData *)data
                                                                      options:0
                                                                       format:NULL
                                                                        error:NULL];
    if (![updates isKindOfClass:[NSDictionary class]] || updates.count == 0) {
        return NULL;
    }
    dispatch_async(VLMBackgroundIngestQueue(), ^{
        gApplyingRemotePrefs = YES;
        VLMWritePrefsValues(updates, NO);
        gApplyingRemotePrefs = NO;
    });
    return NULL;
}

void VLMStartIncomingObserverIfNeeded(void) {
    if (!VLMIsSpringBoardProcess()) {
        return;
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSOperationQueue *queue = [[NSOperationQueue alloc] init];
        queue.name = @"com.qins.verticalmenu.incoming";
        queue.qualityOfService = NSQualityOfServiceUtility;
        queue.maxConcurrentOperationCount = 1;
        static id incomingObserver;
        incomingObserver = [[NSDistributedNotificationCenter defaultCenter] addObserverForName:@"com.qins.verticalmenu.incoming"
                                                                                       object:nil
                                                                                        queue:queue
                                                                                   usingBlock:^(NSNotification *note) {
            NSDictionary *updates = note.userInfo;
            dispatch_async(VLMBackgroundIngestQueue(), ^{
                if ([updates isKindOfClass:[NSDictionary class]] && updates.count > 0) {
                    gApplyingRemotePrefs = YES;
                    VLMWritePrefsValues(updates, YES);
                    gApplyingRemotePrefs = NO;
                }
                VLMIngestIncomingPrefs();
            });
        }];
        (void)incomingObserver;
        VLMIngestIncomingPrefs();
    });
}

void VLMStartPrefsWriterIfNeeded(void) {
    if (!VLMIsSpringBoardProcess()) {
        return;
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        VLMTryUnsandbox();
        Boolean shouldFree = false;
        CFMessagePortRef port = CFMessagePortCreateLocal(kCFAllocatorDefault,
                                                         CFSTR("com.qins.verticalmenu.prefsport"),
                                                         VLMPrefsPortCallback,
                                                         NULL,
                                                         &shouldFree);
        if (port) {
            CFMessagePortSetDispatchQueue(port, dispatch_get_main_queue());
        }
        VLMStartIncomingObserverIfNeeded();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       VLMBackgroundIngestQueue(),
                       ^{
            VLMIngestIncomingPrefs();
        });
    });
}

static BOOL VLMSendPrefsToSpringBoard(NSDictionary<NSString *, id> *changes) {
    if (gApplyingRemotePrefs || VLMIsSpringBoardProcess() || changes.count == 0) {
        return NO;
    }
    CFMessagePortRef remote = CFMessagePortCreateRemote(kCFAllocatorDefault, CFSTR("com.qins.verticalmenu.prefsport"));
    if (!remote) {
        return NO;
    }
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:changes
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:&error];
    SInt32 status = kCFMessagePortIsInvalid;
    if (data) {
        status = CFMessagePortSendRequest(remote, 1, (__bridge CFDataRef)data, 0.15, 0, NULL, NULL);
    }
    CFRelease(remote);
    return status == kCFMessagePortSuccess;
}

static BOOL VLMWriteIncomingData(NSData *data, NSString *directory) {
    if (!data || directory.length == 0) {
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:directory isDirectory:&isDirectory] || !isDirectory) {
        [fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{
            NSFilePosixPermissions: @0777
        } error:nil];
    }
    NSString *xml = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    BOOL wrote = NO;
    for (NSString *name in @[@"com.qins.verticalmenu.incoming.plist", @"VerticalMenu-incoming.plist"]) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        BOOL ok = NO;
        if (xml.length > 0) {
            ok = [xml writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }
        if (!ok) {
            ok = [data writeToFile:path atomically:YES];
        }
        if (ok) {
            chmod(path.fileSystemRepresentation, 0666);
            wrote = YES;
        }
    }
    return wrote;
}

BOOL VLMWriteIncomingSnapshot(NSDictionary<NSString *, id> *changes) {
    if (changes.count == 0) {
        return NO;
    }
    VLMTryUnsandbox();
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:changes
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:&error];
    if (!data) {
        return NO;
    }
    BOOL wrote = VLMWriteIncomingData(data, NSTemporaryDirectory());
    wrote = VLMWriteIncomingData(data, [NSHomeDirectory() stringByAppendingPathComponent:@"tmp"]) || wrote;
    wrote = VLMWriteIncomingData(data, [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]) || wrote;
    return wrote;
}

static BOOL VLMDropIncomingPrefs(NSDictionary<NSString *, id> *changes) {
    if (gApplyingRemotePrefs || changes.count == 0) {
        return NO;
    }
    VLMTryUnsandbox();
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:changes
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:&error];
    if (!data) {
        return NO;
    }

    NSString *tmp = NSTemporaryDirectory();
    BOOL sandboxWrote = VLMWriteIncomingData(data, tmp);
    sandboxWrote = VLMWriteIncomingData(data, [NSHomeDirectory() stringByAppendingPathComponent:@"tmp"]) || sandboxWrote;
    sandboxWrote = VLMWriteIncomingData(data, [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/tmp"]) || sandboxWrote;
    sandboxWrote = VLMWriteIncomingData(data, [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences"]) || sandboxWrote;
    sandboxWrote = VLMWriteIncomingData(data, [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]) || sandboxWrote;

    BOOL sharedWrote = NO;
    for (NSString *directory in VLMIncomingDirectories()) {
        if ([directory isEqualToString:tmp]
            || [directory isEqualToString:[NSHomeDirectory() stringByAppendingPathComponent:@"tmp"]]
            || [directory isEqualToString:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences"]]) {
            continue;
        }
        if (VLMWriteIncomingData(data, directory)) {
            sharedWrote = YES;
        }
    }

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)VLMIncomingNotificationName,
        NULL,
        NULL,
        true
    );
    NSString *bundle = VLMCurrentBundleID();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"com.qins.verticalmenu.incoming"
                                                                           object:bundle
                                                                         userInfo:nil
                                                               deliverImmediately:YES];
        } @catch (__unused NSException *exception) {
        }
    });
    VLMStorageLog(@"prefs drop sandbox=%d shared=%d tmp=%@ bundle=%@",
                  sandboxWrote, sharedWrote, tmp, bundle);
    return sandboxWrote || sharedWrote;
}

static NSArray *VLMDiskOnlyProfiles(void) {
    NSMutableArray<NSDictionary *> *sources = [NSMutableArray array];
    NSDictionary *anyHost = VLMCopyCFPrefs(kCFPreferencesAnyHost);
    if (anyHost.count > 0) {
        [sources addObject:anyHost];
    }
    NSDictionary *currentHost = VLMCopyCFPrefs(kCFPreferencesCurrentHost);
    if (currentHost.count > 0) {
        [sources addObject:currentHost];
    }
    for (NSString *path in VLMPrefsFilePaths()) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (dict.count > 0) {
            [sources addObject:dict];
        }
    }
    return VLMMergedProfilesFromSources(sources);
}

static NSArray *VLMDiskOnlyRegistry(void) {
    NSMutableArray<NSDictionary *> *sources = [NSMutableArray array];
    NSDictionary *anyHost = VLMCopyCFPrefs(kCFPreferencesAnyHost);
    if (anyHost.count > 0) [sources addObject:anyHost];
    NSDictionary *currentHost = VLMCopyCFPrefs(kCFPreferencesCurrentHost);
    if (currentHost.count > 0) [sources addObject:currentHost];
    for (NSString *path in VLMPrefsFilePaths()) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (dict.count > 0) [sources addObject:dict];
    }
    return VLMLatestRegistryFromSources(sources);
}

static dispatch_queue_t VLMBackgroundIngestQueue(void) {
    // Registry ingestion, policy migration and settings writes all mutate one
    // preference snapshot. A shared serial queue prevents their replace/merge
    // modes from overlapping and resurrecting stale records.
    return VLMPrefsWriteQueue();
}

static dispatch_queue_t VLMPrefsWriteQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.qins.verticalmenu.prefs-writer", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void VLMIngestIncomingPrefsNow(void) {
    if (gApplyingRemotePrefs) {
        return;
    }
    if (!VLMIsSpringBoardProcess()) {
        return;
    }
    VLMTryUnsandbox();
    NSArray<NSString *> *paths = VLMIncomingPlistPathsForIngest();
    if (paths.count == 0) {
        return;
    }
    VLMStorageLog(@"ingest paths=%lu sb=%d first=%@",
                  (unsigned long)paths.count,
                  VLMIsSpringBoardProcess(),
                  paths.firstObject);
    gApplyingRemotePrefs = YES;
    NSMutableArray<NSDictionary *> *incoming = [NSMutableArray array];
    for (NSString *path in paths) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (dict.count > 0) {
            [incoming addObject:dict];
            VLMStorageLog(@"ingest read %@ profiles=%lu",
                          path,
                          (unsigned long)VLMSanitizeProfiles(dict[VLMMenuProfilesKey]).count);
        }
    }
    NSDictionary *merged = VLMReadPrefsDictionary();
    NSArray *profiles = VLMMergedProfilesFromSources((incoming.count > 0)
        ? [@[merged] arrayByAddingObjectsFromArray:incoming]
        : @[merged]);
    NSArray *registry = VLMMergedRegistryFromSources((incoming.count > 0)
        ? [@[merged] arrayByAddingObjectsFromArray:incoming]
        : @[merged]);
    BOOL wrote = NO;
    gReplaceProfiles = YES;
    if (profiles.count > 0) {
        VLMWritePrefsValues(@{VLMMenuProfilesKey: profiles}, YES);
        wrote = YES;
    }
    gReplaceRegistry = YES;
    if (registry.count > 0) {
        VLMWritePrefsValues(@{VLMMenuRegistryKey: registry}, YES);
        wrote = YES;
    }
    gReplaceRegistry = NO;
    gReplaceProfiles = NO;
    if (wrote) {
        for (NSString *path in paths) {
            if ([path containsString:@"/Containers/Data/"]) {
                continue;
            }
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        }
    }
    gApplyingRemotePrefs = NO;
}

void VLMIngestIncomingPrefs(void) {
    if (!VLMIsSpringBoardProcess()) {
        return;
    }
    dispatch_async(VLMBackgroundIngestQueue(), ^{
        static BOOL coalesced = NO;
        if (coalesced) {
            return;
        }
        coalesced = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       VLMBackgroundIngestQueue(),
                       ^{
            coalesced = NO;
            VLMIngestIncomingPrefsNow();
        });
    });
}

void VLMReplacePrefsValues(NSDictionary<NSString *, id> *updates, BOOL bumpStamp) {
    gReplaceProfiles = YES;
    gReplaceRegistry = YES;
    VLMWritePrefsValues(updates, bumpStamp);
    gReplaceRegistry = NO;
    gReplaceProfiles = NO;
}

void VLMWritePrefsValuesAsync(NSDictionary<NSString *, id> *updates, BOOL bumpStamp) {
    NSDictionary *snapshot = [updates copy] ?: @{};
    dispatch_async(VLMPrefsWriteQueue(), ^{
        VLMWritePrefsValues(snapshot, bumpStamp);
    });
}

void VLMReplacePrefsValuesAsync(NSDictionary<NSString *, id> *updates, BOOL bumpStamp) {
    NSDictionary *snapshot = [updates copy] ?: @{};
    dispatch_async(VLMPrefsWriteQueue(), ^{
        VLMReplacePrefsValues(snapshot, bumpStamp);
    });
}

void VLMWritePrefsValues(NSDictionary<NSString *, id> *updates, BOOL bumpStamp) {
    if (updates.count == 0 && !bumpStamp) {
        return;
    }
    NSMutableDictionary<NSString *, id> *changes = [updates mutableCopy] ?: [NSMutableDictionary dictionary];
    if (bumpStamp) {
        changes[VLMPrefsStampKey] = @((NSTimeInterval)[[NSDate date] timeIntervalSince1970]);
    }

    BOOL runtimeClient = !gApplyingRemotePrefs && !VLMIsSpringBoardProcess() && !VLMCurrentProcessIsPreferences();
    if (runtimeClient && VLMSendPrefsToSpringBoard(changes)) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)VLMReloadNotificationName,
            NULL,
            NULL,
            true
        );
        VLMStorageLog(@"prefs handed to SpringBoard profiles=%lu in %@",
                      (unsigned long)[changes[VLMMenuProfilesKey] count],
                      [[NSBundle mainBundle] bundleIdentifier] ?: @"?");
        return;
    }

    if (changes[VLMMenuProfilesKey] && !gReplaceProfiles) {
        changes[VLMMenuProfilesKey] = VLMProfilesByReplacingProfiles(VLMDiskOnlyProfiles(), changes[VLMMenuProfilesKey]);
    }
    if (changes[VLMMenuRegistryKey] && !gReplaceRegistry) {
        changes[VLMMenuRegistryKey] = VLMRegistryByReplacingRecords(VLMDiskOnlyRegistry(), changes[VLMMenuRegistryKey]);
    }

    VLMTryUnsandbox();
    for (NSString *key in changes) {
        VLMWriteCFPrefValue(key, changes[key]);
    }
    CFPreferencesAppSynchronize((__bridge CFStringRef)VLMPrefsIdentifier);

    BOOL wroteFile = VLMWritePrefsFiles(changes);
    if (!wroteFile) {
        gUnsandboxed = NO;
        VLMTryUnsandbox();
        wroteFile = VLMWritePrefsFiles(changes);
    }
    BOOL dropped = NO;
    BOOL ported = NO;
    BOOL needsHandoff = !wroteFile || (!VLMIsSpringBoardProcess() && !VLMCurrentProcessIsPreferences());
    if (needsHandoff && !gApplyingRemotePrefs) {
        dropped = VLMDropIncomingPrefs(changes);
        NSDictionary *portPayload = [changes copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            VLMSendPrefsToSpringBoard(portPayload);
        });
        ported = YES;
    }
    VLMStorageLog(@"prefs persist file=%d port=%d drop=%d profiles=%lu in %@",
                  wroteFile, ported, dropped,
                  (unsigned long)VLMSanitizeProfiles(changes[VLMMenuProfilesKey]).count,
                  [[NSBundle mainBundle] bundleIdentifier] ?: @"?");

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)VLMReloadNotificationName,
        NULL,
        NULL,
        true
    );
}

static NSArray<NSDictionary *> *VLMCatalog(void) {
    static NSArray<NSDictionary *> *items;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        items = @[
            @{
                @"id": @"cut",
                @"label": @"剪切",
                @"titles": @[@"剪切", @"剪下", @"Cut"],
                @"sels": @[@"cut:"],
            },
            @{
                @"id": @"copy",
                @"label": @"拷贝",
                @"titles": @[@"拷贝", @"拷貝", @"复制", @"複製", @"Copy"],
                @"sels": @[@"copy:"],
            },
            @{
                @"id": @"paste",
                @"label": @"粘贴",
                @"titles": @[@"粘贴", @"貼上", @"Paste"],
                @"sels": @[@"paste:"],
            },
            @{
                @"id": @"select",
                @"label": @"选择",
                @"titles": @[@"选择", @"選擇", @"Select"],
                @"sels": @[@"select:"],
            },
            @{
                @"id": @"selectAll",
                @"label": @"全选",
                @"titles": @[@"全选", @"全選", @"Select All"],
                @"sels": @[@"selectAll:"],
            },
            @{
                @"id": @"lookup",
                @"label": @"查询",
                @"titles": @[@"查询", @"查詢", @"Look Up", @"Look up"],
                @"sels": @[@"_lookup:", @"lookup:", @"_lookupDefinition:", @"lookupDefinition:"],
                @"idents": @[@"lookup", @"com.apple.menu.lookup"],
            },
            @{
                @"id": @"findSelection",
                @"label": @"查找所选内容",
                @"titles": @[@"查找所选内容", @"查找所選內容", @"Find Selection", @"Find Selected", @"Find"],
                @"sels": @[@"_findSelected:", @"findSelected:", @"find:", @"_find:", @"findInPage:"],
                @"idents": @[@"findSelection", @"find", @"com.apple.menu.find"],
            },
            @{
                @"id": @"searchWeb",
                @"label": @"搜索网页",
                @"titles": @[@"搜索网页", @"搜尋網頁", @"Search Web", @"Search the Web"],
                @"sels": @[@"_searchWeb:", @"searchWeb:", @"_searchTheWeb:", @"searchTheWeb:"],
                @"idents": @[@"searchWeb", @"com.apple.menu.searchTheWeb"],
            },
            @{
                @"id": @"translate",
                @"label": @"翻译",
                @"titles": @[@"翻译", @"翻譯", @"Translate"],
                @"sels": @[@"_translate:", @"translate:", @"_translateSelection:", @"translateSelection:"],
                @"idents": @[@"translate", @"com.apple.menu.translate"],
            },
            @{
                @"id": @"share",
                @"label": @"共享",
                @"titles": @[@"分享", @"共享", @"Share"],
                @"sels": @[@"_share:", @"share:", @"_shareSelection:", @"shareSelection:"],
                @"idents": @[@"share", @"com.apple.menu.share"],
            },
            @{
                @"id": @"quickNote",
                @"label": @"新建快速备忘录",
                @"titles": @[@"新建快速备忘录", @"新增快速備忘錄", @"New Quick Note", @"Add to Quick Note"],
                @"sels": @[@"_addToQuickNote:", @"addToQuickNote:", @"_quickNote:", @"newQuickNote:"],
                @"idents": @[@"quickNote", @"com.apple.menu.quickNote"],
            },
            @{
                @"id": @"replace",
                @"label": @"替换",
                @"titles": @[@"替换", @"取代", @"Replace"],
                @"sels": @[@"_promptForReplace:", @"replace:"],
            },
            @{
                @"id": @"delete",
                @"label": @"删除",
                @"titles": @[@"删除", @"刪除", @"Delete"],
                @"sels": @[@"delete:"],
            },
            @{
                @"id": @"scan",
                @"label": @"扫描",
                @"titles": @[@"扫描", @"掃描", @"Scan", @"Scan Documents"],
                @"sels": @[@"scan:"],
            },
            @{
                @"id": @"pin",
                @"label": @"置顶",
                @"titles": @[@"置顶", @"置頂", @"Pin"],
                @"sels": @[@"pin:"],
            },
            @{
                @"id": @"lock",
                @"label": @"锁定",
                @"titles": @[@"锁定", @"鎖定", @"Lock"],
                @"sels": @[@"lock:"],
            },
            @{
                @"id": @"bold",
                @"label": @"粗体",
                @"titles": @[@"粗体", @"粗體", @"Bold"],
                @"sels": @[@"toggleBoldface:"],
            },
            @{
                @"id": @"italic",
                @"label": @"斜体",
                @"titles": @[@"斜体", @"斜體", @"Italic"],
                @"sels": @[@"toggleItalics:"],
            },
            @{
                @"id": @"underline",
                @"label": @"下划线",
                @"titles": @[@"下划线", @"底線", @"Underline"],
                @"sels": @[@"toggleUnderline:"],
            },
            @{
                @"id": @"define",
                @"label": @"定义",
                @"titles": @[@"定义", @"定義", @"Define"],
                @"sels": @[@"_define:", @"define:"],
            },
            @{
                @"id": @"speak",
                @"label": @"朗读",
                @"titles": @[@"朗读", @"朗讀", @"Speak"],
                @"sels": @[@"_speak:", @"speak:"],
            },
            @{
                @"id": @"copyLink",
                @"label": @"拷贝链接",
                @"titles": @[@"拷贝链接", @"拷貝連結", @"复制链接", @"Copy Link"],
                @"sels": @[@"copyLink:", @"_copyLink:"],
            },
            @{
                @"id": @"openLink",
                @"label": @"打开",
                @"titles": @[@"打开", @"打開", @"打开链接", @"Open", @"Open Link"],
                @"sels": @[@"openURL:", @"openLink:"],
            },
            @{
                @"id": @"readingList",
                @"label": @"添加到阅读列表",
                @"titles": @[@"添加到阅读列表", @"加入閱讀列表", @"Add to Reading List"],
                @"sels": @[@"addToReadingList:"],
            },
            @{
                @"id": @"autofill",
                @"label": @"自动填充",
                @"titles": @[@"自动填充", @"自動填寫", @"AutoFill", @"Autofill"],
                @"sels": @[@"_autofill:", @"autofill:"],
            },
        ];
    });
    return items;
}

NSArray<NSDictionary *> *VLMCatalogItems(void) {
    return VLMCatalog();
}

static BOOL VLMIsCatalogID(NSString *itemID) {
    return VLMRulesCatalogContainsID(VLMCatalog(), itemID);
}

NSArray<NSString *> *VLMCoreOrderIDs(void) {
    static NSArray<NSString *> *ids;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ids = @[
            @"cut",
            @"copy",
            @"paste",
            @"select",
            @"selectAll",
            @"findSelection",
            @"lookup",
            @"translate",
            @"searchWeb",
            @"share",
            @"quickNote",
            @"replace",
            @"speak",
        ];
    });
    return ids;
}

NSArray<NSString *> *VLMDefaultOrderIDs(void) {
    return VLMCoreOrderIDs();
}

NSString *VLMLabelForItemID(NSString *itemID) {
    return VLMRulesCatalogLabelForID(VLMCatalog(), itemID);
}

NSString *VLMCatalogIDForTitle(NSString *title) {
    return VLMRulesCatalogIDForTitle(VLMCatalog(), title);
}

NSString *VLMCatalogIDForSelectorName(NSString *selectorName) {
    return VLMRulesCatalogIDForSelector(VLMCatalog(), selectorName);
}

NSString *VLMCatalogIDForIdentifier(NSString *identifier) {
    return VLMRulesCatalogIDForIdentifier(VLMCatalog(), identifier);
}

static NSString *VLMExtractItemID(id item) {
    if ([item isKindOfClass:[NSString class]]) {
        return item;
    }
    if ([item isKindOfClass:[NSDictionary class]]) {
        id itemID = item[@"id"];
        return [itemID isKindOfClass:[NSString class]] ? itemID : nil;
    }
    return nil;
}

static BOOL VLMKnownItemsLookPolluted(NSArray *stored) {
    if (stored.count == 0) {
        return NO;
    }
    NSInteger catalogHits = 0;
    for (id item in stored) {
        if (VLMIsCatalogID(VLMExtractItemID(item))) {
            catalogHits += 1;
        }
    }
    return catalogHits >= (NSInteger)VLMCatalog().count - 1;
}

NSArray<NSString *> *VLMDisplayOrderIDs(id orderValue, id knownValue) {
    NSArray<NSString *> *core = VLMCoreOrderIDs();
    NSMutableSet<NSString *> *allowed = [NSMutableSet setWithArray:core];
    NSMutableArray<NSString *> *knownIDs = [NSMutableArray array];
    for (NSDictionary *item in VLMSanitizeKnownItems(knownValue)) {
        NSString *itemID = item[@"id"];
        if (itemID.length == 0) {
            continue;
        }
        [allowed addObject:itemID];
        [knownIDs addObject:itemID];
    }

    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    if ([orderValue isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)orderValue) {
            NSString *itemID = VLMExtractItemID(item);
            if (itemID.length == 0 || [seen containsObject:itemID] || ![allowed containsObject:itemID]) {
                continue;
            }
            [seen addObject:itemID];
            [ids addObject:itemID];
        }
    }
    for (NSString *itemID in core) {
        if (![seen containsObject:itemID]) {
            [ids addObject:itemID];
        }
    }
    for (NSString *itemID in knownIDs) {
        if (![seen containsObject:itemID]) {
            [ids addObject:itemID];
        }
    }
    return ids;
}

NSArray<NSString *> *VLMSanitizeOrderIDs(id value) {
    return VLMDisplayOrderIDs(value, nil);
}

NSArray<NSString *> *VLMSanitizeHiddenIDs(id value) {
    if (![value isKindOfClass:[NSArray class]]) {
        return @[];
    }
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id item in (NSArray *)value) {
        NSString *itemID = VLMExtractItemID(item);
        if (itemID.length == 0 || [seen containsObject:itemID]) {
            continue;
        }
        [seen addObject:itemID];
        [ids addObject:itemID];
    }
    return ids;
}

BOOL VLMIsCapturedJunkItem(NSString *title, NSString *itemID) {
    return VLMRulesIsCapturedJunkItem(title, itemID);
}

static void VLMAppendKnownItem(NSMutableArray<NSDictionary *> *result, NSMutableSet<NSString *> *seen, id item) {
    NSString *itemID = nil;
    NSString *title = nil;
    if ([item isKindOfClass:[NSDictionary class]]) {
        id rawID = item[@"id"];
        id rawTitle = item[@"title"] ?: item[@"label"];
        itemID = [rawID isKindOfClass:[NSString class]] ? rawID : nil;
        title = [rawTitle isKindOfClass:[NSString class]] ? rawTitle : nil;
    } else if ([item isKindOfClass:[NSString class]]) {
        itemID = VLMCatalogIDForTitle(item) ?: [@"custom:" stringByAppendingString:item];
        title = item;
    }
    if (itemID.length == 0 || [seen containsObject:itemID]) {
        return;
    }
    if (VLMIsCapturedJunkItem(title, itemID)) {
        return;
    }
    [seen addObject:itemID];
    [result addObject:@{
        @"id": itemID,
        @"title": title.length ? title : (VLMLabelForItemID(itemID) ?: itemID),
    }];
}

NSArray<NSDictionary *> *VLMSanitizeKnownItems(id value) {
    if (![value isKindOfClass:[NSArray class]] || VLMKnownItemsLookPolluted(value)) {
        return @[];
    }
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSSet<NSString *> *core = [NSSet setWithArray:VLMCoreOrderIDs()];
    for (id item in (NSArray *)value) {
        NSString *itemID = VLMExtractItemID(item);
        if ([core containsObject:itemID]) {
            continue;
        }
        VLMAppendKnownItem(result, seen, item);
    }
    return result;
}

NSArray<NSDictionary *> *VLMMergedKnownItems(NSArray *stored, NSArray *extra) {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id item in VLMSanitizeKnownItems(stored)) {
        VLMAppendKnownItem(result, seen, item);
    }
    for (id item in extra) {
        VLMAppendKnownItem(result, seen, item);
    }
    return result;
}

NSString *VLMCurrentBundleID(void) {
    return [[NSBundle mainBundle] bundleIdentifier] ?: @"";
}

NSString *VLMGuessAppName(NSString *bundleID) {
    NSString *current = [[NSBundle mainBundle] bundleIdentifier];
    if (bundleID.length && [bundleID isEqualToString:current]) {
        NSString *name = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];
        if (name.length == 0) {
            name = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
        }
        if (name.length > 0) {
            return name;
        }
    }
    static NSDictionary<NSString *, NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @{
            @"com.apple.mobilenotes": @"备忘录",
            @"com.apple.mobilesafari": @"Safari",
            @"com.apple.MobileSMS": @"信息",
            @"com.apple.mail": @"邮件",
            @"com.apple.mobilemail": @"邮件",
            @"com.apple.DocumentsApp": @"文件",
            @"com.apple.mobileslideshow": @"照片",
            @"com.apple.mobilecal": @"日历",
            @"com.apple.reminders": @"提醒事项",
            @"com.apple.Preferences": @"设置",
            @"com.atebits.Tweetie2": @"X",
            @"com.twitter.twitter": @"X",
        };
    });
    if (bundleID.length && names[bundleID]) {
        return names[bundleID];
    }
    return bundleID.length ? bundleID : @"未知 App";
}

NSString *VLMKindDisplayName(NSString *kind) {
    if ([kind isEqualToString:VLMMenuKindContext]) {
        return @"上下文菜单";
    }
    return @"文本选择";
}

NSString *VLMProfileIDForMenu(NSString *kind, NSString *bundleID, NSArray<NSString *> *itemIDs) {
    (void)itemIDs;
    return VLMRulesProfileID(kind.length ? kind : VLMMenuKindEdit, bundleID);
}

static NSDictionary *VLMNormalizedProfile(NSDictionary *profile) {
    NSArray<NSDictionary *> *items = VLMProfileItems(profile);
    if (items.count == 0 || ![profile isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSString *kind = profile[@"kind"] ?: VLMMenuKindEdit;
    NSString *bundle = profile[@"bundle"] ?: @"";
    NSString *canonicalID = VLMProfileIDForMenu(kind, bundle, nil);
    return @{
        @"id": canonicalID,
        @"kind": kind,
        @"bundle": bundle,
        @"appName": profile[@"appName"] ?: VLMGuessAppName(bundle),
        @"items": items,
        @"order": VLMProfileDisplayOrder(profile),
        @"hidden": VLMProfileHiddenIDs(profile),
        @"customOrder": @(VLMProfileCustomOrder(profile)),
        @"seenAt": profile[@"seenAt"] ?: @0,
    };
}

static NSDictionary *VLMCombineProfiles(NSDictionary *left, NSDictionary *right) {
    if (!left) {
        return right;
    }
    if (!right) {
        return left;
    }
    NSTimeInterval leftSeen = [left[@"seenAt"] doubleValue];
    NSTimeInterval rightSeen = [right[@"seenAt"] doubleValue];
    NSDictionary *newer = (rightSeen >= leftSeen) ? right : left;
    NSDictionary *older = (newer == right) ? left : right;
    NSArray<NSDictionary *> *items = VLMProfileItems(newer);
    if (items.count < 2) {
        items = VLMProfileItems(older);
    }
    BOOL custom = VLMProfileCustomOrder(left) || VLMProfileCustomOrder(right);
    NSArray<NSString *> *order = custom
        ? (VLMProfileCustomOrder(left) ? VLMProfileDisplayOrder(left) : VLMProfileDisplayOrder(right))
        : VLMProfileDisplayOrder(newer);
    NSMutableArray<NSString *> *hidden = [NSMutableArray array];
    NSMutableSet<NSString *> *seenHidden = [NSMutableSet set];
    for (NSString *itemID in [VLMProfileHiddenIDs(left) arrayByAddingObjectsFromArray:VLMProfileHiddenIDs(right)]) {
        if (itemID.length == 0 || [seenHidden containsObject:itemID]) {
            continue;
        }
        [seenHidden addObject:itemID];
        [hidden addObject:itemID];
    }
    NSMutableDictionary *merged = [newer mutableCopy];
    merged[@"items"] = items;
    merged[@"order"] = order;
    merged[@"hidden"] = hidden;
    merged[@"customOrder"] = @(custom);
    merged[@"seenAt"] = @(MAX(leftSeen, rightSeen));
    if ([older[@"appName"] length] && ![merged[@"appName"] length]) {
        merged[@"appName"] = older[@"appName"];
    }
    return VLMNormalizedProfile(merged);
}

NSArray<NSDictionary *> *VLMSanitizeProfiles(id value) {
    if (![value isKindOfClass:[NSArray class]]) {
        return @[];
    }
    NSMutableArray<NSDictionary *> *profiles = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *indexByID = [NSMutableDictionary dictionary];
    for (id item in (NSArray *)value) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *normalized = VLMNormalizedProfile(item);
        if (!normalized) {
            continue;
        }
        NSString *profileID = normalized[@"id"];
        NSNumber *existingIndex = indexByID[profileID];
        if (existingIndex) {
            profiles[existingIndex.unsignedIntegerValue] = VLMCombineProfiles(profiles[existingIndex.unsignedIntegerValue], normalized);
            continue;
        }
        indexByID[profileID] = @(profiles.count);
        [profiles addObject:normalized];
    }
    [profiles sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSTimeInterval leftSeen = [left[@"seenAt"] doubleValue];
        NSTimeInterval rightSeen = [right[@"seenAt"] doubleValue];
        if (leftSeen < rightSeen) {
            return NSOrderedDescending;
        }
        if (leftSeen > rightSeen) {
            return NSOrderedAscending;
        }
        return [VLMProfileDisplayTitle(left) compare:VLMProfileDisplayTitle(right)];
    }];
    return profiles;
}

BOOL VLMProfilesNeedRewrite(id raw) {
    if (![raw isKindOfClass:[NSArray class]]) {
        return NO;
    }
    NSArray *sanitized = VLMSanitizeProfiles(raw);
    if ([(NSArray *)raw count] != sanitized.count) {
        return YES;
    }
    for (id item in (NSArray *)raw) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *profile = item;
        NSString *kind = profile[@"kind"] ?: VLMMenuKindEdit;
        NSString *bundle = profile[@"bundle"] ?: @"";
        NSString *expected = VLMProfileIDForMenu(kind, bundle, nil);
        if (![profile[@"id"] isEqualToString:expected]) {
            return YES;
        }
        NSArray *rawItems = [profile[@"items"] isKindOfClass:[NSArray class]] ? profile[@"items"] : @[];
        if (rawItems.count != VLMProfileItems(profile).count) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSDictionary *> *VLMSanitizeProfileItems(id value) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    if (![value isKindOfClass:[NSArray class]]) {
        return items;
    }
    for (id item in (NSArray *)value) {
        VLMAppendKnownItem(items, seen, item);
    }
    return items;
}

NSArray<NSDictionary *> *VLMProfileItems(NSDictionary *profile) {
    if (![profile isKindOfClass:[NSDictionary class]]) {
        return @[];
    }
    return VLMSanitizeProfileItems(profile[@"items"]);
}

NSArray<NSString *> *VLMProfileDisplayOrder(NSDictionary *profile) {
    NSArray<NSDictionary *> *items = VLMProfileItems(profile);
    NSMutableArray<NSString *> *discovery = [NSMutableArray array];
    NSMutableSet<NSString *> *allowed = [NSMutableSet set];
    for (NSDictionary *item in items) {
        NSString *itemID = item[@"id"];
        if (itemID.length == 0 || [allowed containsObject:itemID]) {
            continue;
        }
        [allowed addObject:itemID];
        [discovery addObject:itemID];
    }
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    id saved = profile[@"order"];
    if ([saved isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)saved) {
            NSString *itemID = VLMExtractItemID(item);
            if (itemID.length == 0 || [seen containsObject:itemID] || ![allowed containsObject:itemID]) {
                continue;
            }
            [seen addObject:itemID];
            [order addObject:itemID];
        }
    }
    for (NSString *itemID in discovery) {
        if (![seen containsObject:itemID]) {
            [order addObject:itemID];
        }
    }
    return order;
}

NSArray<NSString *> *VLMProfileHiddenIDs(NSDictionary *profile) {
    if (![profile isKindOfClass:[NSDictionary class]]) {
        return @[];
    }
    return VLMSanitizeHiddenIDs(profile[@"hidden"]);
}

BOOL VLMProfileCustomOrder(NSDictionary *profile) {
    if (![profile isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    return [profile[@"customOrder"] boolValue];
}

NSString *VLMProfileDisplayTitle(NSDictionary *profile) {
    if (![profile isKindOfClass:[NSDictionary class]]) {
        return @"菜单";
    }
    NSString *appName = profile[@"appName"];
    if (appName.length == 0) {
        appName = VLMGuessAppName(profile[@"bundle"]);
    }
    return [NSString stringWithFormat:@"%@ · %@", appName, VLMKindDisplayName(profile[@"kind"])];
}

NSString *VLMProfileSubtitle(NSDictionary *profile) {
    NSArray<NSDictionary *> *items = VLMProfileItems(profile);
    NSArray<NSString *> *hidden = VLMProfileHiddenIDs(profile);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *item in items) {
        if (names.count >= 4) {
            break;
        }
        NSString *title = item[@"title"] ?: VLMLabelForItemID(item[@"id"]);
        if (title.length > 0) {
            [names addObject:title];
        }
    }
    NSString *preview = names.count ? [names componentsJoinedByString:@"、"] : @"暂无项目";
    NSString *countText = [NSString stringWithFormat:@"%lu 项", (unsigned long)items.count];
    if (hidden.count > 0) {
        return [NSString stringWithFormat:@"%@ · 已隐藏 %lu 项 · %@", countText, (unsigned long)hidden.count, preview];
    }
    return [NSString stringWithFormat:@"%@ · %@", countText, preview];
}

NSDictionary *VLMProfileWithID(NSArray *profiles, NSString *profileID) {
    if (profileID.length == 0) {
        return nil;
    }
    for (NSDictionary *profile in profiles) {
        if ([profile[@"id"] isEqualToString:profileID]) {
            return profile;
        }
    }
    return nil;
}

NSDictionary *VLMBuildProfile(NSString *kind,
                             NSString *bundleID,
                             NSString *appName,
                             NSArray<NSDictionary *> *items,
                             NSDictionary *existing,
                             NSArray *inheritHidden) {
    NSArray<NSDictionary *> *cleanItems = VLMSanitizeProfileItems(items);
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (NSDictionary *item in cleanItems) {
        if (item[@"id"]) {
            [ids addObject:item[@"id"]];
        }
    }
    NSMutableDictionary *incoming = [NSMutableDictionary dictionary];
    incoming[@"id"] = VLMProfileIDForMenu(kind, bundleID, ids);
    incoming[@"kind"] = kind.length ? kind : VLMMenuKindEdit;
    incoming[@"bundle"] = bundleID ?: @"";
    incoming[@"appName"] = appName.length ? appName : VLMGuessAppName(bundleID);
    incoming[@"items"] = cleanItems;
    incoming[@"order"] = ids;
    incoming[@"seenAt"] = @([[NSDate date] timeIntervalSince1970]);
    incoming[@"customOrder"] = @NO;
    if ([existing isKindOfClass:[NSDictionary class]]) {
        incoming[@"hidden"] = VLMProfileHiddenIDs(existing);
        incoming[@"customOrder"] = @(VLMProfileCustomOrder(existing));
        if (VLMProfileCustomOrder(existing)) {
            incoming[@"order"] = VLMProfileDisplayOrder(existing);
        }
        return VLMNormalizedProfile(incoming);
    }
    NSSet<NSString *> *idSet = [NSSet setWithArray:ids];
    NSMutableArray<NSString *> *hidden = [NSMutableArray array];
    for (id item in inheritHidden) {
        NSString *itemID = VLMExtractItemID(item);
        if (itemID.length && [idSet containsObject:itemID] && ![hidden containsObject:itemID]) {
            [hidden addObject:itemID];
        }
    }
    incoming[@"hidden"] = hidden;
    return VLMNormalizedProfile(incoming) ?: incoming;
}

NSArray<NSDictionary *> *VLMUpsertProfile(NSArray *profiles, NSDictionary *profile) {
    NSMutableArray<NSDictionary *> *result = [VLMSanitizeProfiles(profiles) mutableCopy];
    NSString *profileID = profile[@"id"];
    if (profileID.length == 0) {
        return result;
    }
    NSUInteger index = [result indexOfObjectPassingTest:^BOOL(NSDictionary *candidate, NSUInteger idx, BOOL *stop) {
        return [candidate[@"id"] isEqualToString:profileID];
    }];
    NSDictionary *clean = [VLMSanitizeProfiles(@[profile]) firstObject] ?: profile;
    if (index == NSNotFound) {
        [result insertObject:clean atIndex:0];
    } else {
        result[index] = clean;
    }
    return [VLMSanitizeProfiles(result) copy];
}

NSArray<NSDictionary *> *VLMRemoveProfile(NSArray *profiles, NSString *profileID) {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSDictionary *profile in VLMSanitizeProfiles(profiles)) {
        if (![profile[@"id"] isEqualToString:profileID]) {
            [result addObject:profile];
        }
    }
    return result;
}

static const NSUInteger kVLMRegistryItemsPerMenuLimit = 64;
static const NSUInteger kVLMRegistryRecordLimit = 240;

static NSDictionary *VLMNormalizedRegistryRecord(NSDictionary *record) {
    if (![record isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    id rawKind = record[@"kind"];
    NSString *kind = [rawKind isKindOfClass:[NSString class]] && [rawKind isEqualToString:VLMMenuKindContext]
        ? VLMMenuKindContext : VLMMenuKindEdit;
    NSString *bundle = [record[@"bundle"] isKindOfClass:[NSString class]] ? record[@"bundle"] : @"";
    NSMutableArray *scopedItems = [NSMutableArray array];
    NSArray *rawItems = [record[@"items"] isKindOfClass:[NSArray class]] ? record[@"items"] : @[];
    for (id rawItem in rawItems) {
        if ([rawItem isKindOfClass:[NSString class]]) {
            NSString *title = rawItem;
            NSString *itemID = VLMCatalogIDForTitle(title);
            if (itemID.length == 0) {
                NSString *folded = VLMRulesFoldedText(title);
                if (folded.length > 0) itemID = [NSString stringWithFormat:@"title:%@:%@", bundle, folded];
            }
            if (itemID.length > 0) [scopedItems addObject:@{@"id": itemID, @"title": title}];
            continue;
        }
        if (![rawItem isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSMutableDictionary *item = [rawItem mutableCopy];
        id rawID = item[@"id"];
        id rawTitle = item[@"title"] ?: item[@"label"];
        NSString *itemID = [rawID isKindOfClass:[NSString class]] ? rawID : nil;
        NSString *title = [rawTitle isKindOfClass:[NSString class]] ? rawTitle : nil;
        if ([itemID hasPrefix:@"custom:"] && title.length > 0) {
            NSString *folded = VLMRulesFoldedText(title);
            if (folded.length > 0) item[@"id"] = [NSString stringWithFormat:@"title:%@:%@", bundle, folded];
        }
        [scopedItems addObject:item];
    }
    NSArray<NSDictionary *> *items = VLMSanitizeProfileItems(scopedItems);
    if (items.count > kVLMRegistryItemsPerMenuLimit) {
        items = [items subarrayWithRange:NSMakeRange(0, kVLMRegistryItemsPerMenuLimit)];
    }
    if (items.count == 0 || bundle.length == 0) {
        return nil;
    }
    id rawAppName = record[@"appName"];
    NSString *appName = [rawAppName isKindOfClass:[NSString class]] ? rawAppName : nil;
    id rawSeenAt = record[@"seenAt"];
    NSNumber *seenAt = [rawSeenAt respondsToSelector:@selector(doubleValue)] ? @([rawSeenAt doubleValue]) : @0;
    return @{
        @"id": VLMProfileIDForMenu(kind, bundle, nil),
        @"kind": kind,
        @"bundle": bundle,
        @"appName": appName.length > 0 ? appName : VLMGuessAppName(bundle),
        @"items": items,
        @"seenAt": seenAt,
    };
}

static NSDictionary *VLMCombineRegistryRecords(NSDictionary *left, NSDictionary *right) {
    if (!left) return right;
    if (!right) return left;
    NSTimeInterval leftSeen = [left[@"seenAt"] doubleValue];
    NSTimeInterval rightSeen = [right[@"seenAt"] doubleValue];
    NSDictionary *newer = rightSeen >= leftSeen ? right : left;
    NSDictionary *older = newer == right ? left : right;
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSDictionary *item in VLMProfileItems(newer)) {
        VLMAppendKnownItem(items, seen, item);
    }
    for (NSDictionary *item in VLMProfileItems(older)) {
        VLMAppendKnownItem(items, seen, item);
    }
    if (items.count > kVLMRegistryItemsPerMenuLimit) {
        [items removeObjectsInRange:NSMakeRange(kVLMRegistryItemsPerMenuLimit,
                                                items.count - kVLMRegistryItemsPerMenuLimit)];
    }
    NSMutableDictionary *combined = [newer mutableCopy];
    combined[@"items"] = items;
    combined[@"seenAt"] = @(MAX(leftSeen, rightSeen));
    if (![combined[@"appName"] length] && [older[@"appName"] length]) {
        combined[@"appName"] = older[@"appName"];
    }
    return VLMNormalizedRegistryRecord(combined);
}

NSArray<NSDictionary *> *VLMSanitizeRegistryRecords(id value) {
    if (![value isKindOfClass:[NSArray class]]) {
        return @[];
    }
    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *indexByID = [NSMutableDictionary dictionary];
    for (id valueRecord in (NSArray *)value) {
        NSDictionary *record = VLMNormalizedRegistryRecord(valueRecord);
        if (!record) continue;
        NSString *recordID = record[@"id"];
        NSNumber *existingIndex = indexByID[recordID];
        if (existingIndex) {
            NSUInteger index = existingIndex.unsignedIntegerValue;
            records[index] = VLMCombineRegistryRecords(records[index], record);
        } else {
            indexByID[recordID] = @(records.count);
            [records addObject:record];
        }
    }
    [records sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSTimeInterval leftSeen = [left[@"seenAt"] doubleValue];
        NSTimeInterval rightSeen = [right[@"seenAt"] doubleValue];
        if (leftSeen < rightSeen) return NSOrderedDescending;
        if (leftSeen > rightSeen) return NSOrderedAscending;
        return [VLMProfileDisplayTitle(left) compare:VLMProfileDisplayTitle(right)];
    }];
    if (records.count > kVLMRegistryRecordLimit) {
        [records removeObjectsInRange:NSMakeRange(kVLMRegistryRecordLimit,
                                                  records.count - kVLMRegistryRecordLimit)];
    }
    return records;
}

NSDictionary *VLMRegistryRecordWithID(NSArray *records, NSString *recordID) {
    if (recordID.length == 0) return nil;
    NSArray *values = [records isKindOfClass:[NSArray class]] ? records : @[];
    for (id value in values) {
        if (![value isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *record = value;
        if ([record[@"id"] isKindOfClass:[NSString class]] && [record[@"id"] isEqualToString:recordID]) return record;
    }
    return nil;
}

NSDictionary *_Nullable VLMBuildRegistryRecord(NSString *kind,
                                               NSString *_Nullable bundleID,
                                               NSString *_Nullable appName,
                                               NSArray<NSDictionary *> *items,
                                               NSDictionary *_Nullable existing) {
    NSDictionary *incoming = VLMNormalizedRegistryRecord(@{
        @"kind": kind ?: VLMMenuKindEdit,
        @"bundle": bundleID ?: @"",
        @"appName": appName.length ? appName : VLMGuessAppName(bundleID),
        @"items": items ?: @[],
        @"seenAt": @([[NSDate date] timeIntervalSince1970]),
    });
    return VLMCombineRegistryRecords(existing, incoming) ?: incoming;
}

NSArray<NSDictionary *> *VLMUpsertRegistryRecord(NSArray *records, NSDictionary *record) {
    NSMutableArray<NSDictionary *> *result = [VLMSanitizeRegistryRecords(records) mutableCopy];
    NSDictionary *clean = VLMNormalizedRegistryRecord(record);
    if (!clean) return result ?: @[];
    NSString *recordID = clean[@"id"];
    NSUInteger index = [result indexOfObjectPassingTest:^BOOL(NSDictionary *candidate, NSUInteger idx, BOOL *stop) {
        (void)idx;
        (void)stop;
        return [candidate[@"id"] isEqualToString:recordID];
    }];
    if (index == NSNotFound) {
        [result addObject:clean];
    } else {
        result[index] = VLMCombineRegistryRecords(result[index], clean);
    }
    return VLMSanitizeRegistryRecords(result);
}

NSArray<NSDictionary *> *VLMRemoveRegistryRecord(NSArray *records, NSString *recordID) {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSDictionary *record in VLMSanitizeRegistryRecords(records)) {
        if (![record[@"id"] isEqualToString:recordID]) {
            [result addObject:record];
        }
    }
    return result;
}

static NSDictionary *VLMNormalizedGlobalRule(NSDictionary *rule, NSString *kind) {
    (void)kind;
    return VLMRulesNormalizedGlobalRule(rule, VLMCatalogItems());
}

static NSDictionary *VLMGlobalRulesFromDictionary(NSDictionary<NSString *, id> *prefs) {
    id raw = [prefs isKindOfClass:[NSDictionary class]] ? prefs[VLMGlobalRulesKey] : nil;
    return [raw isKindOfClass:[NSDictionary class]] ? raw : @{};
}

NSDictionary *VLMGlobalRuleForKind(NSString *kind) {
    return VLMGlobalRuleForKindInPrefs(VLMReadPrefsDictionary(), kind);
}

NSDictionary *VLMGlobalRuleForKindInPrefs(NSDictionary<NSString *, id> *prefs, NSString *kind) {
    NSString *key = [kind isEqualToString:VLMMenuKindContext] ? VLMMenuKindContext : VLMMenuKindEdit;
    NSDictionary *rules = VLMGlobalRulesFromDictionary(prefs);
    id rule = rules[key];
    return VLMNormalizedGlobalRule([rule isKindOfClass:[NSDictionary class]] ? rule : @{}, key);
}

NSArray<NSDictionary *> *VLMGlobalRuleItems(NSString *kind) {
    return VLMGlobalRuleForKind(kind)[@"items"] ?: @[];
}

NSArray<NSString *> *VLMGlobalOrderIDs(NSString *kind) {
    return VLMGlobalRuleForKind(kind)[@"order"] ?: VLMDefaultOrderIDs();
}

NSArray<NSString *> *VLMGlobalHiddenIDs(NSString *kind) {
    return VLMGlobalRuleForKind(kind)[@"hidden"] ?: @[];
}

BOOL VLMGlobalCustomOrder(NSString *kind) {
    return [VLMGlobalRuleForKind(kind)[@"customOrder"] boolValue];
}

NSArray<NSString *> *VLMEffectiveOrderIDs(NSString *kind, NSDictionary *profile) {
    NSDictionary *profileRule = @{
        @"order": VLMProfileDisplayOrder(profile),
        @"customOrder": @(VLMProfileCustomOrder(profile)),
    };
    return VLMRulesEffectiveOrderIDs(VLMGlobalRuleForKind(kind), profileRule);
}

NSArray<NSString *> *VLMEffectiveHiddenIDs(NSString *kind, NSDictionary *profile) {
    NSDictionary *profileRule = @{
        @"hidden": VLMProfileHiddenIDs(profile),
    };
    return VLMRulesEffectiveHiddenIDs(VLMGlobalRuleForKind(kind), profileRule);
}

BOOL VLMEffectiveCustomOrder(NSString *kind, NSDictionary *profile) {
    NSDictionary *profileRule = @{
        @"customOrder": @(VLMProfileCustomOrder(profile)),
    };
    return VLMRulesEffectiveCustomOrder(VLMGlobalRuleForKind(kind), profileRule);
}

void VLMWriteGlobalRule(NSString *kind,
                        NSArray<NSString *> *order,
                        NSArray<NSString *> *hidden,
                        NSArray<NSDictionary *> *items,
                        BOOL customOrder) {
    NSString *key = [kind isEqualToString:VLMMenuKindContext] ? VLMMenuKindContext : VLMMenuKindEdit;
    NSMutableDictionary *rules = [VLMGlobalRulesFromDictionary(VLMReadPrefsDictionary()) mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *rule = [VLMNormalizedGlobalRule(rules[key], key) mutableCopy];
    if (order) {
        rule[@"order"] = VLMSanitizeHiddenIDs(order);
    }
    if (hidden) {
        rule[@"hidden"] = VLMSanitizeHiddenIDs(hidden);
    }
    if (items) {
        NSMutableArray<NSDictionary *> *clean = [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        for (id item in items) {
            VLMAppendKnownItem(clean, seen, item);
        }
        rule[@"items"] = clean;
    }
    rule[@"customOrder"] = @(customOrder);
    rules[key] = VLMNormalizedGlobalRule(rule, key);
    rules[@"migrated"] = @YES;
    VLMWritePrefsValues(@{VLMGlobalRulesKey: rules}, YES);
}

void VLMWriteGlobalRuleAsync(NSString *kind,
                             NSArray<NSString *> *order,
                             NSArray<NSString *> *hidden,
                             NSArray<NSDictionary *> *items,
                             BOOL customOrder) {
    NSString *kindSnapshot = [kind copy];
    NSArray *orderSnapshot = [order copy];
    NSArray *hiddenSnapshot = [hidden copy];
    NSArray *itemsSnapshot = [items copy];
    dispatch_async(VLMPrefsWriteQueue(), ^{
        VLMWriteGlobalRule(kindSnapshot, orderSnapshot, hiddenSnapshot, itemsSnapshot, customOrder);
    });
}

void VLMMigrateToGlobalRulesIfNeeded(void) {
    if (!VLMIsSpringBoardProcess() && !VLMCurrentProcessIsPreferences()) {
        return;
    }
    NSDictionary *prefs = VLMReadPrefsDictionary();
    NSDictionary *rules = [prefs[VLMGlobalRulesKey] isKindOfClass:[NSDictionary class]] ? prefs[VLMGlobalRulesKey] : nil;
    if ([rules[@"migrated"] boolValue] && rules[VLMMenuKindEdit] && rules[VLMMenuKindContext]) {
        return;
    }
    NSArray *profiles = VLMSanitizeProfiles(prefs[VLMMenuProfilesKey]);
    NSArray *legacyHidden = VLMSanitizeHiddenIDs(prefs[VLMHiddenItemsKey]);
    NSDictionary *next = VLMRulesMigratedGlobalRules(rules,
                                                       profiles,
                                                       legacyHidden,
                                                       VLMCatalogItems(),
                                                       VLMDefaultOrderIDs(),
                                                       VLMMenuKindEdit,
                                                       VLMMenuKindContext);
    VLMWritePrefsValues(@{VLMGlobalRulesKey: next}, YES);
}

void VLMMigrateToGlobalRulesIfNeededAsync(void) {
    dispatch_async(VLMPrefsWriteQueue(), ^{
        VLMMigrateToGlobalRulesIfNeeded();
    });
}

static NSString *VLMNormalizedKind(NSString *kind) {
    return [kind isEqualToString:VLMMenuKindContext] ? VLMMenuKindContext : VLMMenuKindEdit;
}

NSDictionary *VLMPolicyRootInPrefs(NSDictionary<NSString *, id> *prefs) {
    NSDictionary *raw = [prefs[VLMMenuPoliciesKey] isKindOfClass:[NSDictionary class]] ? prefs[VLMMenuPoliciesKey] : @{};
    NSDictionary *rawGlobal = [raw[@"global"] isKindOfClass:[NSDictionary class]] ? raw[@"global"] : @{};
    NSDictionary *rawApps = [raw[@"apps"] isKindOfClass:[NSDictionary class]] ? raw[@"apps"] : @{};
    NSMutableDictionary *global = [NSMutableDictionary dictionary];
    global[VLMMenuKindEdit] = VLMRulesNormalizedPolicy(rawGlobal[VLMMenuKindEdit] ?: @{@"orderMode": VLMRulesOrderModeSystem});
    global[VLMMenuKindContext] = VLMRulesNormalizedPolicy(rawGlobal[VLMMenuKindContext] ?: @{@"orderMode": VLMRulesOrderModeSystem});
    NSMutableDictionary *apps = [NSMutableDictionary dictionary];
    [rawApps enumerateKeysAndObjectsUsingBlock:^(id rawBundle, id rawKinds, BOOL *stop) {
        (void)stop;
        if (![rawBundle isKindOfClass:[NSString class]] || [rawBundle length] == 0 || ![rawKinds isKindOfClass:[NSDictionary class]]) {
            return;
        }
        NSMutableDictionary *kinds = [NSMutableDictionary dictionary];
        id edit = rawKinds[VLMMenuKindEdit];
        id context = rawKinds[VLMMenuKindContext];
        if ([edit isKindOfClass:[NSDictionary class]]) kinds[VLMMenuKindEdit] = VLMRulesNormalizedPolicy(edit);
        if ([context isKindOfClass:[NSDictionary class]]) kinds[VLMMenuKindContext] = VLMRulesNormalizedPolicy(context);
        if (kinds.count > 0) apps[rawBundle] = kinds;
    }];
    return @{
        @"schema": @2,
        @"global": global,
        @"apps": apps,
    };
}

NSDictionary *VLMGlobalPolicyForKindInPrefs(NSDictionary<NSString *, id> *prefs, NSString *kind) {
    NSDictionary *root = [prefs[VLMMenuPoliciesKey] isKindOfClass:[NSDictionary class]] ? prefs[VLMMenuPoliciesKey] : @{};
    NSDictionary *global = [root[@"global"] isKindOfClass:[NSDictionary class]] ? root[@"global"] : @{};
    id raw = global[VLMNormalizedKind(kind)];
    return VLMRulesNormalizedPolicy([raw isKindOfClass:[NSDictionary class]]
        ? raw : @{@"orderMode": VLMRulesOrderModeSystem});
}

NSDictionary *VLMAppPolicyForKindInPrefs(NSDictionary<NSString *, id> *prefs, NSString *bundleID, NSString *kind) {
    if (bundleID.length == 0) {
        return VLMRulesNormalizedPolicy(@{@"orderMode": VLMRulesOrderModeInherit});
    }
    NSDictionary *root = [prefs[VLMMenuPoliciesKey] isKindOfClass:[NSDictionary class]] ? prefs[VLMMenuPoliciesKey] : @{};
    NSDictionary *apps = [root[@"apps"] isKindOfClass:[NSDictionary class]] ? root[@"apps"] : @{};
    NSDictionary *kinds = [apps[bundleID] isKindOfClass:[NSDictionary class]] ? apps[bundleID] : @{};
    id raw = kinds[VLMNormalizedKind(kind)];
    return VLMRulesNormalizedPolicy([raw isKindOfClass:[NSDictionary class]]
        ? raw : @{@"orderMode": VLMRulesOrderModeInherit});
}

NSDictionary *VLMResolvedPolicyForKindInPrefs(NSDictionary<NSString *, id> *prefs, NSString *bundleID, NSString *kind) {
    NSDictionary *rawRoot = [prefs[VLMMenuPoliciesKey] isKindOfClass:[NSDictionary class]] ? prefs[VLMMenuPoliciesKey] : nil;
    id rawSchema = rawRoot[@"schema"];
    NSInteger schema = [rawSchema respondsToSelector:@selector(integerValue)] ? [rawSchema integerValue] : 0;
    if (schema >= 2) {
        return VLMRulesResolvedPolicy(VLMGlobalPolicyForKindInPrefs(prefs, kind),
                                      VLMAppPolicyForKindInPrefs(prefs, bundleID, kind));
    }

    // Preferences and SpringBoard perform the durable V2 migration, but an
    // already-running target App may load before either process has written
    // MenuPoliciesV2. Resolve the legacy snapshot in memory so global hidden
    // items still inherit immediately; the next normal migration persists it.
    NSDictionary *legacyRules = [prefs[VLMGlobalRulesKey] isKindOfClass:[NSDictionary class]]
        ? prefs[VLMGlobalRulesKey] : @{};
    if (![legacyRules[@"migrated"] boolValue]) {
        legacyRules = VLMRulesMigratedGlobalRules(legacyRules,
                                                   VLMSanitizeProfiles(prefs[VLMMenuProfilesKey]),
                                                   VLMSanitizeHiddenIDs(prefs[VLMHiddenItemsKey]),
                                                   VLMCatalogItems(),
                                                   VLMDefaultOrderIDs(),
                                                   VLMMenuKindEdit,
                                                   VLMMenuKindContext);
    }
    NSString *normalizedKind = VLMNormalizedKind(kind);
    NSDictionary *legacyGlobal = VLMRulesPolicyFromLegacyRule(legacyRules[normalizedKind], NO);
    NSDictionary *legacyApp = @{ @"orderMode": VLMRulesOrderModeInherit };
    if (bundleID.length > 0) {
        for (NSDictionary *profile in VLMSanitizeProfiles(prefs[VLMMenuProfilesKey])) {
            if (![profile[@"bundle"] isEqualToString:bundleID]
                || ![VLMNormalizedKind(profile[@"kind"]) isEqualToString:normalizedKind]) {
                continue;
            }
            legacyApp = VLMRulesPolicyFromLegacyRule(profile, YES);
            break;
        }
    }
    return VLMRulesResolvedPolicy(legacyGlobal, legacyApp);
}

static void VLMWritePolicy(NSString *bundleID, NSString *kind, NSDictionary *policy) {
    NSDictionary *prefs = VLMReadPrefsDictionary();
    NSMutableDictionary *root = [VLMPolicyRootInPrefs(prefs) mutableCopy];
    NSString *key = VLMNormalizedKind(kind);
    if (bundleID.length == 0) {
        NSMutableDictionary *global = [root[@"global"] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSMutableDictionary *normalized = [VLMRulesNormalizedPolicy(policy) mutableCopy];
        if ([normalized[@"orderMode"] isEqualToString:VLMRulesOrderModeInherit]) {
            normalized[@"orderMode"] = VLMRulesOrderModeSystem;
        }
        global[key] = normalized;
        root[@"global"] = global;
    } else {
        NSMutableDictionary *apps = [root[@"apps"] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSMutableDictionary *kinds = [apps[bundleID] mutableCopy] ?: [NSMutableDictionary dictionary];
        kinds[key] = VLMRulesNormalizedPolicy(policy);
        apps[bundleID] = kinds;
        root[@"apps"] = apps;
    }
    root[@"schema"] = @2;
    VLMWritePrefsValues(@{VLMMenuPoliciesKey: root}, YES);
}

static NSString *VLMV2ScopedLegacyID(NSString *itemID, NSString *bundleID, NSDictionary *profile) {
    if (![itemID hasPrefix:@"custom:"] || bundleID.length == 0) return itemID;
    NSString *title = [itemID substringFromIndex:7];
    for (NSDictionary *item in VLMProfileItems(profile)) {
        if ([item[@"id"] isEqualToString:itemID] && [item[@"title"] length] > 0) {
            title = item[@"title"];
            break;
        }
    }
    NSString *folded = VLMRulesFoldedText(title);
    return folded.length > 0 ? [NSString stringWithFormat:@"title:%@:%@", bundleID, folded] : itemID;
}

static NSArray<NSString *> *VLMV2ScopedLegacyIDs(NSArray<NSString *> *ids, NSString *bundleID, NSDictionary *profile) {
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *itemID in ids) {
        NSString *next = VLMV2ScopedLegacyID(itemID, bundleID, profile);
        if (next.length > 0 && ![seen containsObject:next]) {
            [seen addObject:next];
            [result addObject:next];
        }
    }
    return result;
}

void VLMWriteGlobalPolicyAsync(NSString *kind, NSDictionary *policy) {
    NSString *kindSnapshot = [kind copy];
    NSDictionary *policySnapshot = [policy copy] ?: @{};
    dispatch_async(VLMPrefsWriteQueue(), ^{
        VLMWritePolicy(nil, kindSnapshot, policySnapshot);
    });
}

void VLMWriteAppPolicyAsync(NSString *bundleID, NSString *kind, NSDictionary *policy) {
    NSString *bundleSnapshot = [bundleID copy];
    NSString *kindSnapshot = [kind copy];
    NSDictionary *policySnapshot = [policy copy] ?: @{};
    dispatch_async(VLMPrefsWriteQueue(), ^{
        VLMWritePolicy(bundleSnapshot, kindSnapshot, policySnapshot);
    });
}

void VLMMigrateToPolicyV2IfNeeded(void) {
    if (!VLMIsSpringBoardProcess() && !VLMCurrentProcessIsPreferences()) {
        return;
    }
    NSDictionary *prefs = VLMReadPrefsDictionary();
    NSDictionary *rawRoot = [prefs[VLMMenuPoliciesKey] isKindOfClass:[NSDictionary class]] ? prefs[VLMMenuPoliciesKey] : nil;
    id rawSchema = rawRoot[@"schema"];
    BOOL hasV2 = [rawSchema respondsToSelector:@selector(integerValue)] && [rawSchema integerValue] >= 2;
    if (hasV2) {
        return;
    }
    NSArray<NSDictionary *> *legacyProfiles = VLMSanitizeProfiles(prefs[VLMMenuProfilesKey]);
    NSArray<NSDictionary *> *registry = [prefs[VLMMenuRegistryKey] isKindOfClass:[NSArray class]]
        ? prefs[VLMMenuRegistryKey] : @[];
    for (NSDictionary *profile in legacyProfiles) {
        registry = VLMUpsertRegistryRecord(registry, profile);
    }

    NSDictionary *legacyRules = [prefs[VLMGlobalRulesKey] isKindOfClass:[NSDictionary class]] ? prefs[VLMGlobalRulesKey] : nil;
    if (![legacyRules[@"migrated"] boolValue]) {
        legacyRules = VLMRulesMigratedGlobalRules(legacyRules,
                                                   legacyProfiles,
                                                   VLMSanitizeHiddenIDs(prefs[VLMHiddenItemsKey]),
                                                   VLMCatalogItems(),
                                                   VLMDefaultOrderIDs(),
                                                   VLMMenuKindEdit,
                                                   VLMMenuKindContext);
    }
    NSMutableDictionary *global = [NSMutableDictionary dictionary];
    global[VLMMenuKindEdit] = VLMRulesPolicyFromLegacyRule(legacyRules[VLMMenuKindEdit], NO);
    global[VLMMenuKindContext] = VLMRulesPolicyFromLegacyRule(legacyRules[VLMMenuKindContext], NO);
    NSMutableDictionary *apps = [NSMutableDictionary dictionary];
    for (NSDictionary *profile in legacyProfiles) {
        NSString *bundle = profile[@"bundle"];
        NSString *kind = VLMNormalizedKind(profile[@"kind"]);
        if (bundle.length == 0) continue;
        NSMutableDictionary *kinds = [apps[bundle] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSMutableDictionary *scopedProfile = [profile mutableCopy];
        scopedProfile[@"hidden"] = VLMV2ScopedLegacyIDs(VLMProfileHiddenIDs(profile), bundle, profile);
        scopedProfile[@"order"] = VLMV2ScopedLegacyIDs(VLMProfileDisplayOrder(profile), bundle, profile);
        kinds[kind] = VLMRulesPolicyFromLegacyRule(scopedProfile, YES);
        apps[bundle] = kinds;
    }
    NSDictionary *root = @{
        @"schema": @2,
        @"global": global,
        @"apps": apps,
    };
    NSMutableDictionary *updates = [NSMutableDictionary dictionaryWithObject:root forKey:VLMMenuPoliciesKey];
    if (registry.count > 0) updates[VLMMenuRegistryKey] = registry;
    if (!prefs[VLMPolicyV1BackupKey]) {
        updates[VLMPolicyV1BackupKey] = @{
            VLMGlobalRulesKey: prefs[VLMGlobalRulesKey] ?: @{},
            VLMMenuProfilesKey: prefs[VLMMenuProfilesKey] ?: @[],
            VLMMenuOrderKey: prefs[VLMMenuOrderKey] ?: @[],
            VLMCustomOrderKey: prefs[VLMCustomOrderKey] ?: @NO,
            VLMKnownItemsKey: prefs[VLMKnownItemsKey] ?: @[],
            VLMHiddenItemsKey: prefs[VLMHiddenItemsKey] ?: @[],
        };
    }
    gReplaceRegistry = YES;
    VLMWritePrefsValues(updates, YES);
    gReplaceRegistry = NO;
}

void VLMMigrateToPolicyV2IfNeededAsync(void) {
    dispatch_async(VLMPrefsWriteQueue(), ^{
        VLMMigrateToPolicyV2IfNeeded();
    });
}
