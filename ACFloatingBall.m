#import "ACFloatingBall.h"
#import "ACConfig.h"
#import "ACUtils.h"
#import "ACFullscreenController.h"
#import "ACMediaSaver.h"
#import "ACLog.h"
#import <math.h>

static const CGFloat kBallSize      = 56.0;
static const CGFloat kCollapsedSize = 28.0;
static const CGFloat kPanelWidth    = 252.0;
static const CGFloat kPanelHeight   = 304.0;
static const CGFloat kPanelPad      = 14.0;
static const CGFloat kPanelGap      = 10.0;
static const CGFloat kEdgeInset     = 4.0;
static const CGFloat kPanelMargin   = 8.0;

static NSString *ACRateText(double value) {
    if (fabs(value - round(value)) < 0.001) {
        return [NSString stringWithFormat:@"%.0f×", value];
    }
    if (fabs(value * 10.0 - round(value * 10.0)) < 0.001) {
        return [NSString stringWithFormat:@"%.1f×", value];
    }
    return [NSString stringWithFormat:@"%.2f×", value];
}

@interface ACFloatingBall () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIView *ball;
@property (nonatomic, strong) UILabel *ballLabel;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) NSMutableArray<UIButton *> *speedButtons;
@property (nonatomic, strong) UISwitch *commentSwitch;
@property (nonatomic, strong) UIButton *portraitButton;
@property (nonatomic, strong) UIButton *landscapeButton;
@property (nonatomic, strong) UIButton *customSpeedButton;
@property (nonatomic, strong) UIButton *saveButton;
@property (nonatomic, strong) UISwitch *autoPlaySwitch;
@property (nonatomic, strong) UITapGestureRecognizer *dismissTap;
@property (nonatomic, strong) UITapGestureRecognizer *tripleDoubleTap;
@property (nonatomic, assign) BOOL panelOpen;
@property (nonatomic, assign) CGPoint ballCenter;
@property (nonatomic, assign) CGPoint dragOffset;
@end

@implementation ACFloatingBall

+ (instancetype)shared {
    static ACFloatingBall *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ACFloatingBall alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _speedButtons = [NSMutableArray array];
        _ballCenter = CGPointMake(200, 300);
    }
    return self;
}

#pragma mark - 几何

- (CGFloat)currentBallSize {
    return [ACConfig shared].ballCollapsed ? kCollapsedSize : kBallSize;
}

- (CGSize)screenSize {
    UIWindow *host = ACKeyWindow();
    if (host) return host.bounds.size;
    return [UIScreen mainScreen].bounds.size;
}

- (UIEdgeInsets)safeInsets {
    UIWindow *host = ACKeyWindow();
    if (host) {
        if (@available(iOS 11.0, *)) {
            return host.safeAreaInsets;
        }
    }
    return UIEdgeInsetsZero;
}

- (CGPoint)clampCenter:(CGPoint)center {
    CGSize screen = [self screenSize];
    UIEdgeInsets inset = [self safeInsets];
    CGFloat half = [self currentBallSize] / 2.0;
    CGFloat x = MAX(half + kEdgeInset, MIN(screen.width - half - kEdgeInset, center.x));
    CGFloat y = MAX(inset.top + half + kEdgeInset, MIN(screen.height - inset.bottom - half - kEdgeInset, center.y));
    return CGPointMake(x, y);
}

/// 窗口只包住球本身，绝不覆盖整屏 —— 这是「不挡 App 触摸」的前提
- (void)moveBallToCenter:(CGPoint)center {
    CGFloat size = [self currentBallSize];
    self.ballCenter = center;
    self.window.frame = CGRectMake(center.x - size / 2.0, center.y - size / 2.0, size, size);
    [self.window layoutIfNeeded];
    self.ball.frame = CGRectMake(0, 0, size, size);
    self.ball.layer.cornerRadius = size / 2.0;
}

#pragma mark - 显示

