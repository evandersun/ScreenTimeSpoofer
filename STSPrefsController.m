//
//  STSPrefsController.m
//  ScreenTimeSpoofer —— 设置页（PreferenceLoader）
//
//  演进记录（都是踩过的坑，别改回去）：
//   · v0.2 自绘表格 + 空 specifiers：PSListController 内部路径太多，越界崩溃。
//   · v0.3.0 改回 Root.plist + PSSpecifier：页面能开，但全空。
//       - 原因1：加载写在 -specifiers getter 里没用，框架直读 _specifiers ivar，
//                而 [super viewDidLoad] 里就 reload 了，那一刻还是 nil。
//       - 原因2：loadSpecifiersFromPlistName:target: 依赖 self.bundle，从 detail
//                直接 push 上来时没赋值，它跑去 mainBundle 找 Root.plist。
//   · v0.3.1 修好上面两条（super 前填 ivar + 显式传 bundle），内容出来了，
//     但 PSButtonCell 这条 specifier 被框架丢掉 → 按钮不显示。
//   · v0.3.2 「应用」按钮不再用 PSButtonCell，改成 tableFooterView 里的原生
//     UIButton —— 不依赖 Preferences 的任何 cell 枚举，必定可见可点。
//   · v0.5.8 footer 加第二个按钮「打开屏幕使用时间」，走 URL 深链。
//   · v0.6.0 改成「进程内模拟点击设置首页那一行」+ 状态标签 + 兜底弹窗；
//     v0.6.2 定位到「首页不 active 时 didSelect 被忽略」，改为多阶段协调器，
//     跳转终于成功。v0.6.3 解决跳转要 20 多秒：删掉阻塞主线程的同步
//     openURL:/AppDelegate 直投、URL 精简为 2 个纯异步、立即 pop + 缩短延迟。
//   · v0.6.4 footer 加第三个按钮「QQ群：1135135953」，纯异步 openURL 打开
//     QQ 群 universal-share 链接（https 交给系统，不进跳转协调器）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import "STSConstants.h"

#pragma mark - 与 dylib 共用同一份 boot 日志（0.6.1）

// 0.6.1：之前设置页的所有诊断只走 NSLog（系统 syslog），用户抓回来的
// ScreenTimeSpoofer-boot.log 里完全看不到按钮有没有被点、进程内导航走到哪一步，
// 于是「按了没反应」和「hook 没生效」两件事永远分不清。现在把关键节点
// 追加到 dylib 写的同一个文件，用户只需抓一份日志就能定位。
extern int open(const char *, int, ...);
extern long write(int, const void *, unsigned long);
extern int close(int);
extern unsigned long strlen(const char *);

// 0.6.3：给 [JUMP] 日志自动加 [+X.XXs] 相对耗时，用来直接看出 20 多秒花在哪一段。
// 用纯 C gettimeofday，避免引入 libdispatch / NSDate 依赖；timeval 在 arm64 iOS 上是
// { long tv_sec; int tv_usec; }，与真实 SDK 布局一致。
struct STSTimeval { long tv_sec; int tv_usec; };
extern int gettimeofday(struct STSTimeval *tv, void *tz);
static double STSJumpNow(void) {
    struct STSTimeval tv; tv.tv_sec = 0; tv.tv_usec = 0;
    gettimeofday(&tv, (void *)0);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0;
}
static double gSTSJumpT0 = 0.0;

static void STSPrefsBootLog(NSString *line) {
    @try {
        NSString *out = line;
        if (gSTSJumpT0 > 0.0) {
            const char *raw = [line UTF8String];
            if (raw && raw[0] == '[' && raw[1] == 'J' && raw[2] == 'U' &&
                raw[3] == 'M' && raw[4] == 'P') {
                out = [NSString stringWithFormat:@"[+%5.2fs] %@",
                       STSJumpNow() - gSTSJumpT0, line];
            }
        }
        const char *c = [out UTF8String];
        if (!c) return;
        const char *paths[] = {
            "/var/mobile/Library/Logs/ScreenTimeSpoofer-boot.log",
            "/tmp/ScreenTimeSpoofer-boot.log",
            "/var/mobile/Documents/ScreenTimeSpoofer-boot.log",
        };
        unsigned long len = strlen(c);
        for (int i = 0; i < 3; i++) {
            int fd = open(paths[i], 0x0001 | 0x0200 | 0x0008, 0644);  // O_WRONLY|O_CREAT|O_APPEND
            if (fd < 0) continue;
            write(fd, c, len);
            write(fd, "\n", 1);
            close(fd);
        }
    } @catch (NSException *e) {}
}

#pragma mark - 配置读写（本文件私有，不与其他镜像共享类名）

/// /var/mobile 是越狱无关的「数据区」真实路径：rootless / roothide 都不会把它映射进 jbroot，
/// 所以直接用原路径最稳；只有父目录确实不存在时才回落到 /var/jb 布局。
static NSString *STSPrefsPath(void) {
    NSString *dir = [STS_CONFIG_REL_PATH stringByDeletingLastPathComponent];
    if ([[NSFileManager defaultManager] fileExistsAtPath:dir]) return STS_CONFIG_REL_PATH;
    return [STS_JB_ROOT stringByAppendingString:STS_CONFIG_REL_PATH];
}

