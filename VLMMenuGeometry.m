#import "VLMMenuGeometry.h"
#import <math.h>

static CGFloat VLMFiniteNonnegative(CGFloat value) {
    return isfinite(value) ? MAX(0.0, value) : 0.0;
}

CGRect VLMMenuClampFrame(CGRect frame, CGRect safeRect) {
    if (CGRectIsNull(safeRect) || CGRectIsEmpty(safeRect)) {
        return frame;
    }
    frame.size.width = MIN(VLMFiniteNonnegative(frame.size.width), CGRectGetWidth(safeRect));
    frame.size.height = MIN(VLMFiniteNonnegative(frame.size.height), CGRectGetHeight(safeRect));
    frame.origin.x = MIN(MAX(frame.origin.x, CGRectGetMinX(safeRect)), CGRectGetMaxX(safeRect) - frame.size.width);
    frame.origin.y = MIN(MAX(frame.origin.y, CGRectGetMinY(safeRect)), CGRectGetMaxY(safeRect) - frame.size.height);
    return frame;
}

VLMMenuPlacement VLMMenuPlaceNearAnchor(CGRect safeRect,
                                        CGRect anchorRect,
                                        CGSize desiredSize,
                                        CGFloat gap,
                                        CGFloat arrowOffset,
                                        CGFloat minimumHeight) {
    VLMMenuPlacement result = { .frame = CGRectZero, .belowAnchor = YES };
    if (CGRectIsNull(safeRect) || CGRectIsEmpty(safeRect)) {
        result.frame = (CGRect){CGPointZero, desiredSize};
        return result;
    }

    CGFloat separation = MAX(0.0, gap) + MAX(0.0, arrowOffset);
    CGFloat belowTop = CGRectGetMaxY(anchorRect) + separation;
    CGFloat aboveBottom = CGRectGetMinY(anchorRect) - separation;
    CGFloat belowSpace = MAX(0.0, CGRectGetMaxY(safeRect) - belowTop);
    CGFloat aboveSpace = MAX(0.0, aboveBottom - CGRectGetMinY(safeRect));
    CGFloat desiredHeight = MIN(VLMFiniteNonnegative(desiredSize.height), CGRectGetHeight(safeRect));

    BOOL belowFits = belowSpace >= desiredHeight;
    BOOL aboveFits = aboveSpace >= desiredHeight;
    BOOL below = belowFits || (!aboveFits && belowSpace >= aboveSpace);
    CGFloat available = below ? belowSpace : aboveSpace;
    if (available < minimumHeight) {
        below = belowSpace >= aboveSpace;
        available = below ? belowSpace : aboveSpace;
    }

    CGFloat height = MIN(desiredHeight, available);
    if (height < MIN(minimumHeight, CGRectGetHeight(safeRect))) {
        height = MIN(MAX(available, minimumHeight), CGRectGetHeight(safeRect));
    }
    CGFloat width = MIN(VLMFiniteNonnegative(desiredSize.width), CGRectGetWidth(safeRect));
    CGFloat x = CGRectGetMidX(anchorRect) - width / 2.0;
    CGFloat y = below ? belowTop : aboveBottom - height;

    result.belowAnchor = below;
    result.frame = VLMMenuClampFrame(CGRectMake(x, y, width, height), safeRect);
    return result;
}
