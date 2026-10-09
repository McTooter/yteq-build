#import "YTEQBootstrap.h"
#import "YTEQAudioEngine.h"
#import "YTEQAudioHook.h"
#import "YTEQSwizzle.h"
#import "YTEQPanelViewController.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// ===========================================================================
// How this differs from VolumeBoostYT.dylib, and why it is shaped this way
// ===========================================================================
//
// VolumeBoostYT was reverse engineered for this build. Its shape is:
//
//   * a bare dylib with no Substrate/ElleKit linkage - it hooks with the plain
//     Objective-C runtime (class_addMethod / method_setImplementation walking the
//     superclass chain), so Sideloadly's "inject dylib" is enough to run it;
//   * it returns early unless the host is not com.apple.springboard;
//   * it hooks -setVolume: on AVPlayer, AVAudioPlayer, AVAudioPlayerNode and
//     AVSampleBufferAudioRenderer and multiplies by powf(200, (boost - 1) / 19),
//     which is how it pushes an app past 100% without touching a single sample;
//   * it registers the objects it has seen in an NSHashTable and resets their volume
//     when the setting is switched off;
//   * it injects a settings entry into YouTube through YTSettingsGroupData /
//     YTAppSettingsPresentationData / YTSettingsSectionItemManager, adding a switch via
//     -switchItemWithTitle:titleDescription:accessibilityIdentifier:switchOn:switchBlock:settingItemId:;
//   * it hooks -[UIWindow sendEvent:] for a right-edge pan gesture and shows a floating
//     HUD (YTVolumeHUD) reading "App Vol: NN%".
//
// Everything about how it gets in is kept here: no tweak framework, runtime-only
// hooking, an NSUserDefaults-backed switch, and YouTube's own settings machinery.
//
// What changes is the payload. Scaling one scalar cannot shape a spectrum, so the audio
// side moves to a real biquad cascade on the RemoteIO render callback
// (YTEQAudioHook.m), and the UI becomes a response graph with per-band frequency, gain
// and Q, and a preamp ahead of the cascade.

static NSString * const kYTEQSectionTitle = @"Equalizer";
static const NSInteger kYTEQButtonTag     = 0x59455145; // 'YEQE'

// ---------------------------------------------------------------------------
// Process guard
// ---------------------------------------------------------------------------

// Injected dylibs get loaded into more than one process on a jailbroken device. The
// original tweak guarded on com.apple.springboard for the same reason.
static BOOL YTEQShouldRunInThisProcess(void) {
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
    if (bundle.length == 0) return NO;
    if ([bundle isEqualToString:@"com.apple.springboard"]) return NO;
    if ([bundle isEqualToString:@"com.apple.Preferences"]) return NO;
    if ([bundle hasPrefix:@"com.apple.springboard."]) return NO;
    return YES;
}

// ---------------------------------------------------------------------------
// YouTube settings section
// ---------------------------------------------------------------------------

// YTAppSettingsPresentationData asks a section manager to fill in a category; we append our
// own section on top of whatever YT produced.
//
// Every private selector is reached through respondsToSelector: because these classes move
// between YouTube releases. A missing one degrades the entry point to the nav bar button
// rather than crashing.

// -switchItemWithTitle:titleDescription:accessibilityIdentifier:switchOn:switchBlock:settingItemId:
// All six arguments are objects; YouTube passes @YES/@NO for switchOn.
typedef id (*YTEQSwitchItemFn)(id, SEL, id, id, id, id, id, id);

// -setSectionItems:forCategory:title:icon:titleDescription:headerHidden:
typedef void (*YTEQSetSectionItemsFn)(id, SEL, id, id, id, id, id, BOOL);

// -setSectionItems:forCategory:title:titleDescription:headerHidden:
typedef void (*YTEQSetSectionItemsNoIconFn)(id, SEL, id, id, id, id, BOOL);