- (void)showIfNeeded {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self showIfNeeded]; });
        return;
    }

    // 三指双击关掉之后，页面切换也不能把它弹回来
    [self ensureTripleTapGesture];

    if (![ACConfig shared].ballVisible) {
        if (self.window) self.window.hidden = YES;
        return;
    }

    if (self.window) {
        self.window.hidden = NO;
        [self moveBallToCenter:[self clampCenter:self.ballCenter]];
        return;
    }

    UIWindow *window = ACCreateOverlayWindow(UIWindowLevelAlert + 20);
    window.frame = CGRectMake(0, 0, kBallSize, kBallSize);
    self.window = window;

    [self buildBall];
    [window.rootViewController.view addSubview:self.ball];

    [self buildPanel];
    self.panel.hidden = YES;
    [window.rootViewController.view addSubview:self.panel];

    [self applyCollapsedState];

    CGSize screen = [self screenSize];
    CGPoint norm = [ACConfig shared].ballPosition;
    CGPoint center = CGPointMake(norm.x * screen.width, norm.y * screen.height);
    [self moveBallToCenter:[self clampCenter:center]];

    [self refreshSpeed];
}

- (void)hide {
    [self removeDismissTap];
    self.window.hidden = YES;
}


#pragma mark - 三指双击显隐

- (void)ensureTripleTapGesture {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self ensureTripleTapGesture]; });
        return;
    }
    UIWindow *key = ACKeyWindow();
    if (!key) return;
    if (self.tripleDoubleTap && self.tripleDoubleTap.view == key) return;

    if (self.tripleDoubleTap) {
        [self.tripleDoubleTap.view removeGestureRecognizer:self.tripleDoubleTap];
    }

    UITapGestureRecognizer *gesture =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTripleDoubleTap:)];
    gesture.numberOfTouchesRequired = 3;   // 三指
    gesture.numberOfTapsRequired = 2;      // 双击
    gesture.cancelsTouchesInView = NO;     // 不干扰 App 自己的手势
    gesture.delegate = self;
    [key addGestureRecognizer:gesture];
    self.tripleDoubleTap = gesture;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)handleTripleDoubleTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    [self toggleVisibility];
}

- (void)toggleVisibility {
    BOOL show = ![ACConfig shared].ballVisible;
    [ACConfig shared].ballVisible = show;

    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback prepare];
    [feedback impactOccurred];

    if (show) {
        if (self.window) {
            self.window.hidden = NO;
            [self moveBallToCenter:[self clampCenter:self.ballCenter]];
        } else {
            [self showIfNeeded];
        }
        [self showToast:@"悬浮球已显示"];
    } else {
        if (self.panelOpen) [self closePanel];
        [self removeDismissTap];
        self.window.hidden = YES;
        ACLog(@"悬浮球已隐藏，三指双击恢复");
    }
}

#pragma mark - 悬浮球

- (void)buildBall {
    UIView *ball = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kBallSize, kBallSize)];
    ball.backgroundColor = [UIColor colorWithWhite:0.09 alpha:0.92];
    ball.layer.cornerRadius = kBallSize / 2.0;
    ball.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
    ball.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.16].CGColor;
    ball.layer.shadowColor = [UIColor blackColor].CGColor;
    ball.layer.shadowOpacity = 0.35;
    ball.layer.shadowRadius = 10;
    ball.layer.shadowOffset = CGSizeMake(0, 3);
    ball.isAccessibilityElement = YES;
    ball.accessibilityLabel = @"播放助手";

    UILabel *label = [[UILabel alloc] initWithFrame:ball.bounds];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold];
    label.userInteractionEnabled = NO;
    [ball addSubview:label];
    self.ballLabel = label;

    [ball addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleBallTap)]];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleBallPan:)];
    pan.delegate = self;
    [ball addGestureRecognizer:pan];

    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleBallLongPress:)];
    press.minimumPressDuration = 0.55;
    [ball addGestureRecognizer:press];

    self.ball = ball;
}

- (void)handleBallTap {
    if ([ACConfig shared].ballCollapsed) {
        [ACConfig shared].ballCollapsed = NO;
        [self applyCollapsedState];
    }
    self.panelOpen ? [self closePanel] : [self openPanel];
}

- (void)handleBallLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    [self closePanel];
    [ACConfig shared].ballCollapsed = ![ACConfig shared].ballCollapsed;
    [self applyCollapsedState];
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];
}