static double STSPrefsCurrentMinutes(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:STSPrefsPath()];
    id v = d[@"TargetMinutes"];
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v doubleValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v doubleValue];
    return STS_DEFAULT_TARGET_MINUTES;
}

static BOOL STSPrefsWriteMinutes(double minutes) {
    NSString *path = STSPrefsPath();

    NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
    if (!d || ![d isKindOfClass:[NSDictionary class]]) {
        d = [[NSMutableDictionary alloc] init];
    }

    d[@"TargetMinutes"] = @(minutes);
    // 用户在设置页改时间就是要它生效，别把 Mode 停在 off
    d[@"Mode"] = STS_DEFAULT_MODE;

    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    BOOL ok = [d writeToFile:path atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFileOwnerAccountID: @(STS_MOBILE_UID),
                                                    NSFileGroupOwnerAccountID: @(STS_MOBILE_UID),
                                                    NSFilePosixPermissions: @0666}
                                     ofItemAtPath:path
                                            error:NULL];
    return ok;
}

#pragma mark - specifier 装载（三条路，逐级降级）

/// 从 Root.plist 装载：先试显式 bundle 的三参版本，再试两参版本，最后代码构造。
static NSArray *STSLoadSpecifiers(PSListController *target, Class cls) {
    NSBundle *b = nil;
    @try {
        b = [NSBundle bundleForClass:cls];
    } @catch (NSException *e) {
        NSLog(@"[STS] bundleForClass 异常: %@", e);
    }

    // 1) 三参版本：显式指定 bundle，不依赖 self.bundle
    @try {
        if (b && [target respondsToSelector:@selector(loadSpecifiersFromPlistName:target:bundle:)]) {
            NSArray *a = [target loadSpecifiersFromPlistName:@"Root" target:target bundle:b];
            NSLog(@"[STS] loadSpecifiers(bundle:) -> %lu 项, bundle=%@",
                  (unsigned long)a.count, [b bundlePath]);
            if (a.count) return a;
        }
    } @catch (NSException *e) {
        NSLog(@"[STS] loadSpecifiers(bundle:) 异常: %@", e);
    }

    // 2) 两参版本：老实现，靠 self.bundle / mainBundle
    @try {
        NSArray *a = [target loadSpecifiersFromPlistName:@"Root" target:target];
        NSLog(@"[STS] loadSpecifiers() -> %lu 项", (unsigned long)a.count);
        if (a.count) return a;
    } @catch (NSException *e) {
        NSLog(@"[STS] loadSpecifiers() 异常: %@", e);
    }

    return nil;
}

/// 代码构造兜底。cell 用整型枚举（PSEditTextCell=8 / PSGroupCell=0），
/// 只有 plist 完全加载不出来时才走这里。
static NSArray *STSManualSpecifiers(id target) {
    NSMutableArray *arr = [NSMutableArray array];

    @try {
        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"屏幕使用时间"];
        if (group) {
            [group setProperty:@"填入分钟数后点「应用」；点「打开屏幕使用时间」进入该页面查看；点「QQ群：1135135953」加入交流群"
                        forKey:@"footerText"];
            [arr addObject:group];
        }
    } @catch (NSException *e) {
        NSLog(@"[STS] groupSpecifier 异常: %@", e);
    }

    @try {
        PSSpecifier *edit = [PSSpecifier preferenceSpecifierNamed:@"目标总时长（分钟）"
                                                           target:target
                                                              set:@selector(setPreferenceValue:specifier:)
                                                              get:@selector(readPreferenceValue:)
                                                           detail:nil
                                                             cell:8      // PSEditTextCell
                                                             edit:nil];
        if (edit) {
            [edit setProperty:@"TargetMinutes" forKey:@"key"];
            [edit setProperty:@"com.evander.screentimespoofer" forKey:@"defaults"];
            [edit setProperty:@(STS_DEFAULT_TARGET_MINUTES) forKey:@"default"];
            [edit setProperty:@YES forKey:@"isNumeric"];
            [arr addObject:edit];
        }
    } @catch (NSException *e) {
        NSLog(@"[STS] editSpecifier 异常: %@", e);
    }

    NSLog(@"[STS] 代码构造 specifier: %lu 项", (unsigned long)arr.count);
    return arr;
}

/// 递归找页面里的输入框：用来直接读用户当前输入，
/// 不依赖 PSEditTextCell 什么时候把值提交给 setPreferenceValue:specifier:。
static UITextField *STSFindTextField(UIView *v) {
    if (!v) return nil;
    if ([v isKindOfClass:[UITextField class]]) return (UITextField *)v;
    for (UIView *sub in v.subviews) {
        UITextField *found = STSFindTextField(sub);
        if (found) return found;
    }
    return nil;
}

/// 递归找页面里的 UITableView 实例。
/// ★ 不要直接用 self.tableView：iOS 15+ 重构后 PSListController 不再继承
///   UITableViewController，没有这个 selector（v0.3.2 在这里崩过）。
static UITableView *STSFindTableView(UIView *v) {
    if (!v) return nil;
    if ([v isKindOfClass:[UITableView class]]) return (UITableView *)v;
    for (UIView *sub in v.subviews) {
        UITableView *found = STSFindTableView(sub);
        if (found) return found;
    }
    return nil;
}

