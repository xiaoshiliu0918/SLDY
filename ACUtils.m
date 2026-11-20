#import "ACUtils.h"
#import "ACConfig.h"
#import "ACLog.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

#pragma mark - 悬浮层级窗口

/// 根视图：只有真正命中子视图时才响应触摸，避免整块透明窗口吃掉 App 的手势
@interface ACOverlayRootView : UIView
@end

@implementation ACOverlayRootView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

@interface ACOverlayRootViewController : UIViewController
@end

@implementation ACOverlayRootViewController
- (void)loadView {
    self.view = [[ACOverlayRootView alloc] initWithFrame:[UIScreen mainScreen].bounds];
}
@end

@interface ACOverlayWindow : UIWindow
@end

@implementation ACOverlayWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeFocused { return NO; }

// 关键：iOS 的事件路由会先用 pointInside 决定把触摸派给哪个窗口。
// 如果这里对整屏都返回 YES，随后 hitTest 又返回 nil，这次触摸就被丢弃了，
// 不会落到下层的 App 窗口 —— 表现就是「悬浮球在，但整块屏幕点不动」。
// 所以只在球 / 面板 / 遮罩真正覆盖的位置认领事件，其余一律交还给 App。
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *root = self.rootViewController.view;
    if (!root) return NO;
    CGPoint local = [self convertPoint:point toView:root];
    for (UIView *sub in root.subviews) {
        if (sub.hidden || sub.alpha < 0.01 || !sub.userInteractionEnabled) continue;
        if (CGRectContainsPoint(sub.frame, local)) return YES;
    }
    return NO;
}
@end

UIWindow *ACKeyWindow(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) return w;
            }
        }
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) return w;
            }
        }
    }
    return UIApplication.sharedApplication.keyWindow;
}

UIWindow *ACCreateOverlayWindow(UIWindowLevel level) {
    ACOverlayWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *target = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                target = (UIWindowScene *)scene;
                break;
            }
        }
        if (!target) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    target = (UIWindowScene *)scene;
                    break;
                }
            }
        }
        if (target) window = [[ACOverlayWindow alloc] initWithWindowScene:target];
    }
    if (!window) window = [[ACOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    window.windowLevel = level;
    window.backgroundColor = [UIColor clearColor];
    window.rootViewController = [[ACOverlayRootViewController alloc] init];
    window.hidden = NO;
    return window;
}

#pragma mark - 控制器查找

static __weak UIViewController *gInteractionVC = nil;

void ACSetCurrentInteractionVC(UIViewController *vc) {
    gInteractionVC = vc;
}

UIViewController *ACCurrentInteractionVC(void) {
    return gInteractionVC;
}

static void ACCollectViewControllers(UIViewController *vc, NSMutableArray<UIViewController *> *out, NSUInteger depth) {
    if (!vc || depth > 12 || out.count > 400) return;
    [out addObject:vc];
    for (UIViewController *child in vc.childViewControllers) {
        ACCollectViewControllers(child, out, depth + 1);
    }
    if (vc.presentedViewController) {
        ACCollectViewControllers(vc.presentedViewController, out, depth + 1);
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *child in ((UINavigationController *)vc).viewControllers) {
            ACCollectViewControllers(child, out, depth + 1);
        }
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *selected = ((UITabBarController *)vc).selectedViewController;
        if (selected) ACCollectViewControllers(selected, out, depth + 1);
    }
}

UIViewController *ACFindVCByClassName(NSString *className) {
    Class target = NSClassFromString(className);
    if (!target) return nil;

    NSMutableArray<UIViewController *> *all = [NSMutableArray array];
    UIWindow *window = ACKeyWindow();
    ACCollectViewControllers(window.rootViewController, all, 0);

    for (UIViewController *vc in all) {
        if ([vc isKindOfClass:target]) return vc;
    }

    // popover / 其他 window 兜底
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w == window) continue;
        NSMutableArray<UIViewController *> *list = [NSMutableArray array];
        ACCollectViewControllers(w.rootViewController, list, 0);
        for (UIViewController *vc in list) {
            if ([vc isKindOfClass:target]) return vc;
        }
    }
    return nil;
}

