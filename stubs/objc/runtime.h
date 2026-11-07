#ifndef STUB_RUNTIME_H
#define STUB_RUNTIME_H
#include <objc/objc.h>
struct objc_method; typedef struct objc_method *Method;
Method class_getInstanceMethod(Class, SEL);
void method_getReturnType(Method, char *, size_t);
IMP method_getImplementation(Method);
IMP method_setImplementation(Method, IMP);
IMP imp_implementationWithBlock(id);
Method *class_copyMethodList(Class, unsigned int *);
SEL method_getName(Method);
unsigned int method_getNumberOfArguments(Method);
const char *class_getName(Class);
const char *class_getImageName(Class);
int objc_getClassList(Class *, int);
id objc_getClass(const char *);
const char **objc_copyClassNamesForImage(const char *, unsigned int *);
const char *sel_getName(SEL);
SEL sel_registerName(const char *);
BOOL sel_isEqual(SEL, SEL);
void free(void *);
void *malloc(size_t);
char *strstr(const char *, const char *);
int strncmp(const char *, const char *, size_t);
char *strchr(const char *, int);
#endif
