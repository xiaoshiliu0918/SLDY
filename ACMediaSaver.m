#import "ACMediaSaver.h"
#import "ACUtils.h"
#import "ACConfig.h"
#import "ACLog.h"
#import <objc/runtime.h>

static void ACCollectViewsForModel(UIView *root, NSMutableArray<UIView *> *out, NSUInteger depth);

@interface ACMediaSaver ()
@property (nonatomic, copy) void (^videoCompletion)(NSString *message);
@property (nonatomic, copy) void (^imageCompletion)(NSString *message);
@property (nonatomic, assign) NSInteger imageTotal;
@property (nonatomic, assign) NSInteger imageSuccess;
@property (nonatomic, assign) NSInteger imageFailure;
@property (nonatomic, strong) NSArray<NSString *> *pendingImageURLs;
@property (nonatomic, assign) NSInteger imageIndex;
@end

/// 下载请求统一带上 iPhone UA 与 Referer，否则 CDN 会直接 403
static NSURLRequest *ACMediaRequest(NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
   forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
    request.timeoutInterval = 30;
    return request;
}

@implementation ACMediaSaver

+ (instancetype)shared {
    static ACMediaSaver *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ACMediaSaver alloc] init];
    });
    return instance;
}

#pragma mark - 取当前作品

+ (id)currentModel {
    id model = ACCurrentAweme();
    if (model) return model;

    // 兜底：从视图树反查宿主控制器上的作品字段
    UIWindow *key = ACKeyWindow();
    if (!key) return nil;

    NSMutableArray<UIView *> *views = [NSMutableArray array];
    ACCollectViewsForModel(key.rootViewController.view, views, 0);

    for (UIView *v in views) {
        id owner = v.nextResponder;
        if (![owner isKindOfClass:[UIViewController class]]) continue;
        for (NSString *k in @[@"awemeModel", @"model", @"aweme"]) {
            id value = ACSafeValue(owner, k);
            if (ACLooksLikeAweme(value)) return value;
        }
    }
    return nil;
}

static void ACCollectViewsForModel(UIView *root, NSMutableArray<UIView *> *out, NSUInteger depth) {
    if (!root || depth > 26 || out.count > 1500) return;
    [out addObject:root];
    for (UIView *sub in root.subviews) ACCollectViewsForModel(sub, out, depth + 1);
}

+ (BOOL)currentAwemeIsImage {
    id model = [self currentModel];
    if (!model) return NO;

    NSArray *images = ACSafeValue(model, @"images");
    if ([images isKindOfClass:[NSArray class]] && images.count > 0) return YES;

    // 抖音里 68 是图文
    return [ACSafeValue(model, @"awemeType") longLongValue] == 68;
}

#pragma mark - URL 提取

/// 从各种形态里挖出第一个 http(s) 地址：NSString / NSURL / 数组 / 字典 / 模型对象
static NSString *ACFirstURL(id object) {
    if (!object) return nil;

    if ([object isKindOfClass:[NSString class]]) {
        NSString *text = (NSString *)object;
        if ([text hasPrefix:@"http://"] || [text hasPrefix:@"https://"]) return text;
        return nil;
    }
    if ([object isKindOfClass:[NSURL class]]) {
        return [(NSURL *)object absoluteString];
    }
    if ([object isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)object) {
            NSString *url = ACFirstURL(item);
            if (url.length) return url;
        }
        return nil;
    }
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)object;
        for (NSString *key in @[@"url_list", @"urlList", @"url", @"Uri", @"uri"]) {
            if (dict[key]) {
                NSString *url = ACFirstURL(dict[key]);
                if (url.length) return url;
            }
        }
        return nil;
    }

    // AWEURLModel 的 getter 是 URLList（大写 URL），KVC 大小写敏感，少一个字母都取不到
    for (NSString *key in @[@"URLList", @"urlList", @"url_list", @"originURLList",
                            @"urls", @"url", @"src", @"Uri", @"URI"]) {
        NSString *url = ACFirstURL(ACSafeValue(object, key));
        if (url.length) return url;
    }
    return nil;
}

