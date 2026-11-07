//
//  Tweak.xm
//  ScreenTimeSpoofer
//
//  作用域：只注入 com.apple.Preferences（“设置”App）。
//  原理：ScreenTimeUI 展示的数据来自 ScreenTimeCore 的模型对象，
//        挂钩这些对象的「时长 getter」，在返回值上做等比缩放，
//        顶部总时长、分类小计、柱状图、App 排行会一起变。
//
//  本版（0.3.5）重点：
//   1) 日志改成纯 C（open/write），同时写 3 个真实路径，不依赖 STSConfig；
//      构造器第一行就落盘 —— 只要 dylib 被注入，就一定能看到文件。
//   2) 修掉旧的 STSJB 把日志拼到 /var/jb/var/mobile/... 的错误路径问题。
//   3) 挂钩从「精确名列表」放宽成「名字启发式」，并自动 dump 候选方法，
//      解决 iOS 16.7 上真实 getter 名不在列表里导致 0 命中的问题。
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import "STSConfig.h"
#import "STSConstants.h"

#pragma mark - 纯 C 日志（不依赖 Foundation / 配置）

extern int open(const char *, int, ...);
extern long write(int, const void *, unsigned long);
extern int close(int);
extern unsigned long strlen(const char *);
extern int getpid(void);

#define STS_O_WRONLY 0x0001
#define STS_O_CREAT  0x0200
#define STS_O_APPEND 0x0008
#define STS_O_TRUNC  0x0400

// 三个真实绝对路径（都不加 /var/jb 前缀）：
//   /var/mobile/Library/Logs  —— 最常规，Filza 最容易找
//   /tmp                      —— 越狱环境一定可写，兜底
//   /var/mobile/Documents     —— 再兜一层
static const char *kSTSLogPaths[] = {
    "/var/mobile/Library/Logs/ScreenTimeSpoofer-boot.log",
    "/tmp/ScreenTimeSpoofer-boot.log",
    "/var/mobile/Documents/ScreenTimeSpoofer-boot.log",
};
static const int kSTSLogPathCount = 3;

static void STSRawWrite(const char *line, int truncate) {
    if (!line) return;
    long len = (long)strlen(line);
    for (int i = 0; i < kSTSLogPathCount; i++) {
        int flags = STS_O_WRONLY | STS_O_CREAT | (truncate ? STS_O_TRUNC : STS_O_APPEND);
        int fd = open(kSTSLogPaths[i], flags, 0644);
        if (fd < 0) continue;
        write(fd, line, (unsigned long)len);
        write(fd, "\n", 1);
        close(fd);
    }
}

/// 构造器逐步打点：纯 C，定位「卡在哪一步」用。
static void STSStep(const char *s) {
    STSRawWrite(s, 0);
}

#define STSLOG(fmt, ...) NSLog(@"[STS] " fmt, ##__VA_ARGS__)

/// NSString 落盘 + NSLog。内部全部 @try，绝不影响主逻辑。
static void STSLogLine(NSString *line) {
    @try {
        const char *c = [line UTF8String];
        if (c) STSRawWrite(c, 0);
        NSLog(@"[STS] %@", line);
    } @catch (NSException *e) {
    }
}

#pragma mark - 缩放因子

static _Thread_local int STSDepth = 0;

// 0.5.6：把「总时长」锚定到明确的选择器，不再用「一轮里取最大值」当基准。
// 0.5.5 的失败：日志显示 STUsageReport 同时挂了 maxScreenTime / totalAppUsage /
// totalCategoryUsage / totalWebUsage 等 getter，其中某些值比 totalScreenTime 更大
// （历史峰值、周累计…）。取全局最大值就把分母撑大，系数被压到 0.02 左右，
// 原本几十秒的 App 项被缩成 1 秒 —— 正是用户反馈的「直接变成一秒」。
//
// 现在只把日志证实的总量 getter 当基准：
//   -[STUsageReport totalScreenTime]  /  -[USUsageReport screenTime]
// 它们命中时：记录原始总时长，并直接返回用户填写的目标值；
// 其余所有 getter 统一按「目标 / 原始总时长」缩放（STSBaseFactor）。
static double gSTSTotalOriginal = 0.0;   // 最近一次观测到的原始总时长（秒）
static CFAbsoluteTime gSTSTotalAt = 0;
static const CFAbsoluteTime kTotalTTL = 900.0;  // 15 分钟内有效，超时回落 scale
static SEL gSelTotalScreenTime = NULL;
static SEL gSelScreenTime = NULL;