#pragma mark - 视图查找

static void ACCollectViews(UIView *root, NSMutableArray<UIView *> *out, NSUInteger depth) {
    if (!root || depth > 40 || out.count > 4000) return;
    [out addObject:root];
    for (UIView *sub in root.subviews) ACCollectViews(sub, out, depth + 1);
}

UIView *ACViewByClassName(UIView *root, NSString *className) {
    if (!root) return nil;
    NSMutableArray<UIView *> *all = [NSMutableArray array];
    ACCollectViews(root, all, 0);

    UIView *best = nil;
    CGFloat bestArea = 0;
    for (UIView *v in all) {
        NSString *name = NSStringFromClass(v.class);
        if (![name containsString:className]) continue;
        if (v.hidden || v.alpha < 0.05 || !v.window) continue;
        CGRect r = [v convertRect:v.bounds toView:nil];
        CGFloat area = r.size.width * r.size.height;
        if (!isfinite(area) || area <= 0) continue;
        if (area > bestArea) {
            bestArea = area;
            best = v;
        }
    }
    return best;
}

UIView *ACCurrentPlayerView(void) {
    UIViewController *vc = ACCurrentInteractionVC();
    if (!vc) vc = ACFindVCByClassName(@"AWEPlayInteractionViewController");

    UIView *candidate = ACSafeValue(vc, @"playerView");
    if ([candidate isKindOfClass:[UIView class]] && candidate.window &&
        candidate.bounds.size.width > 1 && candidate.bounds.size.height > 1) {
        return candidate;
    }

    UIView *root = ACKeyWindow();
    UIView *v = ACViewByClassName(root, @"DemaciaPlayerView");
    if (!v) v = ACViewByClassName(root, @"PlayerView");
    if (!v) v = ACViewByClassName(root, @"VideoView");
    return v;
}

#pragma mark - 安全消息发送

id ACSafeValue(id obj, NSString *key) {
    if (!obj || key.length == 0) return nil;
    if (![obj respondsToSelector:NSSelectorFromString(key)]) return nil;
    @try {
        return [obj valueForKey:key];
    } @catch (NSException *e) {
        return nil;
    }
}

BOOL ACCallBool(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(obj, sel);
    } @catch (NSException *e) {
        return NO;
    }
}

BOOL ACCallVoid(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) return NO;
    @try {
        ((void (*)(id, SEL))objc_msgSend)(obj, sel);
        return YES;
    } @catch (NSException *e) {
        return NO;
    }
}

BOOL ACCallWithObject(id obj, SEL sel, id arg) {
    if (!obj || ![obj respondsToSelector:sel]) return NO;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(obj, sel, arg);
        return YES;
    } @catch (NSException *e) {
        return NO;
    }
}

BOOL ACCallWithDouble(id obj, SEL sel, double value) {
    if (!obj || ![obj respondsToSelector:sel]) return NO;
    NSMethodSignature *signature = [obj methodSignatureForSelector:sel];
    if (!signature || signature.numberOfArguments < 3) return NO;

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = obj;
    invocation.selector = sel;

    const char *type = [signature getArgumentTypeAtIndex:2];
    switch (type[0]) {
        case 'd':
            [invocation setArgument:&value atIndex:2];
            break;
        case 'f': {
            float f = (float)value;
            [invocation setArgument:&f atIndex:2];
            break;
        }
        case '@': {
            NSNumber *number = @(value);
            [invocation setArgument:&number atIndex:2];
            break;
        }
        case 'q':
        case 'l': {
            long long v = (long long)llround(value);
            [invocation setArgument:&v atIndex:2];
            break;
        }
        case 'i':
        case 's': {
            int v = (int)llround(value);
            [invocation setArgument:&v atIndex:2];
            break;
        }
        default:
            return NO;
    }

    @try {
        [invocation invoke];
        return YES;
    } @catch (NSException *e) {
        return NO;
    }
}

#pragma mark - 评论区

