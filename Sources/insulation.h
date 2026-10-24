//
//  insulation.h  —  公共声明
//
//  全局状态、偏好读取、CPU 功率换算、状态写入、hook 安装入口。
//
#import <Foundation/Foundation.h>

#define INSHIDDEN __attribute__((visibility("hidden")))
#import <objc/runtime.h>

#pragma mark - 全局状态

INSHIDDEN extern NSDictionary *gPrefs;  // 偏好 plist 缓存
INSHIDDEN extern int gCPURestoreActive;  // >0 时需要恢复 CPU 设置
INSHIDDEN extern int gFullCPUPower;  // 当前上报的 CPU 功率上限
INSHIDDEN extern int gMaxComponentPower;  // 组件功率候选最大值
INSHIDDEN extern NSMutableDictionary *gPowerCache;  // 组件→功率 的缓存字典
INSHIDDEN extern double gProcessStartTime;  // CFAbsoluteTime，进程启动时刻
INSHIDDEN extern dispatch_once_t gHooksOnce;
INSHIDDEN extern IMP gOrigDictionaryWithContentsOfFile;
INSHIDDEN extern id gCommonProductObject;
INSHIDDEN extern id gMitigationControllerObject;
INSHIDDEN extern BOOL gInsulationHooksInstalled;  // 诊断：hook 是否装上
INSHIDDEN extern BOOL gInsulationControllerSeen;  // 诊断：是否抓到 CPMS 对象
// IOReport 分段状态（每完成一步置位）
// 符号加载 订阅成功 采到过样本
extern int gInsulationIOStatus;
// 诊断计数：[0]initProduct [1]initMC [2]setCPULevel [3]setPowerSaveActive [4]puppetEvent

#pragma mark - 导出函数

// 偏好
NSDictionary *InsulationReloadPreferences(void);
NSString     *InsulationPowerMode(void);
BOOL InsulationLowPowerModeEnabled(void);
BOOL InsulationFullPowerModeEnabled(void);
BOOL InsulationAggressiveFullPowerEnabled(void);

// 屏幕 / 温控开关
INSHIDDEN BOOL InsulationBoolPref(NSString *key);  // 通用 BOOL 取键
BOOL InsulationPreventDimmingEnabled(void);
BOOL InsulationDisplayDimmingBypassEnabled(void);
BOOL InsulationThermalDimmingBypassActive(void);
BOOL InsulationPowerMitigationsDisabled(void);

// CPU 功率
BOOL InsulationCPURestoreActive(void);
BOOL InsulationCPULimitEnabled(void);
int  InsulationForcedCPULevel(void);
int  InsulationLimitedCPULevel(int fallback);
int  InsulationFullCPUPower(int level);
int  InsulationLimitedCPUPower(int power);
int  InsulationMitigationPowerFloor(int floorValue);
int  InsulationMaxComponentPower(int power, int componentId);
int  InsulationNoteComponentPowerCandidate(int power);
unsigned InsulationUnrestrictedPowerLimit(void);  // 50000
unsigned InsulationUnrestrictedPowerLimitUInt32(void);  // 50000
int  InsulationBacklightThermalPowerFloor(void);

// 对象
void InsulationSetCommonProductObject(id obj);
void InsulationSetMitigationControllerObject(id obj);

// 事件
void InsulationExecutePuppetEvent(void);
void InsulationExecutePuppetEventSoon(void);

// plist 改写
NSDictionary *InsulationPatchThermalPlist(NSDictionary *plist);

// 安装 hook（constructor 里调用一次）
void InsulationRuntimeHooksInstall(void);
INSHIDDEN void InsulationInstallMitigationHooks(Class mc);
void InsulationInstallCommonProductHooks(Class cp);
void InsulationInstallThermalManagerHooks(Class tm);
void InsulationInstallPackagePowerCCHooks(Class cc);  // insulation_mitigation.m
INSHIDDEN void insulationKillSelf(void);  // kill(getpid(), SIGTERM)

// 配置走 notify：设置页写，daemon 读（文件路径在 roothide 上不可靠）
   

#pragma mark - 内部函数

void   insulationMarkProcessStart(void);
double insulationBootTime(void);  // 附近
BOOL   insulationFullPowerBootGuardActive(void);
double insulationFullPowerBootGuardDurationSeconds(void);  // = 6.0
int    insulationGetRuntimeState(int *a, int *b);
void   insulationSetDarwinThermalPressure(int level);
void   insulationSetOSNotifEnabled(BOOL);
void   insulationSetOSNotifNative(void);
void   insulationSetThermalMitigationsEnabled(BOOL);
void   insulationSetThermalMitigationsNative(void);
void   insulationResetThermalMitigations(void);
void   insulationSetHIPEnabled(BOOL);
void   insulationSetHIPNative(void);
void   insulationSetSimulateHIPEnabled(BOOL);
void   insulationResetSimulateHIP(void);
void   insulationSetSunlightOverride(int);
void   insulationResetSunlightOverride(void);
void   insulationResetOSNotifEnabled(void);
void   insulationResetHIP(void);

#pragma mark - 被 hook 的私有类

@interface MitigationController : NSObject
- (void)setCPMSMitigationsEnabled:(BOOL)enabled;
- (void)setPowerSaveActive:(BOOL)active;
- (void)setCPULevel:(int)level;
- (void)setCPULowPowerTarget:(int)target;
- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(int)src;
- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(int)src;
- (void)setCPUPowerZoneTarget:(int)target;
- (void)setMaxPackagePower:(int)power;
- (void)setPackagePowerCeiling:(int)ceiling fromDecisionSource:(int)src;
- (void)setPackagePowerFloor:(int)floor fromDecisionSource:(int)src;
- (int)getCurrentCPULoadingIndex:(int)cluster;
- (int)CPULevel;
- (int)getCurrentCPUPower;
- (int)getCPUTargetPower;
- (id)initForFastLoop:(BOOL)fast noDisplay:(BOOL)noDisplay
      powerSaveParams:(id)a powerZoneParams:(id)b;
- (void)updateCPU;
- (void)updateGPU;
- (void)updatePackage;
@end

@interface CommonProduct : NSObject
- (void)putDeviceInThermalSimulationMode:(NSString *)mode;
- (void)putDeviceInLowTempSimulationMode:(NSString *)mode;
@end

#pragma mark - 通知名

#define kNotifyExecutePuppet   "com.be-huge.insulation-executePuppetEvent"
#define kNotifyRuntimeState    "com.be-huge.insulation.runtimeState"
#define kNotifyRestartThermal  "com.be-huge.insulation-restartThermalMonitor"
#define kPrefsCacheDomain      "com.be-huge.insulation.prefs-cache"
#define kThermalPressureLevel  "com.apple.system.thermalpressurelevel"

#define kPrefsPath @"/var/mobile/Library/Preferences/com.be-huge.insulation-prefs.plist"

