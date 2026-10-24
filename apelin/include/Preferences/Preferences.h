// 构建用 Preferences.framework 私有头。
//
// 本机 iPhoneOS SDK 只带 Preferences.tbd，没有头文件，而 prefs/INSRootListController.m
// 需要 <Preferences/Preferences.h>。这里只声明源码实际用到的部分，语义对齐 Theos 的
// theos/headers（PSSpecifier 只声明 @public SEL action 这一个 ivar，源码里的
// `refresh->action = @selector(...)` 依赖它）。
#pragma once

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, PSCellType) {
    PSGroupCell,
    PSLinkCell,
    PSLinkListCell,
    PSListItemCell,
    PSTitleValueCell,
    PSSliderCell,
    PSSwitchCell,
    PSStaticTextCell,
    PSEditTextCell,
    PSSegmentCell,
    PSGiantIconCell,
    PSGiantCell,
    PSSecureEditTextCell,
    PSButtonCell,
    PSEditTextViewCell,
    PSSpinnerCell
};

@interface PSSpecifier : NSObject {
@public
    SEL action;
}

+ (instancetype)preferenceSpecifierNamed:(NSString *)identifier
                                  target:(id)target
                                     set:(SEL)set
                                     get:(SEL)get
                                  detail:(Class)detail
                                    cell:(PSCellType)cellType
                                    edit:(Class)edit;
+ (instancetype)emptyGroupSpecifier;
+ (instancetype)groupSpecifierWithName:(NSString *)name;

@property (nonatomic, retain) id target;
@property (nonatomic, retain) NSString *name;
@property (nonatomic, retain) NSString *identifier;
@property (nonatomic) PSCellType cellType;

@property (nonatomic, retain) NSMutableDictionary *properties;
- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)property forKey:(NSString *)key;
- (void)removePropertyForKey:(NSString *)key;

@end

@interface PSViewController : UIViewController
@end

@interface PSListController : PSViewController <UITableViewDelegate, UITableViewDataSource>

@property (nonatomic, retain) UITableView *table;
@property (nonatomic, retain) UITableView *tableView;

- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (NSArray *)specifiers;
- (void)reloadSpecifiers;
- (void)reloadSpecifier:(PSSpecifier *)specifier;
- (UITableViewCell *)cachedCellForSpecifier:(PSSpecifier *)specifier;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;

@end
