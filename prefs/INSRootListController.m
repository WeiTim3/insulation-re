//
//  INSRootListController.m  —  设置页
//
#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>
#import <notify.h>
#import <objc/message.h>
#import <dlfcn.h>

extern NSString *jbroot(NSString *path) __asm("__Z6jbrootP8NSString");

static void INSPostDarwin(NSString *name) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)name, NULL, NULL, true);
}

static void INSPostRuntimeState(uint8_t mode, uint8_t flags) {
    int token = 0;
    if (notify_register_check("com.be-huge.insulation.runtimeState", &token) != 0) return;
    notify_set_state(token, (0x5355494EULL << 32) | ((uint64_t)mode << 8) | flags);
    notify_post("com.be-huge.insulation.runtimeState");
    notify_cancel(token);
}

static void INSPostApplyNotifications(void) {
    INSPostRuntimeState(0, 0);
    INSPostDarwin(@"com.be-huge.insulation-executePuppetEvent");
}

static void INSPostRestartNotifications(void) {
    INSPostDarwin(@"com.be-huge.insulation-restartThermalMonitor");
}

static NSString *INSInsulationPrefsPlistPath(void) {
    NSString *p = @"/var/mobile/Library/Preferences/com.be-huge.insulation-prefs.plist";
    NSString *r = jbroot(p);
    return r.length ? r : p;
}


#pragma mark - 自定义单元格：左侧标题 + 右侧数值

@interface INSValueCell : PSTableCell
@property (nonatomic, strong) UILabel *valueLabel;
@end

@implementation INSValueCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.textLabel.textColor = [UIColor labelColor];
        _valueLabel = [[UILabel alloc] init];
        _valueLabel.textAlignment = NSTextAlignmentRight;
        _valueLabel.font = [UIFont systemFontOfSize:17];
        _valueLabel.textColor = [UIColor secondaryLabelColor];
        _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_valueLabel];
        [NSLayoutConstraint activateConstraints:@[
            [_valueLabel.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
            [_valueLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor]
        ]];
    }
    return self;
}

// PSStaticTextCell 会在布局时把标题重新描成灰色，这里每次布局后强制覆盖
- (void)layoutSubviews {
    [super layoutSubviews];
    self.textLabel.textColor = [UIColor labelColor];
    self.valueLabel.textColor = [UIColor secondaryLabelColor];
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    self.textLabel.textColor = [UIColor labelColor];
    self.valueLabel.textColor = [UIColor secondaryLabelColor];
}
@end

static double INSReadBrightnessNits(void) {
    static id client = nil;
    static BOOL tried = NO;
    if (!tried) {
        tried = YES;
        void *h = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY);
        Class c = h ? NSClassFromString(@"BrightnessSystemClient") : nil;
        if (c) client = [[c alloc] init];
    }
    if (!client) return -1;
    SEL sel = sel_registerName("copyPropertyForKey:");
    id (*fn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
    id val = fn(client, sel, @"DisplayBrightness");
    if (![val isKindOfClass:[NSDictionary class]]) return -1;
    id nits = ((NSDictionary *)val)[@"Nits"];
    if (![nits isKindOfClass:[NSNumber class]]) {
        nits = ((NSDictionary *)val)[@"NitsPhysical"];
    }
    return [nits isKindOfClass:[NSNumber class]] ? [nits doubleValue] : -1;
}

@interface RootListController : PSListController
@property (nonatomic, weak) UIControl *cpuModeMenuOverlay;  // objc_storeWeak
@property (nonatomic, strong) NSTimer *freqTimer;
@property (nonatomic, strong) PSSpecifier *freqPSpec;
@property (nonatomic, strong) PSSpecifier *freqESpec;
@property (nonatomic, strong) PSSpecifier *nitsSpec;
@end

@implementation RootListController

#pragma mark - specifiers

