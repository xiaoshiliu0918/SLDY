#import "ACConfig.h"

static NSString *const kACDoubleTapComment = @"ACDoubleTapComment";
static NSString *const kACFullscreenLandscape = @"ACFullscreenLandscape";
static NSString *const kACPlaybackRate = @"ACPlaybackRate";
static NSString *const kACBallX = @"ACBallX";
static NSString *const kACBallY = @"ACBallY";
static NSString *const kACBallCollapsed = @"ACBallCollapsed";
static NSString *const kACAutoPlay = @"ACAutoPlay";

@implementation ACConfig

+ (instancetype)shared {
    static ACConfig *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ACConfig alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        // 首次启动默认开启双击评论
        if ([ud objectForKey:kACDoubleTapComment] == nil) {
            _doubleTapCommentEnabled = YES;
        } else {
            _doubleTapCommentEnabled = [ud boolForKey:kACDoubleTapComment];
        }
        _fullscreenLandscape = [ud boolForKey:kACFullscreenLandscape];
        _playbackRate = [ud objectForKey:kACPlaybackRate] ? [ud doubleForKey:kACPlaybackRate] : 1.0;
        if (_playbackRate <= 0.0) _playbackRate = 1.0;

        CGFloat x = [ud objectForKey:kACBallX] ? [ud doubleForKey:kACBallX] : 0.88;
        CGFloat y = [ud objectForKey:kACBallY] ? [ud doubleForKey:kACBallY] : 0.55;
        _ballPosition = CGPointMake(x, y);
        _ballCollapsed = [ud boolForKey:kACBallCollapsed];
        // 不落盘：每次启动都显示，避免隐藏后重启找不到球
        _ballVisible = YES;
        _autoPlayEnabled = [ud objectForKey:kACAutoPlay] ? [ud boolForKey:kACAutoPlay] : YES;
    }
    return self;
}

- (void)setDoubleTapCommentEnabled:(BOOL)v {
    _doubleTapCommentEnabled = v;
    [self save];
}

- (void)setFullscreenLandscape:(BOOL)v {
    _fullscreenLandscape = v;
    [self save];
}

- (void)setPlaybackRate:(double)v {
    _playbackRate = v;
    [self save];
}

- (void)setBallPosition:(CGPoint)p {
    _ballPosition = p;
    [self save];
}

- (void)setBallCollapsed:(BOOL)v {
    _ballCollapsed = v;
    [self save];
}

- (void)setBallVisible:(BOOL)v {
    _ballVisible = v;   // 仅当前会话生效，不写磁盘
}

- (void)setAutoPlayEnabled:(BOOL)v {
    _autoPlayEnabled = v;
    [self save];
}

- (void)save {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:_doubleTapCommentEnabled forKey:kACDoubleTapComment];
    [ud setBool:_fullscreenLandscape forKey:kACFullscreenLandscape];
    [ud setDouble:_playbackRate forKey:kACPlaybackRate];
    [ud setDouble:_ballPosition.x forKey:kACBallX];
    [ud setDouble:_ballPosition.y forKey:kACBallY];
    [ud setBool:_ballCollapsed forKey:kACBallCollapsed];
    [ud setBool:_autoPlayEnabled forKey:kACAutoPlay];
    [ud synchronize];
}

@end
