//
//  insulation_freq.m  —  P/E 核实时频率采样
//
//  数据源：IOReport 组 "CPU Stats"
//    subgroup "CPU Complex Voltage States"
//      RawElements 长度 1088 → P 核 17 档
//      RawElements 长度  320 → E 核  5 档
//    每条记录 64 字节，该档累计时间在 +0x30（uint64，只有当前档递增）
//
//  频率 = Σ(该档增量 × 该档频率) / Σ(增量)
//
//  结果广播：notify state = (P_MHz << 16) | E_MHz，通知名 com.be-huge.insulation-freq
//

#import "insulation.h"
#import <dlfcn.h>
#import <notify.h>
#include <string.h>

#define FREQ_NOTIFY_NAME "com.be-huge.insulation-freq"

// 档位表一律运行时从 IORegistry 读取，不做机型硬编码兜底
#define FREQ_MAX_STATES 32
static int gPTable[FREQ_MAX_STATES]; static int gPCount;
static int gETable[FREQ_MAX_STATES]; static int gECount;

typedef void *(*FnCopyChannelsInGroup)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef void *(*FnCreateSubscription)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, void *);
typedef CFDictionaryRef (*FnCreateSamples)(void *, CFMutableDictionaryRef, void *);

static FnCopyChannelsInGroup fCopyChannels;
static FnCreateSubscription fCreateSub;
static FnCreateSamples fCreateSamples;

static void *gSubRef;
static CFMutableDictionaryRef gSubbed;
static BOOL gReady;
static int gToken = -1;

static uint64_t gPrevP[FREQ_MAX_STATES];
static uint64_t gPrevE[FREQ_MAX_STATES];
static BOOL gHavePrev;
static int gLastP, gLastE;
static dispatch_source_t gFreqTimer;   // ARC：必须强引用，否则定时器被释放

// 从 IORegistry 读 voltage-states*-sram，按条目数匹配 cluster 的状态数
typedef uint32_t (*FnEntryFromPath)(uint32_t, const char *);
typedef int (*FnCreateProps)(uint32_t, CFMutableDictionaryRef *, CFAllocatorRef, uint32_t);
typedef int (*FnObjectRelease)(uint32_t);

static int InsFreqLoadTable(const int *skipCounts, int want, int *out, int outMax) {
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!iokit) return 0;
    FnEntryFromPath entryFromPath = (FnEntryFromPath)dlsym(iokit, "IORegistryEntryFromPath");
    FnCreateProps createProps = (FnCreateProps)dlsym(iokit, "IORegistryEntryCreateCFProperties");
    FnObjectRelease release = (FnObjectRelease)dlsym(iokit, "IOObjectRelease");
    if (!entryFromPath || !createProps || !release) return 0;

    uint32_t entry = entryFromPath(0, "IODeviceTree:/arm-io/pmgr");
    if (!entry) return 0;

    CFMutableDictionaryRef props = NULL;
    int kr = createProps(entry, &props, NULL, 0);
    release(entry);
    if (kr != 0 || !props) return 0;

    int found = 0;
    CFIndex n = CFDictionaryGetCount(props);
    const void *keys[64], *vals[64];
    if (n > 64) n = 64;
    CFDictionaryGetKeysAndValues(props, keys, vals);

    // 先找 sram 表，再退回普通表
    for (int pass = 0; pass < 2 && !found; pass++) {
        for (CFIndex i = 0; i < n; i++) {
            const char *k = [(__bridge NSString *)keys[i] UTF8String];
            if (!k || strncmp(k, "voltage-states", 14) != 0) continue;
            BOOL isSram = strstr(k, "-sram") != NULL;
            if (pass == 0 && !isSram) continue;
            if (pass == 1 && isSram) continue;

            CFDataRef data = (CFDataRef)vals[i];
            if (!data || CFGetTypeID(data) != CFDataGetTypeID()) continue;
            CFIndex len = CFDataGetLength(data);
            int count = (int)(len / 8);
            if (count != want) continue;
            if (skipCounts && count == skipCounts[0] && want == skipCounts[1]) continue;

            const uint8_t *b = CFDataGetBytePtr(data);
            for (int j = 0; j < count && j < outMax; j++) {
                uint32_t hz = 0;
                memcpy(&hz, b + j * 8, 4);
                out[j] = (int)((hz + 500000) / 1000000);   // Hz → MHz
            }
            found = count;
            break;
        }
    }
    CFRelease(props);
    return found;
}

