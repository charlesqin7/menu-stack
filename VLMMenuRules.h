#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSString *VLMRulesFoldedText(NSString *_Nullable text);
BOOL VLMRulesCatalogContainsID(NSArray<NSDictionary *> *catalog, NSString *_Nullable itemID);
NSString *_Nullable VLMRulesCatalogIDForTitle(NSArray<NSDictionary *> *catalog, NSString *_Nullable title);
NSString *_Nullable VLMRulesCatalogIDForSelector(NSArray<NSDictionary *> *catalog, NSString *_Nullable selectorName);
NSString *_Nullable VLMRulesCatalogIDForIdentifier(NSArray<NSDictionary *> *catalog, NSString *_Nullable identifier);
NSString *_Nullable VLMRulesCatalogLabelForID(NSArray<NSDictionary *> *catalog, NSString *_Nullable itemID);
NSString *_Nullable VLMRulesItemIDForTitle(NSArray<NSDictionary *> *catalog, NSString *_Nullable title);
BOOL VLMRulesIsCapturedJunkItem(NSString *_Nullable title, NSString *_Nullable itemID);

NSString *VLMRulesProfileID(NSString *kind, NSString *_Nullable bundleID);

extern NSString * const VLMRulesVisibilityInherit;
extern NSString * const VLMRulesVisibilityShow;
extern NSString * const VLMRulesVisibilityHide;
extern NSString * const VLMRulesOrderModeInherit;
extern NSString * const VLMRulesOrderModeSystem;
extern NSString * const VLMRulesOrderModeCustom;

NSDictionary *VLMRulesNormalizedPolicy(NSDictionary *_Nullable policy);
NSDictionary *VLMRulesPolicyFromLegacyRule(NSDictionary *_Nullable rule,
                                            BOOL appScoped);
NSDictionary *VLMRulesResolvedPolicy(NSDictionary *_Nullable globalPolicy,
                                     NSDictionary *_Nullable appPolicy);
NSString *VLMRulesVisibilityForItem(NSDictionary *_Nullable policy,
                                    NSString *_Nullable itemID);
BOOL VLMRulesPolicyHasOrdering(NSDictionary *_Nullable policy);
NSArray *VLMRulesApplyPolicyToItems(NSArray *items,
                                    NSDictionary *_Nullable policy,
                                    NSString *_Nullable (^_Nullable itemID)(id item));
NSArray<NSNumber *> *VLMRulesVisibleOriginalIndexes(NSArray<NSString *> *itemIDs,
                                                     NSDictionary *_Nullable policy);

NSArray *VLMRulesApplyToItems(NSArray *items,
                              BOOL (^_Nullable isHidden)(id item),
                              NSArray<NSString *> *_Nullable orderIDs,
                              BOOL customOrder,
                              NSString *_Nullable (^_Nullable itemID)(id item));

NSDictionary *VLMRulesNormalizedGlobalRule(NSDictionary *_Nullable rule,
                                            NSArray<NSDictionary *> *catalog);
NSArray<NSString *> *VLMRulesEffectiveOrderIDs(NSDictionary *_Nullable globalRule,
                                               NSDictionary *_Nullable profile);
NSArray<NSString *> *VLMRulesEffectiveHiddenIDs(NSDictionary *_Nullable globalRule,
                                                NSDictionary *_Nullable profile);
BOOL VLMRulesEffectiveCustomOrder(NSDictionary *_Nullable globalRule,
                                  NSDictionary *_Nullable profile);

NSDictionary *VLMRulesMigratedGlobalRules(NSDictionary *_Nullable existingRules,
                                           NSArray<NSDictionary *> *profiles,
                                           NSArray<NSString *> *legacyHidden,
                                           NSArray<NSDictionary *> *catalog,
                                           NSArray<NSString *> *defaultOrder,
                                           NSString *editKind,
                                           NSString *contextKind);

NS_ASSUME_NONNULL_END
