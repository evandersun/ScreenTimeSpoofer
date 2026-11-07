#ifndef STUB_UIKIT_H
#define STUB_UIKIT_H
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

/* 只声明真正用到的选择器；全部走消息发送，不访问 ivar，不存在布局风险 */

@class UINavigationController;

@interface UIColor : NSObject
+ (UIColor *)whiteColor;
+ (UIColor *)lightGrayColor;
+ (UIColor *)darkGrayColor;
+ (UIColor *)systemBlueColor;
+ (UIColor *)systemGreenColor;
+ (UIColor *)systemOrangeColor;
+ (UIColor *)systemPurpleColor;
+ (UIColor *)secondarySystemBackgroundColor;
@end

@interface UIFont : NSObject
+ (UIFont *)systemFontOfSize:(CGFloat)size;
+ (UIFont *)boldSystemFontOfSize:(CGFloat)size;
@end

@interface UIResponder : NSObject
- (BOOL)resignFirstResponder;
- (BOOL)becomeFirstResponder;
@end

/* 只用来发 prefs:/App-Prefs: 深链，不访问任何 ivar */
@interface UIApplication : UIResponder
+ (UIApplication *)sharedApplication;
@property (nonatomic, weak) id delegate;
- (BOOL)canOpenURL:(NSURL *)url;
- (BOOL)openURL:(NSURL *)url;
- (void)openURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(void (^)(BOOL success))completion;
@end

/* Preferences 的 AppDelegate 直接处理 prefs: URL 的方法（进程内导航用）。
   只声明给编译器看，运行时用 respondsToSelector 探测，绝不硬调。 */
@interface NSObject (STSPrefsURLHandling)
- (BOOL)application:(id)app openURL:(id)url options:(id)options;
- (BOOL)application:(id)app openURL:(id)url sourceApplication:(id)src annotation:(id)note;
- (BOOL)application:(id)app openURL:(id)url;
- (BOOL)application:(id)app handleOpenURL:(id)url;
@end

@interface UIView : UIResponder
- (instancetype)initWithFrame:(CGRect)frame;
- (void)addSubview:(UIView *)v;
@property (nonatomic) CGRect frame;
@property (nonatomic) CGRect bounds;
@property (nonatomic, strong) UIColor *backgroundColor;
@property (nonatomic, readonly) NSArray *subviews;
@property (nonatomic, copy) NSString *accessibilityLabel;
@property (nonatomic) NSInteger tag;
- (BOOL)endEditing:(BOOL)force;
@end

@interface UIControl : UIView
@property (nonatomic, getter=isEnabled) BOOL enabled;
@end

@interface UILabel : UIView
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) UIColor *textColor;
@property (nonatomic, strong) UIFont *font;
@property (nonatomic) NSInteger textAlignment;
@property (nonatomic) NSInteger numberOfLines;
@end

@interface UITextField : UIControl
- (instancetype)initWithFrame:(CGRect)frame;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *placeholder;
@property (nonatomic, strong) UIFont *font;
@property (nonatomic) NSInteger keyboardType;
@property (nonatomic) NSInteger borderStyle;
@property (nonatomic) NSInteger textAlignment;
@property (nonatomic, weak) id delegate;
@end

@interface UIButton : UIControl
- (instancetype)initWithFrame:(CGRect)frame;
@property (nonatomic, readonly) UILabel *titleLabel;
- (void)setTitle:(NSString *)t forState:(NSUInteger)state;
- (void)setTitleColor:(UIColor *)c forState:(NSUInteger)state;
- (void)addTarget:(id)target action:(SEL)action forControlEvents:(NSUInteger)events;
@end

@protocol UITextFieldDelegate <NSObject>
@end

/* 桩头签名只给编译器看；ObjC 运行时按 selector 名派发，参数类型宽松无害 */
@protocol UITableViewDataSource <NSObject>
- (id)tableView:(id)tv cellForRowAtIndexPath:(id)ip;
@end
@protocol UITableViewDelegate <NSObject>
- (void)tableView:(id)tv didSelectRowAtIndexPath:(id)ip;
@end

@interface UITableViewCell : UIView
- (instancetype)initWithStyle:(NSInteger)style reuseIdentifier:(NSString *)rid;
@property (nonatomic, readonly) UILabel *textLabel;
@property (nonatomic, strong) UIView *accessoryView;
@property (nonatomic, readonly) UIView *contentView;
@property (nonatomic) NSInteger selectionStyle;
@end

@interface UITableView : UIView
@property (nonatomic) BOOL allowsSelection;
@property (nonatomic, strong) UIView *tableFooterView;
@property (nonatomic, weak) id dataSource;
@property (nonatomic, weak) id delegate;
@property (nonatomic, readonly) NSArray *visibleCells;
- (NSInteger)numberOfSections;
- (NSArray *)indexPathsForVisibleRows;
- (NSInteger)numberOfRowsInSection:(NSInteger)section;
- (UITableViewCell *)cellForRowAtIndexPath:(NSIndexPath *)ip;
- (NSIndexPath *)indexPathForCell:(UITableViewCell *)cell;
- (void)selectRowAtIndexPath:(NSIndexPath *)ip animated:(BOOL)animated scrollPosition:(NSInteger)scrollPosition;
- (void)reloadData;
- (void)deselectRowAtIndexPath:(NSIndexPath *)ip animated:(BOOL)animated;
@end

@interface UIViewController : UIResponder
- (void)viewDidLoad;
- (void)viewWillAppear:(BOOL)animated;
- (void)viewDidAppear:(BOOL)animated;
- (void)viewDidLayoutSubviews;
- (void)presentViewController:(UIViewController *)vc animated:(BOOL)flag completion:(void (^)(void))completion;
@property (nonatomic, strong) UIView *view;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, readonly) UINavigationController *navigationController;
@end

@interface UINavigationController : UIViewController
@property (nonatomic, readonly) NSArray *viewControllers;
- (NSArray *)popToRootViewControllerAnimated:(BOOL)animated;
- (void)pushViewController:(UIViewController *)vc animated:(BOOL)animated;
@end

@interface UITableViewController : UIViewController
@property (nonatomic, strong) UITableView *tableView;
@end

@interface UIAlertAction : NSObject
+ (instancetype)actionWithTitle:(NSString *)title style:(NSInteger)style handler:(void (^)(id))handler;
@end

@interface UIAlertController : UIViewController
+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(NSInteger)style;
- (void)addAction:(UIAlertAction *)action;
@end

/* UIAlertController present 失败时的老式兜底（deprecated，但 iOS 上仍可用） */
@interface UIAlertView : NSObject
- (instancetype)initWithTitle:(NSString *)title message:(NSString *)message delegate:(id)delegate cancelButtonTitle:(NSString *)cancel otherButtonTitles:(NSString *)other, ...;
- (void)show;
@end

@interface NSIndexPath (UIKit)
+ (NSIndexPath *)indexPathForRow:(NSInteger)row inSection:(NSInteger)section;
@property (nonatomic, readonly) NSInteger row;
@property (nonatomic, readonly) NSInteger section;
@end

@interface CALayer : NSObject
@property (nonatomic) double cornerRadius;
@property (nonatomic) BOOL masksToBounds;
@end

@interface UIView (STSLayer)
@property (nonatomic, readonly) CALayer *layer;
@end
#endif
