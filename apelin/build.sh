#!/bin/sh
#
# Apelin 外部构建脚本：不经过 Theos / make，直接用本机 clang + iPhoneOS SDK 编译，
# ldid 签名，dpkg-deb 只产出一个 .deb 到 $APELIN_PACKAGE_DIR。
#
# 环境（由 Apelin 提供）：
#   APELIN_PREFIX       roothide 为空，rootless 为 /var/jb
#   APELIN_ARCHITECTURE iphoneos-arm64e / iphoneos-arm64
#   APELIN_BOOTSTRAP    roothide / rootless
#   APELIN_BUILD_ID     写进 dylib 的加载标记
#   APELIN_PACKAGE_DIR  空目录，产物写这里
#   SDKROOT / PATH      已指向可用的 SDK 与工具链
set -eu

PREFIX="${APELIN_PREFIX:-}"
ARCHITECTURE="${APELIN_ARCHITECTURE:-iphoneos-arm64e}"
BOOTSTRAP="${APELIN_BOOTSTRAP:-roothide}"
BUILD_ID="${APELIN_BUILD_ID:-local}"
PACKAGE_DIR="${APELIN_PACKAGE_DIR:?APELIN_PACKAGE_DIR 未设置}"
ROOT="${APELIN_PROJECT_ROOT:-$(pwd)}"

WORK="${TMPDIR:-/tmp}/apelin-insulation-$$"
OBJ="$WORK/obj"
STAGE="$WORK/stage"
mkdir -p "$OBJ" "$STAGE"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

case "$BOOTSTRAP" in
    rootless) ARCHS="arm64 arm64e" ;;
    *)        ARCHS="arm64e" ;;
esac

CONTROL_SRC="$ROOT/layout/DEBIAN/control"
VERSION="$(sed -n 's/^Version:[[:space:]]*//p' "$CONTROL_SRC" | head -1)"
[ -n "$VERSION" ] || { echo "control 里没有 Version" >&2; exit 1; }

CFLAGS_COMMON="-fobjc-arc -O2 -Wno-deprecated-declarations -Wno-unused-function -Wno-nullability-completeness"

echo "== 构建 dylib（$ARCHS）"
DYLIB_SLICES=""
for arch in $ARCHS; do
    out="$OBJ/insulation.$arch.dylib"
    clang -arch "$arch" -dynamiclib $CFLAGS_COMMON \
        -DAPELIN_BUILD_ID="\"$BUILD_ID\"" \
        -framework Foundation -framework CoreFoundation \
        -framework SystemConfiguration -framework IOKit \
        -Wl,-undefined,dynamic_lookup \
        -install_name "$PREFIX/Library/MobileSubstrate/DynamicLibraries/insulation.dylib" \
        -o "$out" \
        "$ROOT/Sources/insulation_rebuilt.m" \
        "$ROOT/Sources/insulation_mitigation.m" \
        "$ROOT/Sources/insulation_cpu.m" \
        "$ROOT/Sources/insulation_state.m" \
        "$ROOT/Sources/insulation_plist.m" \
        "$ROOT/Sources/insulation_freq.m"
    DYLIB_SLICES="$DYLIB_SLICES $out"
done
# shellcheck disable=SC2086
lipo -create $DYLIB_SLICES -output "$OBJ/insulation.dylib"
ldid -S "$OBJ/insulation.dylib"
lipo -info "$OBJ/insulation.dylib"

echo "== 构建设置面板 bundle（$ARCHS）"
PREFS_SLICES=""
for arch in $ARCHS; do
    out="$OBJ/InsulationPrefs.$arch"
    clang -arch "$arch" -bundle $CFLAGS_COMMON \
        -I"$ROOT/apelin/include" \
        -framework UIKit -framework Foundation -framework CoreFoundation \
        -F"$SDKROOT/System/Library/PrivateFrameworks" -framework Preferences \
        -Wl,-undefined,dynamic_lookup \
        -o "$out" "$ROOT/prefs/INSRootListController.m"
    PREFS_SLICES="$PREFS_SLICES $out"