static Class gAggregateClass = NULL;
static SEL gAggregateSel = NULL;
static CFAbsoluteTime gLastConfigCheck = 0;
static const CFAbsoluteTime kConfigCheckInterval = 2.0;

static NSMutableSet<NSString *> *gSTSHookedKeys;

// 改写样本条数。用原子计数而不是 NSMutableArray：被挂的 getter 会被多线程调用，
// 共享数组无锁 addObject 会直接崩（0.3.5 的闪退嫌疑之一）。
static volatile int gSTSApplyCount = 0;
#define kSTSApplySampleLimit 8

// 0.5.2 诊断：分别统计「被挂钩 getter 被调用过多少次」与「其中真正被改写了多少次」。
// 之前只有改写计数，无法区分「挂上了但界面没调用」和「调用过但未改写」。
static volatile int gSTSInvokedCount = 0;
static volatile int gSTSChangedCount = 0;
#define kSTSInvokeSampleLimit 20

static const char *STSModeName(STSMode m) {
    switch (m) {
        case STSModeOff:    return "off";
        case STSModeTarget: return "target";
        case STSModeScale:  return "scale";
        case STSModeCap:    return "cap";
    }
    return "?";
}

/// 当前生效的缩放系数：target 模式 = 目标总时长 / 已观测到的原始总时长。
/// 每次都重新读 cfg.targetSeconds，所以设置页改完数字后无需重进页面也会立刻按新值算。
static double STSBaseFactor(void) {
    STSConfig *cfg = [STSConfig shared];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (cfg.mode == STSModeTarget && cfg.targetSeconds > 0 &&
        gSTSTotalOriginal > 0 && (now - gSTSTotalAt) < kTotalTTL) {
        double f = cfg.targetSeconds / gSTSTotalOriginal;
        if (f > 0 && __builtin_isfinite(f)) return f;
    }
    return (cfg.scale > 0 ? cfg.scale : 1.0);
}

static void STSReloadConfig(void) {
    STSConfig *cfg = [STSConfig shared];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLastConfigCheck < kConfigCheckInterval) return;
    gLastConfigCheck = now;

    @autoreleasepool {
        @try {
            [cfg reloadIfNeeded];
            gAggregateClass = NSClassFromString(cfg.aggregateClass);
            gAggregateSel = sel_registerName(cfg.aggregateSelector.UTF8String);
        } @catch (NSException *e) {
        }
    }
}

static BOOL STSIsAggregate(STSConfig *cfg, id self, SEL sel) {
    if (cfg.mode != STSModeTarget) return NO;
    if (!gAggregateClass || sel != gAggregateSel) return NO;
    return [self isKindOfClass:gAggregateClass];
}

static double STSApplyValueInner(id self, SEL sel, double v);

static double STSApplyValue(id self, SEL sel, double v) {
    @try {
        double out = STSApplyValueInner(self, sel, v);

        int n = __sync_fetch_and_add(&gSTSInvokedCount, 1);
        if (out != v) {
            int c = __sync_fetch_and_add(&gSTSApplyCount, 1);
            __sync_fetch_and_add(&gSTSChangedCount, 1);
            if (c < kSTSApplySampleLimit) {
                // 用 C 层的 class_getName / sel_getName：比 NSStringFromClass /
                // NSStringFromSelector 少一层消息，且不会因对象异常而放大问题。
                @try {
                    STSLogLine([NSString stringWithFormat:@"  sample 改写: -[%s %s] %.0f -> %.0f",
                                class_getName([self class]), sel_getName(sel), v, out]);
                } @catch (NSException *e) {
                }
            }
        } else if (n < kSTSInvokeSampleLimit) {
            @try {
                STSLogLine([NSString stringWithFormat:@"  sample 调用(未改写): -[%s %s] %.0f",
                            class_getName([self class]), sel_getName(sel), v]);
            } @catch (NSException *e) {
            }
        }
        return out;
    } @catch (NSException *e) {
        STSLOG("apply exception: %@", e);
        return v;
    }
}

