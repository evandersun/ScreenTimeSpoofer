//
//  STSConfig.h
//  ScreenTimeSpoofer
//
//  运行期配置：从 /var/mobile/Library/Preferences/com.evander.screentimespoofer.plist 读取，
//  文件修改后自动热重载（按 mtime 判断），改完不需要重启设置 App。
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, STSMode) {
    STSModeOff    = 0,  // 关闭（原样返回）
    STSModeTarget = 1,  // 按「目标总时长」等比缩放：所有数字、柱状图同比缩小，界面自洽
    STSModeScale  = 2,  // 按固定系数缩放
    STSModeCap    = 3,  // 按系数缩放后再封顶
};

@interface STSConfig : NSObject

+ (instancetype)shared;

/// 读取配置；文件 mtime 变化时才真正解析，可被 getter 高频调用
- (void)reloadIfNeeded;

@property (nonatomic, readonly) STSMode mode;
@property (nonatomic, readonly) double targetSeconds;   // STSModeTarget 的目标总秒数
@property (nonatomic, readonly) double scale;           // STSModeScale / STSModeCap 的系数
@property (nonatomic, readonly) double capSeconds;      // 0 = 不封顶

/// 聚合对象（总时长）的类与选择器，用于反推缩放比例
@property (nonatomic, readonly) NSString *aggregateClass;
@property (nonatomic, readonly) NSString *aggregateSelector;

/// 需要挂钩的类名 / 排除的类名 / 需要挂钩的零参返回数值的选择器
@property (nonatomic, readonly) NSSet<NSString *> *includeClasses;
@property (nonatomic, readonly) NSSet<NSString *> *excludeClasses;
@property (nonatomic, readonly) NSSet<NSString *> *durationSelectors;

/// 额外兜底：扫描 ScreenTime*/UsageTracking* 镜像下的全部类（应对版本改名）
@property (nonatomic, readonly) BOOL scanAllScreenTimeClasses;

/// 启发式挂钩：除了精确白名单，再按「名字像时长 + 返回 double」放宽匹配。
/// 设为 NO 则回到只挂精确白名单的保守模式（用于排查闪退）。
@property (nonatomic, readonly) BOOL heuristicHook;

/// 是否也等比缩放「分项 getter」（各 App / 分类 / 图表时长）。
/// 默认 NO：只把总时长改成填写值，分项保持真实值。
/// 真实总时长常有数小时，压到 15 分钟时等比缩放会把几十秒的单 App 缩成 1 秒，
/// 观感很差；需要「总和自洽」时才把它设为 YES。
@property (nonatomic, readonly) BOOL scaleDetails;

/// 打开后会把候选方法清单 dump 到 /var/mobile/Library/Logs/ScreenTimeSpoofer-probe.log
@property (nonatomic, readonly) BOOL probe;

/// 把默认配置写到磁盘（文件不存在时调用）
- (void)writeDefaultsIfNeeded;

/// 用内置 C 常量表构造默认的类/选择器集合。
/// 只能在 init 之外、ObjC 已可用时调用（init 里不做 ObjC 消息，见 .m 注释）。
- (void)buildDefaultSets;

/// 设置页用的读写接口（写完立即刷新内存里的配置）
- (double)targetMinutes;
- (BOOL)setTargetMinutes:(double)minutes;

@property (nonatomic, readonly) NSString *configPath;
@property (nonatomic, readonly) NSString *probeLogPath;
@property (nonatomic, readonly) NSString *bootLogPath;

@end