- (NSArray *)specifiers {
    NSArray *s = [self valueForKey:@"_specifiers"];
    if (!s) {
        s = [self loadSpecifiersFromPlistName:@"Root" target:self];

        NSMutableArray *out = [NSMutableArray arrayWithArray:s];
        NSUInteger insertAt = out.count;
        for (NSUInteger i = 0; i < out.count; i++) {
            PSSpecifier *sp = out[i];
            id cell = [sp propertyForKey:@"cell"];
            if ([cell isEqual:NSClassFromString(@"PSGroupCell")] || [cell isEqual:@"PSGroupCell"]) {
                // 第一组（CPU 模式）结束后插入
                insertAt = i + 1;
                for (NSUInteger j = i + 1; j < out.count; j++) {
                    id c2 = [out[j] propertyForKey:@"cell"];
                    if ([c2 isEqual:NSClassFromString(@"PSGroupCell")] || [c2 isEqual:@"PSGroupCell"]) {
                        insertAt = j;
                        break;
                    }
                }
                break;
            }
        }

        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"CPU 频率"];
        self.freqPSpec  = [PSSpecifier preferenceSpecifierNamed:@"CPU 大核频率" target:self set:NULL get:NULL detail:NULL cell:PSStaticTextCell edit:NULL];
        self.freqESpec  = [PSSpecifier preferenceSpecifierNamed:@"CPU 小核频率" target:self set:NULL get:NULL detail:NULL cell:PSStaticTextCell edit:NULL];
        self.nitsSpec   = [PSSpecifier preferenceSpecifierNamed:@"屏幕当前亮度" target:self set:NULL get:NULL detail:NULL cell:PSStaticTextCell edit:NULL];
        for (PSSpecifier *sp in @[self.freqPSpec, self.freqESpec, self.nitsSpec])
            [sp setProperty:[INSValueCell class] forKey:@"cellClass"];
        PSSpecifier *refresh = [PSSpecifier preferenceSpecifierNamed:@"刷新当前数据"
                                                              target:self
                                                                 set:NULL
                                                                 get:NULL
                                                              detail:NULL
                                                                cell:PSButtonCell
                                                                edit:NULL];
        refresh->action = @selector(refreshTapped:);

        [out insertObjects:@[group, self.freqPSpec, self.freqESpec, self.nitsSpec, refresh]
                 atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(insertAt, 5)]];
        s = out;
        [self setValue:s forKey:@"_specifiers"];
    }
    return s;
}

#pragma mark - 数据刷新

- (void)refreshTapped:(id)sender {
    [self updateLiveValues];
}

- (void)updateLiveValues {
    int token = 0;
    unsigned p = 0, e = 0;
    if (notify_register_check("com.be-huge.insulation-freq", &token) == 0) {
        uint64_t st = 0;
        if (notify_get_state(token, &st) == 0) {
            p = (unsigned)((st >> 16) & 0xFFFF);
            e = (unsigned)(st & 0xFFFF);
        }
        notify_cancel(token);
    }

    INSValueCell *pc = (INSValueCell *)[self cachedCellForSpecifier:self.freqPSpec];
    INSValueCell *ec = (INSValueCell *)[self cachedCellForSpecifier:self.freqESpec];
    INSValueCell *nc = (INSValueCell *)[self cachedCellForSpecifier:self.nitsSpec];
    if ([pc isKindOfClass:[INSValueCell class]])
        pc.valueLabel.text = p ? [NSString stringWithFormat:@"%u MHz", p] : @"—";
    if ([ec isKindOfClass:[INSValueCell class]])
        ec.valueLabel.text = e ? [NSString stringWithFormat:@"%u MHz", e] : @"—";
    if ([nc isKindOfClass:[INSValueCell class]]) {
        double nits = INSReadBrightnessNits();
        nc.valueLabel.text = nits > 0 ? [NSString stringWithFormat:@"%.0f nits", nits] : @"—";
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateLiveValues];
    if (!self.freqTimer) {
        self.freqTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                         target:self
                                                       selector:@selector(updateLiveValues)
                                                       userInfo:nil
                                                        repeats:YES];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.freqTimer invalidate];
    self.freqTimer = nil;
}

#pragma mark - 偏好读写

- (NSDictionary *)insulation_prefsDict {
    return [NSDictionary dictionaryWithContentsOfFile:INSInsulationPrefsPlistPath()];
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSDictionary *props = [spec properties];
    NSString *key = [props objectForKey:@"key"];
    id dflt = [props objectForKey:@"default"];
    id v = key ? [self insulation_prefsDict][key] : nil;
    return v ?: dflt;
}

- (NSString *)currentCPUMode {
    NSString *m = [self insulation_prefsDict][@"thermalPowerMode"];
    return m.length ? m : @"off";
}

- (void)insulation_writePreferenceValue:(id)value forKey:(NSString *)key {
    if (!key.length) return;
    NSString *path = INSInsulationPrefsPlistPath();
    NSMutableDictionary *d = [self insulation_prefsDict].mutableCopy ?: [NSMutableDictionary dictionary];
    if (value) d[key] = value;
    else [d removeObjectForKey:key];
    [d writeToFile:path atomically:YES];

    if ([key hasPrefix:@"thermal"]) INSPostApplyNotifications();
    // 不再为模式切换重启 thermalmonitord：
    // runtimeState 通知会重新应用偏好，重启只会让频率读数短暂归零（显示成 "—"）

}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    [self insulation_writePreferenceValue:value forKey:[spec propertyForKey:@"key"]];
}

#pragma mark - 表格

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:ip];
    NSString *title = cell.textLabel.text;  // -
    if ([title isEqualToString:@"CPU 模式"]) {
        [tableView deselectRowAtIndexPath:ip animated:YES];
        [self showCPUModeMenuFromCell:cell];
        return;
    }
    [super tableView:tableView didSelectRowAtIndexPath:ip];
}

#pragma mark - 配色

- (UIColor *)adaptiveColorWithLight:(UIColor *)light dark:(UIColor *)dark {
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
            return t.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
        }];
    }
    return light;
}

#pragma mark - 菜单