#pragma mark - 打开「屏幕使用时间」：多阶段跳转协调器（v0.6.2）

// ★ 0.6.0 / 0.6.1 为什么「按了没反应」：
//   那时是在「插件设置页」（导航栈栈顶）里，去调用栈底「设置首页」控制器的
//   tableView:didSelectRowAtIndexPath:。首页此刻不是 active / topViewController，
//   Preferences 的 PSListController 会直接忽略这次选中 —— 页面纹丝不动。
//   0.6.1 只补了诊断日志，没有动这个逻辑，等于没修。
//
// ★ v0.6.3 在 v0.6.2（跳转已成功）基础上把 20 多秒压到 1 秒内：
//   A. URL 深链 —— 2 个候选，全部**纯异步**发出（删掉同步 openURL: 与
//      AppDelegate 直投，它们会阻塞主线程等待系统判定，是 20 多秒的主因）。
//   B. 立即 popToRoot 回设置首页（animated:NO）—— 100% 有效的可见变化，
//      也顺带让首页变成 active。不再单独等 0.9 秒验证 URL。
//   C. 0.25 秒后首页 active，触发「屏幕使用时间」那一行的 didSelect 才真正 push。
//   D. 0.5 秒后验证栈顶；仍未进去才全局弹窗提示（用户已在首页，那一行就在眼前）。
//   每条 [JUMP] 日志自动带 [+X.XXs] 相对耗时，可直接定位任何残留卡顿。
//
// ★ 延迟任务挂在独立的协调器单例上：pop 之后插件页 self 会被销毁，
//   不能再用 performSelector:afterDelay: 调度到 self（会发给野指针或直接丢失）。

static NSArray *STSScreenTimeURLStrings(void) {
    // 0.6.3：只留 2 个已验证有效的候选。v0.6.2 的 7 个候选里，
    // x-apple.systempreferences: 是 macOS scheme、带 &path= 的在 iOS 上无效，
    // 每个都要走一次 SpringBoard 判定；再叠加同步 openURL: 就是 20 多秒。
    return @[
        @"App-prefs:SCREEN_TIME",       // iOS 17.3 实测可打开 Screen Time
        @"prefs:root=SCREEN_TIME",      // iOS 16/17 通用写法
    ];
}

/// 「屏幕使用时间」这一行在设置首页的标题（多语言）。
static BOOL STSTitleLooksLikeScreenTime(NSString *t) {
    if (![t isKindOfClass:[NSString class]] || [t length] == 0) return NO;
    if ([t containsString:@"屏幕使用时间"] || [t containsString:@"螢幕使用時間"] ||
        [t containsString:@"螢幕時間"]     || [t containsString:@"屏幕時間"]) return YES;
    NSString *lo = [t lowercaseString];
    if ([lo containsString:@"screen time"] || [lo containsString:@"screentime"]) return YES;
    if ([t containsString:@"スクリーンタイム"] || [t containsString:@"스크린 타임"]) return YES;
    if ([lo containsString:@"temps d'écran"] || [lo containsString:@"bildschirmzeit"]) return YES;
    if ([lo containsString:@"tiempo de uso"] || [lo containsString:@"tempo de uso"]) return YES;
    return NO;
}

/// 递归收集 cell 里所有 UILabel 的文本。iOS 16 设置首页的「屏幕使用时间」是自定义
/// cell，标题未必在 textLabel 里；只看 textLabel 会漏掉（0.6.0 找不到行的原因之一）。
static void STSCollectLabels(UIView *v, NSMutableArray *out, int depth) {
    if (!v || depth > 6) return;
    @try {
        if ([v isKindOfClass:[UILabel class]]) {
            NSString *t = [(UILabel *)v text];
            if ([t length]) [out addObject:t];
        }
        for (UIView *sub in [v subviews]) STSCollectLabels(sub, out, depth + 1);
    } @catch (NSException *e) {
    }
}

/// 栈顶是否已不是「设置首页 / 插件页」—— 即真的进入了新页面。
static BOOL STSIsNewPane(UINavigationController *nav, UIViewController *home) {
    @try {
        NSArray *stack = [nav viewControllers];
        UIViewController *top = stack.count ? [stack objectAtIndex:stack.count - 1] : nil;
        NSString *cn = top ? NSStringFromClass([top class]) : @"(nil)";
        STSPrefsBootLog([NSString stringWithFormat:@"[JUMP] 栈顶=%@ 栈深=%lu",
                         cn, (unsigned long)stack.count]);
        if (!top) return NO;
        if ([cn isEqualToString:@"STSRootListController"]) return NO;
        if (home && top == home) return NO;
        return YES;
    } @catch (NSException *e) {
        STSPrefsBootLog(@"[JUMP] 栈顶检查异常");
        return NO;
    }
}

