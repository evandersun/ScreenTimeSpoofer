//
//  STSConfig.m
//  ScreenTimeSpoofer
//

#import "STSConfig.h"
#import "STSConstants.h"

// 纯 C 诊断日志（与 Tweak.xm 写同一批路径，且完全不依赖 STSConfig 对象 —— 即使 init 中途被
// 信号打挂，下面这些行也已落盘，用来精确定位 shared / init / applyDictionary 断在哪一步）。
extern int open(const char *, int, ...);
extern long write(int, const void *, unsigned long);
extern int close(int);
extern unsigned long strlen(const char *);
static void STSCfgLog(const char *line) {
    if (!line) return;
    const char *paths[] = {
        "/var/mobile/Library/Logs/ScreenTimeSpoofer-boot.log",
        "/tmp/ScreenTimeSpoofer-boot.log",
        "/var/mobile/Documents/ScreenTimeSpoofer-boot.log",
    };
    long len = (long)strlen(line);
    for (int i = 0; i < 3; i++) {
        int fd = open(paths[i], 0x0001 | 0x0200 | 0x0008, 0644);   // O_WRONLY|O_CREAT|O_APPEND
        if (fd < 0) continue;
        write(fd, line, (unsigned long)len);
        write(fd, "\n", 1);
        close(fd);
    }
}

static NSString *STSJB(NSString *path) {
    // /var/mobile、/tmp 是「数据区」真实路径：rootless（/var/jb）与 roothide（.jbroot-XXXX）
    // 都不会把它们映射进 jbroot（roothide 用 libvroot 把 /var/mobile 透明重定向到随机 jbroot
    // 用户目录），所以对这类路径一律不加 /var/jb 前缀，保证设置页与 tweak 解析出的路径完全一致。
    // 只有在目录确实不存在时才回落到 /var/jb 布局（rootless 兜底）。
    if ([path hasPrefix:@"/var/mobile"] || [path hasPrefix:@"/tmp"] || [path hasPrefix:@"/var/jb"]) {
        return path;
    }
    NSString *dir = [path stringByDeletingLastPathComponent];
    if ([[NSFileManager defaultManager] fileExistsAtPath:dir]) return path;
    return [STS_JB_ROOT stringByAppendingString:path];
}

static NSString *STSConfigPath(void) {
    return STSJB(STS_CONFIG_REL_PATH);
}

static NSString *STSProbeLogPath(void) {
    return STSJB(STS_PROBE_REL_PATH);
}

static double STSDouble(NSDictionary *d, NSString *key, double fallback) {
    id v = [d objectForKey:key];
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    if ([v isKindOfClass:[NSString class]]) {
        // 只接受纯数字字符串，宁可用默认值也不猜
        NSScanner *scanner = [NSScanner scannerWithString:(NSString *)v];
        double parsed = 0;
        if ([scanner scanDouble:&parsed] && scanner.isAtEnd) return parsed;
    }
    return fallback;
}

// 0.5.3：全部改用 objectForKey:，不用字典下标语法。
// 下标会走 objectForKeyedSubscript:，崩溃报告里在飞的选择子正是它；
// objectForKey: 是 NSDictionary 的基础方法，解析路径更短也更稳。
static NSSet<NSString *> *STSSet(NSDictionary *d, NSString *key, NSSet<NSString *> *fallback) {
    id v = [d objectForKey:key];
    if ([v isKindOfClass:[NSArray class]]) {
        NSMutableSet *s = [NSMutableSet set];
        for (id o in (NSArray *)v) {
            if ([o isKindOfClass:[NSString class]]) [s addObject:o];
        }
        return s.count ? [s copy] : fallback;
    }
    return fallback;
}

static BOOL STSBool(NSDictionary *d, NSString *key, BOOL fallback) {
    id v = [d objectForKey:key];
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : fallback;
}

@interface STSConfig ()
@property (nonatomic, readwrite) STSMode mode;
@property (nonatomic, readwrite) double targetSeconds;
@property (nonatomic, readwrite) double scale;
@property (nonatomic, readwrite) double capSeconds;
@property (nonatomic, readwrite) NSString *aggregateClass;
@property (nonatomic, readwrite) NSString *aggregateSelector;
@property (nonatomic, readwrite) NSSet<NSString *> *includeClasses;
@property (nonatomic, readwrite) NSSet<NSString *> *excludeClasses;
@property (nonatomic, readwrite) NSSet<NSString *> *durationSelectors;
@property (nonatomic, readwrite) BOOL scanAllScreenTimeClasses;
@property (nonatomic, readwrite) BOOL heuristicHook;
@property (nonatomic, readwrite) BOOL scaleDetails;
@property (nonatomic, readwrite) BOOL probe;
@property (nonatomic, assign) double lastMTime;
- (void)buildDefaultSets;   // 只能在 init 之外、ObjC 可用时调用
@end