- (void)handleBallPan:(UIPanGestureRecognizer *)gesture {
    UIWindow *host = ACKeyWindow();
    if (!host) return;

    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self closePanel];
        CGPoint point = [gesture locationInView:host];
        self.dragOffset = CGPointMake(self.ballCenter.x - point.x, self.ballCenter.y - point.y);
        return;
    }

    CGPoint point = [gesture locationInView:host];
    CGPoint center = CGPointMake(point.x + self.dragOffset.x, point.y + self.dragOffset.y);
    [self moveBallToCenter:[self clampCenter:center]];

    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled) {
        [self snapToEdge];
    }
}

- (void)snapToEdge {
    CGSize screen = [self screenSize];
    CGFloat half = [self currentBallSize] / 2.0;
    CGPoint center = self.ballCenter;
    CGFloat targetX = (center.x > screen.width / 2.0) ? (screen.width - half - kEdgeInset) : (half + kEdgeInset);
    CGPoint target = [self clampCenter:CGPointMake(targetX, center.y)];

    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        [self moveBallToCenter:target];
    } completion:^(BOOL finished) {
        [self persistBallPosition];
    }];
}

- (void)persistBallPosition {
    CGSize screen = [self screenSize];
    if (screen.width <= 0 || screen.height <= 0) return;
    [ACConfig shared].ballPosition = CGPointMake(self.ballCenter.x / screen.width,
                                                 self.ballCenter.y / screen.height);
}

- (void)applyCollapsedState {
    BOOL collapsed = [ACConfig shared].ballCollapsed;
    self.ballLabel.text = collapsed ? @"•" : ACRateText([ACConfig shared].playbackRate);
    self.ballLabel.font = collapsed
        ? [UIFont systemFontOfSize:22 weight:UIFontWeightBold]
        : [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold];
    self.ball.alpha = collapsed ? 0.55 : 1.0;
    if (self.window) {
        [self moveBallToCenter:[self clampCenter:self.ballCenter]];
    }
}

#pragma mark - 面板

