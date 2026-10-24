//
//  insulation_state.m  —  SystemConfiguration / notify 状态写入
//
//  直接改系统的持久化状态：
//    SCPreferences(域 "insulation"，文件 "OSThermalStatus.plist")
//      → SCPreferencesSetValue / RemoveValue
//      → CommitChanges + ApplyChanges
//  键名成对出现：<行为> 与 <行为>PersistentlyEnabled。
//
#import "insulation.h"
#import <notify.h>
#import <dlfcn.h>

typedef struct __SCPreferences *SCPreferencesRef;
typedef SCPreferencesRef (*FnCreate)(CFAllocatorRef, CFStringRef, CFStringRef);
typedef Boolean (*FnSet)(SCPreferencesRef, CFStringRef, CFPropertyListRef);
typedef Boolean (*FnRemove)(SCPreferencesRef, CFStringRef);
typedef Boolean (*FnCommit)(SCPreferencesRef);
typedef Boolean (*FnApply)(SCPreferencesRef);

static struct {
    FnCreate create; FnSet set; FnRemove remove; FnCommit commit; FnApply apply;
} SC;

static void SCInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 只用 dlsym（导入表里没有 dlopen）
        SC.create = (FnCreate)dlsym(RTLD_DEFAULT, "SCPreferencesCreate");
        SC.set    = (FnSet)dlsym(RTLD_DEFAULT, "SCPreferencesSetValue");
        SC.remove = (FnRemove)dlsym(RTLD_DEFAULT, "SCPreferencesRemoveValue");
        SC.commit = (FnCommit)dlsym(RTLD_DEFAULT, "SCPreferencesCommitChanges");
        SC.apply  = (FnApply)dlsym(RTLD_DEFAULT, "SCPreferencesApplyChanges");
    });
}

static SCPreferencesRef SCPrefsOpen(void) {  // -
    SCInit();
    if (!SC.create) return NULL;
    return SC.create(kCFAllocatorDefault, CFSTR("insulation"), CFSTR("OSThermalStatus.plist"));
}

static int SCCommitApply(SCPreferencesRef p) {
    int rc = 0;
    if (SC.commit) rc = SC.commit(p) ? 0 : 1001;
    if (rc == 0 && SC.apply) rc = SC.apply(p) ? 0 : 1001;
    return rc;
}

// 通用体：值写入 + 可选持久化键 + 提交
static int SCSetBoth(BOOL value, BOOL persist, NSString *key, NSString *persistKey) {
    SCPreferencesRef p = SCPrefsOpen();
    if (!p) return 1001;
    if (SC.set) {
        SC.set(p, (__bridge CFStringRef)key, value ? kCFBooleanTrue : kCFBooleanFalse);
        if (persistKey)
            SC.set(p, (__bridge CFStringRef)persistKey, persist ? kCFBooleanTrue : kCFBooleanFalse);
    }
    int rc = SCCommitApply(p);
    CFRelease(p);
    return rc;
}

static int SCRemove(NSString *key, NSString *persistKey) {
    SCPreferencesRef p = SCPrefsOpen();
    if (!p) return 1001;
    if (SC.remove) {
        SC.remove(p, (__bridge CFStringRef)key);
        if (persistKey) SC.remove(p, (__bridge CFStringRef)persistKey);
    }
    int rc = SCCommitApply(p);
    CFRelease(p);
    return rc;
}

#pragma mark - OS 热通知

void insulationSetOSNotifEnabled(BOOL on) {
    SCSetBoth(on, YES, @"OSThermalNotificationEnabled",
              @"OSThermalNotificationPersistentlyEnabled");
}

void insulationSetOSNotifNative(void) {  // 恢复系统值（on=YES, 不持久化覆写）
    SCSetBoth(YES, NO, @"OSThermalNotificationEnabled",
              @"OSThermalNotificationPersistentlyEnabled");
}

void insulationResetOSNotifEnabled(void) {
    SCRemove(@"OSThermalNotificationEnabled", @"OSThermalNotificationPersistentlyEnabled");
}

#pragma mark - 热缓解 / engageBehavior

void insulationSetThermalMitigationsEnabled(BOOL on) {
    SCSetBoth(on, YES, @"engageBehavior", @"engageBehaviorPersistentlyEnabled");
}

void insulationSetThermalMitigationsNative(void) {
    SCSetBoth(YES, NO, @"engageBehavior", @"engageBehaviorPersistentlyEnabled");
}

void insulationResetThermalMitigations(void) {
    SCRemove(@"engageBehavior", @"engageBehaviorPersistentlyEnabled");
}

#pragma mark - HIP

void insulationSetHIPEnabled(BOOL on) {
    SCSetBoth(on, YES, @"hipOverride", @"hipPersistentlyEnabled");
}

void insulationSetHIPNative(void) {
    SCSetBoth(YES, NO, @"hipOverride", @"hipPersistentlyEnabled");
}

void insulationResetHIP(void) {
    SCRemove(@"hipOverride", @"hipPersistentlyEnabled");
}

void insulationSetSimulateHIPEnabled(BOOL on) {
    SCSetBoth(on, YES, @"simulateHip", NULL);
}

void insulationResetSimulateHIP(void) {
    SCRemove(@"simulateHip", NULL);
}

#pragma mark - 阳光暴晒

void insulationSetSunlightOverride(int on) {
    SCSetBoth(on != 0, YES, @"sunlightOverride", @"sunlightOverridePersistentlyEnabled");
}

void insulationResetSunlightOverride(void) {
    SCRemove(@"sunlightOverride", @"sunlightOverridePersistentlyEnabled");
}

#pragma mark - Darwin 热压

// 直接向 notify 键 "com.apple.system.thermalpressurelevel" 写状态；
// 读端用高位魔数 'SUIN'  校验，低 8 位为本插件写入的值。
extern CFStringRef kOSThermalNotificationPressureLevelName;

#define kInsulationStateMagic 0x5355494EULL

void insulationSetDarwinThermalPressure(int level) {
    // 该键存的是 10/20/30/40/50（level*10），0 表示无压力。
    // 【2026-10-24 修复】通过 CoreOS 导出的
    // extern CFStringRef kOSThermalNotificationPressureLevelName;
    // 取键名。本工程用 -undefined,dynamic_lookup 链接，实际设备上该符号
    // 解析出来的不是合法 CFString（实测解引用直接 access violation，
    // 地址 ）。而该键名的字面量是固定的，直接写死即可，
    // 行为完全一致且不依赖外部符号解析。
    static int token = -1;
    static dispatch_once_t once;
    static char key[64];
    dispatch_once(&once, ^{
        strlcpy(key, "com.apple.system.thermalpressurelevel", sizeof(key));
        notify_register_check(key, &token);
    });

    // level 在 1..5 内写 level*10，否则写 0
    uint64_t state = 0;
    if (level >= 1 && level <= 5) state = (uint64_t)level * 10;
    if (token >= 0) notify_set_state(token, state);
    notify_post(key);
}

// 读回状态。返回 0 成功，1 魔数不匹配，其它为 notify 错误码
int insulationGetRuntimeState(int *a, int *b) {
    int token = 0;
    if (notify_register_check(kNotifyRuntimeState, &token) != 0) return 1001;

    uint64_t state = 0;
    int rc = notify_get_state(token, &state);
    notify_cancel(token);
    if (rc != 0) return rc;

    if ((uint32_t)(state >> 32) != kInsulationStateMagic) return 1;
    if (a) *a = (int)((state >> 8) & 0xFF);
    if (b) *b = (int)(state & 0xFF);
    return 0;
}
