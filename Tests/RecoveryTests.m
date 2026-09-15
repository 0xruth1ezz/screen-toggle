#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <CoreGraphics/CoreGraphics.h>
#import <assert.h>

// Run the real controller against a deterministic WindowServer substitute.
// No test invokes a hardware display configuration or waits for a timer.
static BOOL builtinOn, externalOn, externalAsleep, externalMirrored, secondExternal;
static BOOL hideBuiltin, rejectRestore, ignoreRestore;
static BOOL virtualOn, unknownVirtualIdentity;
static BOOL virtualBuiltin, missingBuiltinInvalid;
static NSUInteger restoreRequests, alerts;
static NSMutableArray *completions;

static BOOL TestMissingBuiltin(CGDirectDisplayID display) {
    return display == 1 && !builtinOn && missingBuiltinInvalid;
}
static boolean_t TestBuiltin(CGDirectDisplayID display) {
    if (TestMissingBuiltin(display)) return (boolean_t)-1;
    return display == 1 || (display == 4 && virtualBuiltin);
}
static boolean_t TestOnline(CGDirectDisplayID display) {
    if (TestMissingBuiltin(display)) return (boolean_t)-1;
    return display == 1 ? builtinOn : display == 2 ? externalOn : display == 3 ? secondExternal : virtualOn;
}
static uint32_t TestVendor(CGDirectDisplayID display) {
    if (TestMissingBuiltin(display)) return UINT32_MAX;
    return display == 4 && !unknownVirtualIdentity ? 0x756e6b6e : 0x1234;
}
static uint32_t TestModel(CGDirectDisplayID display) {
    if (TestMissingBuiltin(display)) return UINT32_MAX;
    return display == 4 && !unknownVirtualIdentity ? 0x76697274 : 0x5678;
}
static boolean_t TestActive(CGDirectDisplayID display) {
    if (TestMissingBuiltin(display)) return (boolean_t)-1;
    return TestOnline(display) && !(display == 2 && externalAsleep);
}
static boolean_t TestAsleep(CGDirectDisplayID display) {
    if (TestMissingBuiltin(display)) return (boolean_t)-1;
    return display == 2 && externalAsleep;
}
static boolean_t TestMirrored(CGDirectDisplayID display) {
    if (TestMissingBuiltin(display)) return (boolean_t)-1;
    return display == 2 && externalMirrored;
}
static CGError TestList(uint32_t capacity, CGDirectDisplayID *ids, uint32_t *count) {
    CGDirectDisplayID found[4];
    uint32_t total = 0;
    if (!hideBuiltin) found[total++] = 1;
    if (externalOn) found[total++] = 2;
    if (secondExternal) found[total++] = 3;
    if (virtualOn) found[total++] = 4;
    *count = total;
    for (uint32_t i = 0; ids && i < MIN(capacity, total); i++) ids[i] = found[i];
    return kCGErrorSuccess;
}
static CGError TestOnlineList(uint32_t capacity, CGDirectDisplayID *ids, uint32_t *count) {
    CGDirectDisplayID found[4];
    uint32_t total = 0;
    if (builtinOn) found[total++] = 1;
    if (externalOn) found[total++] = 2;
    if (secondExternal) found[total++] = 3;
    if (virtualOn) found[total++] = 4;
    *count = total;
    for (uint32_t i = 0; ids && i < MIN(capacity, total); i++) ids[i] = found[i];
    return kCGErrorSuccess;
}
static CGError TestBegin(CGDisplayConfigRef *configuration) {
    *configuration = (CGDisplayConfigRef)(uintptr_t)1;
    return kCGErrorSuccess;
}
static CGError TestComplete(CGDisplayConfigRef configuration, CGConfigureOption option) {
    return kCGErrorSuccess;
}
static CGError TestCancel(CGDisplayConfigRef configuration) { return kCGErrorSuccess; }
static CGError TestConfigure(CGDisplayConfigRef configuration, CGDirectDisplayID display, bool enabled) {
    assert(display == 1);
    if (enabled) {
        restoreRequests++;
        if (rejectRestore) return kCGErrorFailure;
        if (ignoreRestore) return kCGErrorSuccess;
    }
    builtinOn = enabled;
    return kCGErrorSuccess;
}
static void TestAfter(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) {
    [completions addObject:[block copy]];
}

