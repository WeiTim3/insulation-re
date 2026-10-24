//
//  insulation_mitigation.m  —  MitigationController 与 CommonProduct 的 hook
//
//  模式只有三种：
//    A. disabled ? UnrestrictedPowerLimit : <夹紧函数>(原值)
//    B. disabled ? 0 : 原值
//    C. disabled ? UnrestrictedPowerLimit : 原值
//
#import "insulation.h"
#import <objc/runtime.h>

void InsulationInstallMitigationHooks(Class mc);

static IMP o_setCPULowPowerTarget;
static IMP o_setCPUPowerCeilingD;
static IMP o_setCPUPowerCeilingDVD1;
static IMP o_setCPUPowerFloorD;
static IMP o_setCPUPowerZoneTarget;
static IMP o_setDVD1Level;
static IMP o_setGPUPowerCeilingD;
static IMP o_setGPUPowerFloorD;
static IMP o_setGPUPowerZoneTarget;
static IMP o_setSGXLevel;
static IMP o_setMaxGraphicsDrivePowerTarget;
static IMP o_setPackagePowerCeilingD;
static IMP o_setPackagePowerFloorD;
static IMP o_setMaxPackagePower;
static IMP o_setPackageLowPowerTarget;
static IMP o_setPackagePowerZoneTarget;
static IMP o_updateCPU, o_updateGPU, o_updatePackage;

static inline void hookOne(Class c, SEL s, IMP n, IMP *o) {
    Method m = class_getInstanceMethod(c, s);
    if (!m) return;
    if (o) *o = method_getImplementation(m);
    method_setImplementation(m, n);
}

#pragma mark - A 组：CPU 功率夹紧

// setCPULowPowerTarget:
static void r_setCPULowPowerTarget(id self, SEL _cmd, int target) {
    int v = InsulationPowerMitigationsDisabled() ? (int)InsulationUnrestrictedPowerLimit()
                                                : InsulationLimitedCPUPower(target);
    ((void (*)(id, SEL, int))o_setCPULowPowerTarget)(self, _cmd, v);
}

// setCPUPowerCeiling:fromDecisionSource:
static void r_setCPUPowerCeilingD(id self, SEL _cmd, int v, int src) {
    int nv = InsulationPowerMitigationsDisabled() ? (int)InsulationUnrestrictedPowerLimit()
                                                 : InsulationLimitedCPUPower(v);
    ((void (*)(id, SEL, int, int))o_setCPUPowerCeilingD)(self, _cmd, nv, src);
}

// setCPUPowerCeiling:forDVD1Contributor:
static void r_setCPUPowerCeilingDVD1(id self, SEL _cmd, int v, int c) {
    int nv = InsulationPowerMitigationsDisabled() ? (int)InsulationUnrestrictedPowerLimit()
                                                 : InsulationLimitedCPUPower(v);
    ((void (*)(id, SEL, int, int))o_setCPUPowerCeilingDVD1)(self, _cmd, nv, c);
}

// setCPUPowerZoneTarget:
static void r_setCPUPowerZoneTarget(id self, SEL _cmd, int v) {
    int nv = InsulationPowerMitigationsDisabled() ? (int)InsulationUnrestrictedPowerLimit()
                                                 : InsulationLimitedCPUPower(v);
    ((void (*)(id, SEL, int))o_setCPUPowerZoneTarget)(self, _cmd, nv);
}

// setCPUPowerFloor:fromDecisionSource:（注意用的是 Floor 专用函数）
static void r_setCPUPowerFloorD(id self, SEL _cmd, int v, int src) {
    int nv = InsulationPowerMitigationsDisabled() ? (int)InsulationUnrestrictedPowerLimit()
                                                 : InsulationMitigationPowerFloor(v);
    ((void (*)(id, SEL, int, int))o_setCPUPowerFloorD)(self, _cmd, nv, src);
}

#pragma mark - B 组：disabled 时归零

// setDVD1Level:  → disabled ? 0 : 原值
static void r_setDVD1Level(id self, SEL _cmd, int v) {
    int nv = InsulationPowerMitigationsDisabled() ? 0 : v;
    ((void (*)(id, SEL, int))o_setDVD1Level)(self, _cmd, nv);
}

