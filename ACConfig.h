#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 全局配置，持久化在 NSUserDefaults
@interface ACConfig : NSObject

@property (nonatomic, assign) BOOL doubleTapCommentEnabled;  // 双击屏幕打开评论区（替代点赞）
@property (nonatomic, assign) BOOL fullscreenLandscape;      // 进入全屏时默认横屏
@property (nonatomic, assign) double playbackRate;           // 当前倍速 0.5 ~ 3.0
@property (nonatomic, assign) CGPoint ballPosition;          // 悬浮球中心点（归一化 0~1）
@property (nonatomic, assign) BOOL ballCollapsed;            // 悬浮球是否收起成小圆点
@property (nonatomic, assign) BOOL ballVisible;              // 悬浮球是否显示（二指双击切换）
@property (nonatomic, assign) BOOL autoPlayEnabled;          // 强制自动播放（推荐/好友/关注都生效）

+ (instancetype)shared;
- (void)save;

@end

NS_ASSUME_NONNULL_END
