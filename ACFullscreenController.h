#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 沉浸式全屏播放：在当前 App 主窗口上盖一层宿主视图托管播放器，
/// 并把其余界面整层隐藏（DYYY 式清屏）。支持竖屏铺满 / 横屏整体旋转铺满。
@interface ACFullscreenController : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly, getter=isActive) BOOL active;
@property (nonatomic, assign) BOOL landscape;

- (BOOL)enter;   // 找到播放视图并成功托管返回 YES
- (void)exit;
- (void)toggle;
- (void)toggleOrientation;

@end

NS_ASSUME_NONNULL_END