// setGPUPowerFloor:fromDecisionSource:
static void r_setGPUPowerFloorD(id self, SEL _cmd, int v, int src) {
    int nv = InsulationPowerMitigationsDisabled() ? 0 : v;
    ((void (*)(id, SEL, int, int))o_setGPUPowerFloorD)(self, _cmd, nv, src);
}

// setGPUPowerZoneTarget:
static void r_setGPUPowerZoneTarget(id self, SEL _cmd, int v) {
    int nv = InsulationPowerMitigationsDisabled() ? 0 : v;
    ((void (*)(id, SEL, int))o_setGPUPowerZoneTarget)(self, _cmd, nv);
}

// setSGXLevel:
static void r_setSGXLevel(id self, SEL _cmd, int v) {
    int nv = InsulationPowerMitigationsDisabled() ? 0 : v;
    ((void (*)(id, SEL, int))o_setSGXLevel)(self, _cmd, nv);
}

// setPackageLowPowerTarget（无参）
static void r_setPackageLowPowerTarget(id self, SEL _cmd) {
    if (InsulationPowerMitigationsDisabled()) return;  // 直接吞掉
    ((void (*)(id, SEL))o_setPackageLowPowerTarget)(self, _cmd);
}

#pragma mark - C 组：disabled 时抬到"不限"

// setGPUPowerCeiling:fromDecisionSource:
static void r_setGPUPowerCeilingD(id self, SEL _cmd, int v, int src) {
    int nv = InsulationPowerMitigationsDisabled() ? (int)InsulationUnrestrictedPowerLimit() : v;
    ((void (*)(id, SEL, int, int))o_setGPUPowerCeilingD)(self, _cmd, nv, src);
}

// setMaxGraphicsDrivePowerTarget:
static void r_setMaxGraphicsDrivePowerTarget(id self, SEL _cmd, int v) {
    int nv = InsulationPowerMitigationsDisabled() ? (int)InsulationUnrestrictedPowerLimit() : v;
    ((void (*)(id, SEL, int))o_setMaxGraphicsDrivePowerTarget)(self, _cmd, nv);
}

// setPackagePowerCeiling:fromDecisionSource:
static void r_setPackagePowerCeilingD(id self, SEL _cmd, int v, int src) {
    int nv = InsulationPowerMitigationsDisabled() ? (int)InsulationUnrestrictedPowerLimit() : v;
    ((void (*)(id, SEL, int, int))o_setPackagePowerCeilingD)(self, _cmd, nv, src);
}

// setPackagePowerFloor:fromDecisionSource:
static void r_setPackagePowerFloorD(id self, SEL _cmd, int v, int src) {
    int nv = InsulationPowerMitigationsDisabled() ? (int)InsulationUnrestrictedPowerLimit() : v;
    ((void (*)(id, SEL, int, int))o_setPackagePowerFloorD)(self, _cmd, nv, src);
}

// setMaxPackagePower:
static void r_setMaxPackagePower(id self, SEL _cmd, int v) {
    int nv = InsulationPowerMitigationsDisabled() ? (int)InsulationUnrestrictedPowerLimit() : v;
    ((void (*)(id, SEL, int))o_setMaxPackagePower)(self, _cmd, nv);
}

// setPackagePowerZoneTarget（无参）
static void r_setPackagePowerZoneTarget(id self, SEL _cmd) {
    if (InsulationPowerMitigationsDisabled()) return;
    ((void (*)(id, SEL))o_setPackagePowerZoneTarget)(self, _cmd);
}

#pragma mark - 周期性 update

// 先记下 MitigationController 实例，再放行
static void r_updateCPU(id self, SEL _cmd) {
    InsulationSetMitigationControllerObject(self);
    if (o_updateCPU) ((void (*)(id, SEL))o_updateCPU)(self, _cmd);
}

static void r_updateGPU(id self, SEL _cmd) {
    if (o_updateGPU) ((void (*)(id, SEL))o_updateGPU)(self, _cmd);
}

static void r_updatePackage(id self, SEL _cmd) {
    if (o_updatePackage) ((void (*)(id, SEL))o_updatePackage)(self, _cmd);
}

