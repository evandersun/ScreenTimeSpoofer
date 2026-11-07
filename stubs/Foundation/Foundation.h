#ifndef STUB_FOUNDATION_H
#define STUB_FOUNDATION_H
#include <objc/objc.h>

/* --- 基础 --- */
typedef long NSInteger;
typedef unsigned long NSUInteger;
typedef struct { NSUInteger loc; NSUInteger len; } NSRange;
static inline NSRange NSMakeRange(NSUInteger l, NSUInteger n) { NSRange r; r.loc=l; r.len=n; return r; }
typedef NSUInteger NSStringEncoding;
#ifndef MAX
#define MAX(a,b) ((a)>(b)?(a):(b))
#define MIN(a,b) ((a)<(b)?(a):(b))
#endif
#define NS_ENUM(_type,_name) enum _name : _type _name; enum _name : _type
#define NS_OPTIONS(_type,_name) enum _name : _type _name; enum _name : _type

/* --- libSystem / C --- */
extern void NSLog(id fmt, ...);

/* --- CoreFoundation --- */
typedef double CFAbsoluteTime;
extern CFAbsoluteTime CFAbsoluteTimeGetCurrent(void);

/* --- libdispatch --- */
typedef long dispatch_once_t;
typedef unsigned long long dispatch_time_t;
typedef struct dispatch_queue_s *dispatch_queue_t;
#define DISPATCH_TIME_NOW 0ull
#define NSEC_PER_SEC 1000000000ull
extern void dispatch_once(dispatch_once_t *, void (^)(void));
extern void dispatch_async(dispatch_queue_t, void (^)(void));
extern void dispatch_after(dispatch_time_t, dispatch_queue_t, void (^)(void));
/* iOS 16 上 dispatch_get_main_queue 不是可直接解析的 dylib 符号；改用自建串行队列，
   保留声明仅为兼容，不在 tweak 中调用。 */
extern dispatch_queue_t dispatch_get_main_queue(void);
extern dispatch_queue_t dispatch_get_global_queue(long identifier, unsigned long flags);
extern dispatch_queue_t dispatch_queue_create(const char *label, void *attr);
extern dispatch_time_t dispatch_time(dispatch_time_t, long long);

/* --- 协议 --- */
typedef struct { unsigned long state; id *itemsPtr; unsigned long *mutationsPtr; unsigned long extra[5]; } NSFastEnumerationState;
@protocol NSFastEnumeration
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)s objects:(id *)b count:(NSUInteger)l;
@end

@class NSString, NSArray, NSDictionary, NSError;

@protocol NSObject
@end

@interface NSObject <NSObject> {
    /* 必须与真实 iOS SDK 一致：NSObject 的第一个实例变量是 isa。
       缺少它会让编译器把子类 ivar 排到对象偏移 0，初始化时直接覆盖 isa，
       随后任意 objc_msgSend 都可能以随机位置 EXC_BAD_ACCESS。 */
    Class isa;
}
+ (instancetype)alloc;
+ (Class)class;
- (instancetype)init;
- (Class)class;
- (BOOL)isKindOfClass:(Class)c;
- (BOOL)respondsToSelector:(SEL)sel;
- (id)copy;
- (id)mutableCopy;
/* 0.6.2：pop 回设置首页后，延迟到下一 runloop 再模拟点击（纯 ObjC，不引入 libdispatch 依赖） */
- (void)performSelector:(SEL)aSelector withObject:(id)anArgument afterDelay:(double)delay;
@end

@interface NSString : NSObject
+ (instancetype)stringWithFormat:(NSString *)fmt, ...;
+ (instancetype)stringWithUTF8String:(const char *)cstr;
- (const char *)UTF8String;
- (NSString *)stringByAppendingString:(NSString *)s;
- (NSString *)stringByDeletingLastPathComponent;
- (NSString *)lowercaseString;
- (NSUInteger)length;
- (BOOL)isEqualToString:(NSString *)s;
- (BOOL)hasPrefix:(NSString *)s;
- (BOOL)containsString:(NSString *)s;
- (BOOL)writeToFile:(NSString *)p atomically:(BOOL)f encoding:(NSStringEncoding)e error:(NSError **)err;
- (double)doubleValue;
@end