done
# shellcheck disable=SC2086
lipo -create $PREFS_SLICES -output "$OBJ/InsulationPrefs"
ldid -S "$OBJ/InsulationPrefs"
lipo -info "$OBJ/InsulationPrefs"

echo "== 摆放安装树（prefix='$PREFIX'）"
DL_DIR="$STAGE$PREFIX/Library/MobileSubstrate/DynamicLibraries"
PREFS_DIR="$STAGE$PREFIX/Library/PreferenceBundles/InsulationPrefs.bundle"
PL_DIR="$STAGE$PREFIX/Library/PreferenceLoader/Preferences"
CC_DIR="$STAGE$PREFIX/Library/ControlCenter/Bundles"
mkdir -p "$DL_DIR" "$PREFS_DIR" "$PL_DIR" "$CC_DIR"

install -m 0755 "$OBJ/insulation.dylib" "$DL_DIR/insulation.dylib"
install -m 0644 "$ROOT/layout/Library/MobileSubstrate/DynamicLibraries/insulation.plist" "$DL_DIR/insulation.plist"

install -m 0644 "$ROOT/prefs/Resources/Info.plist" "$PREFS_DIR/Info.plist"
install -m 0644 "$ROOT/prefs/Resources/Root.plist" "$PREFS_DIR/Root.plist"
install -m 0644 "$ROOT/prefs/Resources/icon.png" "$PREFS_DIR/icon.png"
install -m 0644 "$ROOT/prefs/Resources/icon@2x.png" "$PREFS_DIR/icon@2x.png"
install -m 0644 "$ROOT/prefs/Resources/icon@3x.png" "$PREFS_DIR/icon@3x.png"
install -m 0755 "$OBJ/InsulationPrefs" "$PREFS_DIR/InsulationPrefs"

install -m 0644 "$ROOT/layout/Library/PreferenceLoader/Preferences/InsulationPrefs.plist" \
    "$PL_DIR/InsulationPrefs.plist"

# 控制中心模块只有成品二进制，按仓库原样随包安装
cp -R "$ROOT/layout/Library/ControlCenter/Bundles/InsulationCC.bundle" "$CC_DIR/"
chmod 0755 "$CC_DIR/InsulationCC.bundle/InsulationCC"
chmod 0644 "$CC_DIR/InsulationCC.bundle/Info.plist" "$CC_DIR/InsulationCC.bundle/SettingsIcon.png"

echo "== 写 DEBIAN"
mkdir -p "$STAGE/DEBIAN"
sed "s/^Architecture:.*/Architecture: $ARCHITECTURE/" "$CONTROL_SRC" > "$STAGE/DEBIAN/control"
chmod 0644 "$STAGE/DEBIAN/control"

# 仓库的维护脚本是 rootful/rootless 混合写法；这里把 /var/jb 换成打包时确定的 prefix，
# 不把 /var/jb 硬编码进包里（roothide 上 prefix 为空）。
cat > "$STAGE/DEBIAN/preinst" <<EOF
#!/bin/sh
# 清掉旧 bundle / 入口，避免 dpkg 之外的残留或缓存导致 Settings 加载旧代码
PREFIX="$PREFIX"
for B in "\$PREFIX/Library/PreferenceBundles/InsulationPrefs.bundle" \\
         "\$PREFIX/Library/PreferenceBundles/InsulationFreqPrefs.bundle"; do
    [ -d "\$B" ] && rm -rf "\$B"
done
for P in "\$PREFIX/Library/PreferenceLoader/Preferences/InsulationPrefs.plist" \\
         "\$PREFIX/Library/PreferenceLoader/Preferences/InsulationFreq.plist"; do
    [ -f "\$P" ] && rm -f "\$P"
done
exit 0
EOF

cat > "$STAGE/DEBIAN/postinst" <<EOF
#!/bin/sh
# 重启 thermalmonitord，让 dylib 重新加载。
# 维护脚本在不同 bootstrap 下看到的根不一样：roothide 可能看到真实根
# （bootstrap 在 /var/containers/Bundle/Application/.jbroot-* 下）也可能看到
# bootstrap 根；这里两套路径都试，rootless 走 \$PREFIX。
PREFIX="$PREFIX"