/// 在「设置首页已 active」的前提下，触发「屏幕使用时间」那一行的 didSelect。
/// 与用户手指点一下完全等价，由 Preferences 自己完成 lazy bundle 加载和 push。
static BOOL STSSelectOnActiveHome(UINavigationController *nav, UIViewController *home) {
    @try {
        if (!home) home = [[nav viewControllers] firstObject];
        UIView *rootView = nil;
        @try { rootView = [home view]; } @catch (NSException *e) {}
        UITableView *tv = STSFindTableView(rootView);
        if (!tv) {
            STSPrefsBootLog(@"[JUMP] 首页找不到 UITableView");
            return NO;
        }
        id<UITableViewDataSource> ds = (id<UITableViewDataSource>)[tv dataSource];
        id<UITableViewDelegate>  dl = (id<UITableViewDelegate>)[tv delegate];
        if (!ds || !dl) {
            STSPrefsBootLog(@"[JUMP] 首页表格 dataSource/delegate 为空");
            return NO;
        }

        NSInteger sections = 1;
        @try { sections = [tv numberOfSections]; } @catch (NSException *e) { sections = 1; }
        if (sections <= 0) sections = 1;
        if (sections > 30) sections = 30;   // 0.6.3：收紧上限，避免逐格生成拖慢跳转
        STSPrefsBootLog([NSString stringWithFormat:@"[JUMP] 首页表格 sections=%ld",
                         (long)sections]);

        for (NSInteger sec = 0; sec < sections; sec++) {
            NSInteger rows = 0;
            @try { rows = [tv numberOfRowsInSection:sec]; }
            @catch (NSException *e) { continue; }
            if (rows > 60) rows = 60;

            for (NSInteger r = 0; r < rows; r++) {
                NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:sec];
                UITableViewCell *cell = nil;
                @try {
                    // 用 dataSource 直接生成 cell：首页此刻可能还没把目标行滚到可见区，
                    // -[UITableView cellForRowAtIndexPath:] 对不可见行返回 nil。
                    cell = (UITableViewCell *)[ds tableView:tv cellForRowAtIndexPath:ip];
                } @catch (NSException *e) { continue; }
                if (!cell) continue;

                NSMutableArray *titles = [NSMutableArray array];
                @try {
                    NSString *tl = [[cell textLabel] text];
                    if ([tl length]) [titles addObject:tl];
                } @catch (NSException *e) {}
                @try {
                    NSString *al = [cell accessibilityLabel];
                    if ([al length]) [titles addObject:al];
                } @catch (NSException *e) {}
                STSCollectLabels(cell, titles, 0);

                NSString *hit = nil;
                for (NSString *t in titles) {
                    if (STSTitleLooksLikeScreenTime(t)) { hit = t; break; }
                }
                if (!hit) continue;

                STSPrefsBootLog([NSString stringWithFormat:
                                 @"[JUMP] ★ 命中「%@」section=%ld row=%ld，触发 didSelect",
                                 hit, (long)sec, (long)r]);
                @try { [tv selectRowAtIndexPath:ip animated:NO scrollPosition:0]; }
                @catch (NSException *e) {}
                @try { [dl tableView:tv didSelectRowAtIndexPath:ip]; }
                @catch (NSException *e) {
                    STSPrefsBootLog(@"[JUMP] didSelect 异常");
                    return NO;
                }
                return YES;   // 是否真的 push 由下一阶段验证，绝不假装成功
            }
        }
        STSPrefsBootLog(@"[JUMP] 首页表格里没找到「屏幕使用时间」行");
    } @catch (NSException *e) {
        STSPrefsBootLog(@"[JUMP] 首页 didSelect 阶段异常");
    }
    return NO;
}

/// A 阶段（0.6.3）：只发 2 个候选的**纯异步** openURL，立即返回，绝不阻塞主线程。
///
/// v0.6.2 为什么跳转要 20 多秒：这里对每个候选同时调了异步版和同步版
/// `[app openURL:u]`，还额外直投 AppDelegate —— 7 个候选共 14+ 次 openURL。
/// 同步版在 Preferences 进程内对无效 scheme 会阻塞等待 SpringBoard 判定/超时，
/// 主线程被卡住，连后面 performSelector:afterDelay: 的定时器也一起排队，
/// 于是明明只有 2.1 秒的延迟，实际要等二十几秒才有反应。
/// 现在全部改成异步，发出即返回；completion 只用于记日志，不据此判断成败。
static void STSSendURLSchemes(UIApplication *app) {
    if (!app) { STSPrefsBootLog(@"[JUMP] 取不到 UIApplication，跳过 URL"); return; }
    int sent = 0;
    for (NSString *s in STSScreenTimeURLStrings()) {
        NSURL *u = nil;
        @try { u = [NSURL URLWithString:s]; } @catch (NSException *e) {}
        if (!u) continue;
        @try {
            [app openURL:u options:@{} completionHandler:^(BOOL ok) {
                STSPrefsBootLog([NSString stringWithFormat:@"[JUMP] URL 回调 %@ -> %d", s, ok]);
            }];
            sent++;
        } @catch (NSException *e) {}
    }
    STSPrefsBootLog([NSString stringWithFormat:
                     @"[JUMP] URL 深链异步发出（%d 个，不阻塞主线程）", sent]);
}

#pragma mark - 跳转协调器（独立对象，pop 之后仍能存活）

@interface STSJumpCoordinator : NSObject {
    UINavigationController *_nav;   // 强引用，pop 之后导航控制器仍在
    UIViewController *_home;        // 设置首页控制器，用于判断「是否还在首页」
    BOOL _finished;
}
+ (instancetype)shared;
- (void)startFrom:(UIViewController *)from;
@end

static STSJumpCoordinator *gSTSJumpCoordinator = nil;

@implementation STSJumpCoordinator