- (void)buildPanel {
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPanelWidth, kPanelHeight)];
    panel.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.97];
    panel.layer.cornerRadius = 18;
    panel.layer.borderWidth = 0.5;
    panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
    panel.layer.shadowColor = [UIColor blackColor].CGColor;
    panel.layer.shadowOpacity = 0.4;
    panel.layer.shadowRadius = 18;
    panel.layer.shadowOffset = CGSizeMake(0, 8);
    self.panel = panel;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(kPanelPad, 15, 150, 18)];
    title.text = @"播放助手";
    title.textColor = [UIColor colorWithWhite:1 alpha:0.92];
    title.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [panel addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(kPanelWidth - kPanelPad - 26, 11, 26, 26);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor colorWithWhite:1 alpha:0.55] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [close addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:close];

    NSArray<NSNumber *> *rates = @[@0.5, @0.75, @1.0, @1.25, @1.5, @2.0, @2.5, @3.0];
    CGFloat gap = 8.0;
    CGFloat itemWidth = (kPanelWidth - kPanelPad * 2 - gap * 3) / 4.0;
    CGFloat itemHeight = 31.0;
    CGFloat startY = 42.0;

    for (NSUInteger i = 0; i < rates.count; i++) {
        CGFloat value = rates[i].doubleValue;
        NSUInteger row = i / 4;
        NSUInteger col = i % 4;
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.frame = CGRectMake(kPanelPad + col * (itemWidth + gap),
                                  startY + row * (itemHeight + gap),
                                  itemWidth, itemHeight);
        button.tag = (NSInteger)(value * 100);
        button.layer.cornerRadius = 9;
        button.layer.borderWidth = 0.5;
        button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.09];
        button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.08].CGColor;
        [button setTitle:ACRateText(value) forState:UIControlStateNormal];
        [button setTitleColor:[UIColor colorWithWhite:1 alpha:0.9] forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
        [button addTarget:self action:@selector(handleSpeedTap:) forControlEvents:UIControlEventTouchUpInside];
        [panel addSubview:button];
        [self.speedButtons addObject:button];
    }

    // 第三行：自定义倍速 + 保存作品
    CGFloat wideWidth = itemWidth * 2 + gap;
    CGFloat row3Y = startY + 2 * (itemHeight + gap);

    UIButton *custom = [self actionButtonWithTitle:@"自定义…" frame:CGRectMake(kPanelPad, row3Y, wideWidth, itemHeight)];
    [custom addTarget:self action:@selector(handleCustomSpeed) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:custom];
    self.customSpeedButton = custom;

    UIButton *save = [self actionButtonWithTitle:@"保存视频"
                                           frame:CGRectMake(kPanelPad + wideWidth + gap, row3Y, wideWidth, itemHeight)];
    [save addTarget:self action:@selector(handleSaveMedia) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:save];
    self.saveButton = save;

    UIView *divider = [[UIView alloc] initWithFrame:CGRectMake(kPanelPad, 163, kPanelWidth - kPanelPad * 2, 0.5)];
    divider.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    [panel addSubview:divider];

    UILabel *commentLabel = [[UILabel alloc] initWithFrame:CGRectMake(kPanelPad, 172, 160, 30)];
    commentLabel.text = @"双击打开评论区";
    commentLabel.textColor = [UIColor colorWithWhite:1 alpha:0.88];
    commentLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightRegular];
    [panel addSubview:commentLabel];

    UISwitch *commentSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(kPanelWidth - kPanelPad - 46, 174, 44, 26)];
    commentSwitch.transform = CGAffineTransformMakeScale(0.8, 0.8);
    commentSwitch.onTintColor = [UIColor colorWithRed:0.996 green:0.173 blue:0.333 alpha:1.0];
    commentSwitch.on = [ACConfig shared].doubleTapCommentEnabled;
    [commentSwitch addTarget:self action:@selector(handleCommentSwitch:) forControlEvents:UIControlEventValueChanged];
    [panel addSubview:commentSwitch];
    self.commentSwitch = commentSwitch;

    UILabel *autoPlayLabel = [[UILabel alloc] initWithFrame:CGRectMake(kPanelPad, 206, 160, 30)];
    autoPlayLabel.text = @"自动播放";
    autoPlayLabel.textColor = [UIColor colorWithWhite:1 alpha:0.88];
    autoPlayLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightRegular];
    [panel addSubview:autoPlayLabel];

    UISwitch *autoPlaySwitch = [[UISwitch alloc] initWithFrame:CGRectMake(kPanelWidth - kPanelPad - 46, 208, 44, 26)];
    autoPlaySwitch.transform = CGAffineTransformMakeScale(0.8, 0.8);
    autoPlaySwitch.onTintColor = [UIColor colorWithRed:0.996 green:0.173 blue:0.333 alpha:1.0];
    autoPlaySwitch.on = [ACConfig shared].autoPlayEnabled;
    [autoPlaySwitch addTarget:self action:@selector(handleAutoPlaySwitch:) forControlEvents:UIControlEventValueChanged];
    [panel addSubview:autoPlaySwitch];
    self.autoPlaySwitch = autoPlaySwitch;

    UIView *divider2 = [[UIView alloc] initWithFrame:CGRectMake(kPanelPad, 244, kPanelWidth - kPanelPad * 2, 0.5)];
    divider2.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    [panel addSubview:divider2];

    CGFloat buttonY = kPanelHeight - 12 - 38;
    CGFloat buttonWidth = (kPanelWidth - kPanelPad * 2 - 8) / 2.0;

    UIButton *portrait = [self actionButtonWithTitle:@"竖屏全屏" frame:CGRectMake(kPanelPad, buttonY, buttonWidth, 38)];
    portrait.tag = 0;
    [portrait addTarget:self action:@selector(handleFullscreenTap:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:portrait];
    self.portraitButton = portrait;

    UIButton *landscape = [self actionButtonWithTitle:@"横屏全屏" frame:CGRectMake(kPanelPad + buttonWidth + 8, buttonY, buttonWidth, 38)];
    landscape.tag = 1;
    [landscape addTarget:self action:@selector(handleFullscreenTap:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:landscape];
    self.landscapeButton = landscape;
}

- (UIButton *)actionButtonWithTitle:(NSString *)title frame:(CGRect)frame {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = frame;
    button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    button.layer.cornerRadius = 10;
    button.layer.borderWidth = 0.5;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithWhite:1 alpha:0.92] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    return button;
}

