#import <UIKit/UIKit.h>

@interface PSViewController : UIViewController
- (instancetype)initForContentSize:(CGSize)size;
- (void)setSpecifier:(id)specifier;
- (id)specifier;
- (void)setRootController:(id)controller;
- (void)setParentController:(id)controller;
@end

@interface VLMOrderListController : PSViewController <UITableViewDataSource, UITableViewDelegate>
@end
