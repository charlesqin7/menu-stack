#import <UIKit/UIKit.h>

@interface PSViewController : UIViewController
- (instancetype)initForContentSize:(CGSize)size;
- (void)setSpecifier:(id)specifier;
- (id)specifier;
- (void)setRootController:(id)controller;
- (void)setParentController:(id)controller;
- (id)rootController;
- (id)parentController;
@end

@interface VLMMenuListController : PSViewController <UITableViewDataSource, UITableViewDelegate>
@end
