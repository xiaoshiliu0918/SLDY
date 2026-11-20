#import "ACFullscreenController.h"
#import "ACUtils.h"
#import "ACConfig.h"
#import "ACLog.h"
#import <objc/message.h>
#import <math.h>

/// 沉浸式全屏 = 抖音原生的「清屏」。
///
/// 之前试过两条路都不行：
///   1) 把播放器搬到独立窗口 —— 播放器脱离 App 的渲染链路，黑屏 / 无声；
///   2) 手动把 feed 表格 / cell / 交互层的高度撑满父视图 —— cell 之间的高度关系被打乱，
///      上一条内容和当前视频叠在一起（截图里那种错位）。
///
/// 极速版本身就带清屏能力，入口就在播放交互容器上：
///   AWEPlayInteractionViewController -setPureMode:animateDuration:
/// 它会把所有 UI 元素隐藏、视频铺满、状态栏收起，而且退出动画、tab 切换、后续起播
/// 都由 App 自己处理。所以这里只负责调这一个方法，不碰任何布局。
@interface ACFullscreenController ()
@property (nonatomic, assign, readwrite, getter=isActive) BOOL active;
@property (nonatomic, weak) UIViewController *hostController;
@property (nonatomic, weak) UIView *rotatedRootView;
@property (nonatomic, assign) CGRect rootOriginalBounds;
@property (nonatomic, assign) CGPoint rootOriginalCenter;
@property (nonatomic, assign) CGAffineTransform rootOriginalTransform;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UITapGestureRecognizer *exitGesture;
@end

@implementation ACFullscreenController

@synthesize landscape = _landscape;

+ (instancetype)shared {
    static ACFullscreenController *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ACFullscreenController alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleBackground)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleBackground {
    if (self.active) [self exit];
}

#pragma mark - 清屏调用

/// 极速版上真正干活的是这个方法，两个参数分别是「进入/退出」和「动画时长」
- (void)applyPureMode:(BOOL)pure toController:(UIViewController *)vc {
    if (!vc) return;

    SEL durationSel = NSSelectorFromString(@"setPureMode:animateDuration:");
    if ([vc respondsToSelector:durationSel]) {
        typedef void (*ACBoolDoubleMsg)(id, SEL, BOOL, double);
        ((ACBoolDoubleMsg)objc_msgSend)(vc, durationSel, pure, 0.3);
        return;
    }

    SEL animatedSel = NSSelectorFromString(@"setPureMode:animated:");
    if ([vc respondsToSelector:animatedSel]) {
        typedef void (*ACBoolBoolMsg)(id, SEL, BOOL, BOOL);
        ((ACBoolBoolMsg)objc_msgSend)(vc, animatedSel, pure, YES);
        return;
    }

    SEL plainSel = NSSelectorFromString(@"setPureMode:");
    if ([vc respondsToSelector:plainSel]) {
        typedef void (*ACBoolMsg)(id, SEL, BOOL);
        ((ACBoolMsg)objc_msgSend)(vc, plainSel, pure);
        return;
    }

    ACLog(@"播放容器没有清屏入口");
}

#pragma mark - 进入 / 退出

- (void)toggle {
    self.active ? [self exit] : [self enter];
}

- (BOOL)enter {
    if (self.active) return YES;

    UIViewController *vc = ACCurrentInteractionVC();
    if (!vc) vc = ACFindVCByClassName(@"AWEPlayInteractionViewController");
    if (!vc) {
        ACLog(@"不在视频页，无法全屏");
        return NO;
    }

    // 已经在清屏状态（比如用户自己长按上滑进去的），只补一下状态
    BOOL already = ACCallBool(vc, NSSelectorFromString(@"pureMode"));

    self.active = YES;
    self.hostController = vc;
    _landscape = [ACConfig shared].fullscreenLandscape;

    if (!already) {
        [self applyPureMode:YES toController:vc];
    }

    ACSetStatusBarHidden(YES);
    if (self.landscape) [self applyRotation:YES];

    [self installExitGesture];
    [self showHint];

    ACLog(@"进入全屏 %@", self.landscape ? @"横屏" : @"竖屏");
    return YES;
}