- (void)showCPUModeMenuFromCell:(UITableViewCell *)cell {
    [self dismissCPUModeMenu];
    UIView *view = self.view;
    if (!view) return;

    UIControl *overlay = [[UIControl alloc] initWithFrame:view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor clearColor];
    [overlay addTarget:self action:@selector(dismissCPUModeMenu)
      forControlEvents:UIControlEventTouchDown];

    CGFloat width = MAX(view.bounds.size.width * 0.56, 260.0);
    width = MIN(width, view.bounds.size.width - 28.0);

    NSArray *values = @[@"off", @"lowPower", @"fullPower"];
    NSArray *titles = @[@"苹果原生温控", @"模拟低电频率", @"防止温控降频"];
    const CGFloat rowH = 47.0;
    CGFloat height = values.count * rowH;

    CGRect cellRect = [cell convertRect:cell.bounds toView:view];
    CGFloat x = MAX(CGRectGetMaxX(cellRect) - width - 14.0, 14.0);
    x = MIN(x, view.bounds.size.width - width - 14.0);
    CGFloat y = MAX(CGRectGetMaxY(cellRect) + 8.0, 12.0);
    y = MIN(y, view.bounds.size.height - height - 12.0);

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(x, y, width, height)];
    panel.backgroundColor = [UIColor clearColor];
    panel.layer.shadowColor = [UIColor blackColor].CGColor;
    panel.layer.shadowOpacity = 0.25f;
    panel.layer.shadowRadius = 20.0;
    panel.layer.shadowOffset = CGSizeMake(0, 8);
    panel.layer.shadowPath =
        [UIBezierPath bezierPathWithRoundedRect:panel.bounds cornerRadius:14.0].CGPath;

    UIView *content = [[UIView alloc] initWithFrame:panel.bounds];
    content.backgroundColor = [self adaptiveColorWithLight:[UIColor colorWithWhite:0.98 alpha:0.86]
                                                     dark:[UIColor colorWithWhite:0.12 alpha:0.95]];
    content.layer.cornerRadius = 14.0;
    content.layer.masksToBounds = YES;
    if (@available(iOS 13.0, *)) content.layer.cornerCurve = kCACornerCurveContinuous;

    UIVisualEffectView *blur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    blur.frame = content.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [content insertSubview:blur atIndex:0];
    [panel addSubview:content];

    UIColor *textColor = [self adaptiveColorWithLight:[UIColor blackColor]
                                                dark:[UIColor whiteColor]];
    UIColor *accent = [self adaptiveColorWithLight:[UIColor colorWithRed:0.0 green:0.36 blue:1.0 alpha:1.0]
                                             dark:[UIColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:1.0]];
    NSString *cur = [self currentCPUMode];

    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
        row.frame = CGRectMake(0, i * rowH, width, rowH);
        row.tag = (NSInteger)i;
        row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        row.accessibilityLabel = titles[i];
        [row addTarget:self action:@selector(cpuModeMenuItemTapped:)
      forControlEvents:UIControlEventTouchUpInside];
        [panel addSubview:row];

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(18.0, i * rowH, width - 66.0, rowH)];
        label.text = titles[i];
        label.textColor = textColor;
        label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
        label.userInteractionEnabled = NO;
        [panel addSubview:label];

        if ([values[i] isEqualToString:cur]) {
            UILabel *check = [[UILabel alloc] initWithFrame:CGRectMake(width - 39.0, i * rowH, 22.0, rowH)];
            check.text = @"✓";
            check.font = [UIFont systemFontOfSize:19];
            check.textColor = accent;
            [panel addSubview:check];
        }
    }

    [overlay addSubview:panel];
    [view addSubview:overlay];
    self.cpuModeMenuOverlay = overlay;

    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
    [UIView animateWithDuration:0.16 animations:^{
        panel.transform = CGAffineTransformIdentity;
    }];
}

- (void)cpuModeMenuItemTapped:(UIButton *)sender {
    NSArray *values = @[@"off", @"lowPower", @"fullPower"];
    NSInteger i = sender.tag;
    if (i < 0 || i >= (NSInteger)values.count) return;  // -
    [self insulation_writePreferenceValue:values[i] forKey:@"thermalPowerMode"];
    [self dismissCPUModeMenu];

    // 只刷新「CPU 模式」这一行，避免整页重建（会闪一下、滚动位置也会跳）
    PSSpecifier *modeSpec = nil;
    for (PSSpecifier *sp in [self specifiers]) {
        if ([[sp propertyForKey:@"key"] isEqualToString:@"thermalPowerMode"]) { modeSpec = sp; break; }
    }
    if (modeSpec) [self reloadSpecifier:modeSpec];
    else [self reloadSpecifiers];
}

- (void)dismissCPUModeMenu {
    UIControl *overlay = self.cpuModeMenuOverlay;
    if (!overlay) return;
    self.cpuModeMenuOverlay = nil;
    // alpha 淡出 0.12s，completion 里移除
    [UIView animateWithDuration:0.12 animations:^{
        overlay.alpha = 0.0;
    } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

@end
