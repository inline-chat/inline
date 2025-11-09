#import <Foundation/Foundation.h>

typedef struct {
    unsigned long long attachment;
    unsigned long long alignment;
    double attachmentOffset;
    double alignmentOffset;
    long long gravity;
} ContextMenuAccessoryAnchor;

@protocol UIContextMenuInteractionDelegate_Private <NSObject>
@optional
- (id)_contextMenuInteraction:(id)interaction styleForMenuWithConfiguration:(id)configuration;
@end
