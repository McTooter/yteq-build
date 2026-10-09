// YTEQSwizzle.h — runtime method swizzling helpers.
//
// Ported from the hooking approach used by VolumeBoostYT.dylib, which does NOT use
// Substrate/ElleKit. It walks the class hierarchy with the plain Objective-C runtime
// (class_copyMethodList / method_setImplementation / class_addMethod) so the tweak
// works when injected as a bare dylib by Sideloadly, with no tweak framework present.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

// Swizzles +selector on cls with replacement.
//
// Walks up the superclass chain (matching VolumeBoostYT's helper at 0x4348) so that a
// method inherited from a superclass is found and can still be replaced. If the
// implementation is only found on a superclass, it is added directly to cls so that
// later -class_addMethod calls by the host app cannot clobber us.
//
// `original` (when non-NULL) receives the previous implementation so the replacement can
// call through. It is only written when a previous implementation was found; a class that
// declares the selector without an implementation (or does not declare it at all) leaves
// *original untouched, so callers must check respondsToSelector: before calling through.
FOUNDATION_EXPORT void YTEQSwizzle(Class cls, SEL selector, IMP replacement,
                                   IMP *_Nullable _Nullable original);

// Swizzles +selector only if cls (or a superclass) actually implements it. Returns YES if
// the swizzle was installed. Used for the private AVFoundation/UIKit selectors, which are
// only present on some OS versions.
FOUNDATION_EXPORT BOOL YTEQSwizzleIfPresent(Class cls, SEL selector, IMP replacement,
                                            IMP *_Nullable _Nullable original);

NS_ASSUME_NONNULL_END
