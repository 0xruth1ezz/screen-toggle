#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <errno.h>
#import <os/log.h>
#import <stdio.h>

static NSString *DiagnosticsPath;

// Controller events run on the main thread. Flush each line so a crash or a
// forced quit still leaves the last recovery decision available on disk.
static void LogEvent(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void LogEvent(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    message = [message stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    os_log(OS_LOG_DEFAULT, "ScreenToggle %{public}@", message);
    if (!DiagnosticsPath) return;
    FILE *file = fopen(DiagnosticsPath.fileSystemRepresentation, "a");
    if (file) {
        fseek(file, 0, SEEK_END);
        if (ftell(file) >= 2 * 1024 * 1024) {
            fclose(file);
            rename(DiagnosticsPath.fileSystemRepresentation,
                [DiagnosticsPath stringByAppendingString:@".previous"].fileSystemRepresentation);
            file = fopen(DiagnosticsPath.fileSystemRepresentation, "w");
        }
    }
    if (!file) {
        os_log_error(OS_LOG_DEFAULT, "Cannot write ScreenToggle diagnostics: errno=%d", errno);
        DiagnosticsPath = nil;
        return;
    }
    fprintf(file, "%s uptime=%.3f pid=%d %s\n", NSDate.date.description.UTF8String,
        NSProcessInfo.processInfo.systemUptime, NSProcessInfo.processInfo.processIdentifier, message.UTF8String);
    fclose(file);
}

static BOOL IsFallbackDisplay(CGDirectDisplayID display) {
    return CGDisplayVendorNumber(display) == 0x756e6b6e &&
        CGDisplayModelNumber(display) == 0x76697274;
}

// Public display discovery follows Lunar's CGDisplayIsBuiltin approach.
// Lunar's encrypted BlackOut implementation is not linked into this app.
typedef CGError (*ConfigureEnabled)(CGDisplayConfigRef, CGDirectDisplayID, bool);
typedef CGError (*GetDisplayList)(uint32_t, CGDirectDisplayID *, uint32_t *);

@interface ScreenToggle : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSMenuItem *toggleItem;
@property (strong) NSMenuItem *stateItem;
@property (strong) NSMenuItem *restoreItem;
@property CGDirectDisplayID managedDisplay;
@property CGDirectDisplayID lastKnownBuiltinDisplay;
@property BOOL changing;
@property BOOL sleeping;
@property BOOL restorePending;
@property (copy) NSSet<NSNumber *> *externalDisplaysAtDisable;
@property BOOL toggleShortcutAvailable;
@property BOOL restoreShortcutAvailable;
@property ConfigureEnabled configureEnabled;
@property GetDisplayList getDisplayList;
@property EventHotKeyRef toggleHotKey;
@property EventHotKeyRef restoreHotKey;
@property EventHandlerRef hotKeyHandler;
@property (strong) NSTimer *recoveryTimer;
@property (copy) NSString *lastLoggedState;
@property NSTimeInterval lastStateLogTime;
- (void)refresh;
- (void)toggle:(id)sender;
- (void)restore:(id)sender;
- (void)displaysChanged;
- (void)display:(CGDirectDisplayID)display changedWithFlags:(CGDisplayChangeSummaryFlags)flags;
@end

static void DisplayChanged(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *context) {
    os_log(OS_LOG_DEFAULT, "ScreenToggle callback received: id=%u flags=0x%x", display, flags);
    // Display callbacks can arrive within a configuration transaction.
    dispatch_async(dispatch_get_main_queue(), ^{
        [(__bridge ScreenToggle *)context display:display changedWithFlags:flags];
    });
}

static OSStatus HotKeyPressed(EventHandlerCallRef handler, EventRef event, void *context) {
    EventHotKeyID key = {0};
    OSStatus result = GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
                                       NULL, sizeof(key), NULL, &key);
    if (result != noErr) return result;
    ScreenToggle *app = (__bridge ScreenToggle *)context;
    if (key.id == 1) [app toggle:nil];
    if (key.id == 2) [app restore:nil];
    return noErr;
}

@implementation ScreenToggle

- (NSArray<NSNumber *> *)displaysUsing:(GetDisplayList)function {
    uint32_t count = 0;
    if (!function) return nil;
    CGError result = function(0, NULL, &count);
    if (result != kCGErrorSuccess) {
        LogEvent(@"Display discovery count failed: source=%@ result=%d",
            function == self.getDisplayList ? @"all" : @"online", result);
        return nil;
    }
    // Leave room for a monitor connected between the count and list calls.
    uint32_t capacity = MAX(count + 8, 32);
    CGDirectDisplayID *ids = calloc(capacity, sizeof(CGDirectDisplayID));
    if (!ids) return nil;
    result = function(capacity, ids, &count);
    NSMutableArray *displays = [NSMutableArray array];
    if (result == kCGErrorSuccess) {
        for (uint32_t i = 0; i < MIN(count, capacity); i++) [displays addObject:@(ids[i])];
    }
    free(ids);
    if (result != kCGErrorSuccess) LogEvent(@"Display discovery list failed: source=%@ result=%d",
        function == self.getDisplayList ? @"all" : @"online", result);
    return result == kCGErrorSuccess ? displays : nil;
}

- (CGDirectDisplayID)builtinDisplay {
    NSArray *displays = [self displaysUsing:self.getDisplayList];
    if (!displays) displays = [self displaysUsing:CGGetOnlineDisplayList];
    // Keep the actual panel selected while it is intentionally disconnected.
    // A headless fallback must not replace its cached identity.
    if (self.managedDisplay) return self.managedDisplay;
    for (NSNumber *number in displays) {
        if (!IsFallbackDisplay(number.unsignedIntValue) && CGDisplayIsBuiltin(number.unsignedIntValue)) {
            self.lastKnownBuiltinDisplay = number.unsignedIntValue;
            return self.lastKnownBuiltinDisplay;
        }
    }
    // Disabled panels may disappear from discovery even if another app disabled them.
    return self.lastKnownBuiltinDisplay ?: self.managedDisplay;
}

- (NSSet<NSNumber *> *)usableExternalDisplays {
    NSMutableSet *displays = [NSMutableSet set];
    for (NSNumber *number in [self displaysUsing:CGGetOnlineDisplayList]) {
        CGDirectDisplayID display = number.unsignedIntValue;
        // WindowServer's headless fallback in the disconnect log identifies
        // itself as vendor 'unkn', model 'virt'. It cannot provide a visible screen.
        if (IsFallbackDisplay(display)) continue;
        if (!CGDisplayIsBuiltin(display) && CGDisplayIsOnline(display) && !CGDisplayIsAsleep(display) &&
            (CGDisplayIsActive(display) || CGDisplayIsInMirrorSet(display))) [displays addObject:number];
    }
    return displays;
}

- (BOOL)hasExternalDisplay {
    NSSet *displays = [self usableExternalDisplays];
    // A newly created virtual screen must not replace the monitor that made
    // disabling safe. If all original monitors disappear, restore conservatively.
    return self.externalDisplaysAtDisable ?
        [displays intersectsSet:self.externalDisplaysAtDisable] : displays.count > 0;
}

- (void)logDisplayState:(NSString *)reason {
    NSArray *all = [self displaysUsing:self.getDisplayList];
    NSArray *online = [self displaysUsing:CGGetOnlineDisplayList];
    NSMutableSet *ids = [NSMutableSet setWithArray:all ?: @[]];
    [ids addObjectsFromArray:online ?: @[]];
    CGDirectDisplayID builtin = [self builtinDisplay];
    if (builtin) [ids addObject:@(builtin)];
    NSMutableArray *states = [NSMutableArray array];
    for (NSNumber *number in [ids.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
        CGDirectDisplayID display = number.unsignedIntValue;
        [states addObject:[NSString stringWithFormat:
            @"id=%u builtin=%d online=%d active=%d asleep=%d mirror=%d vendor=%x model=%x",
            display, CGDisplayIsBuiltin(display), CGDisplayIsOnline(display), CGDisplayIsActive(display),
            CGDisplayIsAsleep(display), CGDisplayIsInMirrorSet(display),
            CGDisplayVendorNumber(display), CGDisplayModelNumber(display)]];
    }
    NSString *state = [NSString stringWithFormat:
        @"selected=%u cached=%u verifiedEnabled=%d managed=%u changing=%d sleeping=%d pending=%d originalExternal=%@ usableExternal=%@ all=%@ online=%@ displays=%@",
        builtin, self.lastKnownBuiltinDisplay, [self isEnabled:builtin], self.managedDisplay,
        self.changing, self.sleeping, self.restorePending,
        [self.externalDisplaysAtDisable.allObjects sortedArrayUsingSelector:@selector(compare:)],
        [[self usableExternalDisplays].allObjects sortedArrayUsingSelector:@selector(compare:)], all, online, states];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if ([reason isEqualToString:@"check"] && [state isEqualToString:self.lastLoggedState] &&
        now - self.lastStateLogTime < 30) return;
    self.lastLoggedState = state;
    self.lastStateLogTime = now;
    LogEvent(@"Recovery %@: %@", reason, state);
}

- (BOOL)isEnabled:(CGDirectDisplayID)display {
    // On macOS 27, an absent panel returned -1 for every per-ID status flag
    // during headless fallback. Those values are truthy, not proof of recovery.
    // Require the actual panel in the public online list.
    return display && [[self displaysUsing:CGGetOnlineDisplayList] containsObject:@(display)] &&
        !IsFallbackDisplay(display) && CGDisplayIsOnline(display) && !CGDisplayIsAsleep(display) &&
        (CGDisplayIsActive(display) || CGDisplayIsInMirrorSet(display));
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/ScreenToggle"];
    NSError *logError = nil;
    if ([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&logError]) {
        DiagnosticsPath = [directory stringByAppendingPathComponent:@"recovery.log"];
    }
    LogEvent(@"Screen Toggle build %s %s launched from %@ macOS=%@ diagnostics=%@ error=%@",
        __DATE__, __TIME__, NSBundle.mainBundle.bundlePath,
        NSProcessInfo.processInfo.operatingSystemVersionString, DiagnosticsPath, logError);
    // Resolve private symbols at runtime so an OS change produces an error,
    // rather than preventing the app from launching with a missing symbol.
    void *skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
    if (skyLight) {
        self.configureEnabled = (ConfigureEnabled)dlsym(skyLight, "SLSConfigureDisplayEnabled");
        self.getDisplayList = (GetDisplayList)dlsym(skyLight, "SLSGetDisplayList");
    }
    if (!self.configureEnabled) {
        void *graphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_LOCAL);
        if (graphics) self.configureEnabled = (ConfigureEnabled)dlsym(graphics, "CGSConfigureDisplayEnabled");
    }

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"laptopcomputer" accessibilityDescription:@"Screen Toggle"];
    icon.template = YES;
    self.statusItem.button.image = icon;
    if (!icon) self.statusItem.button.title = @"Screen";
    self.statusItem.button.toolTip = @"Screen Toggle";

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Screen Toggle"];
    menu.autoenablesItems = NO;
    menu.delegate = self;
    self.stateItem = [menu addItemWithTitle:@"Built-in display" action:NULL keyEquivalent:@""];
    self.stateItem.enabled = NO;
    [menu addItem:NSMenuItem.separatorItem];
    self.toggleItem = [menu addItemWithTitle:@"Turn Built-in Display Off" action:@selector(toggle:) keyEquivalent:@""];
    self.toggleItem.target = self;
    self.restoreItem = [menu addItemWithTitle:@"Restore Built-in Display" action:@selector(restore:) keyEquivalent:@""];
    self.restoreItem.target = self;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [menu addItemWithTitle:@"Quit Screen Toggle" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    self.statusItem.menu = menu;

    EventTypeSpec event = {kEventClassKeyboard, kEventHotKeyPressed};
    EventHandlerRef handler = NULL;
    if (InstallApplicationEventHandler(HotKeyPressed, 1, &event, (__bridge void *)self, &handler) == noErr) {
        self.hotKeyHandler = handler;
        EventHotKeyRef toggle = NULL, restore = NULL;
        UInt32 modifiers = cmdKey | controlKey | optionKey;
        self.toggleShortcutAvailable = RegisterEventHotKey(kVK_ANSI_B, modifiers,
            (EventHotKeyID){'ScTg', 1}, GetApplicationEventTarget(), 0, &toggle) == noErr;
        self.restoreShortcutAvailable = RegisterEventHotKey(kVK_ANSI_R, modifiers,
            (EventHotKeyID){'ScTg', 2}, GetApplicationEventTarget(), 0, &restore) == noErr;
        self.toggleHotKey = toggle;
        self.restoreHotKey = restore;
    }
    if (self.toggleShortcutAvailable) {
        self.toggleItem.keyEquivalent = @"b";
        self.toggleItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption;
    }
    if (self.restoreShortcutAvailable) {
        self.restoreItem.keyEquivalent = @"r";
        self.restoreItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption;
    }
    CGError callbackResult = CGDisplayRegisterReconfigurationCallback(DisplayChanged, (__bridge void *)self);
    LogEvent(@"Monitoring registered: callbackResult=%d configureAPI=%d allDisplaysAPI=%d toggleShortcut=%d restoreShortcut=%d",
        callbackResult, self.configureEnabled != NULL, self.getDisplayList != NULL,
        self.toggleShortcutAvailable, self.restoreShortcutAvailable);
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(willSleep:)
        name:NSWorkspaceWillSleepNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(didWake:)
        name:NSWorkspaceDidWakeNotification object:nil];
    [self startRecoveryMonitoring];
    [self logDisplayState:@"launch"];
    [self displaysChanged];
}

