//
//  STSConstants.h
//  ScreenTimeSpoofer
//
//  tweak dylib 与设置页 bundle 会被加载进同一个进程（设置 App），
//  所以这里只能放常量，**不要放类** —— 两边各编一份同名类会触发 runtime 的
//  “Class X is implemented in both” 冲突。
//

#ifndef STSConstants_h
#define STSConstants_h

/// 版本号：boot 日志首行与设置页日志共用。每次发版只改这一处，
/// 这样从设备上抓回来的日志能直接判断到底装的是哪一版（旧 dylib 残留时尤其重要）。
#define STS_VERSION "1.0"

/// 配置文件（相对 JB 根，rootless 下会自动补 /var/jb 前缀）
#define STS_CONFIG_REL_PATH        @"/var/mobile/Library/Preferences/com.evander.screentimespoofer.plist"
/// 探针日志（相对 JB 根）
#define STS_PROBE_REL_PATH         @"/var/mobile/Library/Logs/ScreenTimeSpoofer-probe.log"
/// 开机自检日志（相对 JB 根）：tweak 每次启动都写，用于排查「装上了但没效果」
#define STS_BOOT_REL_PATH          @"/var/mobile/Library/Logs/ScreenTimeSpoofer-boot.log"

#define STS_JB_ROOT                @"/var/jb"

/// 默认值：目标总时长 30 分钟
#define STS_DEFAULT_TARGET_MINUTES 30.0
#define STS_DEFAULT_SCALE          0.2
#define STS_DEFAULT_MODE           @"target"

/// mobile 用户，用于给配置文件/日志赋权
#define STS_MOBILE_UID             501

#endif /* STSConstants_h */
