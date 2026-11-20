#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 可拖拽悬浮球 + 控制面板（倍速 / 双击评论开关 / 全屏入口）
@interface ACFloatingBall : NSObject

+ (instancetype)shared;

/// 二指双击手势（挂在 App keyWindow 上，全屏退出需要和它做互斥）
@property (nonatomic, strong, readonly, nullable) UITapGestureRecognizer *toggleTap;

- (void)showIfNeeded;
- (void)hide;
- (void)refreshSpeed;

@end

NS_ASSUME_NONNULL_END
