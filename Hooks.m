#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>
#import "ACConfig.h"
#import "ACLog.h"
#import "ACUtils.h"
#import "ACFloatingBall.h"
#import "ACFullscreenController.h"

#pragma mark - 原始 IMP

typedef void (*ACVoidFn)(id, SEL);
typedef void (*ACBoolFn)(id, SEL, BOOL);
typedef BOOL (*ACBoolRetFn)(id, SEL);
typedef BOOL (*ACBoolObjectRetFn)(id, SEL, id);
typedef void (*ACObjectFn)(id, SEL, id);
typedef void (*ACPointFn)(id, SEL, CGPoint);
typedef void (*ACDoubleFn)(id, SEL, double);
typedef void (*ACLongLongFn)(id, SEL, long long);

static ACBoolFn      ac_orig_viewDidAppear;
static ACBoolFn      ac_orig_viewWillDisappear;
static ACPointFn     ac_orig_doubleTapAtPoint;
static ACPointFn     ac_orig_feedDoubleClick;
static ACObjectFn    ac_orig_doubleTap;
static ACObjectFn    ac_orig_setData;
static ACVoidFn      ac_orig_willDisplay;
static ACVoidFn      ac_orig_updatePlayer;
static ACVoidFn      ac_orig_feedUpdatePlayer;
static ACDoubleFn    ac_orig_setPlaybackRate;
static ACLongLongFn  ac_orig_playOrResume;
static ACObjectFn    ac_orig_setModel;
static ACObjectFn    ac_orig_baseSetModel;
static ACVoidFn      ac_orig_enginePlay;
static ACDoubleFn    ac_orig_engineSetSpeed;

// 倍速状态机
static ACObjectFn    ac_orig_setCurrentSpeed;
static ACDoubleFn    ac_orig_setSpeedHomepage;
static ACDoubleFn    ac_orig_setSpeedMixVideo;
static ACDoubleFn    ac_orig_setSpeedInterest;
static ACVoidFn      ac_orig_resetSpeedControl;
static ACVoidFn      ac_orig_resetSpeedHomepage;
static ACVoidFn      ac_orig_resetSpeedMixVideo;
static ACVoidFn      ac_orig_resetSpeedInterest;
static ACDoubleFn    ac_orig_changeSpeed;
static ACObjectFn    ac_orig_longPressSpeed;
static ACObjectFn    ac_orig_updateSpeed;
static ACDoubleFn    ac_orig_adjustSpeed;

// 自动播放
static ACBoolObjectRetFn ac_orig_autoPlayEnableWithRefer;
static ACBoolRetFn       ac_orig_autoPlayEnable;
static ACBoolRetFn       ac_orig_autoPlayOpen;

// 状态栏
static ACBoolRetFn   ac_orig_prefersStatusBarHidden;
static ACBoolRetFn   ac_orig_prefersHomeIndicatorAutoHidden;

#pragma mark - 挂载辅助

/// 只在方法确实由该类自己实现时才挂载。
/// 用 class_getInstanceMethod 会把父类的实现也算进来，重复挂钩会拿到自己刚写进去的 IMP，
/// 调用时直接无限递归，所以子类补充挂载必须走这个版本。
static IMP ACHookOwnInstanceMethod(Class cls, NSString *selectorName, IMP replacement) {
    if (!cls) return NULL;
    SEL sel = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NULL;

    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    BOOL owned = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(list[i]) == sel) { owned = YES; break; }
    }
    free(list);

    if (!owned) return NULL;
    return method_setImplementation(method, replacement);
}

static IMP ACHookInstanceMethod(Class cls, NSString *selectorName, IMP replacement) {
    if (!cls) return NULL;
    SEL sel = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        ACLog(@"方法不存在 %@ -%@", NSStringFromClass(cls), selectorName);
        return NULL;
    }
    return method_setImplementation(method, replacement);
}

#pragma mark - 播放交互容器

static void ac_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (ac_orig_viewDidAppear) ac_orig_viewDidAppear(self, _cmd, animated);
    ACSetCurrentInteractionVC(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[ACFloatingBall shared] showIfNeeded];
        ACApplyDesiredSpeed();
    });

    // 页面切换后 App 会把播放器重建，补几针把倍速压回去
    for (NSNumber *delay in @[@0.3, @0.8, @1.5]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (ACSpeedIsLocked()) ACApplyDesiredSpeed();
        });
    }
}

