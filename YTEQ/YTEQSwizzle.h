// YTEQSwizzle.h — runtime method swizzling helpers.
//
// Ported from the hooking approach used by VolumeBoostYT.dylib, which does NOT use
// Substrate/ElleKit. It walks the class hierarchy with the plain Objective-C runtime
// (class_copyMethodList / method_setImplementation / class_addMethod) so the tweak works
// when injected as a bare dylib by Sideloadly, with no tweak framework present.
//
// Nullability is deliberately left off these prototypes: Class, SEL and IMP are C runtime
// types rather than objects, and NS_ASSUME_NONNULL here only produces
// -Wnullability-completeness noise.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Swizzles +selector on cls with replacement.
//
// Walks up the superclass chain (matching VolumeBoostYT's helper at 0x4348) so a method
// inherited from a superclass is found and can still be replaced. If the implementation
// only exists on a superclass it is added directly to cls, so a later -class_addMethod by
// the host app cannot silently clobber us.
//
// `original` (when non-NULL) receives the previous implementation so the replacement can
// call through. It is written only when a previous implementation was found; a class that
// merely declares the selector leaves *original untouched, so callers should check
// respondsToSelector: before calling through.
FOUNDATION_EXPORT void YTEQSwizzle(Class cls, SEL selector, IMP replacement, IMP *original);

// Swizzles +selector only if cls (or a superclass) actually implements it. Returns YES if
// the swizzle was installed. Used for private selectors that only exist on some OS
// versions, where a blind swizzle would add a method that is never called.
FOUNDATION_EXPORT BOOL YTEQSwizzleIfPresent(Class cls, SEL selector, IMP replacement,
                                            IMP *original);