static double STSApplyValueInner(id self, SEL sel, double v) {
    STSConfig *cfg = [STSConfig shared];
    STSReloadConfig();

    if (cfg.mode == STSModeOff || v <= 0) return v;

    // 护栏：只把「像秒数」的值当时长处理。
    // > 30 天（2592000s）的几乎肯定是时间戳/绝对时间，改了必然把界面搞崩，一律不动。
    if (v > 2592000.0) return v;

    // 总时长 getter：记录原始总时长作为唯一基准，并直接返回填写的目标值。
    // 其余 getter 一律按 STSBaseFactor() 缩放，保证「顶部 = 目标、各项之和也 = 目标」。
    // 只用确定的选择器判定，绝不拿 maxScreenTime / 周累计之类的大值当分母。
    if (cfg.mode == STSModeTarget && cfg.targetSeconds > 0 &&
        (STSIsAggregate(cfg, self, sel) ||
         sel == gSelTotalScreenTime || sel == gSelScreenTime)) {
        gSTSTotalOriginal = v;
        gSTSTotalAt = CFAbsoluteTimeGetCurrent();
        double out = cfg.targetSeconds;
        if (cfg.capSeconds > 0 && out > cfg.capSeconds) out = cfg.capSeconds;
        return out;
    }

    // 默认只改总时长，分项保持真实值。
    // 真实总时长约 25077 秒（日志），压到 900 秒时等比系数仅 0.036，
    // 一个原本 30 秒的 App 会变成 1 秒 —— 这就是「直接变成一秒」。
    // 需要「总和自洽」时把 plist 里 ScaleDetails 设为 true。
    if (!cfg.scaleDetails) return v;

    double out = v * STSBaseFactor();
    if (cfg.capSeconds > 0 && out > cfg.capSeconds) out = cfg.capSeconds;
    return out;
}

static id STSApplyObject(id self, SEL sel, id obj) {
    if (![obj isKindOfClass:[NSNumber class]]) return obj;
    double v = [obj doubleValue];
    double out = STSApplyValue(self, sel, v);
    if (out == v) return obj;
    return @(out);
}

#pragma mark - 名字启发式（解决精确列表不命中）

/// 判断选择器名是否「像时长」：命中 usage/duration/seconds/minutes 等，
/// 同时排除 count/since/interval/date/start/end 这类明显不是时长的。
static BOOL STSLooksLikeDuration(NSString *selName) {
    NSString *l = [selName lowercaseString];
    // 排除：计数/时间戳/区间/类型/状态/标识 等明显不是「时长秒数」的
    if ([l containsString:@"count"] || [l containsString:@"since"] ||
        [l containsString:@"interval"] || [l containsString:@"timestamp"] ||
        [l containsString:@"start"] || [l containsString:@"end"] ||
        [l containsString:@"date"] || [l containsString:@"type"] ||
        [l containsString:@"flag"] || [l containsString:@"state"] ||
        [l containsString:@"kind"] || [l containsString:@"index"] ||
        [l containsString:@"sort"] || [l containsString:@"identif"] ||
        [l containsString:@"version"] || [l containsString:@"offset"] ||
        [l containsString:@"limit"]) {
        return NO;
    }
    if ([l containsString:@"usage"] || [l containsString:@"duration"] ||
        [l containsString:@"seconds"] || [l containsString:@"minutes"] ||
        [l containsString:@"timespent"] || [l containsString:@"timeused"] ||
        [l containsString:@"screentime"]) {
        return YES;
    }
    return NO;
}

#pragma mark - 挂钩

static void STSHookMethod(Class cls, SEL sel);

static void STSHookClass(Class cls) {
    if (!cls) return;
    STSConfig *cfg = [STSConfig shared];

    NSString *clsName = NSStringFromClass(cls);
    if ([cfg.excludeClasses containsObject:clsName]) return;

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return;

    for (unsigned int i = 0; i < count; i++) {
        Method m = methods[i];
        if (method_getNumberOfArguments(m) != 2) continue;   // self + _cmd，零参

        char ret[16] = {0};
        method_getReturnType(m, ret, sizeof(ret));
        char t = ret[0];
        if (!strchr("dqQ@", t)) continue;                    // 只碰数值返回值

        SEL sel = method_getName(m);
        NSString *selName = NSStringFromSelector(sel);

        BOOL explicitHit = [cfg.durationSelectors containsObject:selName];
        if (!explicitHit) {
            // 启发式只放宽到「返回 double」的方法（时长几乎都是 NSTimeInterval 秒）。
            // 绝不在 @ / q / Q 上放宽：那些很可能是 NSNumber、枚举或索引，
            // 改坏会直接让界面内部越界断言崩溃（0.3.5 的闪退嫌疑之一）。
            if (!cfg.heuristicHook) continue;
            if (t != 'd') continue;
            if (!STSLooksLikeDuration(selName)) continue;
        }

        NSString *key = [NSString stringWithFormat:@"%@|%@", clsName, selName];
        if ([gSTSHookedKeys containsObject:key]) continue;
        [gSTSHookedKeys addObject:key];

        STSHookMethod(cls, sel);
    }
    free(methods);
}

