# SLDY

抖音极速版（`com.ss.iphone.ugc.aweme.lite`）的增强插件，纯 Objective-C 运行时挂载，**不依赖 Substrate / Logos**，越狱、TrollStore、自签侧载三种方式都能加载。

适配版本：**41.1.0**（`com.ss.iphone.ugc.aweme.lite_41.1.0_decrypted.ipa`）
编译目标：iOS 15.0+ / arm64

---

## 功能

| 功能 | 说明 |
|---|---|
| 双击打开评论区 | 双击视频区域直接拉起评论面板，替代默认的双击点赞 |
| 沉浸全屏 | 调用 App 自带的清屏能力，UI 全部淡出、视频铺满、状态栏收起；支持竖屏 / 横屏，双指轻点退出 |
| 悬浮球倍速 | 可拖拽贴边的悬浮球，面板内 0.5×~3.0× 八档 + 自定义（如 1.75、1.8），**全局生效**，滑到下一条依然保持 |
| 无水印保存 | 视频作品存无水印视频，图文作品逐张存原图；按钮文案按当前作品类型自动切换 |
| 自动连播 | 推荐 / 朋友 / 关注，播完自动下一条 |
| 三指双击 | 显示 / 隐藏悬浮球，不干扰 App 自身手势 |

悬浮球面板：

```
┌─────────────────────────────┐
│ 播放助手                  ✕ │
│ 0.5×  0.75×  1.0×  1.25×   │
│ 1.5×  2.0×   2.5×  3.0×    │
│ 自定义…        保存视频      │
│ ─────────────────────────── │
│ 双击打开评论区         ●    │
│ 自动连播              ●    │
│ ─────────────────────────── │
│ 竖屏全屏      横屏全屏       │
└─────────────────────────────┘
```

---

## 目录结构

```
SLDY/
├── Hooks.m                   运行时挂载：所有 hook 的安装与实现
├── ACUtils.h / ACUtils.m     公共设施：窗口、查找、安全消息发送、倍速、作品模型、状态栏
├── ACConfig.h / ACConfig.m   配置持久化（NSUserDefaults）
├── ACFloatingBall.h/.m       悬浮球与面板
├── ACFullscreenController.h/.m  清屏全屏 + 横屏旋转
├── ACMediaSaver.h/.m         无水印视频 / 图文保存
├── ACLog.h                   统一日志宏（默认编译期剔除）
├── Makefile                  Theos library.mk
├── inject.py                 IPA 注入 + 重打包
├── build.sh                  一键编译脚本
├── tools/                    逆向辅助脚本（类/方法导出、反汇编）
└── .github/workflows/        GitHub Actions 编译
```

---

## 编译

### WSL / Linux（Theos）

```bash
export THEOS=~/theos
make clean && make FINALPACKAGE=1
# 产物：.theos/obj/arm64/AwemeLitePlus.dylib
```

### macOS

同上，Theos 装好后 `make FINALPACKAGE=1` 即可。

### 打开调试日志

日志默认在编译期被完全剔除（二进制里不留任何格式串）。排查问题时：

```bash
make clean && make FINALPACKAGE=1 CFLAGS=-DAC_DEBUG_LOG=1
# 或在 Makefile 里取消 AwemeLitePlus_CFLAGS += -DAC_DEBUG_LOG=1 的注释
```

日志前缀是 `[SLDY]`。

---

## 打包

### dylib 注入 IPA

```bash
python inject.py \
  -i com.ss.iphone.ugc.aweme.lite_41.1.0_decrypted.ipa \
  -d AwemeLitePlus.dylib \
  -o SLDY_41.1.0_injected.ipa
```

注入器做三件事：把 dylib 放进 `Payload/AwemeLite.app/Frameworks/`、在主二进制头部 padding 里写入 `LC_LOAD_DYLIB`、清掉旧的 `_CodeSignature`。**不改动任何 section 偏移**。

### deb