+ (instancetype)shared {
    if (!gSTSJumpCoordinator) gSTSJumpCoordinator = [[self alloc] init];
    return gSTSJumpCoordinator;
}

- (void)startFrom:(UIViewController *)from {
    _finished = NO;
    gSTSJumpT0 = STSJumpNow();          // 0.6.3：耗时计时起点
    @try { _nav = (UINavigationController *)[from navigationController]; }
    @catch (NSException *e) { _nav = nil; }
    NSArray *stack = _nav ? [_nav viewControllers] : nil;
    _home = stack.count ? [stack firstObject] : nil;
    STSPrefsBootLog([NSString stringWithFormat:
                     @"[JUMP] 开始：nav=%@ 栈深=%lu 首页=%@",
                     _nav ? @"有" : @"无", (unsigned long)stack.count,
                     _home ? NSStringFromClass([_home class]) : @"(nil)"]);
    if (!_nav) { [self phaseGiveUp]; return; }

    UIApplication *app = nil;
    @try { app = [UIApplication sharedApplication]; } @catch (NSException *e) {}
    STSSendURLSchemes(app);   // 纯异步，发出即返回

    // 0.6.3：不再等 0.9 秒验证 URL（那是 20 多秒的一部分）。URL 若生效，
    // 栈顶会变，phaseSelect 里的 STSIsNewPane 会检测到并提前结束。
    // 立即 pop 回设置首页 = 100% 有效的可见变化，同时让首页变成 active，
    // 这样稍后的 didSelect 才会被 Preferences 真正执行。animated:NO 省掉动画时间。
    @try { [_nav popToRootViewControllerAnimated:NO]; }
    @catch (NSException *e) { STSPrefsBootLog(@"[JUMP] pop 异常"); }
    STSPrefsBootLog(@"[JUMP] 已立即 pop 回设置首页（animated:NO）");
    [self performSelector:@selector(phaseSelect) withObject:nil afterDelay:0.25];
}

- (void)phaseSelect {
    if (_finished) return;
    if (STSIsNewPane(_nav, _home)) {
        STSPrefsBootLog(@"[JUMP] ✔ URL 深链已生效（栈顶已变），直接进入");
        _finished = YES;
        return;
    }
    STSPrefsBootLog(@"[JUMP] 首页已 active，触发「屏幕使用时间」行 didSelect");
    STSSelectOnActiveHome(_nav, _home);
    [self performSelector:@selector(phaseSelectVerify) withObject:nil afterDelay:0.5];
}

- (void)phaseSelectVerify {
    if (_finished) return;
    if (STSIsNewPane(_nav, _home)) {
        STSPrefsBootLog(@"[JUMP] ✔ 已进入「屏幕使用时间」（总耗时见上方时间戳）");
        _finished = YES;
        return;
    }
    [self phaseGiveUp];
}

- (void)phaseGiveUp {
    STSPrefsBootLog(@"[JUMP] ✘ 自动跳转全部未生效，弹窗提示手动进入");
    @try {
        // UIAlertView 自己找 window，不依赖 presentingViewController 层级
        // （此时插件页已被 pop，presentViewController: 会失败）。
        UIAlertView *av = [[UIAlertView alloc] initWithTitle:@"已返回设置首页"
            message:@"当前系统未响应自动跳转。请在本页点开「屏幕使用时间」查看效果；已设置的总时长在重新进入该页面后生效。"
            delegate:nil cancelButtonTitle:@"好" otherButtonTitles:nil];
        [av show];
    } @catch (NSException *e) {
        STSPrefsBootLog(@"[JUMP] 弹窗失败");
    }
}

@end

#pragma mark - QQ 群入口（v0.6.4）

/// QQ 群「1135135953」的 universal-share 链接。原样保留用户给出的全部参数
/// （authKey / busi_data / data / svctype / tempid），不做二次编码：NSURL 把
/// query 原样交给系统，SpringBoard 再用 Safari / QQ 打开它。
static NSString *STSQQGroupURLString(void) {
    return @"https://qun.qq.com/universal-share/share?ac=1&authKey=6JLxrWHLHaDCYS93fePT0qoFaPsl9h3DYOXqEWbvW0eeqN0t4UiH%2Fj7UNgmbGCO2&busi_data=eyJncm91cENvZGUiOiIxMTM1MTM1OTUzIiwidG9rZW4iOiJwdGxuRjNiUnZsWGdrVlNrYTB6RGgva3RZRHUrZUVBVHB1QjdzNTZUTElBVXVYNkJLZ2IzV1BKSjQxVzdYUWRCIiwidWluIjoiMjE5NzgyMjQzNyJ9&data=DPx-nZpHpXqtm9-ZXBmI0VFeTa5MhmbveENjh5pLUtgvwJoPpvzhMR3PHgo8vsWk1YnnIMz0crdua5r-XGDNmg&svctype=4&tempid=h5_group_info";
}

#pragma mark - 设置页

@interface STSRootListController : PSListController {
    BOOL _stsLoaded;        // 装载尝试过就不再重复
    UIButton *_stsApply;    // footer 里的「应用」按钮
    UIButton *_stsOpen;     // footer 里的「打开屏幕使用时间」按钮
    UIButton *_stsQQ;       // footer 里的「QQ群：1135135953」按钮（v0.6.4）
    UILabel  *_stsStatus;   // footer 里的状态标签：保证每次点击都有可见反应
}
@end

