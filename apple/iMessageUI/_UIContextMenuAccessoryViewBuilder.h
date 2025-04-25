//
//  _UIContextMenuAccessoryViewBuilder.h
//
//  Created by Alex Perez on 7/31/24.
//  Copyright © 2024 Alex Perez. All rights reserved.
//

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSUInteger, UIContextMenuAccessoryAlignment) {
    UIContextMenuAccessoryAlignmentLeading,
    UIContextMenuAccessoryAlignmentTrailing,
};

NS_ASSUME_NONNULL_BEGIN

@interface _UIContextMenuAccessoryViewBuilder : NSObject

+ (nullable UIView *)buildWithAlignment:(UIContextMenuAccessoryAlignment)alignment offset:(CGPoint)offset;

@end

NS_ASSUME_NONNULL_END
