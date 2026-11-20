#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 窗口

/// 当前前台活跃的 keyWindow
UIWindow * _Nullable ACKeyWindow(void);

/// 创建悬浮层级窗口（自动挂到当前活跃 UIWindowScene）
UIWindow * _Nullable ACCreateOverlayWindow(UIWindowLevel level);

#pragma mark - 控制器 / 视图

/// 当前正在显示的 AWEPlayInteractionViewController（播放交互容器）
UIViewController * _Nullable ACCurrentInteractionVC(void);
void ACSetCurrentInteractionVC(UIViewController * _Nullable vc);

/// 屏幕上真正看得见的那条视频的交互容器（按屏幕中心命中判断，回滑后依然准确）
UIViewController * _Nullable ACVisibleInteractionVC(void);

/// 按类名在控制器树里查找
UIViewController * _Nullable ACFindVCByClassName(NSString *className);

/// 按类名在视图树里查找（返回面积最大的那个）
UIView * _Nullable ACViewByClassName(UIView *root, NSString *className);

/// 当前视频播放视图（优先取 interactionVC.playerView，失败则全窗口搜索）
UIView * _Nullable ACCurrentPlayerView(void);

#pragma mark - 安全消息发送

/// 安全 KVC：键不存在、类型不符、抛异常都返回 nil，省掉满屏的 @try/@catch
id _Nullable ACSafeValue(id _Nullable obj, NSString *key);

BOOL ACCallBool(id _Nullable obj, SEL sel);
BOOL ACCallVoid(id _Nullable obj, SEL sel);
BOOL ACCallWithObject(id _Nullable obj, SEL sel, id _Nullable arg);
/// 自动适配 double / float / NSNumber / 整数 参数类型
BOOL ACCallWithDouble(id _Nullable obj, SEL sel, double value);

#pragma mark - 业务

/// 打开评论区，成功接管返回 YES
BOOL ACOpenCommentPanel(void);

/// AwemeLite 的倍速管理器（AWEAwemeSpeedManager）
id _Nullable ACSpeedManager(void);

/// 记录/读取运行时抓到的倍速控制器（AWEPlayInteractionSpeedController）
void ACNoteSpeedController(id _Nullable controller);

/// 记录运行时抓到的倍速管理器（AWEAwemeSpeedManager）
void ACNoteSpeedManager(id _Nullable manager);

/// 记录/读取运行时抓到的播放器控制器（AWEDPlayerViewController）
void ACNotePlayerController(id _Nullable controller);
id _Nullable ACPlayerController(void);

/// 记录运行时抓到的播放内核（TTVideoEngine）
void ACNoteEngine(id _Nullable engine);

#pragma mark - 作品模型

/// 判断一个对象是否像作品模型（带 video / images / awemeId 之一）
BOOL ACLooksLikeAweme(id _Nullable obj);

/// 记录当前作品模型（挂在 setModel: 上，数据绑定时自动缓存）
void ACNoteAweme(id _Nullable model);

/// 当前作品模型：优先缓存，其次交互容器，再退回视图树反查
id _Nullable ACCurrentAweme(void);

#pragma mark - 全局倍速

/// 当前期望倍速（持久化值）
double ACDesiredSpeed(void);
/// 是否处于「非 1.0 倍速」状态，需要压制 App 的重置
BOOL ACSpeedIsLocked(void);
/// 是否正在由本插件主动下发速率（防止 hook 递归改写）
BOOL ACSpeedApplying(void);
void ACSetSpeedApplying(BOOL applying);
/// 用户主动改速（悬浮球 / 原生倍速面板），会同步到全局并落盘
void ACSetDesiredSpeed(double rate);
/// 把期望倍速下发给当前播放器 / 全部已知内核
BOOL ACApplyDesiredSpeed(void);
/// 应用倍速（多级兜底，返回是否至少有一条链路成功）
BOOL ACApplySpeed(double rate);

#pragma mark - 状态栏

/// 全屏时压制状态栏
void ACSetStatusBarHidden(BOOL hidden);
BOOL ACIsStatusBarHidden(void);

NS_ASSUME_NONNULL_END
