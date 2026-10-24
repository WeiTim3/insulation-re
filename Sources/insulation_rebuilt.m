//
//  insulation_rebuilt.m  —  主体：偏好、模式判定、hook 安装、constructor
//
//  构建：Theos，TARGET=iphone:clang:16.5:15.0，ARCHS=arm64 arm64e
//  依赖：Foundation / CoreFoundation / SystemConfiguration / IOKit
//
#import "insulation.h"
#include <string.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <signal.h>
#import <unistd.h>

// 全局强引用赋值：ARC 下等价于 objc_storeStrong
#import <notify.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <objc/runtime.h>

#pragma mark - 全局

NSDictionary *gPrefs;
int gCPURestoreActive;
int gFullCPUPower;
int gMaxComponentPower;
NSMutableDictionary *gPowerCache;
double gProcessStartTime;
dispatch_once_t gHooksOnce;
IMP gOrigDictionaryWithContentsOfFile;
id gCommonProductObject;
id gMitigationControllerObject;

// 原始 IMP 表（hook 时保存）
static IMP gOrigInitProduct;
static IMP gOrigTryTakeAction, gOrigHandleMCS, gOrigSimulateLight, gOrigUpdatePowerzone;
BOOL gInsulationHooksInstalled;  // bit3：hook 装上
BOOL gInsulationControllerSeen;  // bit4：抓到过 CPMS 对象

#pragma mark - 小工具

// libroothide 的 jbroot 是 C++ 修饰名 __Z6jbrootP8NSString，这里 dlsym 拿
// libroothide 导出的是 C 符号 jbroot(const char *)，不是 C++ 修饰名。
// 映射示例：/var/mobile/x -> /var/containers/Bundle/Application/.jbroot-XXXX/var/mobile/x
// ：直接链接 roothide 的 jbroot(NSString*)
extern NSString *jbroot(NSString *path) __asm("__Z6jbrootP8NSString");

static inline NSString *jb(NSString *path) { return jbroot(path); }

void insulationMarkProcessStart(void) {
    if (gProcessStartTime <= 0.0) gProcessStartTime = CFAbsoluteTimeGetCurrent();
}

double insulationFullPowerBootGuardDurationSeconds(void) { return 6.0; }

BOOL insulationFullPowerBootGuardActive(void) {
    insulationMarkProcessStart();
    return (CFAbsoluteTimeGetCurrent() - gProcessStartTime) < 6.0;
}

#pragma mark - 偏好

// 起：带 0.05s 新鲜度的缓存，用串行队列保护（ dispatch_queue_create/sync）
static dispatch_queue_t gPrefsQueue;
static NSTimeInterval gPrefsStamp = -1;

NSDictionary *InsulationReloadPreferences(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gPrefsQueue = dispatch_queue_create("com.be-huge.insulation.prefs-cache", NULL);
    });

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (gPrefs && gPrefsStamp >= 0 && (now - gPrefsStamp) < 0.05) return gPrefs;

    dispatch_sync(gPrefsQueue, ^{
        NSString *path = jb(@"/var/mobile/Library/Preferences/com.be-huge.insulation-prefs.plist");
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        gPrefs = d ?: [NSDictionary dictionary];
        gPrefsStamp = [NSDate timeIntervalSinceReferenceDate];
    });
    return gPrefs;
}

// BOOL 取键，兼容 NSNumber 与 "1/true/yes/on"
BOOL InsulationBoolPref(NSString *key) {
    static NSArray *truthy;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ truthy = @[@"1", @"true", @"yes", @"on"]; });

    if (!gPrefs) InsulationReloadPreferences();
    id v = [gPrefs objectForKey:key];
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]])
        return [truthy containsObject:[v lowercaseString]];
    return NO;
}

BOOL InsulationPreventDimmingEnabled(void) {
    return InsulationBoolPref(@"thermalPreventDimmingEnabled");
}

BOOL InsulationDisplayDimmingBypassEnabled(void) {
    return InsulationBoolPref(@"displayDimmingBypassEnabled");  // [推断] 键名
}

NSString *InsulationPowerMode(void) {
    if (!gPrefs) InsulationReloadPreferences();
    NSString *m = [gPrefs objectForKey:@"thermalPowerMode"];
    if ([m isEqualToString:@"fullPower"] ||
        [m isEqualToString:@"lowPower"] ||
        [m isEqualToString:@"off"]) return m;
    return @"off";
}