static void STSHookMethod(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    char ret[16] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    char t = ret[0];

    IMP origIMP = method_getImplementation(m);

    // ===== 0.5.4 关键修复：imp_implementationWithBlock 的 block 不接收 _cmd =====
    // runtime 生成的 trampoline 会把 (self, _cmd, args...) 重排为 (block, self, args...)，
    // 也就是 _cmd 会被丢掉，block 的第 2 个参数拿到的是「方法的第一个实参」。
    // 以前写成 ^double(id obj, SEL _cmd)：对零参 getter 而言没有实参，_cmd 就是寄存器垃圾。
    // 后果有两个，都已在崩溃报告里被证实：
    //   1) NSStringFromSelector(垃圾) → _platform_strlen → SIGSEGV
    //      （Preferences-2026-11-01-223225：-[STUsageReport initWith...] → block_invoke → strlen）
    //   2) STSIsAggregate 里 sel != gAggregateSel 永远成立 → 聚合基准从未被设置，
    //      这正是「挂上了却没效果」的直接原因
    // 正确写法：block 只声明 (id obj)，选择器由捕获变量传入。
    if (t == 'd') {
        typedef double (*Fn)(id, SEL);
        method_setImplementation(m, imp_implementationWithBlock(^double(id obj) {
            if (STSDepth > 0) return ((Fn)origIMP)(obj, sel);
            STSDepth++;
            double v = ((Fn)origIMP)(obj, sel);
            STSDepth--;
            return STSApplyValue(obj, sel, v);
        }));
    } else if (t == 'q' || t == 'Q') {
        typedef long long (*Fn)(id, SEL);
        method_setImplementation(m, imp_implementationWithBlock(^long long(id obj) {
            if (STSDepth > 0) return ((Fn)origIMP)(obj, sel);
            STSDepth++;
            long long v = ((Fn)origIMP)(obj, sel);
            STSDepth--;
            return (long long)STSApplyValue(obj, sel, (double)v);
        }));
    } else if (t == '@') {
        typedef id (*Fn)(id, SEL);
        method_setImplementation(m, imp_implementationWithBlock(^id(id obj) {
            if (STSDepth > 0) return ((Fn)origIMP)(obj, sel);
            STSDepth++;
            id v = ((Fn)origIMP)(obj, sel);
            STSDepth--;
            return STSApplyObject(obj, sel, v);
        }));
    } else {
        return;   // 结构体/指针/BOOL/int 等一概不碰
    }

    @try {
        STSLogLine([NSString stringWithFormat:@"  hooked -[%s %s] (%c)",
                    class_getName(cls), sel_getName(sel), t]);
    } @catch (NSException *e) {
    }
    STSLOG("hooked -[%s %s] (%c)", class_getName(cls), sel_getName(sel), t);
}

static BOOL STSIsScreenTimeImage(Class cls) {
    const char *image = class_getImageName(cls);
    if (!image) return NO;

    // 只认系统私有框架。不能只用名字包含 ScreenTime：本插件路径里也含
    // ScreenTimeSpoofer，0.5.0 曾因此扫描并挂钩自己的 STSConfig getter。
    static const char *kSTCore = "/System/Library/PrivateFrameworks/ScreenTime";
    static const char *kUsageTracking = "/System/Library/PrivateFrameworks/UsageTracking";
    return strncmp(image, kSTCore, strlen(kSTCore)) == 0 ||
           strncmp(image, kUsageTracking, strlen(kUsageTracking)) == 0;
}

static void STSScanAll(void) {
    @try {
        STSConfig *cfg = [STSConfig shared];

        for (NSString *name in cfg.includeClasses) {
            Class cls = NSClassFromString(name);
            if (cls) STSHookClass(cls);
        }

        if (cfg.scanAllScreenTimeClasses) {
            int count = objc_getClassList(NULL, 0);
            if (count > 0) {
                Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
                if (classes) {
                    count = objc_getClassList(classes, count);
                    for (int i = 0; i < count; i++) {
                        Class cls = classes[i];
                        // 0.4.0：去掉「类名必须 ST 开头」限制 —— 承载时长的类不一定都以 ST 开头，
                        // 直接扫描 ScreenTime/UsageTracking 镜像下所有类，避免漏挂。
                        if (!STSIsScreenTimeImage(cls)) continue;
                        STSHookClass(cls);
                    }
                    free(classes);
                }
            }
        }

        STSLOG("scan done, hooked=%lu", (unsigned long)gSTSHookedKeys.count);
    } @catch (NSException *e) {
        STSLOG("scan exception: %@", e);
        STSLogLine([NSString stringWithFormat:@"扫描异常：%@ %@", e.name, e.reason]);
    }
}

#pragma mark - 框架懒加载检测 + 全量 dump（0.6.1）