- (void)startRecoveryMonitoring {
    // Power changes need not produce a topology callback, and callbacks may
    // precede the final display state. Keep checking even after a failed restore.
    [self.recoveryTimer invalidate];
    __weak ScreenToggle *weakSelf = self;
    self.recoveryTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        [weakSelf displaysChanged];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.recoveryTimer forMode:NSRunLoopCommonModes];
}

- (void)menuWillOpen:(NSMenu *)menu { [self refresh]; }

- (void)refresh {
    CGDirectDisplayID display = [self builtinDisplay];
    BOOL enabled = [self isEnabled:display];
    self.stateItem.title = !self.configureEnabled ? @"Display control unavailable on this macOS version" :
        !display ? @"No built-in display found" : enabled ? @"Built-in display: On" : @"Built-in display: Off";
    self.toggleItem.title = enabled ? @"Turn Built-in Display Off" : @"Turn Built-in Display On";
    self.toggleItem.enabled = self.configureEnabled && display && !self.changing &&
        (!enabled || [self hasExternalDisplay]);
    self.toggleItem.toolTip = enabled && ![self hasExternalDisplay] ? @"Connect an external monitor first." : nil;
    self.restoreItem.enabled = self.configureEnabled && display && !self.changing;
    self.statusItem.button.toolTip = self.stateItem.title;
}