#pragma mark - 安装


// ── 其余 hook（地址取自 arm64e 切片的 method_setImplementation 调用点）
static IMP o_thermalPressureLevel;
static IMP o_setThermalState;
static IMP o_getPotentialForcedThermalPressureLevel;
static IMP o_getPotentialForcedThermalLevel;
static IMP o_thermalUpdatesToWatchdogEnabled;
static IMP o_getThermalSuggestion;
static IMP o_thermalSuggestion;
static IMP o_thermalMitigation;
static IMP o_thermalPressure;
static IMP o_DVD1Level;
static IMP o_SGXLevel;
static IMP o_getPackagePowerZoneMetric;
static IMP o_getGPUTargetPower;
static IMP o_getPackageGPUPowerTarget;
static IMP o_setPowerSaveActive;
static IMP o_setCPULevel;
static IMP o_setCPMSMitigationsEnabled;

#define ORIG0(imp, ret) ((ret (*)(id, SEL))imp)
#define ORIG1(imp, ret, t1) ((ret (*)(id, SEL, t1))imp)
#define ORIG2(imp, ret, t1, t2) ((ret (*)(id, SEL, t1, t2))imp)

// thermalPressureLevel
static long long r_thermalPressureLevel(id self, SEL _cmd) {
    if (InsulationAggressiveFullPowerEnabled()) return 0;
    long long v = o_thermalPressureLevel ? ORIG0(o_thermalPressureLevel, long long)(self, _cmd) : 0;
    if (InsulationAggressiveFullPowerEnabled()) return 0;
    if (InsulationPowerMitigationsDisabled() && v > 1) v = 1;
    return v;
}

// getPotentialForcedThermalPressureLevel
static BOOL r_getPotentialForcedThermalPressureLevel(id self, SEL _cmd) {
    if (InsulationPowerMitigationsDisabled()) return NO;
    return o_getPotentialForcedThermalPressureLevel
        ? ORIG0(o_getPotentialForcedThermalPressureLevel, BOOL)(self, _cmd) : NO;
}

// getPotentialForcedThermalLevel:
static unsigned long long r_getPotentialForcedThermalLevel(id self, SEL _cmd, unsigned long long a) {
    if (InsulationPowerMitigationsDisabled()) return 0;
    return o_getPotentialForcedThermalLevel
        ? ((unsigned long long (*)(id, SEL, unsigned long long))o_getPotentialForcedThermalLevel)(self, _cmd, a)
        : 0;
}

// getThermalSuggestion:
static id r_getThermalSuggestion(id self, SEL _cmd, id a) {
    if (InsulationPowerMitigationsDisabled()) return nil;
    return o_getThermalSuggestion
        ? ORIG1(o_getThermalSuggestion, id, id)(self, _cmd, a) : nil;
}

// thermalSuggestion:
static id r_thermalSuggestion(id self, SEL _cmd, id a) {
    if (InsulationPowerMitigationsDisabled()) return nil;
    return o_thermalSuggestion ? ORIG1(o_thermalSuggestion, id, id)(self, _cmd, a) : nil;
}

// thermalMitigation:
static id r_thermalMitigation(id self, SEL _cmd, id a) {
    if (InsulationPowerMitigationsDisabled()) return nil;
    return o_thermalMitigation ? ORIG1(o_thermalMitigation, id, id)(self, _cmd, a) : nil;
}

// thermalPressure:
static id r_thermalPressure(id self, SEL _cmd, id a) {
    if (InsulationAggressiveFullPowerEnabled()) return @0;
    id r = o_thermalPressure ? ORIG1(o_thermalPressure, id, id)(self, _cmd, a) : nil;
    if (!InsulationPowerMitigationsDisabled()) return r;
    if (![r isKindOfClass:[NSNumber class]]) return r;
    double v = [r doubleValue];
    if (InsulationAggressiveFullPowerEnabled()) return @0;
    if (v > 1) v = 1;
    return [NSNumber numberWithDouble:v];
}