static BOOL InsFreqSetup(void) {
    if (gReady) return YES;
    void *h = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY);
    if (!h) return NO;
    fCopyChannels  = (FnCopyChannelsInGroup)dlsym(h, "IOReportCopyChannelsInGroup");
    fCreateSub     = (FnCreateSubscription)dlsym(h, "IOReportCreateSubscription");
    fCreateSamples = (FnCreateSamples)dlsym(h, "IOReportCreateSamples");
    if (!fCopyChannels || !fCreateSub || !fCreateSamples) return NO;

    CFMutableDictionaryRef ch = fCopyChannels(CFSTR("CPU Stats"), NULL, 0, 0, 0);
    if (!ch) return NO;
    CFMutableDictionaryRef subbed = NULL;
    gSubRef = fCreateSub(NULL, ch, &subbed, 0, NULL);
    CFRelease(ch);
    if (!gSubRef) return NO;
    gSubbed = subbed;
    notify_register_check(FREQ_NOTIFY_NAME, &gToken);

    // 先探一次，拿到两个 cluster 的状态数
    uint64_t probeP[FREQ_MAX_STATES] = {0}, probeE[FREQ_MAX_STATES] = {0};
    int np = 0, ne = 0;
    {
        CFDictionaryRef s0 = fCreateSamples(gSubRef, gSubbed, NULL);
        if (s0) {
            CFArrayRef chans = CFDictionaryGetValue(s0, CFSTR("IOReportChannels"));
            if (chans) {
                CFIndex cn = CFArrayGetCount(chans);
                for (CFIndex i = 0; i < cn; i++) {
                    CFDictionaryRef c = CFArrayGetValueAtIndex(chans, i);
                    CFStringRef sg = CFDictionaryGetValue(c, CFSTR("IOReportSubGroupName"));
                    if (!sg || CFStringCompare(sg, CFSTR("CPU Complex Voltage States"), 0) != kCFCompareEqualTo) continue;
                    CFDataRef raw = CFDictionaryGetValue(c, CFSTR("RawElements"));
                    if (!raw) continue;
                    int cnt = (int)(CFDataGetLength(raw) / 64);
                    if (cnt > np && cnt >= 8) np = cnt;        // P 核档位多
                    else if (cnt > ne && cnt < 8) ne = cnt;    // E 核档位少
                }
            }
            CFRelease(s0);
        }
    }
    (void)probeP; (void)probeE;

    // 按状态数匹配档位表；失败用 A16 兜底
    gPCount = InsFreqLoadTable(NULL, np, gPTable, FREQ_MAX_STATES);
    gECount = InsFreqLoadTable(NULL, ne, gETable, FREQ_MAX_STATES);
    // 取不到表就不上报该簇（设置页显示 "—"），不再用硬编码数值蒙

    gReady = YES;
    return YES;
}

static BOOL InsFreqReadCounters(uint64_t *pOut, uint64_t *eOut) {
    CFDictionaryRef s = fCreateSamples(gSubRef, gSubbed, NULL);
    if (!s) return NO;
    BOOL gotP = NO, gotE = NO;
    CFArrayRef chans = CFDictionaryGetValue(s, CFSTR("IOReportChannels"));
    if (chans) {
        CFIndex n = CFArrayGetCount(chans);
        for (CFIndex i = 0; i < n; i++) {
            CFDictionaryRef c = CFArrayGetValueAtIndex(chans, i);
            CFStringRef sg = CFDictionaryGetValue(c, CFSTR("IOReportSubGroupName"));
            if (!sg || CFStringCompare(sg, CFSTR("CPU Complex Voltage States"), 0) != kCFCompareEqualTo)
                continue;
            CFDataRef raw = CFDictionaryGetValue(c, CFSTR("RawElements"));
            if (!raw) continue;
            CFIndex len = CFDataGetLength(raw);
            const uint8_t *b = CFDataGetBytePtr(raw);
            int cnt = (int)(len / 64);
            if (cnt == gPCount && !gotP) {
                for (int k = 0; k < cnt; k++) memcpy(&pOut[k], b + k * 64 + 0x30, 8);
                gotP = YES;
            } else if (cnt == gECount && !gotE) {
                for (int k = 0; k < cnt; k++) memcpy(&eOut[k], b + k * 64 + 0x30, 8);
                gotE = YES;
            }
        }
    }
    CFRelease(s);
    return gotP && gotE;
}

static int InsFreqWeighted(const uint64_t *prev, const uint64_t *cur,
                           int count, const int *table, int fallback) {
    double sum = 0, tot = 0;
    for (int i = 0; i < count; i++) {
        uint64_t d = (cur[i] >= prev[i]) ? (cur[i] - prev[i]) : 0;
        if (!d) continue;
        sum += (double)d * (double)table[i];
        tot += (double)d;
    }
    if (tot <= 0) return fallback;
    return (int)(sum / tot + 0.5);
}

void InsulationFreqSample(void) {
    if (!InsFreqSetup()) return;
    uint64_t p[FREQ_MAX_STATES] = {0}, e[FREQ_MAX_STATES] = {0};
    if (!InsFreqReadCounters(p, e)) return;

    if (!gHavePrev) {
        memcpy(gPrevP, p, sizeof(uint64_t) * FREQ_MAX_STATES);
        memcpy(gPrevE, e, sizeof(uint64_t) * FREQ_MAX_STATES);
        gHavePrev = YES;
        return;
    }
    int pm = InsFreqWeighted(gPrevP, p, gPCount, gPTable, gLastP);
    int em = InsFreqWeighted(gPrevE, e, gECount, gETable, gLastE);
    memcpy(gPrevP, p, sizeof(uint64_t) * FREQ_MAX_STATES);
    memcpy(gPrevE, e, sizeof(uint64_t) * FREQ_MAX_STATES);

    if (pm > 0) gLastP = pm;
    if (em > 0) gLastE = em;
    if (gLastP <= 0 && gLastE <= 0) return;

    uint64_t state = ((uint64_t)(gLastP & 0xFFFF) << 16) | (uint64_t)(gLastE & 0xFFFF);
    if (gToken >= 0) notify_set_state(gToken, state);
    notify_post(FREQ_NOTIFY_NAME);
}

void InsulationFreqStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t q = dispatch_queue_create("com.be-huge.insulation.freq", NULL);
        gFreqTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_t t = gFreqTimer;
        dispatch_source_set_timer(t,
                                  dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                  2 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(t, ^{ InsulationFreqSample(); });
        dispatch_resume(t);
    });
}

int InsulationFreqLastP(void) { return gLastP; }
int InsulationFreqLastE(void) { return gLastE; }