- (void)verifyRestore:(CGDirectDisplayID)display {
    [self logDisplayState:@"restore verification"];
    if (!self.sleeping && [self isEnabled:display]) {
        LogEvent(@"Recovery confirmed: panel=%u; clearing pending restore and original monitors", display);
        self.managedDisplay = 0;
        self.restorePending = NO;
        self.externalDisplaysAtDisable = nil;
    } else {
        LogEvent(@"Recovery unconfirmed: panel=%u; restore remains pending", display);
    }
}

- (void)showError:(NSString *)message {
    LogEvent(@"Display error: %@", message);
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Couldn’t change the built-in display";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (BOOL)setDisplay:(CGDirectDisplayID)display enabled:(BOOL)enabled error:(NSString **)error {
    if (!display || !self.configureEnabled) {
        if (error) *error = @"The built-in display or the macOS display control API is unavailable.";
        return NO;
    }
    if (!enabled && ![self hasExternalDisplay]) {
        if (error) *error = @"Connect an external monitor before turning off the built-in display.";
        return NO;
    }
    CGDisplayConfigRef configuration = NULL;
    LogEvent(@"Display change begin: id=%u enabled=%d", display, enabled);
    CGError result = CGBeginDisplayConfiguration(&configuration);
    LogEvent(@"Display change begin result: %d", result);
    if (result == kCGErrorSuccess) {
        result = self.configureEnabled(configuration, display, enabled);
        LogEvent(@"Display change configure result: %d", result);
        if (result == kCGErrorSuccess) {
            // macOS restores the session configuration when this process exits.
            result = CGCompleteDisplayConfiguration(configuration, kCGConfigureForAppOnly);
        } else {
            CGCancelDisplayConfiguration(configuration);
        }
    }
    LogEvent(@"Display change end: id=%u enabled=%d result=%d", display, enabled, result);
    if (result != kCGErrorSuccess && error) {
        *error = [NSString stringWithFormat:@"macOS rejected the display change (error %d).", result];
    }
    return result == kCGErrorSuccess;
}

