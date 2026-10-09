#import "YTEQSwizzle.h"

void YTEQSwizzle(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (cls == Nil || selector == NULL || replacement == NULL) return;

    // Walk the hierarchy so an implementation inherited from a superclass is found.
    for (Class c = cls; c != Nil; c = class_getSuperclass(c)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(c, &count);
        if (methods == NULL) continue;

        BOOL found = NO;
        const char *types = NULL;
        for (unsigned int i = 0; i < count; i++) {
            if (method_getName(methods[i]) != selector) continue;
            // Record what we are replacing.
            if (original != NULL) *original = method_getImplementation(methods[i]);
            types = method_getTypeEncoding(methods[i]);
            found = YES;
            break;
        }

        if (found) {
            if (c == cls) {
                method_setImplementation(class_getInstanceMethod(cls, selector), replacement);
            } else {
                // Inherited: add our implementation to the subclass directly.
                class_addMethod(cls, selector, replacement, types ?: "v@:");
            }
            free(methods);
            return;
        }
        free(methods);
    }

    // Selector not implemented anywhere in the chain: define it.
    class_addMethod(cls, selector, replacement, "v@:");
}

BOOL YTEQSwizzleIfPresent(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (cls == Nil || selector == NULL || replacement == NULL) return NO;
    if (class_getInstanceMethod(cls, selector) == NULL) return NO;
    YTEQSwizzle(cls, selector, replacement, original);
    return YES;
}