BOOL ACOpenCommentPanel(void) {
    static CFAbsoluteTime lastOpen = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastOpen < 0.35) return YES;   // 去抖，防止多个手势链路重复弹面板

    UIViewController *vc = ACCurrentInteractionVC();
    if (!vc) vc = ACFindVCByClassName(@"AWEPlayInteractionViewController");
    if (!vc) return NO;

    if (ACCallBool(vc, NSSelectorFromString(@"isCommentListShowing"))) return YES;

    lastOpen = now;

    // performCommentAction 在 VC 上只是转发给 panelDelegate(AWEPlayInteractionPanelController)，
    // delegate 为空时调用不会有任何效果，这里先确认它存在，避免白吃掉一次双击。
    id delegate = ACSafeValue(vc, @"panelDelegate");
    BOOL invoked = ACCallVoid(vc, NSSelectorFromString(@"performCommentAction"));
    if (!invoked) {
        ACLog(@"performCommentAction 不可用");
        return NO;
    }
    return delegate != nil;
}

#pragma mark - 作品模型

static __weak id gAwemeModel = nil;

BOOL ACLooksLikeAweme(id obj) {
    if (!obj) return NO;
    return [obj respondsToSelector:NSSelectorFromString(@"video")] ||
           [obj respondsToSelector:NSSelectorFromString(@"images")] ||
           [obj respondsToSelector:NSSelectorFromString(@"awemeId")] ||
           [obj respondsToSelector:NSSelectorFromString(@"awemeID")];
}

void ACNoteAweme(id model) {
    if (ACLooksLikeAweme(model)) gAwemeModel = model;
}

id ACCurrentAweme(void) {
    // 1) 交互容器上的 awemeModel 最贴近「正在播的这条」
    //    （注意不是 model，那个字段不是作品）
    UIViewController *vc = ACCurrentInteractionVC();
    if (!vc) vc = ACFindVCByClassName(@"AWEPlayInteractionViewController");

    id model = ACSafeValue(vc, @"awemeModel");
    if (ACLooksLikeAweme(model)) {
        gAwemeModel = model;
        return model;
    }

    // 2) setModel: 时缓存下来的那份
    //    cell 预加载可能写进相邻作品，所以排在实时字段之后
    id cached = gAwemeModel;
    if (ACLooksLikeAweme(cached)) return cached;

    // 3) 播放基类上的同名字段
    id base = ACSafeValue(vc, @"awemeBaseViewController");
    for (NSString *key in @[@"awemeModel", @"model", @"aweme"]) {
        id candidate = ACSafeValue(base, key);
        if (ACLooksLikeAweme(candidate)) {
            gAwemeModel = candidate;
            return candidate;
        }
    }
    return nil;
}

#pragma mark - 倍速

static __weak id gSpeedController = nil;
static __weak id gPlayerController = nil;
static __weak id gSpeedManager = nil;
static NSHashTable *gEngines = nil;
static BOOL gSpeedApplying = NO;

static id ACPlayerControllerForCurrentVideo(void);

static void ACEnsureRegistries(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gEngines = [NSHashTable weakObjectsHashTable];
    });
}

void ACNoteSpeedController(id controller) {
    if (controller) gSpeedController = controller;
}

void ACNotePlayerController(id controller) {
    if (controller) gPlayerController = controller;
}

void ACNoteSpeedManager(id manager) {
    if (manager) gSpeedManager = manager;
}

void ACNoteEngine(id engine) {
    if (!engine) return;
    ACEnsureRegistries();
    @synchronized (gEngines) {
        [gEngines addObject:engine];
    }
}

id ACPlayerController(void) {
    return gPlayerController;
}

id ACSpeedManager(void) {
    if (gSpeedManager) return gSpeedManager;

    UIViewController *vc = ACCurrentInteractionVC();
    if (!vc) vc = ACFindVCByClassName(@"AWEPlayInteractionViewController");

    // 三条来源依次尝试：交互容器 -> 播放基类 -> 播放器控制器
    id owners[3] = {
        vc,
        ACSafeValue(vc, @"awemeBaseViewController"),
        ACPlayerControllerForCurrentVideo()
    };
    for (NSUInteger i = 0; i < 3; i++) {
        id manager = ACSafeValue(owners[i], @"speedManager");
        if (manager) {
            gSpeedManager = manager;
            return manager;
        }
    }
    return nil;
}