// DVD1Level / SGXLevel / getPackagePowerZoneMetric
static long r_DVD1Level(id self, SEL _cmd) {
    if (InsulationAggressiveFullPowerEnabled()) return 0;
    return o_DVD1Level ? ORIG0(o_DVD1Level, long)(self, _cmd) : 0;
}
static long r_SGXLevel(id self, SEL _cmd) {
    if (InsulationAggressiveFullPowerEnabled()) return 0;
    return o_SGXLevel ? ORIG0(o_SGXLevel, long)(self, _cmd) : 0;
}
static long r_getPackagePowerZoneMetric(id self, SEL _cmd) {
    if (InsulationAggressiveFullPowerEnabled()) return 0;
    return o_getPackagePowerZoneMetric
        ? ORIG0(o_getPackagePowerZoneMetric, long)(self, _cmd) : 0;
}

// getGPUTargetPower / getPackageGPUPowerTarget（fullPower 下固定 50000）
static long r_getGPUTargetPower(id self, SEL _cmd) {
    if (InsulationAggressiveFullPowerEnabled()) return 50000;
    return o_getGPUTargetPower ? ORIG0(o_getGPUTargetPower, long)(self, _cmd) : 0;
}
static long r_getPackageGPUPowerTarget(id self, SEL _cmd) {
    if (InsulationAggressiveFullPowerEnabled()) return 50000;
    return o_getPackageGPUPowerTarget
        ? ORIG0(o_getPackageGPUPowerTarget, long)(self, _cmd) : 0;
}

// setPowerSaveActive:
static void r_setPowerSaveActive(id self, SEL _cmd, BOOL active) {
    if (!o_setPowerSaveActive) return;
    if (InsulationAggressiveFullPowerEnabled()) active = NO;
    else active = active || InsulationLowPowerModeEnabled();  // = lowPower
    ORIG1(o_setPowerSaveActive, void, BOOL)(self, _cmd, active);
}

// setCPULevel:
static void r_setCPULevel(id self, SEL _cmd, int level) {
    if (!o_setCPULevel) return;
    if (InsulationAggressiveFullPowerEnabled()) level = 0;
    else if (InsulationLowPowerModeEnabled()) level = 2;
    ORIG1(o_setCPULevel, void, int)(self, _cmd, level);
}

// setCPMSMitigationsEnabled:
static void r_setCPMSMitigationsEnabled(id self, SEL _cmd, BOOL enabled) {
    if (!o_setCPMSMitigationsEnabled) return;
    BOOL v = enabled && !InsulationAggressiveFullPowerEnabled();
    ORIG1(o_setCPMSMitigationsEnabled, void, BOOL)(self, _cmd, v);
}

// setThermalState:
static void r_setThermalState(id self, SEL _cmd, int state) {
    if (!o_setThermalState) return;
    int s = state;
    if (InsulationAggressiveFullPowerEnabled()) {
        if (s != 0) return;  // fullPower：只允许 0
    } else if (InsulationPowerMitigationsDisabled()) {
        if (s > 1) s = 1;  // lowPower：压到 ≤1
    }
    ORIG1(o_setThermalState, void, int)(self, _cmd, s);
}

// thermalUpdatesToWatchdogEnabled:
// 真实签名是 v24@0:8@16 —— 参数是对象（BOOL 包成 NSNumber 或 nil），不是 C BOOL
static void r_thermalUpdatesToWatchdogEnabled(id self, SEL _cmd, id enabled) {
    if (!o_thermalUpdatesToWatchdogEnabled) return;
    id v = InsulationAggressiveFullPowerEnabled() ? nil : enabled;
    ORIG1(o_thermalUpdatesToWatchdogEnabled, void, id)(self, _cmd, v);
}


// ── 全功率参数改写
static IMP o_getConfigurationFor;
static IMP o_initWithParams;

static BOOL INSContainsAny(NSString *lower, NSArray<NSString *> *arr) {
    for (NSString *s in arr) if ([lower containsString:s]) return YES;
    return NO;
}

static NSArray *INSZeroKeys(void) {
    static NSArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[@"mitigation", @"contextualclamp", @"clamp", @"thermalpressure",
              @"forcedthermal", @"powersave", @"lowpower", @"throttle", @"cpms"];
    });
    return a;
}

