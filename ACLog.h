#import <Foundation/Foundation.h>

/// 统一日志入口。
///
/// 默认关闭：ACLog 在编译期被完全剔除，二进制里不会留下任何格式串和调用，
/// 也不会有字符串常量可被检索。排查问题时在 Makefile 里加 -DAC_DEBUG_LOG=1
/// 重新编译即可打开。
#ifdef AC_DEBUG_LOG
#define ACLog(fmt, ...) NSLog((@"[SLDY] " fmt), ##__VA_ARGS__)
#else
#define ACLog(fmt, ...) do {} while (0)
#endif