static void YTEQAppendSectionItems(id manager, SEL category) {
    if (manager == nil || category == NULL) return;

    Class builder = NSClassFromString(@"YTSettingsSectionItemManager");
    SEL switchSelector = NSSelectorFromString(
        @"switchItemWithTitle:titleDescription:accessibilityIdentifier:switchOn:switchBlock:settingItemId:");
    if (builder == Nil || ![builder respondsToSelector:switchSelector]) return;

    YTEQAudioEngine *engine = [YTEQAudioEngine shared];
    __weak YTEQAudioEngine *weakEngine = engine;

    // YT retains the block. It is called with the new switch value, and reads back the
    // resulting state, which keeps this working if YT ever passes a value through.
    id switchBlock = [^(id newValue) {
        YTEQAudioEngine *live = weakEngine;
        if (live == nil) return;
        if ([newValue respondsToSelector:@selector(boolValue)]) {
            live.enabled = [newValue boolValue];
        } else {
            live.enabled = !live.enabled;
        }
        [live save];
    } copy];

    YTEQSwitchItemFn makeSwitch = (YTEQSwitchItemFn)objc_msgSend;
    id item = makeSwitch(builder, switchSelector,
                         @"Enable Equalizer",
                         @"Preamp + 10 bands with frequency, gain and Q",
                         @"YTEQ.enabled",
                         @(engine.enabled),
                         switchBlock,
                         @"YTEQ.enable");
    if (item == nil) return;

    NSArray *section = @[ item ];

    SEL withIcon = NSSelectorFromString(
        @"setSectionItems:forCategory:title:icon:titleDescription:headerHidden:");
    if ([manager respondsToSelector:withIcon]) {
        YTEQSetSectionItemsFn setter = (YTEQSetSectionItemsFn)objc_msgSend;
        setter(manager, withIcon, section, category, kYTEQSectionTitle, nil,
               @"Open the graph to shape the sound", NO);
        return;
    }

    SEL withoutIcon = NSSelectorFromString(
        @"setSectionItems:forCategory:title:titleDescription:headerHidden:");
    if ([manager respondsToSelector:withoutIcon]) {
        YTEQSetSectionItemsNoIconFn setter = (YTEQSetSectionItemsNoIconFn)objc_msgSend;
        setter(manager, withoutIcon, section, category, kYTEQSectionTitle,
               @"Open the graph to shape the sound", NO);
    }
}

// The category argument's type is not knowable from outside YouTube, so it is carried as
// id and passed straight back through. That keeps the hook correct whether YouTube passes
// an NSString, an NSNumber or anything else, and avoids the ARC error for coercing a SEL
// to id.
typedef void (*YTEQUpdateSectionIMP)(id, SEL, id, id);

static YTEQUpdateSectionIMP g_originalUpdateSection = NULL;

static void YTEQUpdateSectionForCategory(id self, SEL _cmd, id category, id entry) {
    if (g_originalUpdateSection != NULL) {
        g_originalUpdateSection(self, _cmd, category, entry);
    }
    YTEQAppendSectionItems(self, category);
}

static void YTEQInstallSettingsSectionHook(void) {
    if (g_originalUpdateSection != NULL) return; // already installed

    Class manager = NSClassFromString(@"YTSettingsSectionItemManager");
    if (manager == Nil) return;

    SEL selector = NSSelectorFromString(@"updateSectionForCategory:withEntry:");
    IMP original = NULL;
    YTEQSwizzleIfPresent(manager, selector, (IMP)YTEQUpdateSectionForCategory, &original);
    if (original != NULL) {
        g_originalUpdateSection = (YTEQUpdateSectionIMP)original;
    }
}

// VolumeBoostYT also touches YTSettingsGroupData and YTAppSettingsPresentationData to make
// sure a "tweaks" category exists before adding its switch. This does not, because it
// hooks the section manager itself, so the switch lands in whichever category the user is
// currently looking at. That is strictly more robust than depending on a category
// identifier that shifts between YouTube releases.

// ---------------------------------------------------------------------------
// Presenting the panel
// ---------------------------------------------------------------------------

static void YTEQPresentPanel(void) {
    UIWindow *keyWindow = nil;
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        // -windows is on UIWindowScene, not on the UIScene superclass.
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) { keyWindow = candidate; break; }
        }
        if (keyWindow != nil) break;
    }
    UIViewController *presenter = keyWindow.rootViewController;
    while (presenter.presentedViewController != nil) {
        presenter = presenter.presentedViewController;
    }
    if (presenter == nil) return;
    [YTEQPanelViewController presentFromViewController:presenter];
}