#define CGDisplayIsBuiltin TestBuiltin
#define CGDisplayVendorNumber TestVendor
#define CGDisplayModelNumber TestModel
#define CGDisplayIsOnline TestOnline
#define CGDisplayIsActive TestActive
#define CGDisplayIsAsleep TestAsleep
#define CGDisplayIsInMirrorSet TestMirrored
#define CGGetOnlineDisplayList TestOnlineList
#define CGBeginDisplayConfiguration TestBegin
#define CGCompleteDisplayConfiguration TestComplete
#define CGCancelDisplayConfiguration TestCancel
#define dispatch_after TestAfter
#define main ScreenToggleApplicationMain
#include "../main.m"
#undef main

@interface TestScreenToggle : ScreenToggle
@end
@implementation TestScreenToggle
- (void)showError:(NSString *)message { alerts++; }
@end

static void FinishChanges(void) {
    NSArray *pending = [completions copy];
    [completions removeAllObjects];
    for (dispatch_block_t block in pending) block();
}

static TestScreenToggle *NewAppWithSecondScreen(BOOL connected) {
    builtinOn = externalOn = YES;
    externalAsleep = externalMirrored = virtualOn = unknownVirtualIdentity = NO;
    virtualBuiltin = missingBuiltinInvalid = NO;
    secondExternal = connected;
    hideBuiltin = rejectRestore = ignoreRestore = NO;
    restoreRequests = alerts = 0;
    completions = [NSMutableArray array];
    TestScreenToggle *app = [TestScreenToggle new];
    app.configureEnabled = TestConfigure;
    app.getDisplayList = TestList;
    [app startRecoveryMonitoring];
    [app toggle:nil];
    assert(!builtinOn);
    return app;
}

static TestScreenToggle *NewApp(void) { return NewAppWithSecondScreen(NO); }

static void Stop(TestScreenToggle *app) {
    assert(alerts == 0);
    [app.recoveryTimer invalidate];
    [completions removeAllObjects];
}