static void ac_viewWillDisappear(id self, SEL _cmd, BOOL animated) {
    if (ac_orig_viewWillDisappear) ac_orig_viewWillDisappear(self, _cmd, animated);
    if (ACCurrentInteractionVC() == self) ACSetCurrentInteractionVC(nil);
}

#pragma mark - 作品模型缓存

// 数据绑定时把作品模型存下来，保存功能就不必猜字段名
static void ac_setModel(id self, SEL _cmd, id model) {
    if (ac_orig_setModel) ac_orig_setModel(self, _cmd, model);
    ACNoteAweme(model);
}

static void ac_baseSetModel(id self, SEL _cmd, id model) {
    if (ac_orig_baseSetModel) ac_orig_baseSetModel(self, _cmd, model);
    ACNoteAweme(model);
}

#pragma mark - 双击 -> 评论区

static void ac_doubleTapAtPoint(id self, SEL _cmd, CGPoint point) {
    if ([ACConfig shared].doubleTapCommentEnabled && ACOpenCommentPanel()) {
        return;
    }
    if (ac_orig_doubleTapAtPoint) ac_orig_doubleTapAtPoint(self, _cmd, point);
}

// 信息流 cell 层的双击入口（比 VM 更靠前）
static void ac_feedDoubleClick(id self, SEL _cmd, CGPoint point) {
    if ([ACConfig shared].doubleTapCommentEnabled && ACOpenCommentPanel()) {
        return;
    }
    if (ac_orig_feedDoubleClick) ac_orig_feedDoubleClick(self, _cmd, point);
}

static void ac_doubleTap(id self, SEL _cmd, id gesture) {
    if ([ACConfig shared].doubleTapCommentEnabled && ACOpenCommentPanel()) {
        return;
    }
    if (ac_orig_doubleTap) ac_orig_doubleTap(self, _cmd, gesture);
}

#pragma mark - 倍速：状态拦截

// --- AWEAwemeSpeedManager ---

// 核心闸门：App 每次切视频都会把 currentSpeed 写回 1.0。
// 只要用户设过非 1.0 的全局倍速，这里就把参数顶回去。
static void ac_setCurrentSpeed(id self, SEL _cmd, id speed) {
    ACNoteSpeedManager(self);

    if (ACSpeedIsLocked()) {
        double incoming = speed ? [speed doubleValue] : 1.0;
        if (!speed || !isfinite(incoming) || fabs(incoming - 1.0) < 0.001) {
            speed = @(ACDesiredSpeed());
            ACLog(@"拦截 currentSpeed 重置 -> %.2fx", ACDesiredSpeed());
        }
    }
    if (ac_orig_setCurrentSpeed) ac_orig_setCurrentSpeed(self, _cmd, speed);
}

static void ac_setSpeedHomepage(id self, SEL _cmd, double value) {
    ACNoteSpeedManager(self);
    if (ACSpeedIsLocked() && fabs(value - 1.0) < 0.001) value = ACDesiredSpeed();
    if (ac_orig_setSpeedHomepage) ac_orig_setSpeedHomepage(self, _cmd, value);
}

static void ac_setSpeedMixVideo(id self, SEL _cmd, double value) {
    ACNoteSpeedManager(self);
    if (ACSpeedIsLocked() && fabs(value - 1.0) < 0.001) value = ACDesiredSpeed();
    if (ac_orig_setSpeedMixVideo) ac_orig_setSpeedMixVideo(self, _cmd, value);
}

static void ac_setSpeedInterest(id self, SEL _cmd, double value) {
    ACNoteSpeedManager(self);
    if (ACSpeedIsLocked() && fabs(value - 1.0) < 0.001) value = ACDesiredSpeed();
    if (ac_orig_setSpeedInterest) ac_orig_setSpeedInterest(self, _cmd, value);
}

// resetSpeedControl：清空当前倍速 + itemId。锁速时只重写倍速，不清 itemId。
static void ac_resetSpeedControl(id self, SEL _cmd) {
    ACNoteSpeedManager(self);
    if (ACSpeedIsLocked()) {
        ACCallWithObject(self, NSSelectorFromString(@"setCurrentSpeed:"), @(ACDesiredSpeed()));
        return;
    }
    if (ac_orig_resetSpeedControl) ac_orig_resetSpeedControl(self, _cmd);
}

