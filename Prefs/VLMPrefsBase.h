#import <UIKit/UIKit.h>

#ifndef VLM_PSVIEWCONTROLLER_DEFINED
#define VLM_PSVIEWCONTROLLER_DEFINED
@interface PSViewController : UIViewController
- (instancetype)initForContentSize:(CGSize)size;
- (void)setSpecifier:(id)specifier;
- (id)specifier;
- (void)setRootController:(id)controller;
- (void)setParentController:(id)controller;
- (id)rootController;
- (id)parentController;
@end
#endif