@implementation STSRootListController

/// 唯一的装载入口：三条路走完仍为空就返回空数组（不返回 nil，防止调用方再自己加载）
- (void)sts_ensureSpecifiers {
    if (_stsLoaded) return;
    _stsLoaded = YES;

    NSArray *a = STSLoadSpecifiers(self, [self class]);
    if (a.count == 0) a = STSManualSpecifiers(self);
    _specifiers = a ?: @[];
    NSLog(@"[STS] specifiers ready: %lu 项", (unsigned long)_specifiers.count);
}

/// 覆写 getter 只是为了让外部调用拿到真实数组；
/// 真正起作用的是 viewDidLoad 里「super 之前」先把 _specifiers 填好。
- (NSArray *)specifiers {
    [self sts_ensureSpecifiers];
    return _specifiers;
}

- (void)viewDidLoad {
    // ★ 关键顺序：先填 _specifiers，再走 super 的 reloadData。
    //   反过来的话 super 里读到的就是 nil，页面就白了。
    [self sts_ensureSpecifiers];

    @try {
        [super viewDidLoad];
    } @catch (NSException *e) {
        NSLog(@"[STS] super viewDidLoad 异常: %@", e);
    }

    self.title = @"屏幕使用时间";
    [self sts_installFooterButtons];

    if (_specifiers.count == 0) {
        // 三条路全失败：至少把原因显示出来，不给你一个纯白页
        NSLog(@"[STS] specifier 全部装载失败，bundle=%@", [NSBundle bundleForClass:[self class]]);
        UILabel *lbl = [[UILabel alloc] initWithFrame:self.view.bounds];
        lbl.text = @"设置项加载失败，请查看 [STS] 日志";
        lbl.textAlignment = 1;   // NSTextAlignmentCenter
        lbl.textColor = [UIColor darkGrayColor];
        lbl.font = [UIFont systemFontOfSize:14];
        [self.view addSubview:lbl];
    }
}

#pragma mark - footer：三个按钮 + 状态标签（tableFooterView，不依赖 PSButtonCell）

#define STS_FOOTER_H  236.0

- (void)sts_installFooterButtons {
    @try {
        UITableView *tv = STSFindTableView(self.view);
        if (!tv) {
            NSLog(@"[STS] sts_installFooterButtons: 找不到 UITableView，放弃");
            return;
        }
        CGFloat w = tv.bounds.size.width;
        if (w <= 0) w = self.view.bounds.size.width;
        if (w <= 0) w = 320;

        UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, STS_FOOTER_H)];

        // ① 应用：把输入框里的分钟数写进配置文件
        UIButton *apply = [[UIButton alloc] initWithFrame:CGRectMake(0, 0, 0, 0)];   // UIButtonTypeCustom
        apply.frame = CGRectMake(16, 14, w - 32, 46);
        [apply setTitle:@"应用" forState:0];
        [apply setTitleColor:[UIColor whiteColor] forState:0];
        apply.backgroundColor = [UIColor systemBlueColor];
        apply.titleLabel.font = [UIFont boldSystemFontOfSize:17];
        apply.layer.cornerRadius = 10;
        apply.layer.masksToBounds = YES;
        [apply addTarget:self action:@selector(applyTapped) forControlEvents:64];  // TouchUpInside
        [footer addSubview:apply];
        _stsApply = apply;

        // ② 打开「屏幕使用时间」
        UIButton *open = [[UIButton alloc] initWithFrame:CGRectMake(0, 0, 0, 0)];
        open.frame = CGRectMake(16, 70, w - 32, 46);
        [open setTitle:@"打开屏幕使用时间" forState:0];
        [open setTitleColor:[UIColor whiteColor] forState:0];
        open.backgroundColor = [UIColor systemGreenColor];
        open.titleLabel.font = [UIFont boldSystemFontOfSize:17];
        open.layer.cornerRadius = 10;
        open.layer.masksToBounds = YES;
        [open addTarget:self action:@selector(openScreenTimeTapped) forControlEvents:64];
        [footer addSubview:open];
        _stsOpen = open;

        // ③ QQ 群：纯异步打开 https 链接，交给系统跳 QQ / Safari
        UIButton *qq = [[UIButton alloc] initWithFrame:CGRectMake(0, 0, 0, 0)];
        qq.frame = CGRectMake(16, 126, w - 32, 46);
        [qq setTitle:@"QQ群：1135135953" forState:0];
        [qq setTitleColor:[UIColor whiteColor] forState:0];
        qq.backgroundColor = [UIColor systemOrangeColor];
        qq.titleLabel.font = [UIFont boldSystemFontOfSize:17];
        qq.layer.cornerRadius = 10;
        qq.layer.masksToBounds = YES;
        [qq addTarget:self action:@selector(qqGroupTapped) forControlEvents:64];
        [footer addSubview:qq];
        _stsQQ = qq;

        // ④ 状态标签：每次点击都写一行结果，杜绝「按了没反应」的观感
        UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(16, 182, w - 32, 46)];
        status.text = @"输入分钟数并点「应用」即可改变显示的总时长";
        status.textAlignment = 1;   // NSTextAlignmentCenter
        status.textColor = [UIColor darkGrayColor];
        status.font = [UIFont systemFontOfSize:12];
        status.numberOfLines = 2;
        [footer addSubview:status];
        _stsStatus = status;

        tv.tableFooterView = footer;
        NSLog(@"[STS] footer 已挂到 tableFooterView（3 按钮 + 状态标签）, width=%.0f", (double)w);
        STSPrefsBootLog([NSString stringWithFormat:
                         @"[UI] footer 已装上（3 按钮 + 状态标签）, width=%.0f", (double)w]);
    } @catch (NSException *e) {
        NSLog(@"[STS] 安装 footer 按钮失败: %@", e);
    }
}

