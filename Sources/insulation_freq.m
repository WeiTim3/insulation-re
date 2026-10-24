//
//  insulation_freq.m  —  在 thermalmonitord 内采样 P/E 簇当前档位并广播
//
//  做法与早期可用的版本一致：直接问 CPMS 要「当前档位索引」，
//  而不是用 IOReport 计数器做加权平均。
//  原因：计数器在簇完全空闲时增量为 0，算不出频率（会显示空白）；
//       而 getCurrentCPULoadingIndex: 始终返回一个合法档位。
//
//  协议：state = 'FREQ'<<32 | flags<<16 | pIndex<<8 | eIndex
//        flags bit0 = 上报器已启动
//        pIndex/eIndex = 0xFF 表示该簇暂不可用
//

#import "insulation.h"
#import <notify.h>
#import <objc/message.h>
#include <string.h>

#define kFreqStateName "com.be-huge.insulation.freqstate"
#define kFreqMagic     0x46524551ULL   // 'FREQ'

static int gFreqToken = -1;
static dispatch_source_t gFreqTimer;   // ARC：必须强引用

static int INSClusterIndex(int cluster) {
    id c = gMitigationControllerObject;
    if (!c) return -1;
    if (![c respondsToSelector:@selector(getCurrentCPULoadingIndex:)]) return -1;
    int idx = -1;
    @try {
        idx = ((int (*)(id, SEL, int))objc_msgSend)(c, @selector(getCurrentCPULoadingIndex:), cluster);
    } @catch (NSException *e) {
        return -1;
    }
    if (idx < 0 || idx > 31) return -1;
    return idx;
}

void InsulationFreqStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (gFreqToken < 0) notify_register_check(kFreqStateName, &gFreqToken);

        dispatch_queue_t q = dispatch_queue_create("com.be-huge.insulation.freq", NULL);
        gFreqTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(gFreqTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                  2 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gFreqTimer, ^{
            if (gFreqToken < 0) return;
            int p = INSClusterIndex(1);   // P 核
            int e = INSClusterIndex(0);   // E 核
            uint64_t flags = 0x1;
            if (p >= 0 && e >= 0) flags |= 0x2;
            uint64_t state = (kFreqMagic << 32) |
                             (flags << 16) |
                             ((uint64_t)(p < 0 ? 0xFF : p) << 8) |
                             (uint64_t)(e < 0 ? 0xFF : e);
            notify_set_state(gFreqToken, state);
        });
        dispatch_resume(gFreqTimer);
    });
}

// 设置页读取：0 成功；pIdx/eIdx 为 -1 表示该簇不可用
int InsulationFreqRead(int *pIdx, int *eIdx) {
    int token = 0;
    if (notify_register_check(kFreqStateName, &token) != 0) return 1;
    uint64_t state = 0;
    int rc = notify_get_state(token, &state);
    notify_cancel(token);
    if (rc != 0) return rc;
    if ((uint32_t)(state >> 32) != (uint32_t)kFreqMagic) return 2;

    int p = (int)((state >> 8) & 0xFF);
    int e = (int)(state & 0xFF);
    if (pIdx) *pIdx = (p == 0xFF) ? -1 : p;
    if (eIdx) *eIdx = (e == 0xFF) ? -1 : e;
    return 0;
}
