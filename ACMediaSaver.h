#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 保存当前作品：视频作品存无水印视频，图文作品逐张存原图
@interface ACMediaSaver : NSObject

+ (instancetype)shared;

/// 当前作品是不是图文（用来决定按钮文案）
+ (BOOL)currentAwemeIsImage;

/// 执行保存，message 回传给悬浮球做 toast
- (void)saveCurrentAwemeWithCompletion:(void (^)(NSString *message))completion;

@end

NS_ASSUME_NONNULL_END