static void ac_resetSpeedHomepage(id self, SEL _cmd) {
    ACNoteSpeedManager(self);
    if (ACSpeedIsLocked()) return;
    if (ac_orig_resetSpeedHomepage) ac_orig_resetSpeedHomepage(self, _cmd);
}

static void ac_resetSpeedMixVideo(id self, SEL _cmd) {
    ACNoteSpeedManager(self);
    if (ACSpeedIsLocked()) return;
    if (ac_orig_resetSpeedMixVideo) ac_orig_resetSpeedMixVideo(self, _cmd);
}

static void ac_resetSpeedInterest(id self, SEL _cmd) {
    ACNoteSpeedManager(self);
    if (ACSpeedIsLocked()) return;
    if (ac_orig_resetSpeedInterest) ac_orig_resetSpeedInterest(self, _cmd);
}

static void ac_updateSpeed(id self, SEL _cmd, id notification) {
    ACNoteSpeedManager(self);
    if (ac_orig_updateSpeed) ac_orig_updateSpeed(self, _cmd, notification);
}

static void ac_adjustSpeed(id self, SEL _cmd, double value) {
    ACNoteSpeedManager(self);
    if (ac_orig_adjustSpeed) ac_orig_adjustSpeed(self, _cmd, value);
}

// --- AWEPlayInteractionSpeedController ---

// 用户在原生倍速面板选了一个值：同步成新的全局倍速
static void ac_changeSpeed(id self, SEL _cmd, double rate) {
    ACNoteSpeedController(self);
    if (isfinite(rate) && rate > 0.05 && rate < 10.0) {
        ACSetDesiredSpeed(rate);
        ACLog(@"原生面板改速 %.2fx", rate);
    }
    if (ac_orig_changeSpeed) ac_orig_changeSpeed(self, _cmd, rate);
}

static void ac_longPressSpeed(id self, SEL _cmd, id value) {
    ACNoteSpeedController(self);
    double rate = 0;
    if ([value isKindOfClass:[NSNumber class]]) {
        rate = [value doubleValue];
    } else if ([value respondsToSelector:NSSelectorFromString(@"speed")]) {
        @try {
            rate = [[value valueForKey:@"speed"] doubleValue];
        } @catch (NSException *e) { (void)e; }
    }
    if (isfinite(rate) && rate > 0.05 && rate < 10.0) {
        ACSetDesiredSpeed(rate);
    }
    if (ac_orig_longPressSpeed) ac_orig_longPressSpeed(self, _cmd, value);
}

static void ac_setData(id self, SEL _cmd, id data) {
    if (ac_orig_setData) ac_orig_setData(self, _cmd, data);
    ACNoteSpeedController(self);
}

static void ac_willDisplay(id self, SEL _cmd) {
    if (ac_orig_willDisplay) ac_orig_willDisplay(self, _cmd);
    ACNoteSpeedController(self);
    if (ACSpeedIsLocked()) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ACApplyDesiredSpeed();
        });
    }
}

#pragma mark - 倍速：播放器层强制改写

static void ac_updatePlayer(id self, SEL _cmd) {
    if (ac_orig_updatePlayer) ac_orig_updatePlayer(self, _cmd);
    ACNotePlayerController(self);
    if (ACSpeedIsLocked()) {
        ACCallWithDouble(self, NSSelectorFromString(@"setPlaybackRate:"), ACDesiredSpeed());
    }
}

// 播放器每次起播都会重置为 1.0，这里直接改参数
static void ac_setPlaybackRate(id self, SEL _cmd, double rate) {
    if (ACSpeedIsLocked() && !ACSpeedApplying() && fabs(rate - 1.0) < 0.001) {
        rate = ACDesiredSpeed();
    }
    if (ac_orig_setPlaybackRate) ac_orig_setPlaybackRate(self, _cmd, rate);
    ACNotePlayerController(self);
}

static void ac_feedUpdatePlayer(id self, SEL _cmd) {
    if (ac_orig_feedUpdatePlayer) ac_orig_feedUpdatePlayer(self, _cmd);
    ACNotePlayerController(self);
}