@implementation STSConfig

+ (instancetype)shared {
    // 0.4.1：不用 dispatch_once —— dyld 构造器极早期调 GCD 有崩溃风险
    // （0.3.7/0.4.0 的日志都断在 [STSConfig shared]）。构造器首次调用是单线程，
    // 之后 cfg 不再变，简单的 nil 判断足够。
    static STSConfig *cfg = nil;
    if (!cfg) {
        STSCfgLog("SHARED: creating");
        cfg = [[self alloc] init];
        STSCfgLog("SHARED: created");
    }
    return cfg;
}

// 默认值表用 C 数组保存：构造它们不需要发任何 ObjC 消息，
// 由 buildDefaultSets 在「ObjC 已确认可用」的时机构造成 NSSet。
static const char * const kDefaultIncludeClasses[] = {
    "STUsageDetails", "STAppUsage", "STCategoryUsage", "STDeviceUsage",
    "STUsageTimedItem", "STUsageBlock", "STUsageCountedItem", "STUsageItem",
    "STAppUsageGroup",
    // iOS 16 报告/视图模型相关（日志里已确认存在 STUsageReporter、USUsageReport 等）
    "STUsageReport", "STScreenTimeReport", "STDailyReport", "STWeeklyReport",
    "STAppUsageReport", "STCategoryUsageReport", "STWebUsageReport",
    "STDeviceUsageReport", "STUsageReporter",
    "USApplicationUsageReport", "USCategoryUsageReport", "USWebUsageReport",
    "USUsageReport",
    NULL
};
static const char * const kDefaultDurationSelectors[] = {
    "totalUsage", "totalUsageIncludingWeb", "totalTime", "totalTimeIncludingWeb",
    "usage", "duration", "totalDuration", "usageDuration", "activeDuration",
    "screenTime", "totalScreenTime", "seconds", "totalSeconds", "timeUsed",
    // iOS 16 可能命名
    "screenTimeInSeconds", "totalScreenTimeInSeconds", "usageTime",
    "totalUsageTime", "applicationUsageTime", "categoryUsageTime",
    "webUsageTime", "durationInSeconds", "timeInSeconds", "totalTimeInSeconds",
    NULL
};

- (instancetype)init {
    STSCfgLog("INIT: enter");
    if ((self = [super init])) {
        // 只做标量与常量赋值，避免不必要的早期依赖。
        // 0.5.0 已修复真正的崩溃根因：旧桩头 NSObject 缺少 Class isa，
        // 导致下面的 BOOL ivar 被排到对象偏移 0/1/2 并覆盖 isa。现在 ivar 布局与真实 SDK 一致。
        _mode         = STSModeTarget;
        _targetSeconds = STS_DEFAULT_TARGET_MINUTES * 60.0;
        _scale        = STS_DEFAULT_SCALE;
        _capSeconds   = 0;
        _aggregateClass    = @"STUsageReport";
        _aggregateSelector = @"totalScreenTime";
        _scanAllScreenTimeClasses = YES;
        _heuristicHook = YES;
        _scaleDetails = NO;   // 默认只改总时长，不把分项缩成 1 秒
        _probe        = NO;
        _lastMTime    = 0;
        // 三个集合留 nil：由 buildDefaultSets 在安全时机（init 之后）构造。
        // Tweak 侧对 nil 集合天然容忍（containsObject: 对 nil 返回 NO，for-in 不执行）。
        _includeClasses    = nil;
        _excludeClasses    = nil;
        _durationSelectors = nil;
    }
    STSCfgLog("INIT: done");
    return self;
}

// 只能在 init 之外（ObjC 已验证可用时）调用：用 C 数组构造默认集合。
// 直接写 ivar，不走属性 setter。
- (void)buildDefaultSets {
    STSCfgLog("SETS: enter");
    NSMutableSet *inc = [NSMutableSet set];
    for (int i = 0; kDefaultIncludeClasses[i]; i++) {
        [inc addObject:[NSString stringWithUTF8String:kDefaultIncludeClasses[i]]];
    }
    NSMutableSet *sel = [NSMutableSet set];
    for (int i = 0; kDefaultDurationSelectors[i]; i++) {
        [sel addObject:[NSString stringWithUTF8String:kDefaultDurationSelectors[i]]];
    }
    _includeClasses    = [inc copy];
    _durationSelectors = [sel copy];
    _excludeClasses    = [NSSet set];
    STSCfgLog("SETS: built");
}