- (void)changeEnabled:(BOOL)enabled {
    LogEvent(@"Manual request: enabled=%d changing=%d sleeping=%d pending=%d",
        enabled, self.changing, self.sleeping, self.restorePending);
    if (self.changing || self.sleeping) return;
    if (!enabled && self.restorePending) { [self displaysChanged]; return; }
    CGDirectDisplayID display = [self builtinDisplay];
    if (!display) { [self showError:@"No built-in display was found."]; return; }
    if (!enabled && ![self isEnabled:display]) { [self refresh]; return; }
    self.changing = YES;
    if (!enabled) {
        self.externalDisplaysAtDisable = [self usableExternalDisplays];
        self.managedDisplay = display;
    } else {
        // The restore shortcut must actually send an enable request, even when
        // a transient discovery result claims the panel is already on.
        self.restorePending = YES;
    }
    [self logDisplayState:enabled ? @"manual on" : @"manual off"];
    [self refresh];
    NSString *error = nil;
    if (![self setDisplay:display enabled:enabled error:&error]) {
        self.changing = NO;
        [self refresh];
        [self showError:error];
        return;
    }
    // WindowServer updates its display list after the transaction completes.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        self.changing = NO;
        if (self.sleeping) return;
        if (!enabled && (self.restorePending || ![self hasExternalDisplay])) {
            // Losing the external screen supersedes an in-flight off request.
            [self displaysChanged];
            return;
        }
        if ([self isEnabled:display] != enabled) {
            // A private API can report success without applying the change.
            self.restorePending = YES;
            [self setDisplay:display enabled:YES error:NULL];
            [self refresh];
            [self showError:@"macOS did not apply the requested display state. A restore was requested. This macOS build may not support the display toggle API."];
        } else {
            if (enabled) [self verifyRestore:display];
            [self displaysChanged];
        }
    });
}