```bash
# rootful
mkdir -p pkg/Library/MobileSubstrate/DynamicLibraries
cp AwemeLitePlus.dylib pkg/Library/MobileSubstrate/DynamicLibraries/
printf '{ Filter = { Bundles = ( "com.ss.iphone.ugc.aweme.lite" ); }; }\n' \
  > pkg/Library/MobileSubstrate/DynamicLibraries/AwemeLitePlus.plist
dpkg-deb -b pkg SLDY_rootful.deb      # rootless 把路径换成 /var/jb/...
```

### 签名

```bash
zsign -k cert.p12 -p 密码 -m ent.plist -o signed.ipa SLDY_41.1.0_injected.ipa
```

---

## 安装

- **TrollStore**：直接装注入后的 IPA，安装时自动签名
- **侧载**：zsign / Sideloadly 重签后安装，嵌套 dylib 会一起签
- **越狱**：按越狱类型装 rootless 或 rootful 的 deb，然后 respring

---

## 实现要点

### 双击打开评论区

`AWEPlayInteractionViewController -onVideoPlayerViewDoubleClicked:` 是空实现（只有一条 `ret`），真正的双击落在两层：

```
AWEFeedInteractiveVideoViewController -playableDoubleClickLikeWithPoint:
        ↓
AWEPlayInteractionLikeElementViewModel -onVideoPlayerViewDoubleClicked(AtPoint):
```

两处都接管，命中后改走 `performCommentAction` → `panelDelegate` → 评论面板。`panelDelegate` 为空时回落到原生点赞，不会白吃一次双击。0.35 秒去抖，避免多条链路重复弹面板。

### 沉浸全屏

前两版试过「把播放器搬进独立窗口」和「手工撑满各层容器高度」，都不行：前者播放器脱离 App 渲染链路会黑屏 / 无声，后者打乱 cell 高度关系，上一条内容和当前视频会叠在一起。

最终直接调用 App 自己的清屏入口：

```objc
[AWEPlayInteractionViewController setPureMode:YES animateDuration:0.3];
```

UI 淡出、视频铺满、状态栏收起、退出动画与后续起播全部由 App 处理，插件一行布局代码都不碰。调用顺序做了三级兜底（`setPureMode:animateDuration:` → `setPureMode:animated:` → `setPureMode:`），进入前先读一次 `pureMode`，用户自己长按上滑进过清屏时不会重复触发。

横屏是把根视图整体旋转 90°，同样不搬播放器；退出按原始 bounds / center / transform 逐项还原。