// 0.6.1 核心：boot(7).log 显示「hooked=8 被调用=0 被改写=0」，结论是
// 「显示数据来自其它类」。但更根本的问题是：插件在「设置」刚启动时就扫完，
// 那时「设置 → 屏幕使用时间」页面用的私有框架（ScreenTimeSettingsUI 等）还没
// 被懒加载，日志第 8 行「启动时已加载 ScreenTime 镜像」只有 3 个就是证据。
// 挂上的 8 个 getter 全在 ScreenTimeCore / UsageTracking 的模型类里，那个页面
// 根本不调它们 —— 于是永远零调用，日志也永远列不出真正的数据类。
//
// 这一版：每 0.5 秒轮询 dyld 镜像表，一旦发现新的 ScreenTime 相关框架出现，
// 立刻全量 dump 它的类名与「名字像时长」的零参方法（含返回 NSString 的格式化
// getter，不限数值返回值），并让同一次重扫把新类挂上。
// 不用 _dyld_register_func_for_add_image：那个回调在 dyld 阶段触发，0.5.0 曾因
// 回调里解析不到 dispatch_get_main_queue 直接 abort；轮询只在自建队列里跑，零风险。

static NSMutableSet<NSString *> *gSTSKnownImages = nil;

/// dump 用的镜像筛选比 hook 更宽：多列几个框架，便于看出真正的数据类在哪。
/// hook 仍只覆盖 ScreenTime* / UsageTracking（见 STSIsScreenTimeImage）。
static BOOL STSIsDumpTargetImage(const char *p) {
    if (!p || !strstr(p, "/System/Library/PrivateFrameworks/")) return NO;
    return (strstr(p, "ScreenTime") || strstr(p, "UsageTracking") ||
            strstr(p, "FamilyControls") || strstr(p, "ManagedSettings") ||
            strstr(p, "DeviceActivity")) ? YES : NO;
}

/// 纯 C 版「名字像时长」，大小写不敏感。故意放宽到 formatted / time / elapsed，
/// 因为界面显示的「3 小时 18 分钟」很可能是返回 NSString 的格式化 getter，
/// 旧版 dump 只列数值返回值，把它整个漏掉了。
static BOOL STSDurationLikeC(const char *name) {
    if (!name) return NO;
    char buf[256];
    unsigned long n = strlen(name);
    if (n >= sizeof(buf)) n = sizeof(buf) - 1;
    for (unsigned long i = 0; i < n; i++) {
        char c = name[i];
        buf[i] = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
    }
    buf[n] = 0;
    static const char *keys[] = {
        "usage", "duration", "second", "minute", "hour", "screentime",
        "timespent", "timeused", "totaltime", "timeinterval", "formatted",
        "elapsed", "spent", "budget", "screen", "time", NULL
    };
    for (int i = 0; keys[i]; i++) if (strstr(buf, keys[i])) return YES;
    return NO;
}

/// dump 单个镜像：全部类名（紧凑）+ 所有「名字像时长」的零参方法及其返回类型。
static void STSDumpImageFull(NSString *imagePath) {
    @try {
        const char *img = [imagePath UTF8String];
        if (!img) return;
        unsigned int cc = 0;
        const char **cn = objc_copyClassNamesForImage(img, &cc);
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"\n## 框架全量清单：%@  [%u 个类]", imagePath, cc];
        if (!cn) { STSLogLine(out); return; }

        [out appendString:@"\n  类："];
        for (unsigned int j = 0; j < cc && j < 200; j++) {
            [out appendFormat:@" %s", cn[j]];
        }
        if (cc > 200) [out appendFormat:@" …(共%u个)", cc];

        int lines = 0;
        for (unsigned int j = 0; j < cc && lines < 400; j++) {
            Class cls = objc_getClass(cn[j]);
            if (!cls) continue;
            unsigned int mc = 0;
            Method *ms = class_copyMethodList(cls, &mc);
            if (!ms) continue;
            BOOL header = NO;
            for (unsigned int k = 0; k < mc && lines < 400; k++) {
                if (method_getNumberOfArguments(ms[k]) != 2) continue;  // 零参
                const char *sn = sel_getName(method_getName(ms[k]));
                if (!STSDurationLikeC(sn)) continue;
                char ret[32] = {0};
                method_getReturnType(ms[k], ret, sizeof(ret));
                if (!header) { [out appendFormat:@"\n  %s:", cn[j]]; header = YES; }
                [out appendFormat:@"\n     - %s (%s)", sn, ret];
                lines++;
            }
            free(ms);
        }
        [out appendFormat:@"\n  （时长相关零参方法 %d 条；返回 @ 的是字符串/对象，v/V 是 void）", lines];
        free(cn);
        STSLogLine(out);
    } @catch (NSException *e) {
        STSLogLine([NSString stringWithFormat:@"## dump 镜像异常：%@ %@", e.name, e.reason]);
    }
}