int main(void) {
    @autoreleasepool {
        TestScreenToggle *app = NewApp();
        FinishChanges();
        externalOn = NO;
        hideBuiltin = YES;
        [app displaysChanged];
        assert(builtinOn && restoreRequests == 1); // Cached panel ID survives removal.
        FinishChanges();
        [app.recoveryTimer fire];
        assert(restoreRequests == 1);
        Stop(app);

        app = NewApp();
        FinishChanges();
        [app displaysChanged]; // Callback arrives before the online list changes.
        assert(restoreRequests == 0);
        externalOn = NO; // No subsequent callback.
        [app.recoveryTimer fire];
        assert(builtinOn && restoreRequests == 1);
        Stop(app);

        app = NewApp();
        externalOn = NO;
        [app displaysChanged]; // Disconnection during the off transaction.
        assert(restoreRequests == 0);
        FinishChanges();
        assert(builtinOn && restoreRequests == 1);
        Stop(app);

        app = NewApp();
        externalOn = NO;
        builtinOn = YES; // macOS itself restores before off verification finishes.
        FinishChanges();
        assert(builtinOn && restoreRequests == 1); // Explicitly verify restoration before releasing ownership.
        Stop(app);

        app = NewApp();
        FinishChanges();
        externalOn = NO;
        rejectRestore = YES;
        [app displaysChanged];
        [app.recoveryTimer fire];
        assert(!builtinOn && restoreRequests == 1); // No overlapping attempts.
        FinishChanges();
        rejectRestore = NO;
        ignoreRestore = YES;
        [app.recoveryTimer fire];
        assert(!builtinOn && restoreRequests == 2); // API success is not recovery.
        FinishChanges();
        ignoreRestore = NO;
        [app.recoveryTimer fire];
        assert(builtinOn && restoreRequests == 3);
        FinishChanges();
        [app.recoveryTimer fire];
        assert(restoreRequests == 3);
        Stop(app);

        app = NewApp();
        FinishChanges();
        externalAsleep = externalMirrored = YES;
        [app.recoveryTimer fire];
        assert(builtinOn && restoreRequests == 1);
        Stop(app);

        app = NewAppWithSecondScreen(YES);
        FinishChanges();
        externalAsleep = externalMirrored = YES;
        [app.recoveryTimer fire];
        assert(!builtinOn && restoreRequests == 0); // Another usable screen remains.
        secondExternal = NO;
        [app.recoveryTimer fire];
        assert(builtinOn && restoreRequests == 1);
        Stop(app);

        app = NewApp();
        FinishChanges();
        app.managedDisplay = 0; // Recovery also covers a panel disabled elsewhere.
        app.externalDisplaysAtDisable = nil;
        externalOn = NO;
        [app.recoveryTimer fire];
        assert(builtinOn && restoreRequests == 1);
        Stop(app);
        app = NewApp();
        FinishChanges();
        externalOn = NO;
        virtualOn = YES; // Reproduce the fallback screen seen in WindowServer's log.
        [app.recoveryTimer fire];
        assert(builtinOn && restoreRequests == 1);
        Stop(app);

        app = NewApp();
        FinishChanges();
        externalOn = NO;
        virtualOn = unknownVirtualIdentity = YES;
        [app.recoveryTimer fire]; // Original monitor loss works without a known fingerprint.
        assert(builtinOn && restoreRequests == 1);
        Stop(app);

        app = NewApp();
        FinishChanges();
        app.managedDisplay = 0;
        app.externalDisplaysAtDisable = nil;
        externalOn = NO;
        virtualOn = YES; // Startup recovery has no original-monitor snapshot.
        [app displaysChanged];
        assert(builtinOn && restoreRequests == 1);
        Stop(app);

        app = NewApp();
        rejectRestore = YES;
        [app willSleep:nil]; // Sleep while the off transaction is settling.
        assert(app.restorePending && restoreRequests == 1 && !builtinOn);
        FinishChanges();
        [app.recoveryTimer fire];
        assert(restoreRequests == 1); // Do not fight sleep or clear the pending restore.
        [app didWake:nil]; // External is still connected; restoration must still be retried.
        assert(restoreRequests == 2 && app.restorePending);
        FinishChanges();
        rejectRestore = NO;
        [app.recoveryTimer fire];
        FinishChanges();
        assert(builtinOn && restoreRequests == 3 && !app.restorePending);
        Stop(app);

        app = NewApp();
        FinishChanges();
        externalOn = NO;
        rejectRestore = YES;
        [app displaysChanged];
        FinishChanges();
        externalOn = YES; // Reconnecting must not cancel an already requested restore.
        rejectRestore = NO;
        [app.recoveryTimer fire];
        FinishChanges();
        assert(builtinOn && restoreRequests == 2 && !app.restorePending);
        Stop(app);
        app = NewApp();
        FinishChanges();
        externalOn = NO;
        hideBuiltin = virtualOn = virtualBuiltin = YES;
        [app displaysChanged]; // A fallback claiming to be built-in must not replace the panel.
        assert(builtinOn && restoreRequests == 1 && app.lastKnownBuiltinDisplay == 1);
        FinishChanges();
        Stop(app);

        app = NewApp();
        FinishChanges();
        externalOn = NO;
        hideBuiltin = virtualOn = missingBuiltinInvalid = YES;
        // Reproduce the -1 status flags captured during the macOS 27 unplug test.
        assert(![app isEnabled:1]);
        [app refresh];
        [app displaysChanged];
        assert(builtinOn && restoreRequests == 1);
        FinishChanges();
        Stop(app);

        app = NewApp();
        FinishChanges();
        builtinOn = YES;
        [app refresh]; // A transient observation during reconfiguration is not verification.
        builtinOn = externalOn = NO;
        virtualOn = unknownVirtualIdentity = YES;
        [app displaysChanged];
        assert(builtinOn && restoreRequests == 1);
        FinishChanges();
        Stop(app);
        app = NewApp();
        [app display:2 changedWithFlags:kCGDisplayBeginConfigurationFlag];
        assert(restoreRequests == 0 && !app.restorePending);
        [app display:2 changedWithFlags:kCGDisplayRemoveFlag]; // List can still say the monitor is online.
        assert(app.restorePending && restoreRequests == 0);
        FinishChanges();
        assert(builtinOn && restoreRequests == 1);
        FinishChanges();
        assert(!app.restorePending && app.managedDisplay == 0);
        Stop(app);

        app = NewAppWithSecondScreen(YES);
        FinishChanges();
        [app display:2 changedWithFlags:kCGDisplayRemoveFlag];
        assert(!builtinOn && restoreRequests == 0 && !app.restorePending);
        Stop(app);

        app = NewApp();
        FinishChanges();
        builtinOn = YES;
        [app restore:nil]; // The emergency shortcut sends a request even if status already says on.
        assert(restoreRequests == 1);
        FinishChanges();
        assert(!app.restorePending && app.managedDisplay == 0);
        Stop(app);
        puts("Passed 19 display recovery scenarios.");
    }
    return 0;
}