// ---------------------------------------------------------------------------
// Nav bar entry point
// ---------------------------------------------------------------------------

typedef void (*YTEQViewDidAppearIMP)(id, SEL, BOOL);

static YTEQViewDidAppearIMP g_originalViewDidAppear = NULL;

static BOOL YTEQControllerLooksLikeSettings(UIViewController *controller) {
    NSString *name = NSStringFromClass([controller class]);
    return [name containsString:@"Settings"] || [name containsString:@"Account"];
}

static void YTEQViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (g_originalViewDidAppear != NULL) {
        g_originalViewDidAppear(self, _cmd, animated);
    }

    if (![(UIViewController *)self isKindOfClass:[UIViewController class]]) return;
    UIViewController *controller = (UIViewController *)self;
    if (!YTEQControllerLooksLikeSettings(controller)) return;
    if (controller.navigationItem == nil) return;

    NSArray<UIBarButtonItem *> *existing = controller.navigationItem.rightBarButtonItems;
    for (UIBarButtonItem *item in existing) {
        if (item.tag == kYTEQButtonTag) return;
    }

    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:@"EQ"
                                                            style:UIBarButtonItemStylePlain
                                                           target:controller
                                                           action:@selector(yteq_openPanel:)];
    item.tag = kYTEQButtonTag;

    // Append rather than replace, so YT's own controls stay reachable.
    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray arrayWithCapacity:existing.count + 1];
    [items addObjectsFromArray:existing ?: @[]];
    [items addObject:item];
    controller.navigationItem.rightBarButtonItems = items;
}

static void YTEQOpenPanel(id self, SEL _cmd, id sender) {
    (void)self; (void)_cmd; (void)sender;
    YTEQPresentPanel();
}

// ---------------------------------------------------------------------------
// Install
// ---------------------------------------------------------------------------

@implementation YTEQBootstrap

+ (void)install {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!YTEQShouldRunInThisProcess()) return;

        // Touch the engine so settings are read from NSUserDefaults and coefficients are
        // designed before the first buffer arrives.
        (void)[YTEQAudioEngine shared];

        // The RemoteIO interposition is live from image load; this only resolves the real
        // AudioUnitSetProperty symbol.
        [YTEQAudioHook install];

        YTEQInstallSettingsSectionHook();
        [YTEQBootstrap installSettingsSectionWithRetry:6];
        [YTEQBootstrap installNavButton];
    });
}

+ (void)installNavButton {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        IMP original = NULL;
        YTEQSwizzle([UIViewController class], @selector(viewDidAppear:),
                    (IMP)YTEQViewDidAppear, &original);
        g_originalViewDidAppear = (YTEQViewDidAppearIMP)original;

        // Declared on UIViewController at runtime so it does not need a category. The
        // implementation is a plain C function, which is valid for an ObjC action.
        YTEQSwizzle([UIViewController class],
                    NSSelectorFromString(@"yteq_openPanel:"), (IMP)YTEQOpenPanel, NULL);
    });
}

+ (void)installSettingsSectionWithRetry:(NSInteger)attempt {
    if (attempt <= 0) return;
    if (g_originalUpdateSection != NULL) return;
    YTEQInstallSettingsSectionHook();
    if (g_originalUpdateSection != NULL) return;
    // YT's settings classes are in the main binary, so they exist immediately, but the
    // manager may not have been realised yet. A couple of cheap retries cover the
    // difference without a timer running for the life of the process.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [YTEQBootstrap installSettingsSectionWithRetry:attempt - 1];
    });
}

@end

// Runs when the image is mapped, which is before AVFoundation or AudioToolbox can have
// installed any render callback. A constructor is the right hook here: it needs no tweak
// framework, matching how VolumeBoostYT gets loaded, and it runs early enough for the
// AudioUnitSetProperty interposition in YTEQAudioHook.m to already be in place.
__attribute__((constructor))
static void YTEQLoad(void) {
    @autoreleasepool {
        [YTEQBootstrap install];
    }
}