static NSArray *INSPowerKeys(void) {
    static NSArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[@"target", @"ceiling", @"floor", @"budget", @"limit", @"max",
              @"thermalpower", @"powerzone"];
    });
    return a;
}

// 命中「限流类」键 → 值清零
static id INSZeroValue(id v) {
    if ([v isKindOfClass:[NSNumber class]]) return @0;
    if ([v isKindOfClass:[NSString class]]) return @"0";
    if ([v isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray arrayWithCapacity:[v count]];
        for (id e in v) [a addObject:INSZeroValue(e)];
        return a;
    }
    if ([v isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithCapacity:[v count]];
        for (id k in v) d[k] = INSZeroValue(v[k]);
        return d;
    }
    return @0;
}

// power 类键的值夹到 50000
static id INSClampPower(id v) {
    long long n = 0;
    if ([v isKindOfClass:[NSNumber class]]) {
        n = [v longLongValue];
        if (n > 50000) n = 50000;
        return @(n);
    }
    if ([v isKindOfClass:[NSString class]]) {
        n = [v longLongValue];
        if (n > 50000) n = 50000;
        return [NSString stringWithFormat:@"%lld", n];
    }
    return v;
}

// 逐键值改写：
static id INSCoerceValue(NSString *key, id value) {
    if (![key isKindOfClass:[NSString class]]) return value;
    NSString *lower = [key lowercaseString];
    if (INSContainsAny(lower, INSZeroKeys())) return INSZeroValue(value);
    if (([key containsString:@"power"] || [key containsString:@"dvd1"]) &&
        INSContainsAny(lower, INSPowerKeys()) &&
        ![lower containsString:@"powersave"] && ![lower containsString:@"lowpower"]) {
        return INSClampPower(value);
    }
    return value;
}

// 递归改写整个字典/数组：
static id INSTransformValue(id obj) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:[obj count]];
        for (id k in (NSDictionary *)obj) {
            id v = INSTransformValue(((NSDictionary *)obj)[k]);
            id c = INSCoerceValue(k, v);
            out[k] = c ?: [NSNull null];
        }
        return out;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray arrayWithCapacity:[(NSArray *)obj count]];
        for (id e in (NSArray *)obj) [a addObject:INSTransformValue(e) ?: [NSNull null]];
        return a;
    }
    return obj;
}

// ThermalManager getConfigurationFor: —— 真实签名 ^v24@0:8^{__CFString=}16
// 返回的是 CFDictionaryRef 的 +1 引用（替换体在返回前 CFRelease 了中间对象）
static void *r_getConfigurationFor(id self, SEL _cmd, CFStringRef key) {
    void *cf = o_getConfigurationFor
        ? ((void *(*)(id, SEL, CFStringRef))o_getConfigurationFor)(self, _cmd, key)
        : NULL;
    if (!cf) return NULL;
    id cfg = (__bridge id)cf;

    BOOL disabled = InsulationPowerMitigationsDisabled();
    BOOL full = InsulationAggressiveFullPowerEnabled();
    if (!disabled && !full) return cf;
    // 用 CF 类型检查（CFGetTypeID / CFDictionaryGetTypeID / CFDictionaryGetCount）
    if (CFGetTypeID(cf) != CFDictionaryGetTypeID()) return cf;
    if (CFDictionaryGetCount((CFDictionaryRef)cf) == 0) return cf;

    NSMutableDictionary *m = [(NSDictionary *)cfg mutableCopy];
    if (full) {
        id t = INSTransformValue(m);
        if ([t isKindOfClass:[NSMutableDictionary class]]) m = t;
    }
    if (disabled) {
        m[@"needsPushingTSFDtoDisplayDriver"] = @NO;
        m[@"displayBrightnessMitigation"] = @NO;
        m[@"displayMitigation"] = @NO;
    }
    if (full) {
        m[@"needsContextualClamp"] = @NO;
        m[@"shouldEnforceLightThermalPressure"] = @NO;
        m[@"shouldEnforceThermalPressure"] = @NO;
        m[@"thermalPressureMitigation"] = @NO;
        m[@"forcedThermalLevel"] = @0;
        m[@"performanceMitigation"] = @NO;
        m[@"CPMSMitigationState"] = @NO;
        m[@"CPMSMitigationLevel"] = @0;
        m[@"maxPower"] = @50000;
        m[@"packagePowerTarget"] = @50000;
    }
    return (void *)CFBridgingRetain([NSDictionary dictionaryWithDictionary:m]);
}