/// 返回「本次还没 dump 过」的目标框架镜像路径。
static NSArray<NSString *> *STSFreshScreenTimeImages(void) {
    NSMutableArray *fresh = [NSMutableArray array];
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *p = _dyld_get_image_name(i);
        if (!STSIsDumpTargetImage(p)) continue;
        NSString *key = [NSString stringWithUTF8String:p];
        if (!key || [gSTSKnownImages containsObject:key]) continue;
        [gSTSKnownImages addObject:key];
        [fresh addObject:key];
    }
    return fresh;
}

#pragma mark - 入口

// 0.5.1：不调用 dispatch_get_main_queue。iOS 16 上它不是可直接解析的 dylib 符号，
// _dyld_register_func_for_add_image 的回调触发后调用它会直接 _dyld_missing_symbol_abort
// （0.5.0 的 SIGABRT 证据）。全部内部任务改到这条串行队列，顺带避免扫描与配置热重载竞争。
static dispatch_queue_t gSTSWorkQueue = NULL;
static dispatch_queue_t STSWorkQueue(void) {
    if (!gSTSWorkQueue) {
        gSTSWorkQueue = dispatch_queue_create("com.evander.screentimespoofer.work", NULL);
    }
    return gSTSWorkQueue;
}

// ScreenTimeSettingsUI（承载 STUsageReport 的框架）只在点进「屏幕使用时间」时才懒加载，
// 0.5.5 日志显示它直到 8 秒统计之后才被补扫挂上，用户首屏因此看到的是真实值。
// 0.5.6：前 15 秒每 0.5 秒补扫，之后到 60 秒每 2 秒，再往后 10 秒周期。
static int gSTSRescanTick = 0;
static void STSScheduleRescan(void) {
    double delay;
    if (gSTSRescanTick < 30)      delay = 0.5;   // 0~15s
    else if (gSTSRescanTick < 52) delay = 2.0;   // 15~59s
    else                          delay = 10.0;
    gSTSRescanTick++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * (double)NSEC_PER_SEC)),
                   STSWorkQueue(), ^{
        @autoreleasepool {
            @try {
                // 0.6.1：先看有没有新的 ScreenTime 相关框架被懒加载（用户点进
                // 「屏幕使用时间」页面时才会出现）。有就立刻全量 dump，让日志
                // 能列出那个页面真正用到的数据类，然后本次重扫就能把它们挂上。
                NSArray<NSString *> *fresh = STSFreshScreenTimeImages();
                for (NSString *img in fresh) {
                    STSLogLine([NSString stringWithFormat:@"## ★ 检测到懒加载框架：%@", img]);
                    STSDumpImageFull(img);
                }
                unsigned long before = gSTSHookedKeys ? gSTSHookedKeys.count : 0;
                STSScanAll();
                unsigned long after = gSTSHookedKeys ? gSTSHookedKeys.count : 0;
                if (after != before) {
                    STSLogLine([NSString stringWithFormat:@"## 补扫新增挂钩：%lu -> %lu",
                                before, after]);
                }
            } @catch (NSException *e) {
                STSLOG("rescan exception: %@", e);
            }
            STSScheduleRescan();
        }
    });
}

// 0.5.0 根因修复：自建 Foundation 桩头的 NSObject 漏了 Class isa，导致编译器把
// STSConfig 的 BOOL ivar 排到对象偏移 0/1/2，初始化时覆盖 isa，之后任意消息发送都可能崩。
// 0.4.6 的 init 反汇编直接显示 strh [x19] / strb [x19,#2]；最新报告则崩在 shared 返回后
// 的 retain，都是同一对象布局错误的表现。桩头已补齐 isa，并修正 arm64 BOOL 为 _Bool。
// 保留延迟初始化：elaKit 注入期间主线程仍在 dyld，推迟到后台执行更稳妥。
__attribute__((constructor)) static void STSInit(void) {
    // 字符串字面量拼接，纯 C：日志首行带真实版本号，便于判断设备是否加载了旧 dylib。
    STSRawWrite("# ===== ScreenTimeSpoofer " STS_VERSION " boot =====", 1);
}

@interface STSBootstrap : NSObject
@end
static void STSRealInit(void);
@implementation STSBootstrap
+ (void)load {
    STSRawWrite("LOAD: scheduled async init", 0);
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        @autoreleasepool {
            STSRealInit();
        }
    });
}
@end