- (void)viewDidLayoutSubviews {
    @try {
        [super viewDidLayoutSubviews];
    } @catch (NSException *e) {
        NSLog(@"[STS] super viewDidLayoutSubviews 异常: %@", e);
    }

    // footer 不会自动跟随表格宽度，这里手动对齐一次
    @try {
        UITableView *tv = STSFindTableView(self.view);
        if (!tv) return;
        UIView *footer = tv.tableFooterView;
        CGFloat w = tv.bounds.size.width;
        if (footer && w > 0 &&
            (footer.frame.size.width != w || footer.frame.size.height != STS_FOOTER_H)) {
            footer.frame = CGRectMake(0, 0, w, STS_FOOTER_H);
            _stsApply.frame  = CGRectMake(16, 14,  w - 32, 46);
            _stsOpen.frame   = CGRectMake(16, 70,  w - 32, 46);
            _stsQQ.frame     = CGRectMake(16, 126, w - 32, 46);
            _stsStatus.frame = CGRectMake(16, 182, w - 32, 46);
        }
    } @catch (NSException *e) {
        NSLog(@"[STS] footer 布局异常: %@", e);
    }
}

- (void)viewWillAppear:(BOOL)animated {
    @try {
        [super viewWillAppear:animated];
    } @catch (NSException *e) {
        NSLog(@"[STS] super viewWillAppear 异常: %@", e);
    }
    UITableView *tv = STSFindTableView(self.view);

    // 万一某个路径把 footer 清掉了，这里补装一次按钮
    if (tv && !tv.tableFooterView) {
        [self sts_installFooterButtons];
    }

    // 再刷一次：万一 super 的 reload 发生在 _specifiers 填入之前，这里补上渲染
    if (_specifiers.count > 0 && tv) {
        @try {
            [tv reloadData];
        } @catch (NSException *e) {
            NSLog(@"[STS] tableView reload 异常: %@", e);
        }
    }
}

#pragma mark - 读写钩子（Root.plist 里 PSEditTextCell 的 defaults/key 会走这里）

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:STSPrefsPath()];
    id v = d[[specifier propertyForKey:@"key"]];
    if (!v) v = [specifier propertyForKey:@"default"];
    // 文本框需要字符串
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    return v;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    // PSEditTextCell 给的是字符串；NSNumber 也兼容
    double minutes = 0;
    if ([value isKindOfClass:[NSNumber class]]) minutes = [(NSNumber *)value doubleValue];
    else if ([value isKindOfClass:[NSString class]]) minutes = [(NSString *)value doubleValue];
    if (minutes < 0) minutes = 0;

    STSPrefsWriteMinutes(minutes);
}

#pragma mark - 反馈：状态标签 + 弹窗（带 UIAlertView 兜底）

- (void)sts_setStatus:(NSString *)s {
    @try { _stsStatus.text = s; }
    @catch (NSException *e) { NSLog(@"[STS] 状态标签写入异常: %@", e); }
    NSLog(@"[STS] UI: %@", s);
    STSPrefsBootLog([NSString stringWithFormat:@"[UI] %@", s]);
}