static void ac_playOrResume(id self, SEL _cmd, long long mode) {
    if (ac_orig_playOrResume) ac_orig_playOrResume(self, _cmd, mode);

    if (!ACSpeedIsLocked()) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SEL setRate = NSSelectorFromString(@"setPlaybackRate:");
        if ([self respondsToSelector:setRate]) {
            BOOL wasApplying = ACSpeedApplying();
            ACSetSpeedApplying(YES);
            ACCallWithDouble(self, setRate, ACDesiredSpeed());
            ACSetSpeedApplying(wasApplying);
        } else {
            ACApplyDesiredSpeed();
        }
    });
}

static void ac_enginePlay(id self, SEL _cmd) {
    if (ac_orig_enginePlay) ac_orig_enginePlay(self, _cmd);
    ACNoteEngine(self);

    if (!ACSpeedIsLocked()) return;
    double desired = ACDesiredSpeed();
    BOOL wasApplying = ACSpeedApplying();
    ACSetSpeedApplying(YES);
    ACCallWithDouble(self, NSSelectorFromString(@"setPlaybackSpeed:"), desired);
    ACSetSpeedApplying(wasApplying);
}

static void ac_engineSetSpeed(id self, SEL _cmd, double speed) {
    if (ACSpeedIsLocked() && !ACSpeedApplying() && fabs(speed - 1.0) < 0.001) {
        speed = ACDesiredSpeed();
    }
    if (ac_orig_engineSetSpeed) ac_orig_engineSetSpeed(self, _cmd, speed);
    ACNoteEngine(self);
}

#pragma mark - 自动播放

// 抖音默认按「仅 WiFi」「用户关闭」等条件拦住自动播放，这里统一放行，
// 推荐 / 朋友 / 关注 用的都是同一个 manager，所以一处生效就全生效。
static BOOL ac_autoPlayEnableWithRefer(id self, SEL _cmd, id referString) {
    if ([ACConfig shared].autoPlayEnabled) return YES;
    if (ac_orig_autoPlayEnableWithRefer) return ac_orig_autoPlayEnableWithRefer(self, _cmd, referString);
    return NO;
}

// 总闸门：播完回调里先看这个，为 NO 时后面全是白搭
static BOOL ac_autoPlayOpen(id self, SEL _cmd) {
    if ([ACConfig shared].autoPlayEnabled) return YES;
    if (ac_orig_autoPlayOpen) return ac_orig_autoPlayOpen(self, _cmd);
    return NO;
}

static BOOL ac_autoPlayEnable(id self, SEL _cmd) {
    if ([ACConfig shared].autoPlayEnabled) return YES;
    if (ac_orig_autoPlayEnable) return ac_orig_autoPlayEnable(self, _cmd);
    return NO;
}

#pragma mark - 状态栏

static BOOL ac_prefersStatusBarHidden(id self, SEL _cmd) {
    if (ACIsStatusBarHidden()) return YES;
    if (ac_orig_prefersStatusBarHidden) return ac_orig_prefersStatusBarHidden(self, _cmd);
    return NO;
}

static BOOL ac_prefersHomeIndicatorAutoHidden(id self, SEL _cmd) {
    if (ACIsStatusBarHidden()) return YES;
    if (ac_orig_prefersHomeIndicatorAutoHidden) return ac_orig_prefersHomeIndicatorAutoHidden(self, _cmd);
    return NO;
}

#pragma mark - 安装

static BOOL ac_baseHooksInstalled = NO;
static BOOL ac_playerHooksInstalled = NO;
static BOOL ac_speedHooksInstalled = NO;
static BOOL ac_autoPlayHooksInstalled = NO;