- (NSString *)configPath { return STSConfigPath(); }
- (NSString *)probeLogPath { return STSProbeLogPath(); }
- (NSString *)bootLogPath { return STSJB(STS_BOOT_REL_PATH); }

#pragma mark - 默认值

+ (NSDictionary *)defaultDictionary {
    return @{
        @"Mode"            : STS_DEFAULT_MODE,
        @"TargetMinutes"   : @(STS_DEFAULT_TARGET_MINUTES),
        @"Scale"           : @(STS_DEFAULT_SCALE),
        @"CapMinutes"      : @0,

        // 总时长对象。Probe 里看到实际类名不对时在这里改。
        @"AggregateClass"    : @"STUsageReport",
        @"AggregateSelector" : @"totalScreenTime",

        @"ScanAllScreenTimeClasses" : @YES,
        // 0.4.0：默认开启保守启发式（只对返回 double + 名字像时长的方法），
        // 否则白名单没命中 iOS 16.7 真实 getter 时 hooked=0，界面完全无变化。
        // 若因此闪退，改 plist HeuristicHook=false 退回保守模式。
        @"HeuristicHook" : @YES,
        @"ScaleDetails" : @NO,
        @"Probe" : @NO,

        @"IncludeClasses" : @[
            @"STUsage",
            @"STUsageReport",
            @"STScreenTimeReport",
            @"STDailyReport",
            @"STWeeklyReport",
            @"STAppUsageReport",
            @"STCategoryUsageReport",
            @"STWebUsageReport",
            @"STDeviceUsageReport",
            @"STUsageReporter",
            @"USApplicationUsageReport",
            @"USCategoryUsageReport",
            @"USWebUsageReport",
            @"USUsageReport",
            @"STUsageDetails",
            @"STAppUsage",
            @"STWebUsage",
            @"STCategoryUsage",
            @"STDeviceUsage",
            @"STUsageTimedItem",
            @"STUsageBlock",
            @"STUsageCountedItem",
            @"STUsageItem",
            @"STAppUsageGroup",
        ],

        @"ExcludeClasses" : @[],

        // 只挂钩「零参 + 返回数值」的选择器，名字必须精确命中
        @"DurationSelectors" : @[
            @"totalUsage",
            @"totalUsageIncludingWeb",
            @"totalTime",
            @"totalTimeIncludingWeb",
            @"usage",
            @"duration",
            @"totalDuration",
            @"usageDuration",
            @"activeDuration",
            @"screenTime",
            @"totalScreenTime",
            @"seconds",
            @"totalSeconds",
            @"timeUsed",
            @"screenTimeInSeconds",
            @"totalScreenTimeInSeconds",
            @"usageTime",
            @"totalUsageTime",
            @"applicationUsageTime",
            @"categoryUsageTime",
            @"webUsageTime",
            @"durationInSeconds",
            @"timeInSeconds",
            @"totalTimeInSeconds",
        ],
    };
}

