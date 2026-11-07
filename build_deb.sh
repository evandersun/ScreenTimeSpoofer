#!/usr/bin/env bash
#
# build_deb.sh —— 在无 iOS SDK 的 Linux 上交叉编译 arm64 并打出 deb
#
# 默认只出 roothide 隐根越狱包（Dopamine RootHide 等）：out/ScreenTimeSpoofer.deb
#   - deb 内用 rootful 式绝对路径（不带 /var/jb），roothide 的 dpkg 自动映射到随机 jbroot
#   - control 的 Architecture = iphoneos-arm64e（roothide 规范，仅为包标识）
#   - 含 Mach-O 的目录自动加 .jbroot 符号链接
# 需要顺带出其它变体时：ROOTLESS=1 ./build_deb.sh  或  ROOTFUL=1 ./build_deb.sh
#
# 产物（roothide 下相对 jbroot 根）：
#   1) tweak dylib        /Library/MobileSubstrate/DynamicLibraries/
#   2) 设置页 bundle      /Library/PreferenceBundles/ScreenTimeSpoofer.bundle/
#   3) PreferenceLoader   /Library/PreferenceLoader/Preferences/
#
# 依赖：clang（支持 arm64-apple-ios target）、lld 的 ld64.lld、dpkg-deb
set -euo pipefail

cd "$(dirname "$0")"

NAME=ScreenTimeSpoofer
# 桩头随仓库一起发布，clone 下来就能直接构建；需要外部桩头时用 STUB=/path/to/stubs 覆盖
STUB=${STUB:-$(dirname "$0")/stubs}
BUILD=.build
OUT=out
MIN_IOS=15.0

CC=${CC:-clang}
LD64=${LD64:-}
command -v "$LD64" >/dev/null 2>&1 || LD64=$(ls /usr/lib/llvm-*/bin/ld64.lld 2>/dev/null | head -1)
[ -n "$LD64" ] || { echo "找不到 ld64.lld，请先安装 lld"; exit 1; }

# 对象布局防线：桩头 NSObject 若漏掉 isa，子类 BOOL ivar 会从偏移 0 开始并覆盖 isa，
# 曾在 0.3.5–0.4.6 造成位置漂移的 EXC_BAD_ACCESS。宁可拒绝构建，也不能再发出这种包。
grep -Eq 'Class[[:space:]]+isa;' "$STUB/Foundation/Foundation.h" || {
    echo "错误：$STUB/Foundation/Foundation.h 的 NSObject 缺少 Class isa"; exit 1;
}

# -fobjc-exceptions：源码里用 @try/@catch 兜住私有框架的异常，必须有这个开关
CFLAGS="-target arm64-apple-ios$MIN_IOS -fobjc-arc -fobjc-runtime=ios-$MIN_IOS \
        -fobjc-exceptions -nostdinc -isystem $STUB -I. -O2 -Wall -Wextra \
        -Wno-unused-parameter -Wno-deprecated-declarations"

rm -rf "$BUILD" "$OUT"
mkdir -p "$BUILD" "$OUT"

echo "==> 编译 tweak (arm64, iOS $MIN_IOS)"
$CC $CFLAGS -c STSConfig.m -o "$BUILD/STSConfig.o"
cp Tweak.xm "$BUILD/Tweak.m"
$CC $CFLAGS -c "$BUILD/Tweak.m" -o "$BUILD/Tweak.o"

echo "==> 编译设置页 bundle（不编 STSConfig：避免与 tweak 在同一进程里撞同名类）"
$CC $CFLAGS -c STSPrefsController.m -o "$BUILD/Prefs.o"

echo "==> 链接"
"$LD64" -arch arm64 -dylib \
        -platform_version ios $MIN_IOS $MIN_IOS \
        -undefined dynamic_lookup -adhoc_codesign \
        -install_name /Library/MobileSubstrate/DynamicLibraries/$NAME.dylib \
        -o "$BUILD/$NAME.dylib" "$BUILD/STSConfig.o" "$BUILD/Tweak.o"

"$LD64" -arch arm64 -dylib \
        -platform_version ios $MIN_IOS $MIN_IOS \
        -undefined dynamic_lookup -adhoc_codesign \
        -install_name /Library/PreferenceBundles/$NAME.bundle/$NAME \
        -o "$BUILD/$NAME.bundle.exec" "$BUILD/Prefs.o"

if command -v llvm-objdump-18 >/dev/null 2>&1; then
    echo "==> 校验 Mach-O"
    for f in "$BUILD/$NAME.dylib" "$BUILD/$NAME.bundle.exec"; do
        printf '    %s: ' "$(basename "$f")"
        llvm-objdump-18 --macho --private-headers "$f" \
            | grep -E "MH_MAGIC_64|platform ios|minos" | tr -s ' ' | tr '\n' ' '
        echo
    done
fi

