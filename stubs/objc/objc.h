#ifndef STUB_OBJC_H
#define STUB_OBJC_H
typedef __SIZE_TYPE__ size_t;
typedef long intptr_t;
typedef unsigned int uint32_t;
typedef long time_t;
typedef long long int64_t;
typedef unsigned long long uint64_t;
typedef long long intptr_t_unused;
#define NULL ((void *)0)
#define nil ((id)0)
/* arm64 iOS 的 OBJC_BOOL_IS_BOOL=1，BOOL 必须是 C99 bool，不能按旧 armv7 写成 signed char。 */
typedef _Bool BOOL;
#define YES ((BOOL)1)
#define NO ((BOOL)0)
typedef struct objc_object { struct objc_class *isa; } *id;
typedef struct objc_class *Class;
typedef struct objc_selector *SEL;
typedef void (*IMP)(void);
#endif