static void ACInstallHooks(void) {
    if (ac_baseHooksInstalled && ac_playerHooksInstalled && ac_speedHooksInstalled && ac_autoPlayHooksInstalled) return;

    Class interaction = objc_getClass("AWEPlayInteractionViewController");
    Class likeVM = objc_getClass("AWEPlayInteractionLikeElementViewModel");
    Class speedController = objc_getClass("AWEPlayInteractionSpeedController");
    Class speedManager = objc_getClass("AWEAwemeSpeedManager");
    Class playerVC = objc_getClass("AWEDPlayerViewController");
    Class feedPlayerVC = objc_getClass("AWEDPlayerFeedPlayerViewController");
    Class engine = objc_getClass("TTVideoEngine");
    Class interactiveCell = objc_getClass("AWEFeedInteractiveVideoViewController");

    // 第 1 组：双击评论 + 页面生命周期（必需类齐全才装）
    if (!ac_baseHooksInstalled && interaction && likeVM) {
        ac_orig_viewDidAppear = (ACBoolFn)ACHookInstanceMethod(interaction, @"viewDidAppear:", (IMP)ac_viewDidAppear);
        ac_orig_viewWillDisappear = (ACBoolFn)ACHookInstanceMethod(interaction, @"viewWillDisappear:", (IMP)ac_viewWillDisappear);

        ac_orig_doubleTapAtPoint = (ACPointFn)ACHookInstanceMethod(likeVM, @"onVideoPlayerViewDoubleClickedAtPoint:", (IMP)ac_doubleTapAtPoint);
        ac_orig_doubleTap = (ACObjectFn)ACHookInstanceMethod(likeVM, @"onVideoPlayerViewDoubleClicked:", (IMP)ac_doubleTap);

        if (interactiveCell) {
            ac_orig_feedDoubleClick = (ACPointFn)ACHookInstanceMethod(interactiveCell, @"playableDoubleClickLikeWithPoint:", (IMP)ac_feedDoubleClick);
        }

        // 基类统一接管，子类自己实现了再补一刀（只补自身实现，避免递归）
        ac_orig_prefersStatusBarHidden = (ACBoolRetFn)ACHookInstanceMethod([UIViewController class], @"prefersStatusBarHidden", (IMP)ac_prefersStatusBarHidden);
        ac_orig_prefersHomeIndicatorAutoHidden = (ACBoolRetFn)ACHookInstanceMethod([UIViewController class], @"prefersHomeIndicatorAutoHidden", (IMP)ac_prefersHomeIndicatorAutoHidden);

        // 只挂类自身的实现，避免父子类共用同一个 Method 造成递归
        ac_orig_setModel = (ACObjectFn)ACHookOwnInstanceMethod(interaction, @"setModel:", (IMP)ac_setModel);
        Class baseVC = objc_getClass("AWEAwemeBaseViewController");
        ac_orig_baseSetModel = (ACObjectFn)ACHookOwnInstanceMethod(baseVC, @"setModel:", (IMP)ac_baseSetModel);
        ACHookOwnInstanceMethod(interaction, @"prefersStatusBarHidden", (IMP)ac_prefersStatusBarHidden);

        ac_baseHooksInstalled = YES;
        ACLog(@"基础 hooks 就绪");
    }

    // 第 2 组：播放器 / 播放内核层（不依赖倍速管理器）
    if (!ac_playerHooksInstalled && speedController && playerVC && engine) {
        ac_orig_changeSpeed = (ACDoubleFn)ACHookInstanceMethod(speedController, @"changeSpeed:", (IMP)ac_changeSpeed);
        ac_orig_longPressSpeed = (ACObjectFn)ACHookInstanceMethod(speedController, @"longPressSpeedControlDidChangeSpeed:", (IMP)ac_longPressSpeed);
        ac_orig_setData = (ACObjectFn)ACHookInstanceMethod(speedController, @"setData:", (IMP)ac_setData);
        ac_orig_willDisplay = (ACVoidFn)ACHookInstanceMethod(speedController, @"willDisplay", (IMP)ac_willDisplay);

        ac_orig_updatePlayer = (ACVoidFn)ACHookInstanceMethod(playerVC, @"updatePlayerIfNeeded", (IMP)ac_updatePlayer);
        ac_orig_setPlaybackRate = (ACDoubleFn)ACHookInstanceMethod(playerVC, @"setPlaybackRate:", (IMP)ac_setPlaybackRate);

        if (feedPlayerVC) {
            ac_orig_feedUpdatePlayer = (ACVoidFn)ACHookInstanceMethod(feedPlayerVC, @"updatePlayerIfNeeded", (IMP)ac_feedUpdatePlayer);
            ac_orig_playOrResume = (ACLongLongFn)ACHookInstanceMethod(feedPlayerVC, @"playOrResumeVideo:", (IMP)ac_playOrResume);
        }

        ac_orig_enginePlay = (ACVoidFn)ACHookInstanceMethod(engine, @"play", (IMP)ac_enginePlay);
        ac_orig_engineSetSpeed = (ACDoubleFn)ACHookInstanceMethod(engine, @"setPlaybackSpeed:", (IMP)ac_engineSetSpeed);

        ac_playerHooksInstalled = YES;
        ACLog(@"播放器 hooks 就绪");
    }

    // 第 3 组：倍速管理器状态机（可能懒加载，单独一轮）
    if (!ac_speedHooksInstalled && speedManager) {
        ac_orig_setCurrentSpeed = (ACObjectFn)ACHookInstanceMethod(speedManager, @"setCurrentSpeed:", (IMP)ac_setCurrentSpeed);
        ac_orig_setSpeedHomepage = (ACDoubleFn)ACHookInstanceMethod(speedManager, @"setCurrentSpeedInHomepage:", (IMP)ac_setSpeedHomepage);
        ac_orig_setSpeedMixVideo = (ACDoubleFn)ACHookInstanceMethod(speedManager, @"setCurrentSpeedInMixVideo:", (IMP)ac_setSpeedMixVideo);
        ac_orig_setSpeedInterest = (ACDoubleFn)ACHookInstanceMethod(speedManager, @"setCurrentSpeedInInterestDiscover:", (IMP)ac_setSpeedInterest);
        ac_orig_resetSpeedControl = (ACVoidFn)ACHookInstanceMethod(speedManager, @"resetSpeedControl", (IMP)ac_resetSpeedControl);
        ac_orig_resetSpeedHomepage = (ACVoidFn)ACHookInstanceMethod(speedManager, @"resetSpeedInHomepage", (IMP)ac_resetSpeedHomepage);
        ac_orig_resetSpeedMixVideo = (ACVoidFn)ACHookInstanceMethod(speedManager, @"resetSpeedInMixVideo", (IMP)ac_resetSpeedMixVideo);
        ac_orig_resetSpeedInterest = (ACVoidFn)ACHookInstanceMethod(speedManager, @"resetSpeedInInterestDiscover", (IMP)ac_resetSpeedInterest);
        ac_orig_updateSpeed = (ACObjectFn)ACHookInstanceMethod(speedManager, @"updateSpeed:", (IMP)ac_updateSpeed);
        ac_orig_adjustSpeed = (ACDoubleFn)ACHookInstanceMethod(speedManager, @"adjustCurrentSpeedwithFloatValue:", (IMP)ac_adjustSpeed);

        ac_speedHooksInstalled = YES;
        ACLog(@"倍速 hooks 就绪");
    }

    // 第 4 组：自动播放
    if (!ac_autoPlayHooksInstalled) {
        Class autoPlayManager = objc_getClass("AWEFeedIPhoneAutoPlayManager");
        if (autoPlayManager) {
            ac_orig_autoPlayEnableWithRefer =
                (ACBoolObjectRetFn)ACHookInstanceMethod(autoPlayManager, @"autoPlayEnableWithReferString:", (IMP)ac_autoPlayEnableWithRefer);
            ac_orig_autoPlayEnable =
                (ACBoolRetFn)ACHookInstanceMethod(autoPlayManager, @"autoPlayEnable", (IMP)ac_autoPlayEnable);
            ac_orig_autoPlayOpen =
                (ACBoolRetFn)ACHookInstanceMethod(autoPlayManager, @"isAutoPlayOpen", (IMP)ac_autoPlayOpen);
            if (ac_orig_autoPlayEnableWithRefer || ac_orig_autoPlayEnable || ac_orig_autoPlayOpen) {
                ac_autoPlayHooksInstalled = YES;
                ACLog(@"自动播放 hooks 就绪");
            }
        }
    }
}

static void ACScheduleInstall(NSUInteger attempt) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(attempt == 0 ? 0.2 * NSEC_PER_SEC : 1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ACInstallHooks();
        BOOL done = ac_baseHooksInstalled && ac_playerHooksInstalled && ac_speedHooksInstalled && ac_autoPlayHooksInstalled;
        if (!done && attempt < 30) {
            ACScheduleInstall(attempt + 1);
        }
    });
}

__attribute__((constructor)) static void ac_initialize(void) {
    ACLog(@"dylib loaded");
    ACScheduleInstall(0);
}