package() {
    local variant=$1 prefix=$2 arch=$3 mkjbroot=$4 debdir
    debdir="$BUILD/deb-$variant"
    # prefix: jbroot 内路径前缀（不含任何斜杠，可为空）；rootless=var/jb，roothide/rootful=空。
    # base 拼出 jbroot 在包内的根目录，避免 debdir 与 Library 之间缺/多斜杠。
    local base="$debdir"
    [ -n "$prefix" ] && base="$debdir/$prefix"
    rm -rf "$debdir"
    mkdir -p "$debdir/DEBIAN" "$base/Library/MobileSubstrate/DynamicLibraries"

    # 1) tweak
    cp "$BUILD/$NAME.dylib" "$base/Library/MobileSubstrate/DynamicLibraries/$NAME.dylib"
    cp "$NAME.plist"        "$base/Library/MobileSubstrate/DynamicLibraries/$NAME.plist"
    # roothide：含 Mach-O 的目录放 .jbroot -> / 符号链接（roothide 让 jbroot 根映射为 /）
    if [ "$mkjbroot" = "1" ]; then
        ln -sf / "$base/Library/MobileSubstrate/DynamicLibraries/.jbroot"
    fi

    # 2) 设置页：layout/ 直接铺进去
    mkdir -p "$base/Library/PreferenceBundles/$NAME.bundle"
    cp "$BUILD/$NAME.bundle.exec" "$base/Library/PreferenceBundles/$NAME.bundle/$NAME"
    cp "layout/Library/PreferenceBundles/$NAME.bundle/Info.plist" \
       "$base/Library/PreferenceBundles/$NAME.bundle/Info.plist"
    cp "layout/Library/PreferenceBundles/$NAME.bundle/Root.plist" \
       "$base/Library/PreferenceBundles/$NAME.bundle/Root.plist"
    if [ "$mkjbroot" = "1" ]; then
        ln -sf / "$base/Library/PreferenceBundles/$NAME.bundle/.jbroot"
    fi
    mkdir -p "$base/Library/PreferenceLoader/Preferences"
    cp "layout/Library/PreferenceLoader/Preferences/$NAME.plist" \
       "$base/Library/PreferenceLoader/Preferences/$NAME.plist"

    # 版本/依赖统一取自项目根目录的 control，只按打包变体覆盖 Architecture
    sed -e "s/^Architecture:.*/Architecture: $arch/" control > "$debdir/DEBIAN/control"

    # 0.5.9：只清理「已知安装位置」的旧残留，几个 rm 常数时间完成。
    # 0.5.3~0.5.8 这里用 find 扫 /var/containers/Bundle/Application（数万文件），
    # 而且 /var 与 /private/var 在 iOS 上是同一目录，等于扫了两遍 —— 这就是
    # 前几版 unpack 卡几十秒的原因。文件冲突改由 control 的 Replaces 处理。
    cat > "$debdir/DEBIAN/preinst" <<'EOF'
#!/bin/sh
# roothide 下 /Library/... 由 libjbroot 自动映射到随机 jbroot；rootless 用 /var/jb 前缀。
for root in "" "/var/jb"; do
    for f in \
        "$root/Library/MobileSubstrate/DynamicLibraries/ScreenTimeSpoofer.dylib" \
        "$root/Library/MobileSubstrate/DynamicLibraries/ScreenTimeSpoofer.plist" \
        "$root/Library/PreferenceLoader/Preferences/ScreenTimeSpoofer.plist" \
        "$root/Library/PreferenceBundles/ScreenTimeSpoofer.bundle/ScreenTimeSpoofer" \
        "$root/Library/PreferenceBundles/ScreenTimeSpoofer.bundle/Info.plist" \
        "$root/Library/PreferenceBundles/ScreenTimeSpoofer.bundle/Root.plist"; do
        rm -f "$f" 2>/dev/null
    done
done
exit 0
EOF

    cat > "$debdir/DEBIAN/postinst" <<'EOF'
#!/bin/sh
killall -9 Preferences 2>/dev/null
exit 0
EOF
    cat > "$debdir/DEBIAN/prerm" <<'EOF'
#!/bin/sh
killall -9 Preferences 2>/dev/null
exit 0
EOF
    chmod 0755 "$debdir/DEBIAN/preinst" "$debdir/DEBIAN/postinst" "$debdir/DEBIAN/prerm"

    local deb="$OUT/$NAME-$variant.deb"
    if [ "$variant" = "roothide" ]; then deb="$OUT/$NAME.deb"; fi
    dpkg-deb --build --root-owner-group "$debdir" "$deb"
    echo "    -> $deb  ($arch)"
}

echo "==> 打包（默认 roothide：rootful 式绝对路径布局 + iphoneos-arm64e + .jbroot 符号链接，"
echo "    roothide 的 dpkg 会自动把文件映射到随机 jbroot）"
package roothide "" iphoneos-arm64e 1
# 可选：同时出其它变体（默认不编，按需在前面加环境变量）
if [ "${ROOTLESS:-0}" = "1" ]; then package rootless "var/jb" iphoneos-arm64 0; fi
if [ "${ROOTFUL:-0}"  = "1" ]; then package rootful  ""       iphoneos-arm   0; fi

echo "==> 完成"
ls -lh "$OUT"
