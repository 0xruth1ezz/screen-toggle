#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>

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
@property BOOL toggleShortcutAvailable;
@property BOOL restoreShortcutAvailable;
@property ConfigureEnabled configureEnabled;
@property GetDisplayList getDisplayList;
@property EventHotKeyRef toggleHotKey;
@property EventHotKeyRef restoreHotKey;
@property EventHandlerRef hotKeyHandler;
- (void)refresh;
- (void)toggle:(id)sender;
- (void)restore:(id)sender;
- (void)displaysChanged;
@end

static void DisplayChanged(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *context) {
    if (flags & kCGDisplayBeginConfigurationFlag) return;
    // Display callbacks can arrive within a configuration transaction.
    dispatch_async(dispatch_get_main_queue(), ^{
        [(__bridge ScreenToggle *)context displaysChanged];
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
    if (!function || function(0, NULL, &count) != kCGErrorSuccess) return nil;
    // Leave room for a monitor connected between the count and list calls.
    uint32_t capacity = MAX(count + 8, 32);
    CGDirectDisplayID *ids = calloc(capacity, sizeof(CGDirectDisplayID));
    if (!ids) return nil;
    CGError result = function(capacity, ids, &count);
    NSMutableArray *displays = [NSMutableArray array];
    if (result == kCGErrorSuccess) {
        for (uint32_t i = 0; i < MIN(count, capacity); i++) [displays addObject:@(ids[i])];
    }
    free(ids);
    return result == kCGErrorSuccess ? displays : nil;
}

- (CGDirectDisplayID)builtinDisplay {
    NSArray *displays = [self displaysUsing:self.getDisplayList];
    if (!displays) displays = [self displaysUsing:CGGetOnlineDisplayList];
    for (NSNumber *number in displays) {
        if (CGDisplayIsBuiltin(number.unsignedIntValue)) {
            self.lastKnownBuiltinDisplay = number.unsignedIntValue;
            return self.lastKnownBuiltinDisplay;
        }
    }
    // Disabled panels may disappear from discovery even if another app disabled them.
    return self.lastKnownBuiltinDisplay ?: self.managedDisplay;
}

- (BOOL)hasExternalDisplay {
    for (NSNumber *number in [self displaysUsing:CGGetOnlineDisplayList]) {
        CGDirectDisplayID display = number.unsignedIntValue;
        if (!CGDisplayIsBuiltin(display) && CGDisplayIsOnline(display) &&
            (CGDisplayIsActive(display) || CGDisplayIsInMirrorSet(display))) return YES;
    }
    return NO;
}

- (BOOL)isEnabled:(CGDirectDisplayID)display {
    return display && CGDisplayIsOnline(display) &&
        (CGDisplayIsActive(display) || CGDisplayIsInMirrorSet(display));
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
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
    CGDisplayRegisterReconfigurationCallback(DisplayChanged, (__bridge void *)self);
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(willSleep:)
        name:NSWorkspaceWillSleepNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(didWake:)
        name:NSWorkspaceDidWakeNotification object:nil];
    [self displaysChanged];
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
    if (self.managedDisplay && [self isEnabled:self.managedDisplay] && !self.changing) self.managedDisplay = 0;
}

- (void)showError:(NSString *)message {
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
    CGError result = CGBeginDisplayConfiguration(&configuration);
    if (result == kCGErrorSuccess) {
        result = self.configureEnabled(configuration, display, enabled);
        if (result == kCGErrorSuccess) {
            // macOS restores the session configuration when this process exits.
            result = CGCompleteDisplayConfiguration(configuration, kCGConfigureForAppOnly);
        } else {
            CGCancelDisplayConfiguration(configuration);
        }
    }
    if (result != kCGErrorSuccess && error) {
        *error = [NSString stringWithFormat:@"macOS rejected the display change (error %d).", result];
    }
    return result == kCGErrorSuccess;
}

- (void)changeEnabled:(BOOL)enabled {
    if (self.changing) return;
    CGDirectDisplayID display = [self builtinDisplay];
    if (!display) { [self showError:@"No built-in display was found."]; return; }
    if ([self isEnabled:display] == enabled) { [self refresh]; return; }
    self.changing = YES;
    if (!enabled) self.managedDisplay = display;
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
        if ([self isEnabled:display] != enabled) {
            // A private API can report success without applying the change.
            [self setDisplay:display enabled:YES error:NULL];
            [self refresh];
            [self showError:@"macOS did not apply the requested display state. A restore was requested. This macOS build may not support the display toggle API."];
        } else {
            [self displaysChanged];
        }
    });
}

- (void)toggle:(id)sender { [self changeEnabled:![self isEnabled:[self builtinDisplay]]]; }
- (void)restore:(id)sender { [self changeEnabled:YES]; }

- (void)displaysChanged {
    if (self.changing) return;
    CGDirectDisplayID display = [self builtinDisplay];
    if (self.configureEnabled && display && ![self isEnabled:display] && ![self hasExternalDisplay]) {
        [self changeEnabled:YES];
    }
    [self refresh];
}

- (void)willSleep:(NSNotification *)notification {
    if (self.managedDisplay) [self setDisplay:self.managedDisplay enabled:YES error:NULL];
}

- (void)didWake:(NSNotification *)notification {
    if (self.managedDisplay) [self restore:nil];
    [self displaysChanged];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (self.managedDisplay) [self setDisplay:self.managedDisplay enabled:YES error:NULL];
    // The app-only configuration also supplies process-exit recovery.
    return NSTerminateNow;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
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
