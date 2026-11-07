#ifndef STUB_PREFS_H
#define STUB_PREFS_H
#import <UIKit/UIKit.h>

@interface PSSpecifier : NSObject
+ (PSSpecifier *)groupSpecifierWithName:(NSString *)name;
+ (PSSpecifier *)preferenceSpecifierNamed:(NSString *)name target:(id)target set:(SEL)set get:(SEL)get detail:(Class)detail cell:(long)cell edit:(Class)edit;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
- (NSString *)name;
@property (nonatomic) SEL action;
@property (nonatomic) id target;
@end

@interface PSListController : UITableViewController {
    NSArray *_specifiers;
}
- (instancetype)initForContentSize:(CGSize)size;
- (NSArray *)specifiers;
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target bundle:(NSBundle *)bundle;
- (NSArray *)specifiersFromPlist:(NSDictionary *)plist;
- (void)reloadSpecifiers;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
@end
#endif
