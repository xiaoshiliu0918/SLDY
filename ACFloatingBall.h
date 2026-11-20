#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 可拖拽悬浮球 + 控制面板（倍速 / 双击评论开关 / 全屏入口）
@interface ACFloatingBall : NSObject

+ (instancetype)shared;

- (void)showIfNeeded;
- (void)hide;
- (void)refreshSpeed;

@end

NS_ASSUME_NONNULL_END
