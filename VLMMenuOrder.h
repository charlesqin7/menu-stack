#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const VLMPrefsIdentifier;
extern NSString * const VLMReloadNotificationName;
extern NSString * const VLMMenuOrderKey;
extern NSString * const VLMCustomOrderKey;
extern NSString * const VLMKnownItemsKey;
extern NSString * const VLMHiddenItemsKey;
extern NSString * const VLMPrefsStampKey;
extern NSString * const VLMMenuProfilesKey;
extern NSString * const VLMMenuKindEdit;
extern NSString * const VLMMenuKindContext;
extern NSString * const VLMIncomingNotificationName;

NSDictionary<NSString *, id> *VLMReadPrefsDictionary(void);
void VLMWritePrefsValues(NSDictionary<NSString *, id> *updates, BOOL bumpStamp);
void VLMReplacePrefsValues(NSDictionary<NSString *, id> *updates, BOOL bumpStamp);
void VLMStartPrefsWriterIfNeeded(void);
void VLMIngestIncomingPrefs(void);

NSArray<NSDictionary *> *VLMCatalogItems(void);
NSArray<NSString *> *VLMCoreOrderIDs(void);
NSArray<NSString *> *VLMDefaultOrderIDs(void);
NSString *_Nullable VLMLabelForItemID(NSString *itemID);
NSString *_Nullable VLMCatalogIDForTitle(NSString *title);
NSString *_Nullable VLMCatalogIDForSelectorName(NSString *selectorName);
NSString *_Nullable VLMCatalogIDForIdentifier(NSString *identifier);

NSArray<NSString *> *VLMSanitizeOrderIDs(id _Nullable value);
NSArray<NSString *> *VLMDisplayOrderIDs(id _Nullable orderValue, id _Nullable knownValue);
NSArray<NSString *> *VLMSanitizeHiddenIDs(id _Nullable value);
NSArray<NSDictionary *> *VLMSanitizeKnownItems(id _Nullable value);
NSArray<NSDictionary *> *VLMMergedKnownItems(NSArray * _Nullable stored, NSArray * _Nullable extra);

NSString *VLMCurrentBundleID(void);
NSString *VLMGuessAppName(NSString *_Nullable bundleID);
NSString *VLMKindDisplayName(NSString *_Nullable kind);
NSString *VLMProfileIDForMenu(NSString *kind, NSString *_Nullable bundleID, NSArray<NSString *> * _Nullable itemIDs);
NSArray<NSDictionary *> *VLMSanitizeProfiles(id _Nullable value);
BOOL VLMProfilesNeedRewrite(id _Nullable raw);
NSDictionary *_Nullable VLMProfileWithID(NSArray *_Nullable profiles, NSString *_Nullable profileID);
NSArray<NSDictionary *> *VLMProfileItems(NSDictionary *_Nullable profile);
NSArray<NSString *> *VLMProfileDisplayOrder(NSDictionary *_Nullable profile);
NSArray<NSString *> *VLMProfileHiddenIDs(NSDictionary *_Nullable profile);
BOOL VLMProfileCustomOrder(NSDictionary *_Nullable profile);
NSString *VLMProfileDisplayTitle(NSDictionary *_Nullable profile);
NSString *VLMProfileSubtitle(NSDictionary *_Nullable profile);
NSDictionary *VLMBuildProfile(NSString *kind,
                             NSString *_Nullable bundleID,
                             NSString *_Nullable appName,
                             NSArray<NSDictionary *> *items,
                             NSDictionary *_Nullable existing,
                             NSArray *_Nullable inheritHidden);
NSArray<NSDictionary *> *VLMUpsertProfile(NSArray *_Nullable profiles, NSDictionary *profile);
NSArray<NSDictionary *> *VLMRemoveProfile(NSArray *_Nullable profiles, NSString *profileID);

NS_ASSUME_NONNULL_END