# 诊断日志写在插件目录里，便于安装后确认维护脚本到底做了什么
LOG=""
for d in "\$PREFIX/usr/lib/TweakInject" \\
         /var/containers/Bundle/Application/.jbroot-*/usr/lib/TweakInject \\
         "\$PREFIX/Library/MobileSubstrate/DynamicLibraries" \\
         /var/jb/Library/MobileSubstrate/DynamicLibraries; do
    if [ -d "\$d" ]; then LOG="\$d/insulation-postinst.log"; break; fi
done
say() { [ -n "\$LOG" ] && echo "\$(date '+%F %T') \$*" >> "\$LOG"; }
say "postinst start"

LAUNCHCTL=""
for c in "\$PREFIX/bin/launchctl" /bin/launchctl "\$PREFIX/usr/bin/launchctl" /usr/bin/launchctl \\
         /var/jb/bin/launchctl /var/jb/usr/bin/launchctl \\
         /var/containers/Bundle/Application/.jbroot-*/bin/launchctl \\
         /var/containers/Bundle/Application/.jbroot-*/usr/bin/launchctl; do
    if [ -x "\$c" ]; then LAUNCHCTL="\$c"; break; fi
done

KILLALL=""
for c in "\$PREFIX/usr/bin/killall" /usr/bin/killall "\$PREFIX/bin/killall" /bin/killall \\
         /var/jb/usr/bin/killall \\
         /var/containers/Bundle/Application/.jbroot-*/usr/bin/killall; do
    if [ -x "\$c" ]; then KILLALL="\$c"; break; fi
done

PS=""
for c in /bin/ps /usr/bin/ps /var/containers/Bundle/Application/.jbroot-*/bin/ps; do
    if [ -x "\$c" ]; then PS="\$c"; break; fi
done

say "launchctl=\$LAUNCHCTL killall=\$KILLALL ps=\$PS"
for f in "\$PREFIX/usr/lib/TweakInject/insulation.dylib" \\
         /var/containers/Bundle/Application/.jbroot-*/usr/lib/TweakInject/insulation.dylib; do
    [ -f "\$f" ] && say "dylib: \$(ls -l "\$f" 2>/dev/null | awk '{print \$5, \$6, \$7, \$8}')"
done
[ -n "\$PS" ] && say "pid before: \$("\$PS" -A -o pid,comm 2>/dev/null | awk '/thermalmonitord/{print \$1}' | tr '\n' ' ')"

restarted=0
if [ -n "\$LAUNCHCTL" ]; then
    sleep 3
    if "\$LAUNCHCTL" kickstart -k system/com.apple.thermalmonitord >/dev/null 2>&1; then
        restarted=1
        say "kickstart ok"
    else
        say "kickstart failed (\$?)"
    fi
fi
# launchctl 不可用或重启失败时，用 killall 兜底（launchd 会重新拉起）
if [ "\$restarted" -eq 0 ] && [ -n "\$KILLALL" ]; then
    sleep 3
    "\$KILLALL" -9 thermalmonitord >/dev/null 2>&1 || true
    say "killall thermalmonitord"
    sleep 1
    "\$KILLALL" -9 Preferences >/dev/null 2>&1 || true
fi

sleep 2
[ -n "\$PS" ] && say "pid after: \$("\$PS" -A -o pid,comm 2>/dev/null | awk '/thermalmonitord/{print \$1}' | tr '\n' ' ')"
say "postinst end"

exit 0
EOF
chmod 0755 "$STAGE/DEBIAN/preinst" "$STAGE/DEBIAN/postinst"

DEB="$PACKAGE_DIR/insulation_${VERSION}_${ARCHITECTURE}.deb"
echo "== 打包 $DEB"
dpkg-deb -b --root-owner-group "$STAGE" "$DEB" >/dev/null
ls -l "$DEB"
