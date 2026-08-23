#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    CGRect frame;
    BOOL belowAnchor;
} VLMMenuPlacement;

CGRect VLMMenuClampFrame(CGRect frame, CGRect safeRect);
VLMMenuPlacement VLMMenuPlaceNearAnchor(CGRect safeRect,
                                        CGRect anchorRect,
                                        CGSize desiredSize,
                                        CGFloat gap,
                                        CGFloat arrowOffset,
                                        CGFloat minimumHeight);

NS_ASSUME_NONNULL_END