- (void)applyDictionary:(NSDictionary *)d {
    STSCfgLog("APPLY: enter");
    if (!d) return;
    NSDictionary *def = [self.class defaultDictionary];
    NSSet *defInclude   = [NSSet setWithArray:[def objectForKey:@"IncludeClasses"]];
    NSSet *defSelectors = [NSSet setWithArray:[def objectForKey:@"DurationSelectors"]];
    STSCfgLog("APPLY: default sets ready");

    // 0.5.3：全部直接写 ivar，不再走属性 setter —— 崩溃报告里最后在飞的
    // 消息正是 setHeuristicHook: 这类 setter。少发消息就少一处风险。
    NSString *mode = [d objectForKey:@"Mode"];
    STSCfgLog("APPLY: mode read");
    if ([mode isKindOfClass:[NSString class]]) {
        NSString *m = [mode lowercaseString];
        STSCfgLog("APPLY: mode lowered");
        if ([m isEqualToString:@"off"])         _mode = STSModeOff;
        else if ([m isEqualToString:@"target"]) _mode = STSModeTarget;
        else if ([m isEqualToString:@"scale"])  _mode = STSModeScale;
        else if ([m isEqualToString:@"cap"])    _mode = STSModeCap;
        else                                    _mode = STSModeTarget;
    } else {
        _mode = STSModeTarget;
    }
    STSCfgLog("APPLY: mode done");

    double t = STSDouble(d, @"TargetMinutes", STS_DEFAULT_TARGET_MINUTES) * 60.0;
    _targetSeconds = t > 0 ? t : 0;
    STSCfgLog("APPLY: target done");
    double sc = STSDouble(d, @"Scale", STS_DEFAULT_SCALE);
    _scale = sc > 0 ? sc : 1.0;
    double cp = STSDouble(d, @"CapMinutes", 0) * 60.0;
    _capSeconds = cp > 0 ? cp : 0;
    STSCfgLog("APPLY: numbers done");

    NSString *aggCls = [d objectForKey:@"AggregateClass"];
    if ([aggCls isKindOfClass:[NSString class]] && [aggCls length]) {
        _aggregateClass = aggCls;
    }
    STSCfgLog("APPLY: aggCls done");

    NSString *aggSel = [d objectForKey:@"AggregateSelector"];
    if ([aggSel isKindOfClass:[NSString class]] && [aggSel length]) {
        _aggregateSelector = aggSel;
    }
    STSCfgLog("APPLY: aggSel done");

    _includeClasses    = STSSet(d, @"IncludeClasses", defInclude);
    STSCfgLog("APPLY: include done");
    _excludeClasses    = STSSet(d, @"ExcludeClasses", [NSSet set]);
    _durationSelectors = STSSet(d, @"DurationSelectors", defSelectors);
    STSCfgLog("APPLY: selector sets done");
    _scanAllScreenTimeClasses = STSBool(d, @"ScanAllScreenTimeClasses", YES);
    STSCfgLog("APPLY: scanAll done");
    _heuristicHook = STSBool(d, @"HeuristicHook", YES);
    _scaleDetails = STSBool(d, @"ScaleDetails", NO);
    _probe = STSBool(d, @"Probe", NO);
    STSCfgLog("APPLY: done");
}

#pragma mark - 读写

- (void)writeDefaultsIfNeeded {
    NSString *path = STSConfigPath();
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return;

    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    [[self.class defaultDictionary] writeToFile:path atomically:YES];
    // 让 mobile 用户可读写，方便用 Filza / SSH 改
    [[NSFileManager defaultManager] setAttributes:@{NSFileOwnerAccountID: @(STS_MOBILE_UID),
                                                    NSFileGroupOwnerAccountID: @(STS_MOBILE_UID),
                                                    NSFilePosixPermissions: @0644}
                                     ofItemAtPath:path
                                            error:NULL];
}

- (double)targetMinutes {
    return self.targetSeconds / 60.0;
}

- (BOOL)setTargetMinutes:(double)minutes {
    NSString *path = STSConfigPath();

    NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
    if (![d isKindOfClass:[NSDictionary class]] || !d) {
        d = [[self.class defaultDictionary] mutableCopy];
    }

    d[@"TargetMinutes"] = @(minutes);
    // 用户点了「应用」就说明他要用，别让它停在 off
    NSString *mode = d[@"Mode"];
    if ([mode isKindOfClass:[NSString class]] && [(NSString *)mode isEqualToString:@"off"]) {
        d[@"Mode"] = @"target";
    }

    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    BOOL ok = [d writeToFile:path atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFileOwnerAccountID: @(STS_MOBILE_UID),
                                                    NSFileGroupOwnerAccountID: @(STS_MOBILE_UID),
                                                    NSFilePosixPermissions: @0644}
                                     ofItemAtPath:path
                                            error:NULL];

    self.lastMTime = 0;      // 强制下次 reload 生效
    [self reloadIfNeeded];
    return ok;
}

- (void)reloadIfNeeded {
    NSString *path = STSConfigPath();

    // 用 NSFileManager 取 mtime：不碰 struct stat，省掉一套平台相关的头文件依赖
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    id mod = attrs[NSFileModificationDate];
    if (![mod isKindOfClass:[NSDate class]]) return;

    double mtime = [(NSDate *)mod timeIntervalSinceReferenceDate];
    if (mtime == self.lastMTime) return;

    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![d isKindOfClass:[NSDictionary class]]) return;

    self.lastMTime = mtime;
    [self applyDictionary:d];
}

@end