// PackagePowerCC initWithParams: —— 真实签名 @24@0:8^{__CFDictionary=}16
static id r_initWithParams(id self, SEL _cmd, CFDictionaryRef params) {
    id p = (__bridge id)params;
    if (InsulationAggressiveFullPowerEnabled() && [p isKindOfClass:[NSDictionary class]]) {
        id t = INSTransformValue(p);
        if ([t isKindOfClass:[NSDictionary class]]) p = t;
    }
    if (o_initWithParams) return ORIG1(o_initWithParams, id, CFDictionaryRef)(self, _cmd, (__bridge CFDictionaryRef)p);
    return self;
}

void InsulationInstallMitigationHooks(Class mc) {
    if (!mc) return;
    hookOne(mc, @selector(thermalPressureLevel), (IMP)r_thermalPressureLevel, &o_thermalPressureLevel);
    hookOne(mc, @selector(setThermalState:), (IMP)r_setThermalState, &o_setThermalState);
    hookOne(mc, @selector(getPotentialForcedThermalPressureLevel), (IMP)r_getPotentialForcedThermalPressureLevel, &o_getPotentialForcedThermalPressureLevel);
    hookOne(mc, @selector(getPotentialForcedThermalLevel:), (IMP)r_getPotentialForcedThermalLevel, &o_getPotentialForcedThermalLevel);
    hookOne(mc, @selector(thermalUpdatesToWatchdogEnabled:), (IMP)r_thermalUpdatesToWatchdogEnabled, &o_thermalUpdatesToWatchdogEnabled);
    hookOne(mc, @selector(DVD1Level), (IMP)r_DVD1Level, &o_DVD1Level);
    hookOne(mc, @selector(SGXLevel), (IMP)r_SGXLevel, &o_SGXLevel);
    hookOne(mc, @selector(getPackagePowerZoneMetric), (IMP)r_getPackagePowerZoneMetric, &o_getPackagePowerZoneMetric);
    hookOne(mc, @selector(getGPUTargetPower), (IMP)r_getGPUTargetPower, &o_getGPUTargetPower);
    hookOne(mc, @selector(getPackageGPUPowerTarget), (IMP)r_getPackageGPUPowerTarget, &o_getPackageGPUPowerTarget);
    hookOne(mc, @selector(setPowerSaveActive:), (IMP)r_setPowerSaveActive, &o_setPowerSaveActive);
    hookOne(mc, @selector(setCPULevel:), (IMP)r_setCPULevel, &o_setCPULevel);
    hookOne(mc, @selector(setCPMSMitigationsEnabled:), (IMP)r_setCPMSMitigationsEnabled, &o_setCPMSMitigationsEnabled);
    hookOne(mc, @selector(setCPULowPowerTarget:),                  (IMP)r_setCPULowPowerTarget,      &o_setCPULowPowerTarget);
    hookOne(mc, @selector(setCPUPowerCeiling:fromDecisionSource:), (IMP)r_setCPUPowerCeilingD,       &o_setCPUPowerCeilingD);
    hookOne(mc, @selector(setCPUPowerCeiling:forDVD1Contributor:), (IMP)r_setCPUPowerCeilingDVD1,    &o_setCPUPowerCeilingDVD1);
    hookOne(mc, @selector(setCPUPowerFloor:fromDecisionSource:),   (IMP)r_setCPUPowerFloorD,         &o_setCPUPowerFloorD);
    hookOne(mc, @selector(setCPUPowerZoneTarget:),                 (IMP)r_setCPUPowerZoneTarget,     &o_setCPUPowerZoneTarget);
    hookOne(mc, @selector(setDVD1Level:),                          (IMP)r_setDVD1Level,              &o_setDVD1Level);
    hookOne(mc, @selector(setGPUPowerCeiling:fromDecisionSource:), (IMP)r_setGPUPowerCeilingD,       &o_setGPUPowerCeilingD);
    hookOne(mc, @selector(setGPUPowerFloor:fromDecisionSource:),   (IMP)r_setGPUPowerFloorD,         &o_setGPUPowerFloorD);
    hookOne(mc, @selector(setGPUPowerZoneTarget:),                 (IMP)r_setGPUPowerZoneTarget,     &o_setGPUPowerZoneTarget);
    hookOne(mc, @selector(setSGXLevel:),                           (IMP)r_setSGXLevel,               &o_setSGXLevel);
    hookOne(mc, @selector(setMaxGraphicsDrivePowerTarget:),        (IMP)r_setMaxGraphicsDrivePowerTarget, &o_setMaxGraphicsDrivePowerTarget);
    hookOne(mc, @selector(setPackagePowerCeiling:fromDecisionSource:), (IMP)r_setPackagePowerCeilingD, &o_setPackagePowerCeilingD);
    hookOne(mc, @selector(setPackagePowerFloor:fromDecisionSource:),   (IMP)r_setPackagePowerFloorD,   &o_setPackagePowerFloorD);
    hookOne(mc, @selector(setMaxPackagePower:),                    (IMP)r_setMaxPackagePower,        &o_setMaxPackagePower);
    hookOne(mc, @selector(setPackageLowPowerTarget),               (IMP)r_setPackageLowPowerTarget,  &o_setPackageLowPowerTarget);
    hookOne(mc, @selector(setPackagePowerZoneTarget),              (IMP)r_setPackagePowerZoneTarget, &o_setPackagePowerZoneTarget);
    hookOne(mc, @selector(updateCPU),                              (IMP)r_updateCPU,                 &o_updateCPU);
    hookOne(mc, @selector(updateGPU),                              (IMP)r_updateGPU,                 &o_updateGPU);
    hookOne(mc, @selector(updatePackage),                          (IMP)r_updatePackage,             &o_updatePackage);
}