BOOL InsulationLowPowerModeEnabled(void) {
    return [InsulationPowerMode() isEqualToString:@"lowPower"];
}

BOOL InsulationFullPowerModeEnabled(void) {
    return [InsulationPowerMode() isEqualToString:@"fullPower"];
}

BOOL InsulationAggressiveFullPowerEnabled(void) {
    return InsulationFullPowerModeEnabled() && !insulationFullPowerBootGuardActive();
}

BOOL InsulationThermalDimmingBypassActive(void) {
    if (InsulationPreventDimmingEnabled()) return YES;
    return InsulationFullPowerModeEnabled();
}

// 与 AggressiveFullPowerEnabled 完全同体（fullPower && !BootGuard）
// preventDimming || fullPower
BOOL InsulationPowerMitigationsDisabled(void) {
    return InsulationPreventDimmingEnabled() || InsulationFullPowerModeEnabled();
}

#pragma mark - CPU 限制

BOOL InsulationCPURestoreActive(void) {
    return gCPURestoreActive > 0;
}

BOOL InsulationCPULimitEnabled(void) {
    return InsulationLowPowerModeEnabled();
}

int InsulationForcedCPULevel(void) {
    return InsulationLowPowerModeEnabled() ? 2 : 0;
}

unsigned InsulationUnrestrictedPowerLimit(void) {
    return 50000;
}

unsigned InsulationUnrestrictedPowerLimitUInt32(void) { return 50000; }

int InsulationBacklightThermalPowerFloor(void) {
    return 0x0F4240;  // 1000000
}

void InsulationSetCommonProductObject(id obj) {
    gCommonProductObject = obj;
}

void InsulationSetMitigationControllerObject(id obj) {
    gMitigationControllerObject = obj;
}

#pragma mark - hook 安装

static void hookMethod(Class cls, SEL sel, IMP newIMP, IMP *origOut) {
    if (!cls || !sel || !newIMP) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    if (origOut) *origOut = method_getImplementation(m);
    method_setImplementation(m, newIMP);
}

static void hookClassMethod(Class cls, SEL sel, IMP newIMP, IMP *origOut) {  // 的类方法变体
    if (!cls || !sel || !newIMP) return;
    Method m = class_getClassMethod(cls, sel);
    if (!m) return;
    if (origOut) *origOut = method_getImplementation(m);
    method_setImplementation(m, newIMP);
}

#pragma mark NSDictionary

static id repl_dictionaryWithContentsOfFile(Class self, SEL _cmd, NSString *path) {
    id result = ((id (*)(id, SEL, id))gOrigDictionaryWithContentsOfFile)(self, _cmd, path);
    if ([result isKindOfClass:[NSDictionary class]] &&
        [path containsString:@"/System/Library/ThermalMonitor/"]) {
        return InsulationPatchThermalPlist(result);
    }
    return result;
}

#pragma mark CommonProduct

static id repl_initProduct(id self, SEL _cmd, id arg) {
    id r = ((id (*)(id, SEL, id))gOrigInitProduct)(self, _cmd, arg);
    InsulationSetCommonProductObject(self);
    InsulationExecutePuppetEvent();
    InsulationExecutePuppetEventSoon();
    return r;
}

// 三个无参 hook 共用的替换体
static void repl_noArg(id self, SEL _cmd, IMP orig) {
    if (InsulationThermalDimmingBypassActive()) InsulationExecutePuppetEvent();
    else ((void (*)(id, SEL))orig)(self, _cmd);
}

static void repl_tryTakeAction(id self, SEL _cmd)       { repl_noArg(self, _cmd, gOrigTryTakeAction); }
static void repl_handleMCSThermalPressure(id self, SEL _cmd) { repl_noArg(self, _cmd, gOrigHandleMCS); }
static void repl_simulateLight(id self, SEL _cmd)       { repl_noArg(self, _cmd, gOrigSimulateLight); }
static void repl_updatePowerzone(id self, SEL _cmd)     { repl_noArg(self, _cmd, gOrigUpdatePowerzone); }

#pragma mark MitigationController


// setCPULevel:


static void INSDoInstallHooks(void);

// 类可能比 dylib 构造函数更晚注册，失败就 0.5s 后重试，最多 60 次
static void INSScheduleHookRetry(int attempt) {
    if (attempt > 60) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                   dispatch_get_global_queue(0, 0), ^{
        if (gInsulationHooksInstalled) return;
        INSDoInstallHooks();
        if (!gInsulationHooksInstalled) INSScheduleHookRetry(attempt + 1);
    });
}

void InsulationRuntimeHooksInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        INSDoInstallHooks();
        if (!gInsulationHooksInstalled) INSScheduleHookRetry(1);
    });
}

static void INSDoInstallHooks(void) {
    static BOOL didDict, didCP, didMC, didTM, didCC;

    if (!didDict) {
        hookClassMethod(objc_getClass("NSDictionary"),
                        @selector(dictionaryWithContentsOfFile:),
                        (IMP)repl_dictionaryWithContentsOfFile,
                        &gOrigDictionaryWithContentsOfFile);
        didDict = YES;
    }

    Class cp = objc_getClass("CommonProduct");
    if (cp && !didCP) {
        hookMethod(cp, @selector(initProduct:), (IMP)repl_initProduct, &gOrigInitProduct);
        hookMethod(cp, @selector(tryTakeAction), (IMP)repl_tryTakeAction, &gOrigTryTakeAction);
        hookMethod(cp, @selector(handleMCSThermalPressure), (IMP)repl_handleMCSThermalPressure, &gOrigHandleMCS);
        hookMethod(cp, @selector(simulateLightThermalPressure), (IMP)repl_simulateLight, &gOrigSimulateLight);
        hookMethod(cp, @selector(updatePowerzoneTelemetry), (IMP)repl_updatePowerzone, &gOrigUpdatePowerzone);
        InsulationInstallCommonProductHooks(cp);
        didCP = YES;
    }

    Class tm = objc_getClass("ThermalManager");
    if (tm && !didTM) {
        InsulationInstallThermalManagerHooks(tm);
        didTM = YES;
    }

    Class cc = objc_getClass("PackagePowerCC");
    if (cc && !didCC) {
        InsulationInstallPackagePowerCCHooks(cc);
        didCC = YES;
    }

    Class mc = objc_getClass("MitigationController");
    if (mc && !didMC) {
        InsulationInstallMitigationHooks(mc);  // 其余 17 个 setter
        didMC = YES;
    }

    gInsulationHooksInstalled = (cp != nil && mc != nil);
}

#pragma mark - constructor

static void onPuppetEvent(CFNotificationCenterRef, void *, CFStringRef, const void *, CFDictionaryRef);
static void onRuntimeState(CFNotificationCenterRef, void *, CFStringRef, const void *, CFDictionaryRef);
static void onRestartThermal(CFNotificationCenterRef, void *, CFStringRef, const void *, CFDictionaryRef);
void insulationKillSelf(void);

extern char ***_NSGetArgv(void);  // libSystem

// 只有 argv[0] 的 basename 是 thermalmonitord 才继续（硬判断）
static BOOL INSProcessIsThermalMonitord(void) {
    const char *name = (*_NSGetArgv())[0];
    if (!name) return NO;
    const char *slash = strrchr(name, '/');
    if (slash) name = slash + 1;
    return strcmp(name, "thermalmonitord") == 0;
}

__attribute__((constructor)) static void insulation_init(void) {
    if (!INSProcessIsThermalMonitord()) return;
    insulationMarkProcessStart();
    InsulationRuntimeHooksInstall();

    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(center, NULL, onPuppetEvent,
                                    CFSTR(kNotifyExecutePuppet), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, NULL, onRuntimeState,
                                    CFSTR(kNotifyRuntimeState), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, NULL, onRestartThermal,
                                    CFSTR(kNotifyRestartThermal), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

static void onPuppetEvent(CFNotificationCenterRef c, void *o, CFStringRef n,
                          const void *obj, CFDictionaryRef info) {
    InsulationExecutePuppetEvent();
    InsulationExecutePuppetEventSoon();
}

static void onRuntimeState(CFNotificationCenterRef c, void *o, CFStringRef n,
                           const void *obj, CFDictionaryRef info) {
    // 【实测依据】 0.1.35：把 prefs 从 off 改成 fullPower 后 post 该通知，
    // thermalmonitord 的 PID 完全不变（只有 -restartThermalMonitor 才会重启）。
    // 所以这里不自杀，只重新应用一次偏好。
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        InsulationExecutePuppetEvent();
        InsulationExecutePuppetEventSoon();
    });
}

static void onRestartThermal(CFNotificationCenterRef c, void *o, CFStringRef n,
                             const void *obj, CFDictionaryRef info) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                   dispatch_get_global_queue(0, 0), ^{
        insulationKillSelf();
    });
}

void insulationKillSelf(void) {
    kill(getpid(), SIGTERM);  // 15
}
