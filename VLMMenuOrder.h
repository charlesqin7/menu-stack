#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const VLMMenuOrderKey;
extern NSString * const VLMCustomOrderKey;
extern NSString * const VLMKnownItemsKey;

NSArray<NSDictionary *> *VLMCatalogItems(void);
NSArray<NSString *> *VLMDefaultOrderIDs(void);
NSString *_Nullable VLMLabelForItemID(NSString *itemID);
NSString *_Nullable VLMCatalogIDForTitle(NSString *title);
NSString *_Nullable VLMCatalogIDForSelectorName(NSString *selectorName);
NSString *_Nullable VLMCatalogIDForIdentifier(NSString *identifier);

NSArray<NSString *> *VLMSanitizeOrderIDs(id value);
NSArray<NSDictionary *> *VLMMergedKnownItems(NSArray * _Nullable stored, NSArray * _Nullable extra);

NS_ASSUME_NONNULL_END
