//
//  insulation_plist.m  —  thermal plist 改写器
//
//  触发链路：
//    +[NSDictionary dictionaryWithContentsOfFile:] hook
//      → path 含 "/System/Library/ThermalMonitor/"
//      → InsulationPatchThermalPlist(dict)
//
#import "insulation.h"

// 关键词表
static NSArray<NSString *> *ZeroKeywords(void) {  // 命中 → 数值归零
    return @[@"mitigation", @"contextualclamp", @"clamp", @"thermalpressure",
             @"forcedthermal", @"powersave", @"lowpower", @"throttle", @"cpms"];
}

static NSArray<NSString *> *RangeKeywords(void) {  // 命中 → 抬到 50000 下限
    return @[@"target", @"ceiling", @"floor", @"budget",
             @"limit", @"max", @"thermalpower", @"powerzone"];
}

#pragma mark - 小工具

static BOOL INSContainsAny(NSString *s, NSArray<NSString *> *keys) {
    for (NSString *k in keys)
        if ([s containsString:k]) return YES;
    return NO;
}

static NSNumber *INSNumberFromObject(id o) {
    if ([o isKindOfClass:[NSNumber class]]) return o;
    if (![o isKindOfClass:[NSString class]]) return nil;

    NSString *trimmed = [(NSString *)o stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSScanner *sc = [NSScanner scannerWithString:trimmed];
    long long v = 0;
    if (![sc scanLongLong:&v]) return nil;
    return @(v);
}

static NSNumber *INSMaxNumberInArray(NSArray *a) {
    NSNumber *best = nil;
    for (id e in a) {
        NSNumber *n = INSNumberFromObject(e);
        if (!n) continue;
        if (!best || n.longLongValue > best.longLongValue) best = n;
    }
    return best;
}

#pragma mark - 背光字典特化

static NSMutableDictionary *INSBacklightFixup(NSMutableDictionary *dict) {
    NSMutableDictionary *out = [dict mutableCopy];

    // ① brightness / backlightpower 数组元素统一成最大值
    for (NSString *k in [[out allKeys] copy]) {
        if (![k isKindOfClass:[NSString class]]) continue;
        NSString *lower = [k lowercaseString];
        if (!([lower containsString:@"brightness"] ||
              [lower containsString:@"backlightpower"])) continue;

        id v = out[k];
        if ([v isKindOfClass:[NSArray class]]) {
            NSNumber *mx = INSMaxNumberInArray(v);
            if (mx) {
                NSMutableArray *m = [v mutableCopy];
                for (NSUInteger i = 0; i < m.count; i++) m[i] = mx;
                out[k] = m;
            }
        }
    }

    // ② 无条件声明「不支持 CPMS」
    out[@"expectsCPMSSupport"] = @0;

    // ③ 收集候选：maxThermalPower / minThermalPower / BacklightPower 数组最大值
    NSInteger floor = InsulationBacklightThermalPowerFloor();
    NSMutableArray *cands = [NSMutableArray array];

    NSNumber *mx = INSNumberFromObject(out[@"maxThermalPower"]);
    NSNumber *mn = INSNumberFromObject(out[@"minThermalPower"]);
    if (mx) [cands addObject:mx];
    if (mn) [cands addObject:mn];

    id bp = out[@"BacklightPower"];
    if ([bp isKindOfClass:[NSArray class]]) {
        NSNumber *v = INSNumberFromObject(INSMaxNumberInArray(bp));
        if (v) {
            [cands addObject:v];
            InsulationNoteComponentPowerCandidate((int)v.integerValue);
        }
    }

    // ④ 取最大，再与 floor 取最大
    NSInteger best = 0;
    for (NSNumber *n in cands) best = MAX(best, (NSInteger)n.integerValue);
    best = MAX(best, floor);

    // ⑤ 两个键写成同一个值
    out[@"maxThermalPower"] = @(best);
    out[@"minThermalPower"] = @(best);
    return out;
}

#pragma mark - 值变换

static id INSTransformValue(NSString *key, id value) {
    if (![key isKindOfClass:[NSString class]]) return value;  // 顶层 key 为 nil
    NSString *lower = [key lowercaseString];

    // ── 主分支：归零 ───────────────────────────────────────────────
    if (INSContainsAny(lower, ZeroKeywords())) {
        if ([value isKindOfClass:[NSNumber class]]) return @0;

        if ([value isKindOfClass:[NSString class]]) {
            return INSNumberFromObject(value) ? @"0" : value;
        }

        if ([value isKindOfClass:[NSArray class]]) {
            NSMutableArray *m = [value mutableCopy];
            BOOL changed = NO;
            for (NSUInteger i = 0; i < m.count; i++) {
                id e = m[i];
                if ([e isKindOfClass:[NSNumber class]]) {
                    m[i] = @0;
                    changed = YES;
                } else if ([e isKindOfClass:[NSString class]]) {
                    if (INSNumberFromObject(e)) {
                        m[i] = @"0";
                        changed = YES;
                    }
                }
            }
            return changed ? m : value;
        }
        return value;
    }

    // ── 次分支：功率类键抬到 50000 下限 ───────────────────────────
    BOOL powerLike = [lower containsString:@"power"] ||
                     [lower containsString:@"dvd1"] ||
                     [lower containsString:@"sgx"];
    if (powerLike &&
        INSContainsAny(lower, RangeKeywords()) &&
        ![lower containsString:@"powersave"] &&
        ![lower containsString:@"lowpower"]) {

        NSInteger limit = (NSInteger)InsulationUnrestrictedPowerLimit();  // 50000

        NSNumber *n = INSNumberFromObject(value);
        if (n) {
            NSInteger v = MAX((NSInteger)n.integerValue, limit);
            NSNumber *out = @(v);
            return [value isKindOfClass:[NSString class]] ? out.stringValue : out;
        }

        if ([value isKindOfClass:[NSArray class]]) {
            NSMutableArray *m = [value mutableCopy];
            BOOL changed = NO;
            for (NSUInteger i = 0; i < m.count; i++) {
                NSNumber *n2 = INSNumberFromObject(m[i]);
                if (!n2) continue;

                NSInteger v = MAX((NSInteger)n2.integerValue, limit);
                NSNumber *out = @(v);

                // 原实现在这里把 changed 覆盖成「当前元素是否为字符串」，
                // 而不是 |= ，属于源码 bug，这里保持一致
                changed = [m[i] isKindOfClass:[NSString class]];
                m[i] = changed ? out.stringValue : out;
            }
            if (changed) return m;
        }
        return value;
    }

    return value;
}

#pragma mark - 递归

static id INSPatchValue(id value, NSString *key) {
    // 字典
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *out = [value mutableCopy];
        for (id k in [[out allKeys] copy]) {
            NSString *kstr = [k isKindOfClass:[NSString class]] ? (NSString *)k : nil;
            id patched = INSPatchValue(out[k], kstr);
            if (InsulationAggressiveFullPowerEnabled())
                patched = INSTransformValue(kstr, patched);
            out[k] = patched ?: [NSNull null];
        }

        BOOL backlight = [key.lowercaseString containsString:@"backlight"];
        if (!backlight) {
            for (id k in out) {
                if (![k isKindOfClass:[NSString class]]) continue;
                NSString *lk = [(NSString *)k lowercaseString];
                if ([lk containsString:@"brightness"] || [lk containsString:@"backlightpower"]) {
                    backlight = YES;
                    break;
                }
            }
        }
        if (backlight) return INSBacklightFixup(out);
        return out;
    }

    // 数组
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [value mutableCopy];
        for (NSUInteger i = 0; i < out.count; i++) {
            id patched = INSPatchValue(out[i], key);
            out[i] = patched ?: [NSNull null];
        }
        if (InsulationAggressiveFullPowerEnabled())
            return INSTransformValue(key, out);
        return out;
    }

    // 标量
    if (InsulationAggressiveFullPowerEnabled())
        return INSTransformValue(key, value);
    return value;
}

#pragma mark - 入口

NSDictionary *InsulationPatchThermalPlist(NSDictionary *plist) {
    if (!InsulationThermalDimmingBypassActive()) return plist;

    @try {
    id patched = INSPatchValue(plist, nil);
    if (![patched isKindOfClass:[NSDictionary class]]) return plist;
    // 最后一步是 CFDictionaryCreateCopy
    CFDictionaryRef copy = CFDictionaryCreateCopy(kCFAllocatorDefault,
                                                  (__bridge CFDictionaryRef)patched);
    return copy ? CFBridgingRelease(copy) : patched;
    } @catch (NSException *e) {
        // 唯一一处日志
        NSLog(@"insulation thermal manager dim patch exception: %@", e);
        return plist;
    }
}