/// 判断是不是视频地址：封面图之类一律排除
static BOOL ACIsVideoURL(NSString *url) {
    if (![url isKindOfClass:[NSString class]] || ![url hasPrefix:@"http"]) return NO;
    NSString *lower = url.lowercaseString;
    return [lower containsString:@".mp4"] ||
           [lower containsString:@"/video/tos/"] ||
           [lower containsString:@"/aweme/v1/play"] ||
           [lower containsString:@"bytevc"] ||
           [lower containsString:@"playwm"];
}

/// 兜底：按属性名递归翻找视频地址，不依赖具体字段命名
static NSString *ACDeepVideoURL(id object, NSUInteger depth, NSMutableSet<NSString *> *seen) {
    if (!object || depth > 4) return nil;

    if ([object isKindOfClass:[NSString class]]) {
        return ACIsVideoURL(object) ? object : nil;
    }
    if ([object isKindOfClass:[NSURL class]]) {
        NSString *text = [(NSURL *)object absoluteString];
        return ACIsVideoURL(text) ? text : nil;
    }
    if ([object isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)object) {
            NSString *url = ACDeepVideoURL(item, depth + 1, seen);
            if (url.length) return url;
        }
        return nil;
    }
    if ([object isKindOfClass:[NSDictionary class]]) {
        for (id value in [(NSDictionary *)object allValues]) {
            NSString *url = ACDeepVideoURL(value, depth + 1, seen);
            if (url.length) return url;
        }
        return nil;
    }

    NSString *mark = [NSString stringWithFormat:@"%p", object];
    if ([seen containsObject:mark]) return nil;
    [seen addObject:mark];

    unsigned int count = 0;
    objc_property_t *props = class_copyPropertyList([object class], &count);
    NSString *found = nil;
    for (unsigned int i = 0; i < count && !found; i++) {
        NSString *name = @(property_getName(props[i]));
        id value = ACSafeValue(object, name);
        if (!value) continue;
        found = ACDeepVideoURL(value, depth + 1, seen);
    }
    if (props) free(props);
    return found;
}

/// 无水印视频地址。
/// downloadURL / downloadAddr 一般就是无水印源；playURL / playAddr 兜底时把 playwm 换成 play。
static NSString *ACVideoDownloadURL(id model) {
    id video = ACSafeValue(model, @"video");
    if (!video) return nil;

    NSArray<NSString *> *keys = @[@"downloadURL", @"downloadAddr",
                                  @"playURL", @"playAddr",
                                  @"h264URL", @"h264DownloadURL",
                                  @"playLowBitURL", @"playAddrH264",
                                  @"endWatermarkDownloadURL", @"miscDownloadAddrs"];

    for (NSString *key in keys) {
        NSString *url = ACFirstURL(ACSafeValue(video, key));
        if (url.length == 0) continue;
        // playwm 是带水印的播放地址，换成 play 就是无水印
        url = [url stringByReplacingOccurrencesOfString:@"playwm" withString:@"play"];
        return url;
    }

    // 字段名对不上时，按属性名递归翻一遍
    NSString *deep = ACDeepVideoURL(video, 0, [NSMutableSet set]);
    if (deep.length) {
        return [deep stringByReplacingOccurrencesOfString:@"playwm" withString:@"play"];
    }
    return nil;
}

static NSArray<NSString *> *ACImageDownloadURLs(id model) {
    NSArray *list = nil;
    for (NSString *key in @[@"downloadableAlbumImages", @"originalAlbumImages",
                            @"images", @"imageInfos", @"albumImages"]) {
        id value = ACSafeValue(model, key);
        if ([value isKindOfClass:[NSArray class]] && [(NSArray *)value count] > 0) {
            list = (NSArray *)value;
            break;
        }
    }

    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    for (id item in list) {
        NSString *url = ACFirstURL(item);
        if (url.length) [urls addObject:url];
    }
    return urls;
}

#pragma mark - 保存入口

