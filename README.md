# ScreenTimeSpoofer

一个 iOS 越狱插件（Theos Tweak），用来改「设置 → 屏幕使用时间」里显示/统计的时长：顶部总时长、分类小计（社交/其他/游戏）、每小时柱状图、最常使用 App 排行会一起变，界面内部自洽。

支持 **roothide（Dopamine RootHide 等隐根，默认）**、rootless（Dopamine / palera1n）与 rootful 三种越狱环境，目标 iOS 15 及以上。

> GitHub 仓库：<https://github.com/evandersun/ScreenTimeSpoofer>　|　**越狱源：`https://evandersun.github.io/`**（Sileo / Zebra / Cydia 添加后直接搜索安装，自动匹配 roothide / rootless）　|　预编译包下载：<https://github.com/evandersun/ScreenTimeSpoofer/releases/tag/v1.0>

---

## 0. 直接安装（预编译）

### 方式 A：越狱源（推荐）

在 Sileo / Zebra / Cydia / Installer 里添加源 **`https://evandersun.github.io/`**，搜索 `ScreenTimeSpoofer` 直接安装。源里同时收录两个架构，包管理器**按设备架构自动匹配**，不用手动挑：

| 架构 | 适用越狱 |
|---|---|
| `iphoneos-arm64e` | **roothide**（Dopamine RootHide 等隐根） |
| `iphoneos-arm64` | **rootless**（Dopamine / palera1n） |