- (void)toggle:(id)sender { [self changeEnabled:![self isEnabled:[self builtinDisplay]]]; }
- (void)restore:(id)sender { [self changeEnabled:YES]; }

- (void)display:(CGDirectDisplayID)display changedWithFlags:(CGDisplayChangeSummaryFlags)flags {
    LogEvent(@"Display callback: id=%u flags=0x%x begin=%d removed=%d disabled=%d",
        display, flags, !!(flags & kCGDisplayBeginConfigurationFlag),
        !!(flags & kCGDisplayRemoveFlag), !!(flags & kCGDisplayDisabledFlag));
    if (flags & kCGDisplayBeginConfigurationFlag) return;
    if ((flags & (kCGDisplayRemoveFlag | kCGDisplayDisabledFlag)) &&
        [self.externalDisplaysAtDisable containsObject:@(display)]) {
        NSMutableSet *remaining = [[self usableExternalDisplays] mutableCopy];
        [remaining removeObject:@(display)];
        if (![remaining intersectsSet:self.externalDisplaysAtDisable]) {
            self.restorePending = YES;
            LogEvent(@"Recovery required: last original external display removed/disabled, id=%u", display);
        }
    }
    [self logDisplayState:@"callback"];
    [self displaysChanged];
}

- (void)displaysChanged {
    [self logDisplayState:@"check"];
    if (self.changing || self.sleeping) return;
    CGDirectDisplayID display = [self builtinDisplay];
    BOOL external = [self hasExternalDisplay];
    if (self.managedDisplay && !external) self.restorePending = YES;
    if (self.configureEnabled && display &&
        (self.restorePending || (![self isEnabled:display] && !external))) {
        // Automatic recovery must not wait for an alert on an invisible screen.
        // Hold the change guard while WindowServer settles, then let the timer
        // retry until discovery confirms the panel is enabled, even if the API
        // returned success without applying the change.
        self.changing = YES;
        self.restorePending = YES;
        LogEvent(@"Recovery attempt: panel=%u externalAvailable=%d", display, external);
        [self setDisplay:display enabled:YES error:NULL];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            self.changing = NO;
            [self verifyRestore:display];
            [self refresh];
        });
    }
    [self refresh];
}

- (void)willSleep:(NSNotification *)notification {
    self.sleeping = YES;
    if (self.managedDisplay) self.restorePending = YES;
    [self logDisplayState:@"will sleep"];
    if (self.restorePending) [self setDisplay:[self builtinDisplay] enabled:YES error:NULL];
}

- (void)didWake:(NSNotification *)notification {
    self.sleeping = NO;
    if (self.managedDisplay) self.restorePending = YES;
    [self logDisplayState:@"did wake"];
    [self displaysChanged];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    [self logDisplayState:@"quit"];
    if (self.managedDisplay) [self setDisplay:self.managedDisplay enabled:YES error:NULL];
    // The app-only configuration also supplies process-exit recovery.
    return NSTerminateNow;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.recoveryTimer invalidate];
    CGDisplayRemoveReconfigurationCallback(DisplayChanged, (__bridge void *)self);
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    if (self.toggleHotKey) UnregisterEventHotKey(self.toggleHotKey);
    if (self.restoreHotKey) UnregisterEventHotKey(self.restoreHotKey);
    if (self.hotKeyHandler) RemoveEventHandler(self.hotKeyHandler);
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        // Reopening the app should not create another process managing displays.
        NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
        for (NSRunningApplication *other in [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier]) {
            if (other.processIdentifier != NSProcessInfo.processInfo.processIdentifier) return 0;
        }
        ScreenToggle *delegate = [[ScreenToggle alloc] init];
        application.delegate = delegate;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [application run];
    }
    return 0;
}
