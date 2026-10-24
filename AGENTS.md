# insulation-re — 工作区构建说明

越狱插件（roothide）：dylib `insulation`（Filter: `thermalmonitord`）＋ 设置面板
`InsulationPrefs.bundle` ＋ 控制中心模块 `InsulationCC.bundle`（只有成品二进制）。

## 构建

Theos / make 在这台设备上不可用，`Makefile` 只作为原始描述保留。构建由
`apelin-project.json` 的 `external` 成员声明，Apelin 的 build 工具执行：

```sh
apelin/build.sh   # sh；环境由 Apelin 提供
```

脚本完全自包含：本机 clang（PATH 上已有）＋ `$SDKROOT`，产物只有一个 .deb。
关键环境变量（Apelin 注入）：`APELIN_PREFIX`（roothide 为空，rootless 为 `/var/jb`）、
`APELIN_ARCHITECTURE`、`APELIN_BOOTSTRAP`、`APELIN_BUILD_ID`、`APELIN_PACKAGE_DIR`、
`APELIN_PROJECT_ROOT`。

- 架构：roothide → arm64e；rootless → arm64 + arm64e（lipo 合并）。
- dylib：`Sources/insulation_{rebuilt,mitigation,cpu,state,plist,freq}.m`，
  `-dynamiclib -fobjc-arc`，链接 Foundation/CoreFoundation/SystemConfiguration/IOKit，
  `-Wl,-undefined,dynamic_lookup`（私有 API 全部运行时解析），install_name 带 prefix。
- 设置面板：`prefs/INSRootListController.m`，`-bundle -fobjc-arc`，链接 UIKit/Foundation/
  CoreFoundation，`-F$SDKROOT/System/Library/PrivateFrameworks -framework Preferences`。
- 两个二进制都 `ldid -S` 签名（与设备上其它插件一致，无 entitlements）。
- 打包：`dpkg-deb -b --root-owner-group`，`Architecture: $APELIN_ARCHITECTURE`。

### 私有 Preferences 头的存根

SDK 只有 `Preferences.tbd`，没有头文件，所以 `prefs/INSRootListController.m` 用的
`<Preferences/Preferences.h>` 由 `apelin/include/Preferences/Preferences.h` 提供。
里面按 Theos `theos/headers` 的写法声明 `@public SEL action;`。ivar 偏移不靠头文件猜：
非脆弱 ABI 下 `refresh->action` 生成的是 `_OBJC_IVAR_$_PSSpecifier.action` 未定义符号，
运行期由 Preferences.framework 里真实的 ivar 决定；作者发布的旧二进制里同样是这个符号。

### 加载标记

`Sources/insulation_rebuilt.m` 的 constructor 第一件事（`APELIN_BUILD_ID` 存在时）：
`os_log` 子系统 `com.be-huge.insulation.rebuilt`，category `insulation`，
内容 `ApelinLoaded <build id>`，`confirm_loaded` 用它判断是否进了 thermalmonitord。
这是本仓库唯一新增的代码。

## 包内容（prefix = `$APELIN_PREFIX`）

```
$PREFIX/Library/MobileSubstrate/DynamicLibraries/insulation.dylib
$PREFIX/Library/MobileSubstrate/DynamicLibraries/insulation.plist
$PREFIX/Library/PreferenceBundles/InsulationPrefs.bundle/{Info.plist,Root.plist,InsulationPrefs,icon*.png}
$PREFIX/Library/PreferenceLoader/Preferences/InsulationPrefs.plist
$PREFIX/Library/ControlCenter/Bundles/InsulationCC.bundle/{Info.plist,InsulationCC,SettingsIcon.png}
```

DEBIAN 里的 control 取自 `layout/DEBIAN/control`（只改 Architecture）。preinst/postinst 由
`apelin/build.sh` 生成：仓库原脚本里的 `/var/jb` 换成打包时的 prefix，不硬编码；
postinst 依次尝试 `$PREFIX/bin/launchctl`、`/bin/launchctl`、`$PREFIX/usr/bin/launchctl`、
`/usr/bin/launchctl` 重启 thermalmonitord，再 `killall thermalmonitord` / `Preferences` 兜底。

`layout/Library/ControlCenter/Bundles/InsulationCC.bundle` 的二进制是成品（fat arm64/arm64e，
已签名），按原样进包，不要反编译。

## 检查与安装

```sh
dpkg-deb -I <deb>      # control / 维护脚本
dpkg-deb -c <deb>      # 文件树
```

安装注意：设备上已有一个**不是本工作区装的** `com.be-huge.insulation.rebuilt 0.1.36-132`
（同为 iphoneos-arm64e），Apelin 不会覆盖别人的包，也不要为此改包名。要装本构建的包，
先用设备上的包管理器（Sileo/Zebra/Irisin 等）卸载旧包，再让 Apelin install。
卸载后重启 thermalmonitord 才会重新加载 dylib；`confirm_loaded` 传 target `thermalmonitord`。

## 设备环境备忘

- 自定义 CLI 在本机一律 `Killed: 9`（AMFI 拒绝 ad-hoc 执行），不要指望在构建流程里跑
  自己编的小程序做运行期探测；静态检查用 `nm -u`、`lipo -info`，不要用 `llvm-otool`
  （缺 `otool-classic`）。
- 仓库根目录的 `insulation-rebuilt-0.1.36-132-arm64e.deb` 是作者预编译的包，不参与构建、
  不发布。