/// 弹窗：UIAlertController 优先，失败或被系统吞掉时用 UIAlertView 兜底。
/// actions 为 nil 时只放一个「好」。
- (void)sts_showAlert:(NSString *)title
              message:(NSString *)msg
           homeAction:(BOOL)homeAction {
    @try {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:msg
                                                                preferredStyle:1]; // Alert
        if (homeAction) {
            [alert addAction:[UIAlertAction actionWithTitle:@"返回设置首页" style:0 handler:^(id a) {
                @try {
                    [(UINavigationController *)[self navigationController] popToRootViewControllerAnimated:YES];
                } @catch (NSException *e) {
                    NSLog(@"[STS] 返回设置首页异常: %@", e);
                }
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:0 handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    } @catch (NSException *e) {
        NSLog(@"[STS] UIAlertController 失败，回退 UIAlertView: %@", e);
    }

    // UIAlertView 自己找 window，不依赖 presentingViewController 层级
    @try {
        UIAlertView *av = [[UIAlertView alloc] initWithTitle:title
                                                     message:msg
                                                    delegate:nil
                                           cancelButtonTitle:@"好"
                                           otherButtonTitles:nil];
        [av show];
    } @catch (NSException *e) {
        NSLog(@"[STS] UIAlertView 也失败: %@", e);
    }
}

#pragma mark - 应用动作

- (void)applyTapped {
    STSPrefsBootLog(@"[BUTTON] 「应用」被点击");
    // 立刻写状态标签：无论后续弹窗是否被系统吞掉，页面上一定有变化
    [self sts_setStatus:@"正在写入…"];

    UITextField *tf = nil;
    double minutes = 0;
    BOOL hasValue = NO;

    @try {
        tf = STSFindTextField(self.view);
        NSString *txt = tf.text;
        if ([txt isKindOfClass:[NSString class]] && txt.length > 0) {
            minutes = [txt doubleValue];
            hasValue = YES;
        }
    } @catch (NSException *e) {
        NSLog(@"[STS] 读取输入框失败: %@", e);
    }

    if (!hasValue) minutes = STSPrefsCurrentMinutes();

    if (minutes <= 0) {
        [self sts_setStatus:@"数值无效：请输入大于 0 的分钟数"];
        [self sts_showAlert:@"数值无效" message:@"请输入大于 0 的分钟数" homeAction:NO];
        return;
    }

    BOOL ok = STSPrefsWriteMinutes(minutes);

    // 收键盘（这一步可能让 cell 把值再回写一次，所以放在写盘之后更保险）
    @try { [self.view endEditing:YES]; }
    @catch (NSException *e) {}

    NSLog(@"[STS] apply -> %.0f 分钟, ok=%d, path=%@", minutes, ok, STSPrefsPath());
    STSPrefsBootLog([NSString stringWithFormat:
                     @"[APPLY] %.0f 分钟 ok=%d path=%@", minutes, ok, STSPrefsPath()]);

    if (ok) {
        [self sts_setStatus:[NSString stringWithFormat:@"已应用 %g 分钟 · 重新进入后生效", minutes]];
        [self sts_showAlert:@"已应用"
                    message:[NSString stringWithFormat:@"总时长将显示为 %g 分钟。\n\n点「打开屏幕使用时间」进入该页面查看；已改的数值在重新进入该页面后生效（最多 2 秒）。", minutes]
                 homeAction:NO];
    } else {
        [self sts_setStatus:@"写入失败：无配置文件写权限"];
        [self sts_showAlert:@"写入失败"
                    message:@"无法写入配置文件，请确认越狱环境对 /var/mobile/Library/Preferences 有写权限"
                 homeAction:NO];
    }
}

#pragma mark - 打开「屏幕使用时间」

- (void)openScreenTimeTapped {
    STSPrefsBootLog(@"[BUTTON] 「打开屏幕使用时间」被点击");
    // 立即可见反馈：先证明这一下确实按到了
    @try { [_stsOpen setTitle:@"正在打开…" forState:0]; }
    @catch (NSException *e) {}
    [self sts_setStatus:@"正在打开「屏幕使用时间」…"];
    @try { [self.view endEditing:YES]; } @catch (NSException *e) {}

    // 交给独立协调器：它会串行尝试 URL 深链 → pop 回首页 → 首页 active 时 didSelect
    // → 验证 → 兜底弹窗，全程写 [JUMP] 日志。pop 之后本控制器会被销毁，
    // 因此后续阶段必须挂在协调器上，不能调度到 self。
    [[STSJumpCoordinator shared] startFrom:self];
}

#pragma mark - QQ 群（v0.6.4）

- (void)qqGroupTapped {
    STSPrefsBootLog(@"[BUTTON] 「QQ群：1135135953」被点击");
    // 立即可见反馈：先证明这一下确实按到了
    [self sts_setStatus:@"正在打开 QQ 群 1135135953…"];
    @try { [self.view endEditing:YES]; } @catch (NSException *e) {}

    // https 链接交给系统：SpringBoard 会用 Safari / QQ 打开。
    // 只用纯异步 openURL，绝不调同步 [app openURL:] —— v0.6.3 已证实同步版
    // 会阻塞主线程等待系统判定，是「按了没反应 / 卡 20 秒」的根因。
    NSURL *url = nil;
    @try { url = [NSURL URLWithString:STSQQGroupURLString()]; }
    @catch (NSException *e) { url = nil; }
    UIApplication *app = nil;
    @try { app = [UIApplication sharedApplication]; } @catch (NSException *e) {}

    if (!url || !app) {
        STSPrefsBootLog(@"[QQ] URL 或 UIApplication 取不到，放弃打开");
        [self sts_setStatus:@"打开失败：无法创建链接"];
        return;
    }
    @try {
        [app openURL:url options:@{} completionHandler:^(BOOL ok) {
            STSPrefsBootLog([NSString stringWithFormat:@"[QQ] openURL 回调 -> %d", ok]);
        }];
        STSPrefsBootLog(@"[QQ] QQ 群链接已异步发出（不阻塞主线程）");
    } @catch (NSException *e) {
        STSPrefsBootLog(@"[QQ] openURL 异常");
        [self sts_setStatus:@"打开失败：系统拒绝了链接"];
    }
}
@end

__attribute__((constructor)) static void STSPrefsInit(void) {
    STSPrefsBootLog([NSString stringWithFormat:
                     @"[BUNDLE] 设置页已加载 v%s，controller=%@",
                     STS_VERSION,
                     NSClassFromString(@"STSRootListController") ? @"ok" : @"missing"]);
    NSLog(@"[STS] preference bundle loaded, controller=%@, bundle=%@",
          NSClassFromString(@"STSRootListController") ? @"ok" : @"missing",
          [[NSBundle bundleForClass:NSClassFromString(@"STSRootListController")] bundlePath]);
}