- (void)saveCurrentAwemeWithCompletion:(void (^)(NSString *message))completion {
    id model = [[self class] currentModel];
    ACLog(@"保存作品 %@", model ? NSStringFromClass([model class]) : @"nil");
    if (!model) {
        if (completion) completion(@"没拿到当前作品信息");
        return;
    }

    if ([[self class] currentAwemeIsImage]) {
        NSArray<NSString *> *urls = ACImageDownloadURLs(model);
        if (urls.count == 0) {
            if (completion) completion(@"这条图文没有可下载的原图");
            return;
        }
        [self saveImages:urls completion:completion];
    } else {
        NSString *url = ACVideoDownloadURL(model);
        if (url.length == 0) {
            if (completion) {
                completion([NSString stringWithFormat:@"没拿到无水印地址（%@）",
                            model ? NSStringFromClass([model class]) : @"nil"]);
            }
            return;
        }
        [self saveVideo:url completion:completion];
    }
}

#pragma mark - 视频

- (void)saveVideo:(NSString *)url completion:(void (^)(NSString *message))completion {
    self.videoCompletion = completion;
    ACLog(@"视频地址 %@", url);

    NSURLRequest *request = ACMediaRequest(url);
    if (!request) {
        [self finishVideoWithMessage:@"地址无效"];
        return;
    }

    NSURLSessionDownloadTask *task =
        [[NSURLSession sharedSession] downloadTaskWithRequest:request
                                           completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            if (error || !location) {
                [self finishVideoWithMessage:@"下载失败，检查网络"];
                return;
            }

            NSString *name = [NSString stringWithFormat:@"sldy_%@.mp4", NSUUID.UUID.UUIDString];
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm removeItemAtPath:path error:nil];

            NSError *moveError = nil;
            [fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:path] error:&moveError];
            if (moveError) {
                [self finishVideoWithMessage:@"写入临时文件失败"];
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                UISaveVideoAtPathToSavedPhotosAlbum(path, self,
                    @selector(video:didFinishSavingWithError:contextInfo:), NULL);
            });
        }];
    [task resume];
}

- (void)video:(NSString *)videoPath didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo {
    NSString *message = error ? @"保存失败，检查相册权限" : @"已保存无水印视频";
    [self finishVideoWithMessage:message];
}

- (void)finishVideoWithMessage:(NSString *)message {
    void (^completion)(NSString *) = self.videoCompletion;
    self.videoCompletion = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(message);
    });
}

#pragma mark - 图片

- (void)saveImages:(NSArray<NSString *> *)urls completion:(void (^)(NSString *message))completion {
    self.imageCompletion = completion;
    self.pendingImageURLs = urls;
    self.imageTotal = urls.count;
    self.imageSuccess = 0;
    self.imageFailure = 0;
    self.imageIndex = 0;

    ACLog(@"图文 %lu 张", (unsigned long)urls.count);
    [self saveNextImage];
}

- (void)saveNextImage {
    if (self.imageIndex >= self.pendingImageURLs.count) {
        [self finishImages];
        return;
    }

    NSString *url = self.pendingImageURLs[self.imageIndex];
    self.imageIndex++;

    NSURLRequest *request = ACMediaRequest(url);
    if (!request) {
        self.imageFailure++;
        [self saveNextImage];
        return;
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = data ? [UIImage imageWithData:data] : nil;
        if (!image) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.imageFailure++;
                [self saveNextImage];
            });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImageWriteToSavedPhotosAlbum(image, self,
                @selector(image:didFinishSavingWithError:contextInfo:), NULL);
        });
    }] resume];
}

- (void)image:(UIImage *)image didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (error) {
            self.imageFailure++;
        } else {
            self.imageSuccess++;
        }
        [self saveNextImage];
    });
}

- (void)finishImages {
    NSString *message = nil;
    if (self.imageSuccess == self.imageTotal) {
        message = [NSString stringWithFormat:@"已保存 %ld 张无水印原图", (long)self.imageSuccess];
    } else if (self.imageSuccess > 0) {
        message = [NSString stringWithFormat:@"已保存 %ld 张，%ld 张失败",
                   (long)self.imageSuccess, (long)self.imageFailure];
    } else {
        message = @"保存失败，检查相册权限";
    }

    void (^completion)(NSString *) = self.imageCompletion;
    self.imageCompletion = nil;
    self.pendingImageURLs = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(message);
    });
}

@end