- (void)openPanel {
    if (self.panelOpen || !self.window) return;

    CGSize screen = [self screenSize];
    UIEdgeInsets inset = [self safeInsets];
    CGFloat half = [self currentBallSize] / 2.0;

    CGRect ballRect = CGRectMake(self.ballCenter.x - half, self.ballCenter.y - half, half * 2, half * 2);

    CGFloat panelX;
    if (self.ballCenter.x > screen.width / 2.0) {
        panelX = CGRectGetMinX(ballRect) - kPanelGap - kPanelWidth;
    } else {
        panelX = CGRectGetMaxX(ballRect) + kPanelGap;
    }
    panelX = MAX(kPanelMargin, MIN(screen.width - kPanelWidth - kPanelMargin, panelX));

    CGFloat panelY = self.ballCenter.y - kPanelHeight / 2.0;
    panelY = MAX(inset.top + kPanelMargin,
                 MIN(screen.height - inset.bottom - kPanelHeight - kPanelMargin, panelY));

    CGRect panelRect = CGRectMake(panelX, panelY, kPanelWidth, kPanelHeight);
    CGRect unionRect = CGRectUnion(ballRect, panelRect);

    self.panelOpen = YES;

    // 窗口扩大到「球 + 面板」的并集，其余屏幕区域仍然不属于这个窗口
    self.window.frame = unionRect;
    [self.window layoutIfNeeded];
    self.ball.frame = CGRectOffset(ballRect, -unionRect.origin.x, -unionRect.origin.y);
    self.panel.frame = CGRectOffset(panelRect, -unionRect.origin.x, -unionRect.origin.y);
    self.panel.hidden = NO;
    self.panel.alpha = 0;
    self.panel.transform = CGAffineTransformMakeScale(0.9, 0.9);

    [self updateFullscreenButtons];
    [self updateSaveButtonTitle];
    [self refreshSpeed];
    [self installDismissTap];

    [UIView animateWithDuration:0.2 delay:0 usingSpringWithDamping:0.88 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.panel.alpha = 1;
        self.panel.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)closePanel {
    if (!self.panelOpen) return;
    self.panelOpen = NO;
    [self removeDismissTap];

    [UIView animateWithDuration:0.14 animations:^{
        self.panel.alpha = 0;
    } completion:^(BOOL finished) {
        if (self.panelOpen) return;
        self.panel.hidden = YES;
        self.panel.alpha = 1;
        [self moveBallToCenter:[self clampCenter:self.ballCenter]];
    }];
}

- (void)updateFullscreenButtons {
    BOOL active = [ACFullscreenController shared].isActive;
    [self.portraitButton setTitle:(active ? @"退出全屏" : @"竖屏全屏") forState:UIControlStateNormal];
    [self.landscapeButton setTitle:(active ? @"切换横竖" : @"横屏全屏") forState:UIControlStateNormal];
}

#pragma mark - 面板外点击关闭

- (void)installDismissTap {
    UIWindow *host = ACKeyWindow();
    if (!host) return;
    [self removeDismissTap];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closePanel)];
    tap.cancelsTouchesInView = YES;
    [host addGestureRecognizer:tap];
    self.dismissTap = tap;
}

- (void)removeDismissTap {
    if (!self.dismissTap) return;
    [self.dismissTap.view removeGestureRecognizer:self.dismissTap];
    self.dismissTap = nil;
}

#pragma mark - 动作


- (void)handleCustomSpeed {
    [self closePanel];

    UIViewController *top = ACKeyWindow().rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if (!top) return;

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"自定义倍速"
                                            message:@"输入 0.25 ~ 3.0 之间的值"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeDecimalPad;
        field.placeholder = @"1.75";
        field.text = [NSString stringWithFormat:@"%.2f", [ACConfig shared].playbackRate];
    }];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"应用" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UITextField *field = alert.textFields.firstObject;
        double value = [field.text doubleValue];
        if (!isfinite(value) || value < 0.25 || value > 3.0) {
            [weakSelf showToast:@"请输入 0.25 ~ 3.0"];
            return;
        }
        ACApplySpeed(value);
        [weakSelf refreshSpeed];
        [weakSelf showToast:[NSString stringWithFormat:@"已切到 %@", ACRateText(value)]];
    }]];

    [top presentViewController:alert animated:YES completion:nil];
}

