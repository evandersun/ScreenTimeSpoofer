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
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import "STSConstants.h"

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
            [group setProperty:@"填入分钟数后点「应用」生效，无需重启设置（返回屏幕使用时间页面即可看到）"
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

#pragma mark - 设置页

@interface STSRootListController : PSListController {
    BOOL _stsLoaded;        // 装载尝试过就不再重复
    UIButton *_stsApply;    // footer 里的「应用」按钮
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
    [self sts_installApplyButton];

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

#pragma mark - 「应用」按钮（tableFooterView，不依赖 PSButtonCell）

- (void)sts_installApplyButton {
    @try {
        UITableView *tv = STSFindTableView(self.view);
        if (!tv) {
            NSLog(@"[STS] sts_installApplyButton: 找不到 UITableView，放弃");
            return;
        }
        CGFloat w = tv.bounds.size.width;
        if (w <= 0) w = self.view.bounds.size.width;
        if (w <= 0) w = 320;

        UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 96)];

        UIButton *btn = [[UIButton alloc] initWithFrame:CGRectMake(16, 24, w - 32, 48)];
        [btn setTitle:@"应用" forState:0];                                       // UIControlStateNormal
        [btn setTitleColor:[UIColor whiteColor] forState:0];
        btn.backgroundColor = [UIColor systemBlueColor];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:17];
        btn.layer.cornerRadius = 10;
        btn.layer.masksToBounds = YES;
        [btn addTarget:self action:@selector(applyTapped) forControlEvents:64];  // TouchUpInside

        [footer addSubview:btn];
        tv.tableFooterView = footer;
        _stsApply = btn;

        NSLog(@"[STS] 应用按钮已挂到 tableFooterView, width=%.0f", (double)w);
    } @catch (NSException *e) {
        NSLog(@"[STS] 安装应用按钮失败: %@", e);
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
        if (footer && w > 0 && footer.frame.size.width != w) {
            footer.frame = CGRectMake(0, 0, w, 96);
            _stsApply.frame = CGRectMake(16, 24, w - 32, 48);
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
        [self sts_installApplyButton];
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

#pragma mark - 应用动作

- (void)sts_alert:(NSString *)title message:(NSString *)msg {
    @try {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:msg
                                                                preferredStyle:1];   // UIAlertControllerStyleAlert
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:0 handler:nil]]; // UIAlertActionStyleDefault
        [self presentViewController:alert animated:YES completion:nil];
    } @catch (NSException *e) {
        NSLog(@"[STS] 弹窗失败: %@", e);
    }
}

- (void)applyTapped {
    // 直接读输入框当前内容：不依赖框架何时调用 setPreferenceValue:
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
        [self sts_alert:@"数值无效" message:@"请输入大于 0 的分钟数"];
        return;
    }

    BOOL ok = STSPrefsWriteMinutes(minutes);

    // 收键盘（这一步可能让 cell 把值再回写一次，所以放在写盘之后更保险）
    @try {
        [self.view endEditing:YES];
    } @catch (NSException *e) {}

    NSLog(@"[STS] apply -> %.0f 分钟, ok=%d, path=%@", minutes, ok, STSPrefsPath());

    if (ok) {
        [self sts_alert:@"已应用"
                message:[NSString stringWithFormat:@"总时长将显示为 %g 分钟（最多 2 秒后生效，返回屏幕使用时间页面即可）", minutes]];
    } else {
        [self sts_alert:@"写入失败" message:@"无法写入配置文件，请确认越狱环境对 /var/mobile/Library/Preferences 有写权限"];
    }
}

@end

__attribute__((constructor)) static void STSPrefsInit(void) {
    NSLog(@"[STS] preference bundle loaded, controller=%@, bundle=%@",
          NSClassFromString(@"STSRootListController") ? @"ok" : @"missing",
          [[NSBundle bundleForClass:NSClassFromString(@"STSRootListController")] bundlePath]);
}
