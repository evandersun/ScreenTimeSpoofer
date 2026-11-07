TARGET := iphone:clang:latest:15.0

# 同时编 arm64 与 arm64e 两个 slice（A12+ / roothide 设备是 arm64e）。
# 注意：arm64e 要求带 PAC 的签名环境（Theos + iOS SDK）。无 SDK 的 Linux 交叉构建
# 脚本 build_deb.sh 仍只产出已验证可用的 arm64 slice；如需单架构可用 make ARCHS=arm64 覆盖。
ARCHS = arm64 arm64e

# 默认按「roothide 隐根越狱」打包（Dopamine RootHide 等）：
#   - deb 内部结构用 rootful 式绝对路径（不带 /var/jb），由 roothide 的 dpkg 自动映射到随机 jbroot
#   - control 的 Architecture 使用 iphoneos-arm64e（roothide 规范，仅为包标识，不影响 arm64 二进制）
#   - 含 Mach-O 的目录会自动加 .jbroot 符号链接
# 需要 rootless（Dopamine / palera1n，/var/jb）时：make THEOS_PACKAGE_SCHEME=rootless
# 需要 rootful（checkra1n / unc0ver）时：make THEOS_PACKAGE_SCHEME=rootful
THEOS_PACKAGE_SCHEME ?= roothide
export THEOS_PACKAGE_SCHEME

# 装完自动重启「设置」进程，方便看效果
INSTALL_TARGET_PROCESSES = Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ScreenTimeSpoofer

ScreenTimeSpoofer_FILES = Tweak.xm STSConfig.m
ScreenTimeSpoofer_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations
ScreenTimeSpoofer_FRAMEWORKS = Foundation
ScreenTimeSpoofer_PRIVATE_FRAMEWORKS =

# 设置页（PreferenceLoader bundle），见 prefs/Makefile
SUBPROJECTS += prefs

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 Preferences || true"
