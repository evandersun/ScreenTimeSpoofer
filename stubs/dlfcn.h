#ifndef STUB_DLFCN_H
#define STUB_DLFCN_H
#define RTLD_NOW 0x2
void *dlopen(const char *, int);
#endif
