//
//  insulation_cpu.m  —  CPU 功率换算 + puppet 事件状态机
//
#import "insulation.h"
#import <notify.h>
#import <SystemConfiguration/SystemConfiguration.h>

// 起的额外状态（原里紧跟在 gMitigationControllerObject 之后）
static BOOL gPuppetEventBusy;  // 重入锁
static BOOL gThermalSimulationActive;  // 是否已置于模拟热档
static NSString *gLastAppliedPuppetValue;  // 上次生效的档位
static BOOL gMitigationsStateInitialized;
static BOOL gMitigationsSpoofed;

#pragma mark - 功率记账

int InsulationNoteComponentPowerCandidate(int p) {
    if (p >= 1 && p > gMaxComponentPower) gMaxComponentPower = p;
    return gMaxComponentPower;
}

int InsulationFullCPUPower(int level) {
    if (level >= 1) gFullCPUPower = MAX(gFullCPUPower, level);
    int v = gFullCPUPower;
    if (level >= 1) v = MAX(v, level);
    return MIN(v, 50000);
}

// 恢复期内一律 0，否则 lowPower?2:0（原实现忽略入参）
int InsulationLimitedCPULevel(int fallback) {
    if (gCPURestoreActive > 0) return 0;
    return InsulationLowPowerModeEnabled() ? 2 : 0;
}

int InsulationLimitedCPUPower(int power) {
    if (power >= 1) gFullCPUPower = MAX(gFullCPUPower, power);

    if (InsulationFullPowerModeEnabled() && !insulationFullPowerBootGuardActive()) {
        int v = gFullCPUPower;
        if (power >= 1) gFullCPUPower = MAX(v, power);  // 原就是这样重复了一次
        v = MAX(v, power);
        return MAX(v, 50000);  // 解除限制时的功率下限
    }
    return power;
}

int InsulationMaxComponentPower(int power, int componentId) {
    if (!gPowerCache) gPowerCache = [NSMutableDictionary dictionary];

    NSNumber *key = [NSNumber numberWithInt:componentId];
    if (power >= 1) {
        gMaxComponentPower = MAX(gMaxComponentPower, power);
        int prev = [[gPowerCache objectForKey:key] intValue];
        gPowerCache[key] = @(MAX(prev, power));
    }

    if (InsulationFullPowerModeEnabled() && !insulationFullPowerBootGuardActive()) {
        int v = [[gPowerCache objectForKey:key] intValue];
        v = MAX(v, gMaxComponentPower);
        v = MAX(v, power);
        power = MAX(v, 50000);
    }
    return power;
}

int InsulationMitigationPowerFloor(int v) {
    if (InsulationFullPowerModeEnabled() && !insulationFullPowerBootGuardActive()) return 0;
    return v;
}

#pragma mark - 控制器复位

static void ResetControllerCPUState(id controller) {
    if (!controller) return;
    [controller setPowerSaveActive:NO];
    [controller setCPULevel:0];
}

#pragma mark - puppet 事件

