# 更新日志 · ScreenTimeSpoofer

当前稳定版：**v0.6.4**。按时间倒序排列，完整源码见 [github.com/evandersun/ScreenTimeSpoofer](https://github.com/evandersun/ScreenTimeSpoofer)。

---

## v0.6.4 · 2026-11-07

**设置页新增 QQ 群入口 + 源侧置顶精选与更新日志**

- 设置页 footer 新增第三个按钮 **「QQ群：1135135953」**（橙色），点击异步打开 QQ 群加群链接；链接全部参数原样保留，不做二次编码。
- 沿用 v0.6.3 的教训，只用 `openURL:options:completionHandler:` 异步版，不调同步 `openURL:`，避免阻塞主线程。
- footer 高度 178 → 236，状态标签下移并同步适配横竖屏；点击写入同一份 boot 日志（`[BUTTON]` / `[QQ]`）。
- 源新增**置顶精选横幅**：修正 `sileo-featured.json` 为官方 `FeaturedBannersView` 格式（此前 `class` 写错导致卡片一直不显示），配两张 16:9 卡片，点击直达插件详情。
- 新增本**更新日志**（仓库 `CHANGELOG.md` + 网页 `changelog.html`），源首页增加「最近更新」区块。
- **插件图标改回几何时钟**；**源头像（猫图）保持不变**。图片 URL 版本戳 `v=2 → v=3` 穿透客户端缓存。
- 两个包同步发布：`iphoneos-arm64e`（roothide）/ `iphoneos-arm64`（rootless）。

## v0.6.3 · 2026-11-07

**一键跳转从 20 多秒压到约 0.75 秒**

- 删掉阻塞主线程的同步 `openURL:` 与 AppDelegate 直投；URL 候选从 7 个精简为 2 个纯异步深链。
- 立即 `popToRootViewControllerAnimated:NO` 回设置首页，`0.25s` 后触发「屏幕使用时间」行的 `didSelect`，`0.5s` 后验证。
- `[JUMP]` 日志自动带 `[+X.XXs]` 相对耗时时间戳，可直接定位任何残留卡顿。
- 新建官方越狱源 `https://evandersun.github.io/`，同时提供 roothide 与 rootless 双架构包。

## v0.6.2 · 2026-11-07

**修复「打开屏幕使用时间」按钮无反应**

- 根因：在插件页栈顶去调用栈底首页（非 active）的 `didSelectRowAtIndexPath:`，被 Preferences 忽略。
- 改为多阶段跳转协调器：URL 深链 → pop 回首页 → 首页 active 时 didSelect → 验证 → 兜底弹窗；延迟任务挂在独立单例上，pop 后不会被销毁。

## v0.6.1 · 2026-11-07

**框架懒加载实时 dump + 统一日志**

- 每 0.5s 轮询新载入的 ScreenTime / UsageTracking / FamilyControls / ManagedSettings / DeviceActivity 框架，dump 类与时长相关零参方法。
- 设置页按钮写入 dylib 同一份 boot 日志，抓一份日志即可区分「没点到按钮」和「hook 没生效」。
- 日志首行写真实版本号，便于判断旧 dylib 残留。

## v0.6.0 · 2026-11-07

**重修一键跳转**：改为进程内导航重写 + 状态标签 + 兜底弹窗，保证每次点击都有可见反馈。

## v0.5.9 · 2026-11-07

**安装速度恢复秒级**

- `control` 加 `Replaces: com.example.screentimepoofer`，解决旧包名残留导致的 `trying to overwrite` 覆盖冲突。
- `preinst` 从全盘 `find /var/containers` 改为精确路径 `rm`，unpack 从几十秒降到 0.00 秒。

## v0.5.7 ~ v0.5.8 · 2026-11-06

- 设置页新增「打开屏幕使用时间」按钮（URL 深链）。
- 修配置/日志路径（`/var/mobile` 不加 `/var/jb` 前缀）、rootless 与 roothide 布局差异。
- 包名统一为 `com.evander.screentimespoofer`，`Makefile` 支持 `arm64 arm64e`。

## v0.5.0 ~ v0.5.6 · 2026-11-01 ~ 11-06

- 修复从 0.3.5 起持续闪退的根因：桩头 `NSObject` 缺 `Class isa`，子类 BOOL ivar 从偏移 0 覆盖类指针。
- 修复 `imp_implementationWithBlock` 的 block 不接收 `_cmd` 导致 `NSStringFromSelector` 崩溃（改为捕获 `SEL`）。
- 修复「固定 15 分钟」与「变成一秒」：锚定 `totalScreenTime` / `screenTime`，默认不缩放分项，取消被污染的自适应基准。
- 设置页闪退/空白/按钮消失：提前填 `_specifiers`、显式 bundle、递归找 `UITableView`、footer 用原生 `UIButton` 而非 `PSButtonCell`。

---

> 诊断日志路径：`/var/mobile/Library/Logs/ScreenTimeSpoofer-boot.log`