// ── ThermalManager（ 5 个）
// 本机（iPhone15,3 / iOS 16.4.1）只有 getConfigurationFor: 存在；
// 其余 4 个由安装器的 cbz 判空跳过，这里照装以保持与一致。
void InsulationInstallThermalManagerHooks(Class tm) {
    if (!tm) return;
    hookOne(tm, @selector(getConfigurationFor:), (IMP)r_getConfigurationFor, &o_getConfigurationFor);
    hookOne(tm, @selector(getThermalSuggestion:), (IMP)r_getThermalSuggestion, &o_getThermalSuggestion);
    hookOne(tm, @selector(thermalSuggestion:), (IMP)r_thermalSuggestion, &o_thermalSuggestion);
    hookOne(tm, @selector(thermalMitigation:), (IMP)r_thermalMitigation, &o_thermalMitigation);
    hookOne(tm, @selector(thermalPressure:), (IMP)r_thermalPressure, &o_thermalPressure);
}

// ── PackagePowerCC（ 1 个）
void InsulationInstallPackagePowerCCHooks(Class cc) {
    if (!cc) return;
    hookOne(cc, @selector(initWithParams:), (IMP)r_initWithParams, &o_initWithParams);
}

// ── 在 CommonProduct 上挂的那几个（签名按运行时实际编码修正）
void InsulationInstallCommonProductHooks(Class cp) {
    if (!cp) return;
    hookOne(cp, @selector(thermalPressureLevel), (IMP)r_thermalPressureLevel, &o_thermalPressureLevel);
    hookOne(cp, @selector(setThermalState:), (IMP)r_setThermalState, &o_setThermalState);
    hookOne(cp, @selector(getPotentialForcedThermalPressureLevel), (IMP)r_getPotentialForcedThermalPressureLevel, &o_getPotentialForcedThermalPressureLevel);
    hookOne(cp, @selector(getPotentialForcedThermalLevel:), (IMP)r_getPotentialForcedThermalLevel, &o_getPotentialForcedThermalLevel);
    hookOne(cp, @selector(thermalUpdatesToWatchdogEnabled:), (IMP)r_thermalUpdatesToWatchdogEnabled, &o_thermalUpdatesToWatchdogEnabled);
}