static void STSRealInit(void) {
    STSStep("LOAD: enter (async, dyld done)");
    NSString *proc = @"?";
    @try {
        const char *img0 = _dyld_get_image_name(0);
        if (img0) proc = [NSString stringWithUTF8String:img0];
    } @catch (NSException *e) {
    }

    // bundle id：确认 dylib 到底进了哪个进程（com.apple.Preferences = 设置 App）
    NSString *bid = @"?";
    @try { bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?"; } @catch (NSException *e) {}
    STSLogLine([NSString stringWithFormat:@"# pid=%d\n# process=%@\n# bundle=%@", getpid(), proc, bid]);

    @autoreleasepool {
        @try {
            STSStep("STEP: gSTSHookedKeys init");
            gSTSHookedKeys = [NSMutableSet set];
            gSTSKnownImages = [NSMutableSet set];   // 0.6.1：记录已 dump 过的框架镜像

            // 总时长基准选择器（SEL 全局唯一，指针比较即可，不依赖 plist 里可能过期的类名）
            gSelTotalScreenTime = sel_registerName("totalScreenTime");
            gSelScreenTime     = sel_registerName("screenTime");

            // 启动时已加载的 ScreenTime 镜像
            STSStep("STEP: list ScreenTime images");
            NSMutableArray<NSString *> *stImages = [NSMutableArray array];
            uint32_t imageCount = _dyld_image_count();
            for (uint32_t i = 0; i < imageCount; i++) {
                const char *name = _dyld_get_image_name(i);
                // 日志清单也排除 TweakInject 里的本插件，避免把自己的 dylib 当成框架。
                if (name && strstr(name, "ScreenTime") && !strstr(name, "/TweakInject/")) {
                    [stImages addObject:[NSString stringWithUTF8String:name]];
                }
            }
            STSLogLine([NSString stringWithFormat:@"## 启动时已加载 ScreenTime 镜像：%@",
                        stImages.count ? [stImages componentsJoinedByString:@", "] : @"(无)"]);

            // 配置：0.3.8 起 init 不碰文件，[STSConfig shared] 只在内存里设默认值，
            // 这里绝对安全。真正的文件读取延后到 STSApplyValueInner 里（已 @try）。
            STSStep("STEP: [STSConfig shared] (in-memory defaults only)");
            STSConfig *cfg = [STSConfig shared];
            STSLogLine([NSString stringWithFormat:@"## 配置(默认)：mode=%s target=%.1fmin scale=%.3f scanAll=%d heuristic=%d",
                        STSModeName(cfg.mode),
                        cfg.targetSeconds / 60.0,
                        cfg.scale,
                        cfg.scanAllScreenTimeClasses ? 1 : 0,
                        cfg.heuristicHook ? 1 : 0]);

            // 0.4.6：默认集合不在 init 里构造（那段必崩），改在这里构造 —— 此处 ObjC
            // 已完全可用（上面 [NSMutableSet set]、stringWithFormat 都跑通了）。
            STSStep("STEP: buildDefaultSets");
            [cfg buildDefaultSets];

            // 不再 dlopen：0.4.4 崩溃报告显示在 dyld 启动阶段从后台线程 dlopen 会重入 dyld、
            // 与 ellaKit 并发注入撞车（栈全在 dyld 的 Loader::getLoader/munmap）。这些框架在
            // Preferences 里本就已加载（见上面的镜像清单），dlopen 纯属多余。真正晚加载的类由
            // add_image 回调 + 周期重扫兜底。
            STSStep("STEP: skip dlopen (frameworks already loaded)");

            STSStep("STEP: setup aggregate cache (no file I/O)");
            gAggregateClass = NSClassFromString(cfg.aggregateClass);
            gAggregateSel = sel_registerName(cfg.aggregateSelector.UTF8String);

            STSStep("STEP: STSScanAll");
            STSScanAll();
            STSLogLine([NSString stringWithFormat:@"## 首次扫描完成：hooked=%lu",
                        (unsigned long)gSTSHookedKeys.count]);

            // 0.5.1：不再注册 add_image。该 API 会先对全部已加载镜像同步回调，而在 dyld
            // 回调里调用不可解析的 dispatch_get_main_queue 会直接 abort（0.5.0 的崩溃）。
            // ScreenTime 框架启动时已加载（日志第 8 行），晚加载类由下方 0.5/2/5 秒补扫和
            // 10 秒周期重扫兜底，足够覆盖设置页实际进入时间。
            STSStep("STEP: skip add_image registration");
            STSStep("STEP: ctor done");
            STSLogLine(@"## 构造器完成，已启动 10 秒周期重扫");
        } @catch (NSException *e) {
            STSLogLine([NSString stringWithFormat:@"## 构造器异常：%@ %@", e.name, e.reason]);
        }
    }

    // 串行队列读一次配置文件（@try 包住；若文件不存在 reloadIfNeeded 直接返回）
    dispatch_async(STSWorkQueue(), ^{
        @try {
            STSStep("STEP: deferred reloadIfNeeded");
            [[STSConfig shared] reloadIfNeeded];
            STSLogLine([NSString stringWithFormat:@"## 配置(文件)：mode=%s target=%.1fmin",
                        STSModeName([STSConfig shared].mode),
                        [STSConfig shared].targetSeconds / 60.0]);
        } @catch (NSException *e) {
            STSLogLine([NSString stringWithFormat:@"## 配置文件读取异常：%@ %@", e.name, e.reason]);
        }
    });

    // 2) 首 5 秒密集补扫
    for (NSNumber *delay in @[@(0.5), @(2.0), @(5.0)]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * (double)NSEC_PER_SEC)),
                       STSWorkQueue(), ^{
            @autoreleasepool {
                @try {
                    STSScanAll();
                } @catch (NSException *e) {
                    STSLOG("scan exception: %@", e);
                }
            }
        });
    }
    STSScheduleRescan();

    // 3) 框架 dump 已并入 0.5 秒周期重扫（见 STSScheduleRescan），这里只留一行标记
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * (double)NSEC_PER_SEC)),
                   STSWorkQueue(), ^{
        STSLogLine(@"## 启动 3 秒：初始框架 dump 已完成；之后每有框架懒加载会实时追加清单");
    });

    // 4) 多次累计统计：只打一次「8 秒统计」时，用户往往还没进「屏幕使用时间」
    //    页面，被调用=0 会被误读成「hook 挂错类」（boot(7).log 正是如此）。
    //    改成 8/20/45/90 秒各打一次，任何时刻抓日志都能看到累计调用数，
    //    并列出此刻已加载的相关框架，用来判断「到底进没进那个页面」。
    for (NSNumber *stat in @[@(8.0), @(20.0), @(45.0), @(90.0)]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(stat.doubleValue * (double)NSEC_PER_SEC)),
                       STSWorkQueue(), ^{
            @autoreleasepool {
                @try {
                    STSLogLine([NSString stringWithFormat:
                                @"## %.0f 秒统计：hooked=%lu 被调用=%d 被改写=%d",
                                stat.doubleValue,
                                (unsigned long)gSTSHookedKeys.count,
                                gSTSInvokedCount, gSTSChangedCount]);
                    {
                        STSConfig *c = [STSConfig shared];
                        STSLogLine([NSString stringWithFormat:
                                    @"## 生效参数：mode=%s target=%.1fmin scale=%.3f 原始总时长=%.1fmin 系数=%.4f 缩放分项=%d",
                                    STSModeName(c.mode), c.targetSeconds / 60.0, c.scale,
                                    gSTSTotalOriginal / 60.0, STSBaseFactor(), c.scaleDetails ? 1 : 0]);
                    }
                    NSMutableArray *loaded = [NSMutableArray array];
                    uint32_t ic = _dyld_image_count();
                    for (uint32_t i = 0; i < ic; i++) {
                        const char *nm = _dyld_get_image_name(i);
                        if (STSIsDumpTargetImage(nm)) {
                            NSString *s = [NSString stringWithUTF8String:nm];
                            if (s) [loaded addObject:s];
                        }
                    }
                    STSLogLine([NSString stringWithFormat:@"## 当前已加载相关框架（%lu）：%@",
                                (unsigned long)loaded.count,
                                loaded.count ? [loaded componentsJoinedByString:@", "] : @"(无)"]);
                    if (gSTSHookedKeys.count == 0) {
                        STSLogLine(@"## 结论：一个方法都没挂上 —— 类名/选择器与预期不符");
                    } else if (gSTSInvokedCount == 0) {
                        STSLogLine(@"## 结论：零调用。若上面没有 ScreenTimeSettingsUI 之类 UI 框架，说明还没进入「屏幕使用时间」页面；请手动进入并停留 5 秒后再抓日志");
                    } else if (gSTSChangedCount == 0) {
                        STSLogLine(@"## 结论：界面调用了被挂的 getter，但值未被改写 —— 检查 mode/护栏/配置");
                    } else {
                        STSLogLine(@"## 结论：已生效，界面显示值应被缩放");
                    }
                } @catch (NSException *e) {
                }
            }
        });
    }
}
