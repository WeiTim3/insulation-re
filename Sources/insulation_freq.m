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

// A16 (iPhone15,3) 出厂档位表
static const int kPTable[17] = {636, 924, 1176, 1428, 1680, 1920, 2100, 2280,
                                2460, 2640, 2820, 2940, 3060, 3180, 3300, 3420, 3468};
static const int kETable[5] = {600, 816, 1200, 1584, 2016};

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

static uint64_t gPrevP[17];
static uint64_t gPrevE[5];
static BOOL gHavePrev;
static int gLastP, gLastE;

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
            if (len == 17 * 64 && !gotP) {
                for (int k = 0; k < 17; k++)
                    memcpy(&pOut[k], b + k * 64 + 0x30, 8);
                gotP = YES;
            } else if (len == 5 * 64 && !gotE) {
                for (int k = 0; k < 5; k++)
                    memcpy(&eOut[k], b + k * 64 + 0x30, 8);
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
    uint64_t p[17] = {0}, e[5] = {0};
    if (!InsFreqReadCounters(p, e)) return;

    if (!gHavePrev) {
        memcpy(gPrevP, p, sizeof(p));
        memcpy(gPrevE, e, sizeof(e));
        gHavePrev = YES;
        return;
    }
    int pm = InsFreqWeighted(gPrevP, p, 17, kPTable, gLastP);
    int em = InsFreqWeighted(gPrevE, e, 5, kETable, gLastE);
    memcpy(gPrevP, p, sizeof(p));
    memcpy(gPrevE, e, sizeof(e));

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
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(t,
                                  dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                  NSEC_PER_SEC, 50 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(t, ^{ InsulationFreqSample(); });
        dispatch_resume(t);
    });
}

int InsulationFreqLastP(void) { return gLastP; }
int InsulationFreqLastE(void) { return gLastE; }