- (void)handleSaveMedia {
    [self closePanel];
    [self showToast:@"正在解析作品…"];

    __weak typeof(self) weakSelf = self;
    [[ACMediaSaver shared] saveCurrentAwemeWithCompletion:^(NSString *message) {
        [weakSelf showToast:message];
    }];
}

- (void)handleAutoPlaySwitch:(UISwitch *)sender {
    [ACConfig shared].autoPlayEnabled = sender.on;
    [self showToast:sender.on ? @"已开启自动播放" : @"已关闭自动播放"];
}

- (void)updateSaveButtonTitle {
    BOOL isImage = [ACMediaSaver currentAwemeIsImage];
    [self.saveButton setTitle:(isImage ? @"保存图片" : @"保存视频") forState:UIControlStateNormal];
}

- (void)handleSpeedTap:(UIButton *)sender {
    double rate = sender.tag / 100.0;
    BOOL applied = ACApplySpeed(rate);
    [self refreshSpeed];

    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];

    if (!applied) {
        [self showToast:@"没有可调节的播放器"];
    }
}

- (void)handleCommentSwitch:(UISwitch *)sender {
    [ACConfig shared].doubleTapCommentEnabled = sender.on;
}

- (void)handleFullscreenTap:(UIButton *)sender {
    ACFullscreenController *controller = [ACFullscreenController shared];

    if (controller.isActive) {
        if (sender.tag == 0) {
            [controller exit];
        } else {
            [controller toggleOrientation];
        }
        [ACConfig shared].fullscreenLandscape = controller.landscape;
        [self closePanel];
        return;
    }

    [self closePanel];
    controller.landscape = (sender.tag == 1);
    [ACConfig shared].fullscreenLandscape = controller.landscape;
    if (![controller enter]) {
        [self showToast:@"没找到视频画面，先播一条视频再试"];
    }
}

- (void)refreshSpeed {
    double rate = [ACConfig shared].playbackRate;
    if (![ACConfig shared].ballCollapsed) {
        self.ballLabel.text = ACRateText(rate);
    }

    for (UIButton *button in self.speedButtons) {
        BOOL selected = fabs(button.tag / 100.0 - rate) < 0.001;
        button.backgroundColor = selected
            ? [UIColor colorWithRed:0.996 green:0.173 blue:0.333 alpha:1.0]
            : [UIColor colorWithWhite:1 alpha:0.09];
        button.layer.borderColor = selected
            ? [UIColor colorWithRed:1 green:0.35 blue:0.5 alpha:0.9].CGColor
            : [UIColor colorWithWhite:1 alpha:0.08].CGColor;
    }
}

/// 提示条挂在 App 主窗口底部：不新建窗口、不接管触摸，
/// 面板已经收起时（保存结果、全屏失败等）也能正常提示。
- (void)showToast:(NSString *)text {
    if (text.length == 0) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self showToast:text]; });
        return;
    }

    UIWindow *host = ACKeyWindow();
    if (!host) return;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.textAlignment = NSTextAlignmentCenter;
    label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
    label.layer.cornerRadius = 15;
    label.clipsToBounds = YES;
    label.userInteractionEnabled = NO;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.85;
    [label sizeToFit];

    CGRect frame = label.frame;
    frame.size.width = MIN(host.bounds.size.width - 48, frame.size.width + 28);
    frame.size.height = 30;

    CGFloat bottomInset = 0;
    if (@available(iOS 11.0, *)) bottomInset = host.safeAreaInsets.bottom;
    frame.origin = CGPointMake((host.bounds.size.width - frame.size.width) / 2.0,
                               host.bounds.size.height - bottomInset - 96);
    label.frame = frame;

    [host addSubview:label];
    label.alpha = 0;
    [UIView animateWithDuration:0.18 animations:^{
        label.alpha = 1;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.3 delay:1.4 options:0 animations:^{
            label.alpha = 0;
        } completion:^(BOOL finished) {
            [label removeFromSuperview];
        }];
    }];
}

@end