- (void)exit {
    if (!self.active) return;
    self.active = NO;

    UIViewController *vc = self.hostController;
    if (!vc) vc = ACFindVCByClassName(@"AWEPlayInteractionViewController");

    if (self.landscape) [self applyRotation:NO];

    // 只有确实还在清屏状态才需要退出，避免把用户自己的清屏状态关掉
    BOOL still = vc ? ACCallBool(vc, NSSelectorFromString(@"pureMode")) : NO;
    if (still) [self applyPureMode:NO toController:vc];

    ACSetStatusBarHidden(NO);

    [self.hintLabel removeFromSuperview];
    self.hintLabel = nil;
    [self removeExitGesture];
    self.hostController = nil;

    ACLog(@"退出全屏");
}

#pragma mark - 退出手势

- (void)installExitGesture {
    [self removeExitGesture];
    UIWindow *key = ACKeyWindow();
    if (!key) return;
    UITapGestureRecognizer *gesture =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleExitGesture:)];
    gesture.numberOfTouchesRequired = 2;
    gesture.cancelsTouchesInView = NO;
    [key addGestureRecognizer:gesture];
    self.exitGesture = gesture;
}

- (void)removeExitGesture {
    if (!self.exitGesture) return;
    [self.exitGesture.view removeGestureRecognizer:self.exitGesture];
    self.exitGesture = nil;
}

- (void)handleExitGesture:(UIGestureRecognizer *)gesture {
    // 用户可能已经用原生手势退出了清屏，这里只同步状态
    [self exit];
}

#pragma mark - 横屏旋转

- (void)applyRotation:(BOOL)rotate {
    UIWindow *key = ACKeyWindow();
    UIView *root = key.rootViewController.view;
    if (!root) return;

    if (rotate) {
        self.rotatedRootView = root;
        self.rootOriginalBounds = root.bounds;
        self.rootOriginalCenter = root.center;
        self.rootOriginalTransform = root.transform;

        CGSize screen = key.bounds.size;
        CGFloat longSide = MAX(screen.width, screen.height);
        CGFloat shortSide = MIN(screen.width, screen.height);

        root.transform = CGAffineTransformIdentity;
        root.bounds = CGRectMake(0, 0, longSide, shortSide);
        root.center = CGPointMake(screen.width / 2.0, screen.height / 2.0);
        root.transform = CGAffineTransformMakeRotation(M_PI_2);
    } else {
        UIView *target = self.rotatedRootView;
        if (!target) return;
        target.transform = CGAffineTransformIdentity;
        target.bounds = self.rootOriginalBounds;
        target.center = self.rootOriginalCenter;
        target.transform = self.rootOriginalTransform;
        self.rotatedRootView = nil;
    }
}

#pragma mark - 切换方向

- (void)setLandscape:(BOOL)landscape {
    if (_landscape == landscape) return;
    BOOL wasActive = self.active;

    if (wasActive) [self exit];
    _landscape = landscape;
    [ACConfig shared].fullscreenLandscape = landscape;
    if (wasActive) [self enter];
}

- (void)toggleOrientation {
    if (!self.active) return;
    self.landscape = !self.landscape;
}

#pragma mark - 提示

- (void)showHint {
    [self.hintLabel removeFromSuperview];

    UIWindow *key = ACKeyWindow();
    if (!key) return;

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectZero];
    hint.text = @"双指轻点屏幕退出全屏";
    hint.textColor = [UIColor colorWithWhite:1 alpha:0.92];
    hint.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    hint.layer.cornerRadius = 14;
    hint.clipsToBounds = YES;
    [hint sizeToFit];
    CGRect frame = hint.frame;
    frame.size.width += 24;
    frame.size.height = 28;
    CGSize size = key.bounds.size;
    frame.origin = CGPointMake((size.width - frame.size.width) / 2.0, size.height - 96);
    hint.frame = frame;
    hint.userInteractionEnabled = NO;
    [key addSubview:hint];
    self.hintLabel = hint;

    hint.alpha = 0;
    [UIView animateWithDuration:0.25 animations:^{
        hint.alpha = 1;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.4 delay:1.8 options:0 animations:^{
            hint.alpha = 0;
        } completion:^(BOOL finished) {
            [hint removeFromSuperview];
        }];
    }];
}

@end