/* 设置深链跳转用：只需要能构造 URL 对象 */
@interface NSURL : NSObject
+ (instancetype)URLWithString:(NSString *)s;
@property (nonatomic, readonly) NSString *absoluteString;
@end

@interface NSMutableString : NSString
+ (instancetype)string;
- (void)appendFormat:(NSString *)fmt, ...;
- (void)appendString:(NSString *)s;
@end

@interface NSNumber : NSObject
+ (NSNumber *)numberWithDouble:(double)d;
+ (NSNumber *)numberWithInt:(int)i;
+ (NSNumber *)numberWithBool:(BOOL)b;
+ (NSNumber *)numberWithLong:(long)l;
- (double)doubleValue;
- (int)intValue;
- (BOOL)boolValue;
- (NSString *)stringValue;
@end

@interface NSArray<__covariant T> : NSObject <NSFastEnumeration>
+ (instancetype)arrayWithObjects:(const id [])objects count:(NSUInteger)cnt;
- (NSUInteger)count;
- (id)objectAtIndex:(NSUInteger)idx;
- (id)firstObject;
- (NSString *)componentsJoinedByString:(NSString *)sep;
- (void)removeObjectsInRange:(NSRange)r;
@end

@interface NSDictionary<K, V> : NSObject
+ (instancetype)dictionaryWithObjects:(const id [])objects forKeys:(const id [])keys count:(NSUInteger)cnt;
+ (instancetype)dictionaryWithContentsOfFile:(NSString *)path;
- (id)objectForKeyedSubscript:(id)key;
- (id)objectForKey:(id)key;
- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)flag;
@end

@interface NSMutableDictionary<K, V> : NSDictionary<K, V>
- (void)setObject:(id)o forKeyedSubscript:(id)key;
- (void)setObject:(id)o forKey:(id)key;
@end

@interface NSSet<__covariant T> : NSObject <NSFastEnumeration>
+ (instancetype)set;
+ (instancetype)setWithArray:(NSArray *)a;
- (NSUInteger)count;
- (BOOL)containsObject:(id)o;
@end

@interface NSMutableSet<__covariant T> : NSSet<T>
+ (instancetype)set;
- (void)addObject:(id)o;
@end

@interface NSDate : NSObject
+ (instancetype)date;
- (double)timeIntervalSinceReferenceDate;
@end

@interface NSIndexPath : NSObject
@end

@interface NSException : NSObject
- (NSString *)name;
- (NSString *)reason;
@end

@interface NSBundle : NSObject
+ (NSBundle *)mainBundle;
+ (NSBundle *)bundleForClass:(Class)c;
+ (NSBundle *)bundleWithPath:(NSString *)p;
- (NSString *)bundlePath;
- (NSString *)bundleIdentifier;
- (NSString *)pathForResource:(NSString *)name ofType:(NSString *)type;
- (BOOL)load;
@end

@interface NSMutableArray<__covariant T> : NSArray<T>
+ (instancetype)array;
+ (instancetype)arrayWithCapacity:(NSUInteger)n;
- (void)addObject:(id)o;
@end

@interface NSScanner : NSObject
+ (instancetype)scannerWithString:(NSString *)s;
- (BOOL)scanDouble:(double *)d;
- (BOOL)isAtEnd;
@end

@interface NSError : NSObject
@end

@interface NSFileManager : NSObject
+ (NSFileManager *)defaultManager;
- (BOOL)fileExistsAtPath:(NSString *)p;
- (BOOL)createDirectoryAtPath:(NSString *)p withIntermediateDirectories:(BOOL)c attributes:(NSDictionary *)a error:(NSError **)e;
- (NSDictionary *)attributesOfItemAtPath:(NSString *)p error:(NSError **)e;
- (BOOL)setAttributes:(NSDictionary *)a ofItemAtPath:(NSString *)p error:(NSError **)e;
@end

/* NSFileAttributeKey 常量（Foundation 导出的 NSString 常量） */
extern id NSFileModificationDate;
extern id NSFileOwnerAccountID;
extern id NSFileGroupOwnerAccountID;
extern id NSFilePosixPermissions;

extern NSStringEncoding const NSUTF8StringEncoding;

/* --- NSObjCRuntime --- */
extern Class NSClassFromString(NSString *s);
extern NSString *NSStringFromClass(Class c);
extern NSString *NSStringFromSelector(SEL s);
extern SEL NSSelectorFromString(NSString *s);

#endif
