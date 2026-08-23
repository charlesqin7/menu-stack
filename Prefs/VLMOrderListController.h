#import "VLMPrefsBase.h"

@interface VLMOrderListController : PSViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *profileID;
@property (nonatomic, copy) NSString *globalKind;
@end