/// 优先拿「当前这条视频」的播放器控制器：AWEDemaciaPlayerView.playerController
static id ACPlayerControllerForCurrentVideo(void) {
    id controller = ACSafeValue(ACCurrentPlayerView(), @"playerController");
    return controller ?: ACPlayerController();
}

double ACDesiredSpeed(void) {
    double rate = [ACConfig shared].playbackRate;
    if (!isfinite(rate) || rate <= 0.05) rate = 1.0;
    return MIN(3.0, MAX(0.25, rate));
}

BOOL ACSpeedIsLocked(void) {
    return fabs(ACDesiredSpeed() - 1.0) > 0.001;
}

BOOL ACSpeedApplying(void) {
    return gSpeedApplying;
}

void ACSetSpeedApplying(BOOL applying) {
    gSpeedApplying = applying;
}

void ACSetDesiredSpeed(double rate) {
    if (!isfinite(rate) || rate <= 0.05) rate = 1.0;
    rate = MIN(3.0, MAX(0.25, rate));
    if (fabs([ACConfig shared].playbackRate - rate) < 0.0001) return;
    [ACConfig shared].playbackRate = rate;
    ACLog(@"全局倍速 %.2fx", rate);
}

BOOL ACApplyDesiredSpeed(void) {
    return ACApplySpeed(ACDesiredSpeed());
}

BOOL ACApplySpeed(double rate) {
    if (!isfinite(rate) || rate <= 0.05) rate = 1.0;
    rate = MIN(3.0, MAX(0.25, rate));
    ACSetDesiredSpeed(rate);
    ACEnsureRegistries();

    BOOL wasApplying = gSpeedApplying;
    gSpeedApplying = YES;

    BOOL applied = NO;
    SEL setRateSel = NSSelectorFromString(@"setPlaybackRate:");
    SEL setSpeedSel = NSSelectorFromString(@"setPlaybackSpeed:");

    id player = ACPlayerControllerForCurrentVideo();
    if (player) applied = ACCallWithDouble(player, setRateSel, rate) || applied;

    NSArray *engines = nil;
    @synchronized (gEngines) {
        engines = gEngines.allObjects;
    }
    for (id engine in engines) {
        if (ACCallWithDouble(engine, setSpeedSel, rate)) applied = YES;
    }

    if (!applied) {
        id controller = gSpeedController;
        if (controller) applied = ACCallWithDouble(controller, NSSelectorFromString(@"changeSpeed:"), rate);
    }

    // 同步 App 自己的倍速状态，保证切集/滑动时 App 主动把速率设成同一值
    id manager = ACSpeedManager();
    if (manager) {
        ACCallWithObject(manager, NSSelectorFromString(@"setCurrentSpeed:"), @(rate));
        applied = YES;
    }

    gSpeedApplying = wasApplying;
    return applied;
}



#pragma mark - 状态栏

static BOOL gStatusBarForcedHidden = NO;

BOOL ACIsStatusBarHidden(void) {
    return gStatusBarForcedHidden;
}

/// 只让整棵控制器树重新询问状态栏 / 小白条的显示状态，不做任何视觉遮挡。
/// （早期版本压过一个同层级的黑窗口，清屏后会在顶部留一条黑边，已去掉。）
void ACSetStatusBarHidden(BOOL hidden) {
    gStatusBarForcedHidden = hidden;

    UIWindow *key = ACKeyWindow();
    UIViewController *root = key.rootViewController;
    if (!root) return;

    NSMutableArray<UIViewController *> *all = [NSMutableArray array];
    ACCollectViewControllers(root, all, 0);

    for (UIViewController *vc in all) {
        [vc setNeedsStatusBarAppearanceUpdate];
        if (@available(iOS 11.0, *)) {
            [vc setNeedsUpdateOfHomeIndicatorAutoHidden];
        }
    }

    [UIView animateWithDuration:0.25 animations:^{
        [root.view layoutIfNeeded];
    }];
}