> 全屏这块的思路参考了 [DYYY](https://github.com/VexCove/DYYY)：不动播放器，只动 UI。

### 全局倍速

`AWEAwemeSpeedManager` 在每次切视频时会走这条链把倍速刷回 1.0：

```
resetSpeedControl            -> setCurrentSpeed:@1.0，并清空 currentItemId
resetSpeedInHomepage         -> setCurrentSpeedInHomepage:1.0
resetSpeedInMixVideo         -> setCurrentSpeedInMixVideo:1.0
resetSpeedInInterestDiscover -> setCurrentSpeedInInterestDiscover:1.0
```

所以只在切换后补一针没用，补针时机过了又被刷回去。这里是**在 setter 层拦截**：用户设过非 1.0 倍速后，这些入口一旦写入 1.0 就把参数改回目标值；`resetSpeedControl` 在锁速时只重写倍速、不执行原重置。

下发链路三级保底，任何一级成功即可：

```
AWEDPlayerViewController  -setPlaybackRate:(double)
        ↓
TTVideoEngine             -setPlaybackSpeed:(double)
        ↓
AWEPlayInteractionSpeedController -changeSpeed:(double)
```

### 无水印保存

取作品模型按可信度排序，并且**校验它确实是作品**（响应 `video` / `images` / `awemeId` 之一），避免拿到同名的别的对象：

```
AWEPlayInteractionViewController -awemeModel     ← 正在播的这条
        ↓
setModel: 时缓存的模型                            ← hook 里存下来的
        ↓
awemeBaseViewController 上的同名字段
        ↓
视图树反查宿主控制器
```

> 注意不能直接用 `model`：交互容器上的 `model` 并不是作品对象，早期版本就是在这里取错，导致 `video` 为空。

地址取值：

| 类型 | 顺序 |
|---|---|
| 视频 | `downloadURL` → `downloadAddr` → `playURL` → `playAddr` → `h264URL` → `h264DownloadURL` → `playLowBitURL` → `playAddrH264` → `endWatermarkDownloadURL` → `miscDownloadAddrs` |
| 图文 | `downloadableAlbumImages` → `originalAlbumImages` → `images` → `imageInfos` → `albumImages` |

- **`AWEURLModel` 的 getter 是 `URLList`（大写 URL）**，KVC 大小写敏感，写成 `urlList` 会一直取到 nil
- 命名对不上时还有一层兜底：按属性名递归翻找含 `.mp4` / `/video/tos/` / `playwm` 的地址，封面图之类的会被过滤掉
- `playwm` 域名替换成 `play` —— 这是去水印的关键
- URL 提取走通用递归器，兼容 `NSString` / `NSURL` / 数组 / 字典 / `urlList` 模型
- 下载带 iPhone UA 与 `Referer`，避免 CDN 403
- 视频走 `UISaveVideoAtPathToSavedPhotosAlbum`，图文逐张串行保存

### 自动连播

`AWEFeedIPhoneAutoPlayController -handleVideoDidPlayFinshNotification:`（App 原拼写）里有两道闸门：

```objc
- (BOOL)isAutoPlayOpen;                             // 总开关，为 NO 时后面全白搭
- (BOOL)autoPlayEnableWithReferString:(id)refer;    // 按来源（推荐/朋友/关注）判断
```

两个都接管后，播完就会自动滑到下一条。只挂后者不生效，是因为总开关先返回了 NO。

### 状态栏 / 小白条

没有压遮挡窗口（截图里那条黑边就是它），而是 hook `UIViewController` 的 `prefersStatusBarHidden` 与 `prefersHomeIndicatorAutoHidden`，全屏期间返回 YES，让系统自己收起来。

### 悬浮球

- 窗口**只包住球本身**（收起 28×28，展开为「球 + 面板」并集），绝不覆盖整屏
- `ACOverlayWindow` 重写 `pointInside:withEvent:` 做白名单，其余区域一律交还给 App —— 这是「球在但不挡触摸」的关键
- 面板外点击关闭用临时 tap 手势，关闭即移除
- 三指双击手势挂在 App 的 keyWindow 上（不是悬浮球窗口），球藏起来后仍能唤回；隐藏状态不落盘，重启一定显示

---

## Hook 一览

| 类 | 方法 | 作用 |
|---|---|---|
| `AWEPlayInteractionViewController` | `viewDidAppear:` / `viewWillDisappear:` | 记录当前交互容器，补倍速 |
| `AWEPlayInteractionViewController` | `setModel:` | 缓存作品模型 |
| `AWEAwemeBaseViewController` | `setModel:` | 同上 |
| `AWEFeedInteractiveVideoViewController` | `playableDoubleClickLikeWithPoint:` | 双击 → 评论 |
| `AWEPlayInteractionLikeElementViewModel` | `onVideoPlayerViewDoubleClicked(AtPoint):` | 双击 → 评论 |
| `AWEAwemeSpeedManager` | `setCurrentSpeed:` / `setCurrentSpeedInHomepage:` / `...MixVideo:` / `...InterestDiscover:` | 拦截倍速重置 |
| `AWEAwemeSpeedManager` | `resetSpeedControl` / `resetSpeedInHomepage` / `...MixVideo:` / `...InterestDiscover` | 锁速时跳过重置 |
| `AWEAwemeSpeedManager` | `updateSpeed:` / `adjustCurrentSpeedwithFloatValue:` | 记录管理器实例 |
| `AWEPlayInteractionSpeedController` | `changeSpeed:` / `longPressSpeedControlDidChangeSpeed:` | 原生面板改速同步为全局 |
| `AWEPlayInteractionSpeedController` | `willDisplay` / `setData:` | 记录控制器实例 |
| `AWEDPlayerViewController` | `setPlaybackRate:` / `updatePlayerIfNeeded` | 播放器层改写 |
| `AWEDPlayerFeedPlayerViewController` | `playOrResumeVideo:` / `updatePlayerIfNeeded` | 起播后补一针 |
| `TTVideoEngine` | `setPlaybackSpeed:` / `play` | 内核层改写 |
| `AWEFeedIPhoneAutoPlayManager` | `isAutoPlayOpen` / `autoPlayEnable` / `autoPlayEnableWithReferString:` | 自动连播 |
| `UIViewController` | `prefersStatusBarHidden` / `prefersHomeIndicatorAutoHidden` | 全屏时收起状态栏 |

所有挂载都用 `method_setImplementation`，类未加载时每秒重试，最多 30 次。

---

## 逆向笔记

`AwemeLite.app` 结构：

```
AwemeLite                       275 KB     只负责加载 Framework 的壳（thin arm64）
AwemeLiteCore.framework         969 MB     真实业务，134,826 个 ObjC 类
TTFFmpeg / bytevc0 / bytevc1    ...        播放与解码
```

- `AwemeLite` 无 `LC_ENCRYPTION_INFO_64`（已解密），第一条依赖就是 `@rpath/AwemeLiteCore.framework/AwemeLiteCore`
- `AwemeLiteCore`：179 条 load command、51 个依赖、`__objc_classlist` = `0x107550`
- 方法表是 **relative method list**（`entsizeAndFlags = 0x8000000c`），`name` 是相对 selref 的偏移，常规 Mach-O 解析器读出来是乱码
- `AwemeLite` 头部有 **26,144 字节 padding**，足够原地写入 `LC_LOAD_DYLIB`，不改任何文件偏移

`tools/` 下的脚本就是干这个的：

```bash
python tools/scan_classes.py AwemeLiteCore out.json 类名...   # 导出类的方法列表
python tools/objc.py list <类名>                              # 方法 + 类型编码 + IMP
python tools/objc.py dis <类名> <方法> <条数>                  # 反汇编
python tools/grep_methods.py AwemeLiteCore keyword...          # 全量搜方法名
```

---

## 更新记录

### 1.5.1

- 修复无水印保存提示「没拿到无水印地址」：`AWEURLModel` 的地址列表 getter 是 `URLList`，之前按 `urlList` 取（KVC 大小写敏感）永远拿不到
- 增加深层扫描兜底：字段名对不上时按属性名递归查找视频地址
- 失败提示带上作品模型的类名，便于定位

### 1.5.0

- 移除全部日志输出（`ACLog` 编译期剔除，二进制零残留），顺带修掉日志参数里做 KVC 可能抛异常的问题
- 自动连播补上 `isAutoPlayOpen` 总闸门，之前只挂 `autoPlayEnableWithReferString:` 不生效
- 无水印保存改走 `awemeModel` 并校验对象类型，补 `downloadAddr` / `playAddr` / `imageInfos` 等字段
- 提示条改挂主窗口：面板收起后（保存结果、全屏失败）也能正常显示
- 去掉状态栏遮挡黑窗，改由 `prefersStatusBarHidden` 接管
- 挂载器补 `ACHookOwnInstanceMethod`，避免父子类共用 Method 造成递归
- 清理 v1.2.0 遗留的布局撑满死代码

### 1.4.0

- 自定义倍速、无水印保存、自动连播

### 1.3.1

- 全屏改为调用原生清屏，修掉撑满布局导致的画面叠层

### 1.3.0

- 三指双击切换悬浮球

### 1.1.0

- 倍速改为在 setter 层拦截，切换视频不再掉回 1.0

### 1.0.0

- 双击评论、全屏、悬浮球倍速

---

## 说明

- 所有类名、方法名基于 41.1.0 的二进制核对；换版本需要重新定位
- 插件只改运行时行为，不改 App 资源与签名逻辑
- 抖音带 HMD / Heimdallr / isecgm 等风控组件，修改客户端存在被识别与封号的可能，自行权衡
