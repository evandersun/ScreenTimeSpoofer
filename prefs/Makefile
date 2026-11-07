# 设置页 bundle 子项目：产出 ScreenTimeSpoofer.bundle 安装到
# <JB 根>/Library/PreferenceBundles/ScreenTimeSpoofer.bundle/
#
# 注意：不编 STSConfig.m —— bundle 和 tweak dylib 会同时加载进设置 App 进程，
# 两边各编一份同名类会触发 runtime 的 “Class X is implemented in both” 冲突。
# 两边只通过 ../STSConstants.h 共享常量。

TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME ?= roothide

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ScreenTimeSpoofer

ScreenTimeSpoofer_FILES = ../STSPrefsController.m
ScreenTimeSpoofer_CFLAGS = -fobjc-arc -I.. -Wno-unused-function -Wno-deprecated-declarations
ScreenTimeSpoofer_INSTALL_PATH = /Library/PreferenceBundles/ScreenTimeSpoofer.bundle
ScreenTimeSpoofer_FRAMEWORKS = UIKit Foundation
ScreenTimeSpoofer_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/bundle.mk