void InsulationExecutePuppetEvent(void) {
    if (gPuppetEventBusy) return;
    gPuppetEventBusy = YES;
    InsulationReloadPreferences();

    id product = gCommonProductObject;
    BOOL preventDim = InsulationPreventDimmingEnabled();
    BOOL full = InsulationFullPowerModeEnabled();
    BOOL guard = insulationFullPowerBootGuardActive();

    // 6.1 热模拟档位（与 一致：fullPower→nominal，其余→light）
    if (preventDim || full) {
        NSString *mode = (full && !guard) ? @"nominal" : @"light";
        [product putDeviceInThermalSimulationMode:mode];
        [product putDeviceInLowTempSimulationMode:mode];
        gThermalSimulationActive = YES;
        if (full && !guard) insulationSetDarwinThermalPressure(0);
    } else if (gThermalSimulationActive) {
        [product putDeviceInThermalSimulationMode:@"off"];
        [product putDeviceInLowTempSimulationMode:@"off"];
        gThermalSimulationActive = NO;
    }

    // 6.2 热缓解开关（带“已改写”记忆，避免反复覆盖系统状态）
    BOOL unrestricted = full && !guard;
    if (unrestricted) {
        insulationSetThermalMitigationsEnabled(NO);
        gMitigationsSpoofed = YES;
    } else {
        if (!(gMitigationsStateInitialized && !gMitigationsSpoofed))
            insulationSetThermalMitigationsNative();
        gMitigationsSpoofed = NO;
    }
    gMitigationsStateInitialized = YES;

    // 6.3 档位变化 → 清空累计统计
    id controller = gMitigationControllerObject;
    NSString *mode = InsulationPowerMode();
    if (![mode isEqualToString:gLastAppliedPuppetValue]) {
        gFullCPUPower = 0;
        gMaxComponentPower = 0;
        [gPowerCache removeAllObjects];
    }

    if (unrestricted) {
        // 6.4 解除 CPU / 封装功率限制
        [controller updateCPU];
        if (controller) {
            int p = MAX(gFullCPUPower, 50000);
            [controller setCPMSMitigationsEnabled:NO];
            ResetControllerCPUState(controller);
            [controller setCPULowPowerTarget:p];
            [controller setCPUPowerCeiling:p fromDecisionSource:0];
            [controller setCPUPowerFloor:p   fromDecisionSource:0];
            [controller setCPUPowerZoneTarget:p];
            [controller setMaxPackagePower:p];
            [controller setPackagePowerCeiling:p fromDecisionSource:0];
            [controller setPackagePowerFloor:p   fromDecisionSource:0];
            [controller setCPMSMitigationsEnabled:NO];
        }
        gLastAppliedPuppetValue = mode;
        gCPURestoreActive = 0;
    } else if ([mode isEqualToString:@"fullPower"]) {
        // 6.5 请求全功率但被 6 秒守卫拦住：记为 off，守卫过期后下次事件会重来
        gLastAppliedPuppetValue = @"off";
        gCPURestoreActive = 0;
    } else if ([mode isEqualToString:@"lowPower"]) {
        int level = InsulationForcedCPULevel();  // 2
        [controller setPowerSaveActive:YES];
        [controller setCPULevel:level];
        [controller updateCPU];
        [controller setPowerSaveActive:YES];
        [controller setCPULevel:level];
        gLastAppliedPuppetValue = mode;
        gCPURestoreActive = 0;
    } else {
        // 6.6 off / 未知：进入 8 次事件的恢复期
        if (gLastAppliedPuppetValue &&
            ![gLastAppliedPuppetValue isEqualToString:@"off"] &&
            gCPURestoreActive == 0) {
            gCPURestoreActive = 8;
        }
        gLastAppliedPuppetValue = @"off";
        if (gCPURestoreActive >= 1) {
            [controller updateCPU];
            ResetControllerCPUState(controller);
            gCPURestoreActive -= 1;
        }
    }

    // 6.7 三个可选覆盖：键存在才接管，否则恢复系统原生
    if ([gPrefs objectForKey:@"thermalSuppressNotificationsEnabled"]) {
        if (InsulationBoolPref(@"thermalSuppressNotificationsEnabled"))
            insulationSetOSNotifEnabled(NO);
        else
            insulationSetOSNotifNative();
    }
    if ([gPrefs objectForKey:@"thermalDisablePocketSunlightEnabled"]) {
        if (InsulationBoolPref(@"thermalDisablePocketSunlightEnabled")) {
            insulationSetHIPEnabled(NO);
            insulationSetSimulateHIPEnabled(NO);
        } else {
            insulationSetHIPNative();
        }
    }
    if ([gPrefs objectForKey:@"thermalSunlightLockedEnabled"]) {
        if (InsulationBoolPref(@"thermalSunlightLockedEnabled"))
            insulationSetSunlightOverride(1);
        else
            insulationResetSunlightOverride();
    }

    gPuppetEventBusy = NO;
}

// 按固定时间表重复应用。
// 把 [0.25,1,2,4,6,8,10] 拷贝成可变数组，再追加 (bootGuard + 0.5)，
// 对每个元素 dispatch_after(delay*1e9) → InsulationExecutePuppetEvent()。
// CPMS/CLPC 初始化需要时间，单次下发会被系统覆盖，所以必须重放。
void InsulationExecutePuppetEventSoon(void) {
    static const double kDelays[] = {0.25, 1.0, 2.0, 4.0, 6.0, 8.0, 10.0};
    double guardPoint = insulationFullPowerBootGuardDurationSeconds() + 0.5;

    dispatch_queue_t q = dispatch_get_global_queue(0, 0);
    for (size_t i = 0; i < sizeof(kDelays) / sizeof(kDelays[0]); i++) {
        int64_t ns = (int64_t)(kDelays[i] * 1e9);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ns), q, ^{
            InsulationExecutePuppetEvent();
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(guardPoint * 1e9)), q, ^{
        InsulationExecutePuppetEvent();
    });
}
