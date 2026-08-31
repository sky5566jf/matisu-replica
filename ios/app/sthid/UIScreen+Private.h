#pragma once
#import <UIKit/UIKit.h>
// shim：UIScreen 私有 API（iOS 13+），不受 App 兼容模式影响的物理像素尺寸
@interface UIScreen (MatisuPrivateSPI)
- (CGRect)_unjailedReferenceBoundsInPixels;
@end
