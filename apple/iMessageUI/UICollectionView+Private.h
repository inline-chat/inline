//
//  UICollectionView+Private.h
//
//  Created by Alex Perez on 7/31/24.
//  Copyright © 2024 Alex Perez. All rights reserved.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface UICollectionView (Private)

- (nullable NSArray *)_contextMenuInteraction:(UIContextMenuInteraction *)interaction
                 accessoriesForMenuWithConfiguration:(UIContextMenuConfiguration *)configuration
                 NS_SWIFT_NAME(contextMenuAccessories(for:configuration:));

- (nullable id)_contextMenuInteraction:(UIContextMenuInteraction *)interaction
                styleForMenuWithConfiguration:(UIContextMenuConfiguration *)configuration
                NS_SWIFT_NAME(contextMenuStyle(for:configuration:));

@end

NS_ASSUME_NONNULL_END