源仓库：[github.com/evandersun/evandersun.github.io](https://github.com/evandersun/evandersun.github.io)。

### 方式 B：手动下载 deb

`out/` 下有一个已经编好的 **arm64** 包（无根越狱专用）：

| 文件 | 架构 | 适用 | 安装到 |
|---|---|---|---|
| `out/ScreenTimeSpoofer.deb` | iphoneos-arm64e | **roothide（Dopamine RootHide 等，默认）** | 随机 jbroot：`/Library/…` |
| `out/ScreenTimeSpoofer-rootless.deb` | iphoneos-arm64 | Dopamine / palera1n rootless（`ROOTLESS=1 ./build_deb.sh`） | `/var/jb/Library/…` |

```bash
scp out/ScreenTimeSpoofer.deb root@<设备IP>:/var/root/
ssh root@<设备IP> "dpkg -i /var/root/ScreenTimeSpoofer.deb"
```

> 有根越狱（checkra1n / unc0ver）需要 `/Library/…` 布局的包：`ROOTFUL=1 ./build_deb.sh`，
> 或用 Theos 时 `make THEOS_PACKAGE_SCHEME=rootful`。

装完 postinst 会自动杀掉设置进程，进「设置 → 屏幕使用时间」就能看到总时长被改成 30 分钟（默认配置）。

同时在「设置」根列表最下方会出现一行 **ScreenTimeSpoofer**，点进去输入分钟数 → 点「应用」即可改时间；页面底部另有**「打开屏幕使用时间」**按钮，点一下约 0.75 秒即在「设置」内部进入该页面查看效果；若当前 iOS 不允许自动跳转，会先返回设置首页并弹窗提示（依赖 PreferenceLoader，Dopamine / palera1n 自带），详见第 3 节。

**装了但没效果**时按顺序查：

1. 确认注入发生：包内已带 ad-hoc 签名，个别环境需要重签一次
   `ldid -S /var/jb/Library/MobileSubstrate/DynamicLibraries/ScreenTimeSpoofer.dylib`
2. 用 `log stream --predicate 'process == "Preferences"'` 看有没有 `[STS] scan done` 日志。
3. 还是没反应 → 说明你的 iOS 版本上类名/选择器对不上，走第 6 节的 Probe 流程。

> 架构说明：`Makefile` / `prefs/Makefile` 已声明 `ARCHS = arm64 arm64e`，用 Theos + iOS SDK 构建时会产出双 slice（arm64e 要求带 PAC 的签名环境）。本仓库 Linux 交叉构建脚本 `build_deb.sh` 打出的预编译 `.deb` 仍是**纯 arm64 slice**，`control` 里的 `Architecture: iphoneos-arm64e` 只是 roothide 的包标识；A12 及以上的 arm64e 设备通常也能正常加载（越狱 dyld 已放行混合架构），若环境拒绝加载，先用 `ldid -S` 给 dylib 补签一次。

## 1. 思路

屏幕使用时间不是一张“图片”，是一条数据链路：

```
UsageTrackingAgent  ──写入──►  usage 数据库（sqlite，受保护）
        │
        ▼  查询
ScreenTimeCore.framework    STUsageDetails / STAppUsage / STCategoryUsage …
        │                  （每个对象自带 totalUsage 之类的时长 getter）
        ▼  渲染
ScreenTimeUI.framework      STUI*ViewController + 柱状图 / 排行列表
        │
        ▼
「设置」App 进程（com.apple.Preferences）
```

改法有两种：

| 方案 | 做法 | 问题 |
|---|---|---|
| 改数据库 | 直接 UPDATE sqlite | 数据受 TCC/加密保护，schema 随版本变，还会污染真实统计 |
| **改渲染层（本插件）** | hook `ScreenTimeCore` 的时长 getter，在返回值上等比缩放 | 类名/选择器是私有 API，需要按版本对齐 |

本插件选第二种：**只在「设置」进程内存里改数值，不落盘**。退出设置后数据恢复原样，卸载即彻底干净。

关键设计点：

1. **只挂零参 + 返回数值的方法**。回调里用 `method_getReturnType` 过滤，只处理 `double / float / long long / NSNumber`，其它类型（结构体、BOOL、字符串）一律不碰，避免签名不匹配导致崩溃。
2. **递归保护**。总时长往往是由子项求和算出来的：如果子项和聚合值都乘系数，数字会被“平方”。所以用一个 thread-local 深度计数，聚合值计算过程中嵌套调用的子项**不缩放**，聚合值本身只缩放一次。
3. **反推比例而非硬编码**。`Mode=target` 时抓到真实总时长 `T`，算出 `factor = 目标 / T` 并缓存 5 秒，于是「3 小时 27 分钟」能精确变成「30 分钟」，而各个分类、每根柱子按同一比例缩小，不会有“总数和明细对不上”的破绽。
4. **运行期类扫描**。不依赖编译期的 `%hook`，启动时（以及每次有镜像加载时）遍历 `ScreenTime*` / `UsageTracking*` 镜像下的类，按选择器名精确匹配再挂钩——这样 iOS 小版本改了类名也大概率还能命中。

---

## 2. 目录结构

```
ScreenTimeSpoofer/
├── Makefile                      # Theos 构建脚本
├── control                       # Debian 包信息
├── ScreenTimeSpoofer.plist       # 注入目标：com.apple.Preferences
├── Tweak.xm                      # 入口 + 挂钩 + 变换 + 探针
├── STSConfig.h / STSConfig.m     # 配置读写（plist，支持热重载）
├── STSPrefsController.m          # 设置页（PSListController 子类 + 自绘 UIKit 表格）
├── prefs/Makefile                # 设置页 bundle 子项目（Theos 构建用）
├── STSConstants.h                # tweak 与设置页共享的常量（不含类，避免撞类）
├── layout/                       # 设置页 bundle 的 Info.plist + PreferenceLoader 入口
├── build_deb.sh                  # 交叉编译 arm64 + 打 deb（不需要 iOS SDK）
├── out/*.deb                     # 预编译好的安装包
└── README.md
```

---

## 3. 设置页

依赖 **PreferenceLoader**（Dopamine / palera1n 自带）。装完 deb 后，「设置」根列表最下方会出现一行 **ScreenTimeSpoofer**，点进去就是设置页：

```
┌──────────────────────────────┐
│ 屏幕使用时间                  │
│  目标总时长（分钟）       30 │   ← 数字键盘输入框
│                              │
│             应用             │   ← 系统样式按钮
└──────────────────────────────┘
```

- 输入框预填当前生效的值，只接受数字；
- 点「应用」写入 `TargetMinutes`，并把处于 `off` 的 `Mode` 自动改回 `target`；
- **不用重启设置**：tweak 和设置页在同一个进程里，tweak 每 2 秒检查一次配置文件 mtime，写完最多 2 秒后返回屏幕使用时间页面就能看到新数值（下拉刷新或切一下「每周/每天」也行）。

### 实现方式：标准 PSSpecifier 路线（v0.3.0 起）

对照 ScreenTimeFaker（MiRO92）等成熟插件重写：设置页不再自绘表格，而是用**标准 specifier 机制**——

- bundle 里带 `Root.plist`，cell 类型写字符串（`PSEditTextCell` / `PSButtonCell`），
  由 Preferences 框架的 `+[PSTableCell cellTypeFromString:]` 自己映射，不存在枚举值猜错的问题；
- `specifiers` 方法用 `loadSpecifiersFromPlistName:@"Root" target:self` 加载，返回**真实的
  PSSpecifier 数组**——框架拿到真实数组后，其内部分节/行高/header 逻辑全部按预期工作；
- 读写走标准钩子 `readPreferenceValue:` / `setPreferenceValue:specifier:`，直接读写
  `/var/mobile/Library/Preferences/com.evander.screentimespoofer.plist`；
- `_specifiers` ivar 通过 `_OBJC_IVAR_$_PSListController._specifiers` 符号在加载时解析，
  offset 由 runtime 计算，没有布局风险（ScreenTimeFaker 的二进制里也是这么引用的）。

### v0.3.4：自检日志 + 周期重扫

「应用后没效果」排查需要设备侧数据，这版起 tweak **每次启动都会写自检日志**：

```
/var/mobile/Library/Logs/ScreenTimeSpoofer-boot.log
```

内容包括：constructor 是否执行、启动时已加载的 ScreenTime 镜像、`dlopen` 两个私有框架的
成败、每次扫描挂上的方法清单、以及**前 8 条真实改写样本**（`- [STUsageItem totalUsage] 12420 -> 1800` 这种）。
任何一环断了，看这个文件立刻知道断在哪：

| 日志表现 | 结论 |
|---|---|
| 文件不存在 | dylib 根本没被注入（检查 /var/jb/Library/MobileSubstrate/DynamicLibraries/ 与过滤器） |
| 「已挂钩的方法」为空 | ScreenTimeCore 没加载 / 类名全变了（开 Probe 跑探针） |
| 挂钩有、样本为空 | 挂的对象/选择器不对，界面不读这些 getter（开 Probe 对照真实方法名） |
| 样本有变化但界面没变 | 改的是别的进程/别的数据源 |

另外扫描从「启动后 3 次」改为 **10 秒周期重扫**（hookedKeys 去重，开销可忽略），
框架/分类晚加载也能补上；所有扫描串行到主队列，消除多线程竞争。

装好后进一次「屏幕使用时间」页面，然后：

```bash
cat /var/mobile/Library/Logs/ScreenTimeSpoofer-boot.log
```

把内容发我即可定位。

### v1.0：正式版 + 包内详情页

版本号从 `0.6.4` 正式升到 **`1.0`**，作为稳定版基线（`STSConstants.h`、`control`、bundle `Info.plist` 三处统一，boot 日志首行也同步）。

`control` 新增两个详情页字段，装之前在包管理器里点开插件就能看到更新内容与安装说明，不用再跳外部网页：

```sh
Depiction: https://evandersun.github.io/depiction/screentimespoofer.html
SileoDepiction: https://evandersun.github.io/depiction/screentimespoofer.json
```

- `Depiction` 是网页版，Cydia / Zebra / Sileo 通用；
- `SileoDepiction` 走 Sileo 原生 `DepictionTabView`，深色主题下不闪白、加载更快；其他客户端自动回落到网页版。
- 两个文件都在源仓库 `depiction/` 下，改版本时同步改这两个文件即可。
- 功能本身无改动：仍是「目标时长输入 + 应用」「一键进入屏幕使用时间」「QQ 群入口」三个入口，roothide / rootless 双架构同步发布。

### v0.6.4：设置页新增「QQ群：1135135953」入口

设置页 footer 加了**第三个按钮**（橙色），标题就叫 `QQ群：1135135953`，点一下**纯异步**打开 QQ 群 universal-share 链接，交给系统用 QQ / Safari 打开加群页。

- 链接原样保留 `authKey` / `busi_data` / `data` / `svctype` / `tempid` 全部参数，不做二次编码（`NSURL` 把 query 原样交给系统）。
- 沿用 v0.6.3 的教训：**只用 `openURL:options:completionHandler:` 异步版**，绝不调同步 `[app openURL:]`。同步版会阻塞主线程等待系统判定，正是之前「按了没反应 / 卡 20 秒」的根因。https 链接不进跳转协调器，也不 pop 当前页。
- footer 高度 `178 → 236`，状态标签下移；`viewDidLayoutSubviews` 同步对齐第三个按钮。点击会写进同一份 boot 日志（`[BUTTON]` / `[QQ]`），抓日志即可确认按钮是否被点到、链接是否发出。
- 桩头 `UIColor` 补 `systemOrangeColor` 声明（仅为编译，运行时是标准 iOS 15 API）。
- 版本 `0.6.4`；roothide（`iphoneos-arm64e`）与 rootless（`iphoneos-arm64`）两个包同步发布。

### v0.6.3：把「一键跳转」从 20 多秒压到 1 秒内

v0.6.2 已经能跳转成功，但从点按钮到页面出现要 **20 多秒**。根因不在页面本身，而在跳转协调器的 URL 阶段：

- `STSSendURLSchemes` 对 **7 个候选 URL 每个都同时调用异步版和同步 `[app openURL:u]`**，还额外直投 AppDelegate —— 共 14+ 次 `openURL`。其中 `x-apple.systempreferences:` 是 macOS scheme、带 `&path=` 的在 iOS 上无效。
- **同步 `openURL:` 会阻塞主线程**等待 SpringBoard 判定/超时（无效 scheme 尤其慢）。主线程被卡住后，连 `performSelector:afterDelay:` 的定时器也一起排队 —— 所以明明各阶段延迟加起来只有 2.1 秒，实际要等二十几秒才动。
- 多个 URL 陆续被系统处理，还可能让页面反复加载/卸载（`ScreenTimeSettingsUI` 有 169 个类需懒加载），进一步放大延迟。

修法（**跳转路径顺序不变，只消除阻塞与等待**）：

| 改动 | v0.6.2 | v0.6.3 |
|---|---|---|
| URL 候选 | 7 个 | **2 个**（`App-prefs:SCREEN_TIME` / `prefs:root=SCREEN_TIME`） |
| `openURL:` 调用 | 每候选同步 + 异步 + AppDelegate 直投 | **仅纯异步一次**，删掉同步与直投 |
| pop 回首页 | 先等 0.9 秒验证 URL 再 pop | **立即 pop**（`animated:NO`），省掉动画与等待 |
| didSelect 延迟 | 0.9 + 0.5 = 1.4 秒后 | **0.25 秒**后 |
| 最终验证 | + 0.7 秒 | **+ 0.5 秒** |
| 理论总耗时 | ~2.1 秒（实测 20+ 秒） | **~0.75 秒** |

- **每条 `[JUMP]` 日志自动带 `[+X.XXs]` 相对耗时**（纯 C `gettimeofday`，不引入 libdispatch 依赖）。抓一次日志就能看出时间花在 URL、pop、还是遍历表格。
- 遍历首页表格上限收紧（sections 40→30、rows 120→60），避免逐格 `cellForRowAtIndexPath:` 拖慢。
- **保留全部已验证有效的路径**：`didSelect` 仍是主路径（不依赖深链）、pop 保证可见变化、弹窗兜底保证有反馈。删掉的 5 个候选与同步调用都不是跳转生效所必需。

> 验证：装完点一次跳转按钮，抓 `ScreenTimeSpoofer-boot.log`，看 `[JUMP]` 各行的时间戳 —— 从 `[+0.00s] 开始` 到 `[JUMP] ✔ 已进入` 应在一秒左右。若某段仍慢，日志会直接指出是哪一段。

- 版本 `0.6.3`。

### v0.6.2：修「一键跳转」按钮用不了（多阶段跳转协调器）

先纠正两个此前的误判：

1. **`boot(8).log` 里根本没有 `[BUTTON] 「打开屏幕使用时间」被点击`、也没有任何 `[NAV]` 行** —— 那次是按上一轮指引「手动从设置首页点进去」抓的日志，压根没点跳转按钮，所以覆盖不到按钮。改时长功能其实已经生效（`STUsageReport totalScreenTime 34570 -> 1200`，iOS 16 上顶部显示 20 分钟）。
2. **「iOS 15+ 没有公开深链」是错的**。查证后确认 `prefs:root=SCREEN_TIME` / `App-Prefs:root=SCREEN_TIME` / `App-prefs:SCREEN_TIME` 在 iOS 16/17 上有效（多份 URL 清单 + iOS 17.3 实测可打开 Screen Time）。v0.6.0 据此把 URL 路径判死刑，方向就偏了。

**真正的根因**：v0.6.0/0.6.1 是在「插件设置页」（导航栈栈顶）里，去调用**栈底「设置首页」控制器**的 `tableView:didSelectRowAtIndexPath:`。那一刻首页不是 active / `topViewController`，Preferences 的 `PSListController` 会直接忽略这次选中 —— 页面纹丝不动。v0.6.1 只补了日志、没动这个逻辑，等于没修。

重写为**串行多阶段协调器**，每阶段都写 `[JUMP]` 日志并验证是否真的进了新页面：

- **A. URL 深链**：7 个候选（含 `App-prefs:SCREEN_TIME`），以 `openURL:options:completionHandler:` 异步版为主，同步版 + 直接投递 AppDelegate 为辅；回调只记日志不据此判成败。
- **B. 0.9 秒后验证栈顶**：没进去就 `popToRootViewControllerAnimated:` 回设置首页 —— 这一步 100% 有效，既是可见变化，也让首页变成 active。
- **C. 首页 active 后再触发**「屏幕使用时间」那一行的 `didSelect` —— 这次才会真正 push。标题匹配不再只读 `textLabel`：递归收集 cell 内所有 `UILabel` 文本 + `accessibilityLabel`（iOS 16 设置首页是自定义 cell，只看 `textLabel` 会漏）。
- **D. 再验证**；仍未进去才用 `UIAlertView`（自己找 window，不依赖 presenting 层级）弹窗提示手动进入。

关键工程细节：pop 之后插件页 `self` 会被销毁，**延迟任务不能再调度到 self**，所以全部挂在独立单例 `STSJumpCoordinator`（强引用持有 `nav` 与首页控制器）上，用 `performSelector:withObject:afterDelay:` 串行推进。桩头 `Foundation.h` 补了该 API 声明。

- 版本 `0.6.2`。抓日志时点一下跳转按钮，看 `[BUTTON]` 与 `[JUMP]` 各阶段结果即可定位。

### v0.6.1：定位「被调用=0」—— 框架懒加载诊断闭环

用户回传的 `ScreenTimeSpoofer-boot(7).log` 最后三行是：

```text
## 8 秒统计：hooked=8 被调用=0 被改写=0
## 生效参数：mode=target target=20.0min scale=0.200 原始总时长=0.0min 系数=0.2000 缩放分项=0
## 结论：已挂上，但界面没有调用这些 getter —— 显示数据来自其它类
```

`原始总时长=0.0min` 说明**总时长基准从未被设置过**，也就是改时长的代码一次都没触发。但把这份日志直接读成「hook 挂错类」是错的，有两个更前置的原因：

1. **它其实不是按钮日志**。这是 dylib 的启动自检日志，设置页按钮的所有诊断原本只走 `NSLog`（系统 syslog），boot.log 里一个字都没有 —— 所以「按钮按了没反应」和「hook 没生效」两件事一直分不清。
2. **日志第 8 行写明：启动时只加载了 `ScreenTimeUICore / ScreenTimeCore / ScreenTimeFoundation` 三个框架**。「设置 → 屏幕使用时间」页面用的 `ScreenTimeSettingsUI` 之类是**点进页面才懒加载**的。插件在设置刚启动就扫完，挂上的 8 个 getter 全在 `UsageTracking` 的模型类里，那个页面根本不调它们。而「8 秒统计」是启动后自动打的，那时用户还停在插件设置页（按钮进不去），零调用是必然的。

另外首行 `ScreenTimeSpoofer 0.5.6 boot` 是**从 0.5.6 起一直没改的硬编码字符串**，不能用来判断设备装的是哪一版 —— 之前多次「旧 dylib 残留」都栽在这上面。

这一版的修法（**不猜新的 hook 目标，先把真相拿到**）：

- **框架懒加载即时感知**：每 0.5 秒轮询 dyld 镜像表，一旦发现新的 ScreenTime / UsageTracking / FamilyControls / ManagedSettings / DeviceActivity 框架加载，立刻全量 dump 它的类名与「名字像时长」的零参方法 —— **包含返回 `NSString` 的格式化 getter**（界面上的「3 小时 18 分钟」很可能就是它，旧版 dump 只列数值返回值，把它整个漏掉了）。同一次重扫随即把新框架里符合规则的类挂上。不用 `_dyld_register_func_for_add_image`：那个回调在 dyld 阶段触发，0.5.0 曾因回调里解析不到 `dispatch_get_main_queue` 直接 abort；轮询只在自建串行队列里跑。
- **设置页按钮写进同一份 boot.log**：`[BUTTON]`、`[NAV]`、`[APPLY]`、`[UI]`、`[BUNDLE]` 前缀记录按钮点击、进程内导航每一步、footer 是否装上、写入结果、bundle 版本。以后只需抓**一份日志**就能判断按钮到底按没按到、走到哪一步。
- **8 秒统计改成 8/20/45/90 秒各打一次累计值**，每次都列出此刻已加载的相关框架 —— 用来判断用户到底进没进「屏幕使用时间」页面。
- **boot 首行带真实版本号**（`STS_VERSION` 宏，`STSConstants.h` 一处定义，dylib 与设置页共用）。

**怎么配合验证（很关键）**：装完 → 打开「设置」→ 点插件页 → 点「应用」→ **手动从设置首页点进「屏幕使用时间」（按钮不好使也没关系）** → 停留 5 秒以上 → 重新抓 `ScreenTimeSpoofer-boot.log`。日志里如果出现 `★ 检测到懒加载框架：.../ScreenTimeSettingsUI.framework/...`，后面就会跟着那个页面真正用到的类与方法清单；下一版就能精准挂钩，不用再盲猜。

- 版本 `0.6.1`。

### v0.6.0：修「打开屏幕使用时间」按钮按了没反应

v0.5.8 加的跳转按钮点了完全没动静，三个原因叠在一起：

1. **深链本身不成立**：`prefs:root=SCREEN_TIME` / `App-Prefs:` 这类 URL 是给「外部 App 跳进设置」用的，而本插件就跑在 `com.apple.Preferences` **进程内部** —— 让设置 App 自己 `openURL` 自己基本是 no-op；而且 Apple 从未开放 Screen Time 的公开 `prefs:root` 路径（iOS 15+ 尤其如此，它已改成 `ScreenTimeSettingsUI` 私有框架懒加载的 cell）。
2. **把 `openURL:` 返回 `YES` 当成成功**：那个 `YES` 只表示「系统受理了这个 URL 请求」，不代表真的跳过去了。旧代码一拿到 `YES` 就 `break` + `return`，静默收场。
3. **异步兜底分支也不给反馈**：`openURL:options:completionHandler:` 之后直接 `return`，连弹窗都没有 —— 注释写的是「怕提示框盖住可能已经跳过去的页面」，结果就是三条路全静默。

修法（跳转逻辑重写）：

- **主路径改成「进程内直接导航」**：本设置页是从「设置」首页 push 进来的，导航栈里就有首页控制器和它的表格。遍历各层 `UITableView` 的 dataSource 找标题为「屏幕使用时间」（含中/英/日/韩/繁中等多语言）的那一行，调首页表格 delegate 的 `tableView:didSelectRowAtIndexPath:` —— **与用户手指点一下完全等价**，由 Preferences 框架自己完成 lazy bundle 加载与 push。不依赖任何 URL scheme、不依赖任何私有控制器类名，也不会因 iOS 小版本改类名而失效。
  - 遍历时**排除本插件自己的页面**（它的分组头也叫「屏幕使用时间」，误命中就白点了）。
  - 调完 `didSelect` **校验导航栈层数是否增加**，只有真的 push 了才算成功 —— 避免重蹈「以为成功就静默返回」的覆辙；没 push 就继续走后面的兜底路径。
- 深链降级为辅助：`openURL:` 全候选 + 直接投递给 Preferences 的 AppDelegate（`application:openURL:options:` 等）+ 异步版都还试一遍，但**不管返回什么都不静默收场**。
- **保证任何情况都有可见反应**：footer 新增状态标签，点击瞬间写「正在打开…」；进程内导航失败后弹窗说明原因，并带一个 **「返回设置首页」** 按钮（`popToRootViewControllerAnimated:`，100% 有效）—— 用户回到首页手动点一下即可，比对着没变化的屏幕强。弹窗 `UIAlertController` 失败时用 `UIAlertView` 兜底。
- 「应用」按钮同步加状态标签反馈，避免弹窗被系统吞掉时同样表现为「没反应」。
- `stubs/UIKit/UIKit.h` 补 `UINavigationController` / `NSIndexPath` / `UITableView` 数据源方法 / `UILabel.numberOfLines` / `UIAlertView` 等声明。
- 版本 `0.6.0`。

### v0.5.9：修 dpkg 覆盖冲突 + 安装提速（无功能性改动）

装 0.5.8 时报错：

```text
dpkg: error processing archive ... (--unpack):
 trying to overwrite '/Library/MobileSubstrate/DynamicLibraries/ScreenTimeSpoofer.dylib',
 which is also in package com.example.screentimepoofer 0.5.6
```

原因是 0.5.7 把包名从 `com.example.screentimepoofer` 改成 `com.evander.screentimespoofer`，但设备上旧包没卸载 —— 两个包都声明同一批文件，dpkg 拒绝覆盖。

- `control` 增加 **`Replaces: com.example.screentimepoofer`**：dpkg 允许覆盖，并把这些文件的所有权从旧包转移到新包（之后卸载旧包不会误删新文件）。
- 顺带修掉「前几版 unpack 很慢」：`preinst` 从 0.5.3 起用 `find` 扫 `/var/containers/Bundle/Application`（数万文件），`/var` 与 `/private/var` 又是同一目录，等于扫两遍，每装一版都要卡几十秒。现在只 `rm` 几个已知安装路径，常数时间完成，文件冲突交给 `Replaces` 处理。
- 版本 `0.5.9`；装完可选 `dpkg -r com.example.screentimepoofer` 清掉旧包记录。

### v0.5.8：设置页新增「打开屏幕使用时间」按钮

- footer 从 1 个按钮改成 2 个：上「应用」、下「打开屏幕使用时间」，点后者直接跳到系统的「设置 → 屏幕使用时间」，省掉手动返回首页再点一次。
- 跳转走系统设置深链（`prefs:root=SCREEN_TIME` / `App-Prefs:root=SCREEN_TIME` 等 5 个候选逐个尝试），**不依赖任何私有控制器类名**，不会因 iOS 小版本改类名而失效；同步 `openURL:` 全失败时再用 `openURL:options:completionHandler:` 兜一次。
- 编译桩头从沙箱临时目录搬进仓库 `stubs/`，`build_deb.sh` 默认使用它 —— clone 下来直接 `./build_deb.sh` 即可构建，不再依赖外部 SDK/桩头。
- 版本 `0.5.8`。

### v0.5.7：包名 / 架构标识调整（无功能性改动）

- deb 包名由 `com.example.screentimepoofer` 改为 **`com.evander.screentimespoofer`**，版本升到 `0.5.7`；配置 plist 路径、设置页 bundle id、PreferenceLoader `defaults` 域、工作队列名同步换到新域名。
- `Makefile` 与 `prefs/Makefile` 的 `ARCHS` 从 `arm64` 改为 **`arm64 arm64e`**（Theos 在有 iOS SDK 的环境会编出双 slice，arm64e 需要带 PAC 的签名环境）。
- 本仓库 Linux 交叉构建脚本 `build_deb.sh` 产出的 `.deb` 仍是**纯 arm64 slice**；`control` 的 `Architecture: iphoneos-arm64e` 只是 roothide 包标识，不代表二进制里带 arm64e slice。
- **升级提示**：包名变了，dpkg 视为全新包，旧的 `com.example.screentimepoofer` 不会被自动卸载。建议先 `dpkg -r com.example.screentimepoofer` 再装新版（`preinst` 也会清理旧 dylib/plist 残留）。旧配置文件 `com.example.screentimepoofer.plist` 不会自动迁移，装完在设置页重新填一次分钟数即可。

### v0.5.6：修「变成一秒」—— 基准锚定 + 默认不缩分项

`boot(6).log` 给出的关键事实：

```text
## 配置(文件)：mode=target target=15.0min        ← 填写值已正确读取
## 8 秒统计：hooked=8 被调用=0 被改写=0          ← 此时 STUsageReport 还没加载
## 补扫新增挂钩：8 -> 15                          ← 之后才挂上真正的数据类
  hooked -[STUsageReport totalScreenTime] (d)
  hooked -[STUsageReport maxScreenTime] (d)
  hooked -[STUsageReport totalAppUsage] (d)
  hooked -[STUsageReport totalCategoryUsage] (d)
  hooked -[STUsageReport totalWebUsage] (d)
  sample 改写: -[STUsageReport totalScreenTime] 25077 -> 600
```

两个问题：

1. **基准被污染**：0.5.5 用「一轮里全局最大值」当总时长，但 `maxScreenTime`、
   `totalAppUsage` 等历史/周累计值比 `totalScreenTime` 更大，把分母撑大，
   系数被压到约 0.024 → 总时长变成 10 分钟而非 15 分钟。
2. **等比缩放的数学必然**：真实总时长 25077 秒（约 7 小时）压到 900 秒时，
   系数只有 0.036，一个原本 30 秒的 App 就变成 **1 秒** —— 正是用户反馈。

修复：

- **基准只锚定日志证实的总量 getter**：`-[STUsageReport totalScreenTime]`、
  `-[USUsageReport screenTime]`（SEL 指针比较，不依赖 plist 里可能过期的类名）。
  命中时记录原始总时长并**直接返回填写的目标值**，顶部数字精确等于设置值。
- **新增 `ScaleDetails`，默认 `NO`**：分项 getter 一律原样返回，不再被缩成 1 秒。
  需要「各项之和也等于目标值」时把 plist 里 `ScaleDetails` 设为 `true`（小项会很小）。
- 默认 `AggregateClass/Selector` 改为 iOS 16 真实存在的 `STUsageReport/totalScreenTime`。
- `STSBaseFactor` 每次都重读 `cfg.targetSeconds`，改完数字无需重进页面即按新值生效。
- 补扫加密：前 15 秒每 0.5 秒、之后到 60 秒每 2 秒（`ScreenTimeSettingsUI`
  只在点进页面时才懒加载，0.5.5 里 8 秒后才挂上，首屏看到真实值）。
- 日志新增 `缩放分项=0/1`，`## 生效参数` 直接显示原始总时长与系数。

### v0.5.5：填的目标分钟数终于生效（自适应聚合基准）

现象：已生效，但显示值**只按固定比例缩放**，设置页填的数字不起作用。

根因：旧逻辑把「总时长」判定绑定在 `AggregateClass`（默认 `STUsageDetails`）+ `totalUsage`
同时命中上。但 iOS 16.7 上这个类**并不存在**（0.5.4 崩溃栈里的真实类是
`ScreenTimeSettingsUI` 里的 `STUsageReport`），所以：

```text
STSIsAggregate 永远返回 NO
→ 从未设置 factor
→ 全部走 STSBaseFactor() 的兜底值 cfg.scale（默认 0.2）
→ 目标分钟数完全没参与计算
```

修复：**不再依赖任何类名**，改成自适应基准——一轮数据加载里「观测到的最大原始值」
必然就是总时长（总时长 ≥ 任何单项），用它作基准：

```text
系数 = 目标总时长 / 本轮观测到的最大原始时长
```

- 顶部总时长 → 正好等于填写值；
- 各 App / 分类按同一系数缩放 → 各项之和也等于填写值；
- 空闲超过 3 秒视为新一轮加载，基准重新统计（切日/刷新都正确）；
- 显式配置的 `AggregateClass` 若存在仍优先命中。

日志新增一行，可直接核对生效参数：

```text
## 生效参数：mode=target target=15.0min scale=0.200 基准总时长=198.0min 系数=0.0757
```

### v0.5.4：真正的功能性根因 —— hook block 收不到 `_cmd`

0.5.3 的 `preinst` 清理生效了，崩溃报告 `Preferences-2026-11-01-223225.txt` 里的
UUID 已经是 `4c4c4468-5555-3144-a158-f394545b3f4a`（= 0.5.3 本体），并且本次
**hook 真的命中了真实数据类**：

```text
-[STUsageReport initWithReportType:startDate:lastUpdatedDate:firstPickup:usageItems:]
  → __STSHookMethod_block_invoke_3
  → STSApplyValue
  → NSStringFromSelector → _platform_strlen → SIGSEGV (地址 0x9023a89d9c179390)
```

崩溃地址是个明显的垃圾指针，指向一个**一直存在却被忽略的 API 误用**：

`imp_implementationWithBlock` 生成的 IMP 会把 `(self, _cmd, args...)` 重排成
`(block, self, args...)`，**`_cmd` 不会被传给 block**。之前写成
`^double(id obj, SEL _cmd)`，block 的第二个参数拿到的是「方法的第一个实参」；
而我们只挂零参 getter，没有实参，于是 `_cmd` 就是寄存器里的残留值。

后果有两个，正好对应长期以来的两个症状：

1. `NSStringFromSelector(垃圾)` → `strlen` → SIGSEGV（本次崩溃）；
2. `STSIsAggregate` 里 `sel != gAggregateSel` 永远为真 → 聚合基准从未被设置
   → **这正是「hooked>0 却始终没效果」的直接原因**。

修复：block 只声明 `(id obj)`，选择器改用**捕获变量**传入；日志改用
`class_getName` / `sel_getName`（C 层，少一层消息）。

已反汇编验证：三个 hook block 都不再把第三个寄存器当作 `_cmd`。

### v0.5.3：确认「设备上跑的不是新包」+ 安装包自动清理旧残留

崩溃报告 `Preferences-2026-11-01-142011.txt` 给出的栈是：

```text
STSInit +956 → +[STSConfig shared] → _dispatch_once_callout
            → -[STSConfig init] +112 → -[STSConfig applyDictionary:] +1616
            → lookUpImpOrForward → EXC_BAD_ACCESS
```

但 0.5.x 的代码里这三件事**都已经不存在**了：`STSInit` 只写一行日志（不可能有 `+956` 的偏移）、
`+shared` 已不用 `dispatch_once`、`init` 已不调用 `applyDictionary`。

用二进制指纹核对后证据闭合：

| 项 | 崩溃里的 dylib | 0.5.2 / 0.5.3 产物 |
|---|---|---|
| LC_UUID | `4C4C44B3-5555-3144-A187-B483F4C0B51C` | `4C4C4468-5555-3144-A158-F394545B3F4A` |
| 镜像大小 | 49152 字节 | 99120 字节 |

结论：**设备上被注入的是残留的旧版 dylib，新包的文件并没有替换掉它**。

本版处理：

- 新增 `DEBIAN/preinst`：在 deb 解压**之前**全盘清理 `ScreenTimeSpoofer.dylib` / `.plist`
  （扫描 `/var/jb`、`/var/containers/Bundle/Application`、
  `/private/var/containers/Bundle/Application`），保证最终注入的一定是本包自带版本。
- 加固 `applyDictionary`：字典下标 `d[key]`（`objectForKeyedSubscript:`）全部改为
  `objectForKey:`；赋值全部改为直接写 ivar，不再走属性 setter（崩溃栈里最后在飞的消息
  正是 `setHeuristicHook:`）。已反汇编确认无残留。

排错要点：**日志首行的版本号就是「到底加载了哪一版」的判据**。
若 `cat` 出来不是 `0.5.3 boot`，说明新包仍未生效，应手动清理残留后重装。

### v0.5.2：不闪退但仍无效果 —— 改为自证命中

- 统计拆成「挂钩数 / 被调用 / 被改写」，8 秒结论段会直接写出属于哪种情况：
  没挂上、挂了但界面没调用、调用了但没改写、已生效。
- 日志新增「调用但未改写」样本，能看出界面到底读了哪些 getter。
- 候选方法 dump 不再过滤「名字像时长」，改为列出 ScreenTime 框架的全部零参数数值 getter。
- 补扫改为前 30 秒每 2 秒一次：ScreenTime 的类常在进入页面时才加载，只有启动扫描会漏掉。
- 补充 iOS 16 可能的报告类名与选择器（`STUsageReport`、`USUsageReport`、`screenTimeInSeconds` 等）。

### v0.5.1：修复 add_image 回调中的 libdispatch 缺失符号崩溃

0.5.0 日志确认初始化已完整跑到挂钩阶段，`isa` 修复生效；随后崩溃报告为 `SIGABRT`：
`STSImageAdded → _dyld_missing_symbol_abort`。根因是 `_dyld_register_func_for_add_image`
会先同步回调所有既有镜像，而回调里调用的 `dispatch_get_main_queue` 不是当前 iOS 16 运行时
可直接解析的 dylib 符号。修复：删除 add_image 注册，全部补扫/热重载/统计改到插件自建串行队列；
扫描范围同时限定为系统 ScreenTime/UsageTracking 私有框架，避免把插件自己的 `STSConfig`
getter 挂进去。

### v0.5.0：修复从 0.3.5 起反复闪退的真正根因（isa 被 ivar 覆盖）

最新报告崩在 `[STSConfig shared]` 返回后的 `objc_retainAutoreleaseReturnValue`，但真正的证据在旧版
`init` 反汇编：编译器生成了 `strh [x19]` 与 `strb [x19,#2]`，也就是把 BOOL ivar 写到对象偏移
0/1/2。对象偏移 0 必须是 `isa`，因此配置对象初始化时就把自己的类指针破坏，之后任何一次消息发送
都可能 EXC_BAD_ACCESS；这同时解释了早期崩溃位置漂移、setter 内崩溃和单例返回后崩溃。

根因是自建 SDK 桩头的 `NSObject` 漏声明 `Class isa`。现已补齐，并把 arm64 的 `BOOL` 从旧的
`signed char` 修正为 `_Bool`。重新反汇编验证：三个 BOOL ivar 现在位于偏移 8/9/10，`init` 不再含
任何写对象偏移 0 的指令。构建脚本也新增桩头 isa 检查，防止再次产出对象布局错误的包。

### v0.4.6：init 不再发送任何 ObjC 消息（消除 applyDictionary 必崩点）

0.4.3 与 0.4.5 两份崩溃报告**崩在同一条指令**：`-[STSConfig applyDictionary:] +1744`
（即 `self.heuristicHook = STSBool(d, @"HeuristicHook", YES)` 的 setter 调用），
`lookUpImpOrForward → dataSegmentsContain` 读到垃圾类指针。反汇编确认崩溃点前后指令正常，
selref/classref 槽位内容也正常，且**同样的 ObjC 代码在 init 之外完全正常**（异步块里的
`[NSMutableSet set]`、`stringWithFormat`、日志都跑通）——说明问题特定于 init 这段
「字典下标 → isKindOfClass: → 属性 setter」。修复：init 只做标量与 CFString 常量赋值
（除 `[super init]` 外零消息发送），默认类名/选择器改存 **C 数组**，由新的
`buildDefaultSets` 在已验证安全时机构造 NSSet。反汇编验证 init 已无 applyDictionary 调用。

### v0.4.5：移除后台线程 dlopen（修复 dyld 重入崩溃）

0.4.4 崩溃报告（`Preferences-2026-11-01-190916`）：崩溃已从我们的 `applyDictionary` 消失，
转移到 **dyld 加载器内部**（`Loader::getLoader → makeJustInTimeLoaderDisk → munmap`），且发生在
我们 dispatch 的后台线程（`com.apple.root.default-qos`）。即 async 修复后代码跑得更远，暴露出
新问题：`STSRealInit` 里三句 `dlopen(ScreenTimeCore/UI/UICore)` 在 dyld 启动阶段从后台线程调用，
重入 dyld 与 ellaKit 并发注入撞车。这些框架在 Preferences 里本就已加载，dlopen 多余 → 直接移除，
晚加载类由 add_image 回调 + 周期重扫兜底。

### v0.4.4：真正根因 —— 推迟到 dyld 完成后才执行 ObjC 初始化

0.4.3 的崩溃报告（`Preferences-2026-11-01-185049.txt`）给出完整调用栈：`+[STSBootstrap load]`
← `load_images` ← `notifyObjCInit`，`EXC_BAD_ACCESS` 崩在 `-[STSConfig applyDictionary:]`
（寄存器在飞选择子 `objectForKeyedSubscript:` / `isKindOfClass:` = `STSBool`）。即：**只要还处
在 dyld 的 load_images 阶段，本注入环境（ellaKit 逐个 dlopen）里给 Foundation 对象发 ObjC
消息就会踩随机雷**——C 构造器、+load 都不安全。修复：+load 里只 `dispatch_async` 调度，
真正的初始化推迟到 dyld 全部完成之后执行（ObjC 完全就绪）。架构本就容忍延迟初始化
（add_image 回调 + 0.5/2/5 秒补扫 + 10 秒周期重扫）。

### v0.4.3：根因修复 —— ObjC 逻辑从 C 构造器移到 +load

0.4.2 日志：纯 C 打点全部落盘、ObjC 代码每次崩在不同位置（0.4.0/0.4.1 崩在 `[STSConfig shared]`，0.4.2 跑到了 `heuristicHook`），崩点漂移且无 NSException = **ObjC 运行时未初始化完毕**。原因：本 dylib 用 `-undefined dynamic_lookup` 链接、不声明对 libobjc/libSystem/Foundation 的依赖，dyld 不把构造器排在这些库初始化之后；systemhook 在 image 0 附近注入，C 构造器在运行时就绪前就跑起来了。修复：构造器只留纯 C 写日志头，全部 ObjC 逻辑移到 `+load`（由运行时自己在镜像加载时调用，必定已就绪——传统 MobileSubstrate 插件的标准做法）。

### v0.4.0~0.4.2：诊断期

- v0.4.0：默认开启保守启发式 hook（只对返回 double + 名字像时长的方法，保留防崩护栏）+ 去掉"类名必须 ST 开头"的扫描限制 + 日志加进程 bundle id 和 ScreenTime 类名清单。
- v0.4.1：弃用 `+shared` 的 `dispatch_once` 改懒加载；`shared/init/applyDictionary` 每步纯 C 打点。
- v0.4.2：`applyDictionary` 逐句打点，把崩溃锁定到具体方法——结果是"每次位置不同"，反而暴露了真正的根因（见 v0.4.3）。

### v0.3.9：默认打包改为 roothide

从本版起，**默认构建产物就是 roothide（隐根）包**，不再默认 rootless。你的设备是 roothide（`systemhook-*.dylib` 注入 + 随机 `.jbroot-XXXX` 路径），之前发 rootless 包（带 `/var/jb`）在 roothide 上安装位置/映射都不对，是「装上没效果 / 日志路径错」的又一个根因。

- **打包布局**：roothide 包的 deb 内部结构用 rootful 式绝对路径（**不带** `/var/jb`），由 roothide 的 dpkg 自动映射到随机 jbroot；`control` 的 `Architecture` 使用 `iphoneos-arm64e`（仅为包标识，不影响 arm64 二进制）。
- **`.jbroot` 符号链接**：每个含 Mach-O 的目录（`MobileSubstrate/DynamicLibraries/`、`PreferenceBundles/ScreenTimeSpoofer.bundle/`）都加了 `.jbroot -> /` 符号链接（roothide 让 jbroot 根映射为 `/`）。
- **`Makefile`**：`THEOS_PACKAGE_SCHEME` 默认 `roothide`；`ARCHS=arm64 arm64e`（0.5.7 起，Theos 下产出双 slice）。
- **代码适配**：`STSJB()` 对 `/var/mobile`、`/tmp` 路径恒等返回，不再错误拼 `/var/jb`，保证设置页与 tweak 在 roothide 下解析出的配置/日志路径完全一致。

> 仍要 rootless / rootful 包：`ROOTLESS=1 ./build_deb.sh` 或 `ROOTFUL=1 ./build_deb.sh`，或 `make THEOS_PACKAGE_SCHEME=rootless`。

### v0.3.8：定位到构造器在 `[STSConfig shared]` 被信号打挂

0.3.7 装上不闪退了，但日志只有 4 行就断：

```
# ===== ScreenTimeSpoofer 0.3.7 boot =====
# pid=8653
# process=/usr/lib/systemhook-C7BA9FA005F558EA.dylib
## 启动时已加载 ScreenTime 镜像：...ScreenTimeUICore..., ScreenTimeCore..., ScreenTimeFoundation..., .../TweakInject/ScreenTimeSpoofer.dylib
```

dylib **确认被注入**（镜像列表里有自己），但写完「已加载镜像」后就没了——既没有 `## 配置`
也没有 `## 配置读取异常`。这说明紧跟在后面的 `[STSConfig shared]` 直接被**信号**
（`EXC_BAD_ACCESS`）打挂，`@try` 根本拦不住。`+shared` 的 `init` 当时会调
`writeDefaultsIfNeeded`（写 plist）+ `reloadIfNeeded`（读 plist），早期文件 I/O 是头号嫌疑。

修法：

| 改动 | 说明 |
|---|---|
| `STSConfig init` 不再做任何文件 I/O | 只在内存里 `applyDictionary:[defaultDictionary]`；写默认值、读文件全部延后 |
| 构造器不再调 `reloadIfNeeded`/`STSReloadConfig` | 聚合缓存直接从内存默认值设；文件读取丢到后台 `dispatch_async` 并 `@try` |
| `dlopen` 加 `ScreenTimeUICore` | iOS16 上 UI 框架叫 `ScreenTimeUICore`（日志里已确认），原来的 `ScreenTimeUI` 必失败 |
| 构造器每一步打点 `STEP: xxx` | 下次若还断，能精确看到卡在哪一步 |

这版**应该不闪退且能写满整个构造器日志**。装完看 `cat /tmp/ScreenTimeSpoofer-boot.log`，
重点关注：
- `## 首次扫描完成：hooked=N` —— N>0 说明挂上了；
- `## 候选方法` —— 真实方法名清单；
- `## 8 秒统计：hooked=N 被调用并改写=M` —— M>0 说明界面真用了被挂的 getter。

### v0.3.7：安全优先的诊断版（先不崩、再拿日志）

0.3.6 收敛到只对 `double` 返回值放宽，仍然闪退。怀疑两处：① 启发式即便只挂 `double`，
仍可能挂到不该挂的 `CGFloat`/动画时长；② 构造器里**极早期**遍历大量类的 `STSDumpCandidates`
可能触发未就绪类的 `+initialize` 而崩。

所以这版**回到 0.3.4（你验证过不闪退）的挂钩行为**，只保留诊断能力：

| 项 | 0.3.7 |
|---|---|
| 启发式挂钩 | **默认关闭**（`HeuristicHook = NO`）—— 行为等同 0.3.4 的精确白名单 |
| 候选 dump | 从构造器移到 **3 秒后**（进程稳定再遍历），且包 `@try` |
| 早期 `NSFileManager createDirectory` | 移除（嫌疑变量） |
| 纯 C 日志 | 保留：构造器第一行就写 `/tmp`，三个路径同写 |

这版**应该不闪退**。装上后即使界面没变，也能拿到 `hooked=N` 和「候选方法」清单，
下一版按真实方法名精准加进白名单即可生效，不再靠启发式盲挂。

> 仍闪退的话，几乎可以断定不是挂钩逻辑，而是注入/加载层 —— 此时请把崩溃日志**文本**直接
> 粘贴给我（附件下载被网络策略拦截，我看不到），并确认日志文件是否生成：
> `cat /tmp/ScreenTimeSpoofer-boot.log`

### v0.3.6：修 0.3.5 的闪退（收敛挂钩 + 去掉无锁共享数组）

0.3.5 装上后「设置」直接闪退。0.3.5 相对 0.3.4（那版只是无效、不闪退）只改了三处，逐个收敛：

| 0.3.5 的改动 | 风险 | 0.3.6 的处理 |
|---|---|---|
| 启发式放宽到 `'@'`（NSNumber）和 `'q'/'Q'`（整数）返回值 | **最高**。整数返回值很可能是枚举/索引/计数，缩放后 UI 内部越界断言直接崩 | 启发式**只作用于返回 `double` 的方法**（时长几乎都是 `NSTimeInterval` 秒）；`'@'`/`'q'`/`'Q'` 恢复为仅精确白名单 |
| 样本收集用共享 `NSMutableArray` `addObject` | 放宽后 getter 被多线程调用，无锁并发写数组必崩 | 改成 `__sync_fetch_and_add` **原子计数**，不再有共享可变数组 |
| 早期调用 `[[NSBundle mainBundle] bundleIdentifier]` | 多余变量 | 移除 |
| — | 新增 | **数值护栏**：`v > 2592000`（30 天）一律不动，避免把时间戳/绝对时间当时长改坏 |

另外新增配置开关 `HeuristicHook`（默认 `YES`）。若仍闪退，把它设为 `false` 即回到 0.3.4 的保守挂钩（只挂精确白名单），无需重新编译：

```
/var/mobile/Library/Preferences/com.evander.screentimespoofer.plist
    HeuristicHook = false
```

**闪退时的紧急开关**（不想折腾直接停用注入）：

```bash
rm /var/jb/Library/MobileSubstrate/DynamicLibraries/ScreenTimeSpoofer.plist
```

删掉这个 filter 文件，dylib 就不再被注入，设置恢复正常；想再试时装回去即可。

### v0.3.5：修日志写不出 + 放宽挂钩命中

上一版装完 `Logs` 目录里没有文件、界面也仍然没变化。定位到三处：

1. **日志被写到了错误路径**。`STSJB()` 在 `/var/mobile/Library/Logs` 不存在时会把路径拼成
   `/var/jb/var/mobile/Library/Logs/...`（一个不存在的路径），所以你在 `Logs` 目录当然看不到。
   本版日志改为**三个真实绝对路径同时写**，纯 C `open/write`，不经过 `STSJB`：
   - `/var/mobile/Library/Logs/ScreenTimeSpoofer-boot.log`
   - `/tmp/ScreenTimeSpoofer-boot.log`   ← 最稳，优先看这个
   - `/var/mobile/Documents/ScreenTimeSpoofer-boot.log`
2. **日志依赖配置，配置一炸日志全丢**。旧版 `STSFlushBootLog` 第一行就 `[STSConfig shared]`，
   初始化抛异常就被 `@catch` 吞掉，一条都写不出来。本版日志**完全不碰配置**，构造器
   **第一行**就落盘 —— 只要 dylib 被注入，就一定有文件。
3. **挂钩命中率太低**。旧版只 hook `DurationSelectors` 里精确列出的名字，iOS 16.7 上真实
   getter 名不在列表里就是 0 命中。本版改成**名字启发式**：名字含
   `usage / duration / seconds / minutes / timespent / timeused / screentime` 且不含
   `count / since / interval / timestamp / start / end / date / type / state / identifier` 等，
   零参 + 返回数值即挂钩；同时**自动把候选方法 dump 进日志**，方便下一步精准适配。

日志新增两段关键信息：

- `## 候选方法`：列出 ScreenTime 镜像里所有「ST* 类 · 零参 · 返回数值 · 名字像时长」的方法，
  即使 0 命中也能看到真实方法名。
- `## 8 秒统计：hooked=N 被调用并改写=M`：M>0 说明界面确实调用了被挂的 getter 并改写了。

排查对照（0.3.5 版）：

| 日志表现 | 结论 |
|---|---|
| 三个路径都没有文件 | dylib 没被注入 → 检查 `/var/jb/Library/MobileSubstrate/DynamicLibraries/` 与过滤器，装完 `killall -9 Preferences` 或 respring |
| 有文件、`hooked=0` | 类名/方法名对不上 → 看 `## 候选方法` 段 |
| `hooked>0` 但 `被调用并改写=0` | 挂的对象没被 UI 用到 → 看候选段换目标 |
| `被调用并改写>0` 但界面没变 | 界面读的是别的数据源（如小组件独立进程） |

### v0.3.3：闪退修复（self.tableView 不存在）

v0.3.2 装上后一点进设置页就闪退。崩溃栈：

```
-[UIResponder doesNotRecognizeSelector:]
___forwarding___
-[STSRootListController viewWillAppear:]
```

反汇编定位到 `objc_msgSend(self, @selector(tableView))` 返回地址处 ——
**iOS 15 重构后 `PSListController` 不再是 `UITableViewController` 子类，没有 `tableView`
这个 selector**（表格视图藏在私有 ivar 里，页面能渲染但外部拿不到）。

这也顺带解释了 v0.3.1「按钮不见」的真正原因：`sts_installApplyButton` 里的
`self.tableView` 抛异常被自己包着的 `@catch` 静默吃掉，按钮根本没装上 ——
不是 `PSButtonCell` 被丢，是我找错了 tableView。

修法：所有需要表格的地方改成从 `self.view` **递归找 `UITableView` 实例**
（`STSFindTableView`），不再假设任何 property 名字。v0.3.1 的 viewWillAppear 没崩
只是因为 `_specifiers` 还是 nil、`reloadData` 那行没执行到，纯属运气。

### v0.3.2：按钮修复

v0.3.1 装上后内容出来了（分组头、输入框、footnote 都在），但「应用」按钮那一行消失。
原因是 `PSButtonCell` 这条 specifier 在 iOS 16.7 上被框架的 plist 加载器丢弃了 ——
同一份 plist 里 `PSGroupCell` / `PSEditTextCell` 都正常，只有它不见了。

不再猜 cell 字符串，改成完全可控的画法：

- 「应用」按钮放进 `tableView.tableFooterView`，用原生 `UIButton` 绘制
  （蓝底白字、圆角 10、高 48）；`viewDidLayoutSubviews` 里跟随表格宽度对齐；
  `viewWillAppear:` 里发现 footer 被清掉就补装；
- 点按钮时**直接读输入框的 text**（递归找 `UITextField`），不依赖
  `PSEditTextCell` 何时把值提交给 `setPreferenceValue:specifier:` —— 那个时机不可控，
  容易读到最后一次提交的旧值；
- 数值 ≤ 0 时弹提示且不写盘；写入失败（权限问题）也有明确弹窗。

### v0.3.1：空白页修复

v0.3.0 能打开页面（标题正确）但表格全空，两个原因叠加：

| 问题 | 说明 | 修法 |
|---|---|---|
| 装载时机错了 | `-specifiers` getter 里懒加载没用 —— `PSListController` 内部大量路径**直接读 `_specifiers` ivar**，不经过 getter；而 `[super viewDidLoad]` 里就会 reload，那一刻还是 nil | 在 `[super viewDidLoad]` **之前**把 `_specifiers` 填好 |
| 找不到 Root.plist | `loadSpecifiersFromPlistName:target:` 依赖 `self.bundle`，从 PreferenceLoader 的 `detail` 直接 push 时这个 bundle 没被赋值，它跑去设置 App 的 mainBundle 里找 | 优先用三参版本，显式传 `[NSBundle bundleForClass:[self class]]` |

另外加了第三层兜底：两个 load 都失败时，用 `PSSpecifier` 代码构造（`PSEditTextCell=8` / `PSButtonCell=13`），
这样最坏情况也能看到输入框，不会给你一片白。以及 `viewWillAppear:` 里再刷一次表格。

装上新版后如果还是空白，抓日志：

```bash
log stream --predicate 'process == "Preferences"' | grep '\[STS\]'
```

`[STS] specifiers ready: N 项` 这行会直接告诉你装载到几项。

历史问题：v0.1/v0.2 曾尝试「空 specifiers + 接管全部 tableView 回调」的自绘路线，
因 `PSListController` 内部路径众多、且 v0.2 的 `@catch(id)` 引入了 `_OBJC_EHTYPE_id`
外部符号（dyld 解析失败会导致整个 dylib 加载失败），都不够稳，v0.3 起废弃。

### 一个容易踩的坑（已在代码里规避）

设置页 bundle 和 tweak dylib 会被加载进**同一个进程**。如果两边各编进一份 `STSConfig` 类，runtime 会报 `Class STSConfig is implemented in both ...`，其中一个类的方法不会被正确 fixup，调用即崩。所以两边只通过 `STSConstants.h` 共享常量，**不共享类**。

### 只想要 tweak、不要设置页

删掉入口 plist 即可，tweak 本身照常工作：

```bash
rm /var/jb/Library/PreferenceLoader/Preferences/ScreenTimeSpoofer.plist
killall -9 Preferences
```

改时间就直接用 `plutil`：

```bash
plutil -replace TargetMinutes -integer 45 /var/mobile/Library/Preferences/com.evander.screentimespoofer.plist
```

## 4. 编译

### 4.1 用 Theos（有 iOS SDK 时）

需要 [Theos](https://theos.dev) 和 iOS SDK（`$THEOS/sdks/` 下至少一个 iPhoneOS SDK）。

```bash
export THEOS=~/theos
cd ScreenTimeSpoofer
make clean && make package      # Makefile 已默认 roothide + ARCHS="arm64 arm64e"
```

`Makefile` 里已固定：

| 变量 | 值 | 说明 |
|---|---|---|
| `ARCHS` | `arm64 arm64e` | Theos 下产出双 slice（arm64e 需 PAC 签名环境）；只要 arm64 用 `make ARCHS=arm64` |
| `THEOS_PACKAGE_SCHEME` | `roothide` | 默认隐根包（rootful 式绝对路径 + `iphoneos-arm64e` + .jbroot 链接）；rootless 用 `make THEOS_PACKAGE_SCHEME=rootless`，rootful 用 `make THEOS_PACKAGE_SCHEME=rootful` |
| `SUBPROJECTS` | `prefs` | 一并编译设置页 bundle（见 `prefs/Makefile`） |

产物在 `packages/com.evander.screentimespoofer_0.6.4_iphoneos-arm64e.deb`。

> `control` 里的 `Package` / `Maintainer` / `Author` 已设为 `com.evander.screentimespoofer` / `evander`；如果要发布自己的分支，记得先换掉，否则会和已有包冲突。

### 3.2 用 build_deb.sh（无 iOS SDK 时，`out/` 里的包就是这么来的）

```bash
./build_deb.sh                 # 默认出 roothide 包：out/ScreenTimeSpoofer.deb（iphoneos-arm64e）
ROOTLESS=1 ./build_deb.sh       # 额外出 rootless 包：out/ScreenTimeSpoofer-rootless.deb
ROOTFUL=1  ./build_deb.sh       # 额外出有根包：out/ScreenTimeSpoofer-rootful.deb
```

只需要 `clang`（支持 `arm64-apple-ios` target）、`lld` 的 `ld64.lld`、`dpkg-deb`，**不需要 Theos 和 iOS SDK**：源码里用到的系统符号全部靠 `-undefined dynamic_lookup` 在加载时从设置 App 进程里解析，所以可以裸编译。

## 5. 安装

```bash
# 方式一：命令行
scp packages/*.deb root@<设备IP>:/var/root/
ssh root@<设备IP> "dpkg -i /var/root/*.deb && killall -9 Preferences"

# 方式二：Filza 打开 deb → 安装；或 Sileo/Zebra 本地安装
```

装完打开「设置 → 屏幕使用时间」，默认应该看到总时长变成 **30 分钟**，柱状图和排行同比缩小。

## 6. 配置

首次启动会自动生成：

```
/var/mobile/Library/Preferences/com.evander.screentimespoofer.plist
```

（roothide / rootless 下该路径经越狱层透明映射，代码里 `STSJB()` 已对 `/var/mobile`、`/tmp` 路径不做 jbroot 前缀适配，无需关心 jbroot 真实位置。）

用 Filza 或 `plutil` 改完保存即可，**不用重启**——每次取时长时会按 mtime 判断是否重载。

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `Mode` | String | `target` | `target` 按目标总时长等比缩放；`scale` 按固定系数；`cap` 系数 + 封顶；`off` 关闭 |
| `TargetMinutes` | Number | `30` | `target` 模式的目标总时长（分钟） |
| `Scale` | Number | `0.2` | `scale`/`cap` 模式的系数；同时是 `target` 反推失败时的兜底 |
| `CapMinutes` | Number | `0` | 封顶值，`0` 表示不限 |
| `AggregateClass` | String | `STUsageDetails` | 承载“总时长”的类 |
| `AggregateSelector` | String | `totalUsage` | 总时长的 getter |
| `IncludeClasses` | Array | 见代码 | 优先挂钩的类名 |
| `ExcludeClasses` | Array | `[]` | 排除的类名（用于修“翻倍”类问题） |
| `DurationSelectors` | Array | 见代码 | 需要挂钩的选择器名（精确匹配） |
| `ScanAllScreenTimeClasses` | Bool | `true` | 兜底扫描全部 ScreenTime 类 |
| `Probe` | Bool | `false` | 打开后 dump 候选方法清单 |

示例：把总时长改成 1 小时 15 分，并限制任何单项不超过 40 分钟：

```bash
plutil -replace Mode -string target \
       -replace TargetMinutes -integer 75 \
       -replace CapMinutes -integer 40 \
       /var/mobile/Library/Preferences/com.evander.screentimespoofer.plist
killall -9 Preferences
```

---

## 7. 版本适配（重要）

`ScreenTimeUI` / `ScreenTimeCore` 是私有框架，**类名和选择器在 iOS 大版本之间会变**。代码里的默认值是 iOS 16/17 上最常见的组合，但不保证在你的系统上全中。

如果装上没效果，按这个流程对齐：

1. 打开探针：

   ```bash
   plutil -replace Probe -bool true /var/mobile/Library/Preferences/com.evander.screentimespoofer.plist
   killall -9 Preferences        # 再进一次「屏幕使用时间」
   ```

2. 看日志文件，里面是「类名 → 零参返回数值的方法」清单：

   ```bash
   cat /var/mobile/Library/Logs/ScreenTimeSpoofer-probe.log
   ```

3. 找承载总时长的类/方法（通常是某个 `STUsageDetails` / `STUsage` 上的 `totalUsage`、`totalTime`），写进 `AggregateClass` / `AggregateSelector`；如果时长 getter 名字不在默认列表里，把它追加到 `DurationSelectors`。

4. 实时看钩子有没有挂上（需要 `libhooker`/`oslog` 环境）：

   ```bash
   log stream --predicate 'subsystem == "com.evander.screentimespoofer"' --level info
   ```

探针会列出全部候选，即使类名完全变了，也能从清单里把新的名字捞出来，改配置即可，不用重新编译。

---

## 8. 常见问题

**装包报 `trying to overwrite '.../ScreenTimeSpoofer.dylib', which is also in package com.example.screentimepoofer`**
0.5.7 改包名后，旧包还装着就会和新包声明同一批文件。0.5.9 起 `control` 加了 `Replaces: com.example.screentimepoofer`，dpkg 允许覆盖；想彻底干净，装完执行 `dpkg -r com.example.screentimepoofer`。

**boot 日志显示 `被调用=0 被改写=0` / `原始总时长=0.0min`**
先别急着下「hook 挂错类」的结论：这份是启动自检日志，8 秒统计时你多半还停在插件设置页、没进「屏幕使用时间」页面，而那个页面用的私有框架是点进去才懒加载的。v0.6.1 起会实时检测新框架并全量 dump，统计也改成 8/20/45/90 秒多次。请装完手动进入那个页面停 5 秒再抓日志，看有没有 `★ 检测到懒加载框架` 以及 `[BUTTON] / [NAV]` 前缀的行：没有 `[BUTTON]` 说明按钮根本没装上或没绑事件，有 `[NAV] 成功` 却仍零调用才是数据源确实不同。另外日志首行的版本号现在是真实的（`0.6.1`），可用来确认是否加载了旧 dylib。

**能跳转，但要等 20 多秒**
v0.6.2 对 7 个 URL 候选逐个调同步 `openURL:`，无效 scheme 会阻塞主线程等待系统判定，连延迟定时器一起被拖住。v0.6.3 起只发 2 个纯异步深链、立即 `animated:NO` pop 回首页、0.25 秒后 didSelect、0.5 秒后验证，总耗时约 0.75 秒；`[JUMP]` 日志带 `[+X.XXs]` 时间戳可直接定位残留卡顿。

**点「打开屏幕使用时间」按钮没反应 / 用不了**
v0.6.0/0.6.1 的根因是：在插件页（栈顶）去调栈底设置首页的 `didSelectRowAtIndexPath:`，首页不是 active 控制器，Preferences 直接忽略 —— 页面纹丝不动。v0.6.2 起改成多阶段协调器：先发 `prefs:` / `App-Prefs:` 深链（iOS 16/17 有效，此前误判为不可用）→ 没进去就 pop 回设置首页让首页 active → 再触发那一行 → 每步验证并写 `[JUMP]` 日志 → 全失败才弹窗。抓取 boot 日志点一次按钮，看 `[BUTTON]` 和 `[JUMP]` 各阶段结果即可定位；最坏情况也会先返回设置首页，「屏幕使用时间」行就在眼前。已应用的时长在重新进入该页面后生效。

**安装时 unpack 卡很久**
0.5.3~0.5.8 的 `preinst` 用 `find` 扫 `/var/containers/Bundle/Application`（数万文件，且 `/var` 与 `/private/var` 是同一目录被扫两遍）。0.5.9 改成只删几个已知路径，安装恢复到秒级。

**数字翻倍 / 变成平方数**
说明某条聚合路径既挂了子项又挂了聚合值。把 `AggregateClass` 对应的类加进 `ExcludeClasses`，或在 `DurationSelectors` 里去掉 `totalUsage`，只留具体类上的 getter。

**装完没反应**
三种可能：① 注入的进程不对（这个界面在 `com.apple.Preferences` 里，确认 filter 没被改成别的）；② 选择器名不匹配 → 跑探针；③ 数据是缓存的老对象，`killall -9 Preferences` 重开一次。

**设置闪退**
进安全模式（Dopamine 长按 → 安全模式）后把 `Mode` 改成 `off`，或直接删配置文件。插件只在被注入进程内生效，不会影响系统启动。

**能不能改某个 App 单独的时长**
可以。`STAppUsage` 也在默认 `IncludeClasses` 里，全局等比缩放后各 App 一起变；如果要“只改某一个 App”，可以在 `STSApplyValue` 里加一条按 `STAppUsage.bundleIdentifier` 判断的分支——这是唯一需要改代码的场景。

**桌面小组件为什么没变**
小组件跑在独立进程（`com.apple.screentime*` 相关扩展），需要在 `ScreenTimeSpoofer.plist` 的 `Bundles` 里追加对应 bundle id 才生效。

---

## 9. 边界

- 只在「设置」App 进程内改显示值，**不写系统数据库**，其它 App 或系统组件读到的仍然是真实数据。
- 依赖私有 API，系统升级后需要重新适配；作者不对刷机/白苹果负责。
- 仅用于自己设备上的界面演示、截图、测试。**不要用来规避家长控制或向他人谎报使用时长**——这类用途既有风险，也会让插件本身失去意义。
