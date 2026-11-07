#ifndef STUB_DYLD_H
#define STUB_DYLD_H
#include <objc/objc.h>
struct mach_header;
uint32_t _dyld_image_count(void);
const char *_dyld_get_image_name(uint32_t);
void _dyld_register_func_for_add_image(void (*)(const struct mach_header *, intptr_t));
#endif
