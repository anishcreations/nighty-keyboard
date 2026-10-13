#import "KeyboardBridge.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <math.h>

// Runtime signatures for the private CoreBrightness keyboard interface.
@interface NSObject (BLPrivateKeyboardSelectors)
- (NSArray *)copyKeyboardBacklightIDs;
- (BOOL)isKeyboardBuiltIn:(uint64_t)keyboard;
- (float)brightnessForKeyboard:(uint64_t)keyboard;
- (float)backlightLevelForKeyboard:(uint64_t)keyboard;
- (BOOL)isAutoBrightnessEnabledForKeyboard:(uint64_t)keyboard;
- (BOOL)enableAutoBrightness:(BOOL)enabled forKeyboard:(uint64_t)keyboard;
- (BOOL)setBrightness:(float)value fadeSpeed:(int)milliseconds commit:(BOOL)commit forKeyboard:(uint64_t)keyboard;
- (BOOL)isBacklightSuppressedOnKeyboard:(uint64_t)keyboard;
- (BOOL)isBacklightDimmedOnKeyboard:(uint64_t)keyboard;
- (BOOL)isIdleDimmingSuspendedOnKeyboard:(uint64_t)keyboard;
- (BOOL)suspendIdleDimming:(BOOL)suspended forKeyboard:(uint64_t)keyboard;
- (id)copyPropertyForKey:(NSString *)key keyboardID:(uint64_t)keyboard;
- (BOOL)setProperty:(id)value withKey:(NSString *)key keyboardID:(uint64_t)keyboard;
- (BOOL)activateWithError:(NSError **)error;
- (void)cancel;
@end

static BOOL BLTypeMatches(const char *actual, const char *expected) {
    while (strchr("rnNoORV", *actual) && *actual) actual++;
    // ObjC BOOL is signed char on Intel, bool on Apple Silicon.
    if (!strcmp(expected, "B")) return !strcmp(actual, "B") || !strcmp(actual, "c");
    if (!strcmp(expected, "Q")) return !strcmp(actual, @encode(uint64_t));
    return !strcmp(actual, expected);
}
static BOOL BLHasSignature(id obj, NSString *name, const char *result, NSArray<NSString *> *arguments) {
    SEL sel = NSSelectorFromString(name);
    if (![obj respondsToSelector:sel]) return NO;
    NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
    if (!sig || !BLTypeMatches(sig.methodReturnType, result) || sig.numberOfArguments != arguments.count + 2) return NO;
    for (NSUInteger i = 0; i < arguments.count; i++) {
        if (!BLTypeMatches([sig getArgumentTypeAtIndex:i + 2], arguments[i].UTF8String)) return NO;
    }
    return YES;
}

@implementation BLKeyboardBridge {
    id _client;
    id _writer;
    BOOL _available;
    NSString *_availabilityReason;
}
- (instancetype)init {
    if (!(self = [super init])) return nil;
    // Deliberately retained for the process lifetime: unloading would invalidate ObjC classes.
    if (!dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY | RTLD_LOCAL)) {
        _availabilityReason = @"This macOS version does not expose keyboard brightness controls.";
        return self;
    }
    Class cls = NSClassFromString(@"KeyboardBrightnessClient");
    if (!cls) { _availabilityReason = @"Keyboard brightness service is unavailable."; return self; }
    @try { _client = [[cls alloc] init]; } @catch (NSException *exception) { _client = nil; }
    BOOL valid = BLHasSignature(_client, @"copyKeyboardBacklightIDs", "@", @[])
        && BLHasSignature(_client, @"brightnessForKeyboard:", "f", @[@"Q"])
        && BLHasSignature(_client, @"isAutoBrightnessEnabledForKeyboard:", "B", @[@"Q"])
        && BLHasSignature(_client, @"enableAutoBrightness:forKeyboard:", "B", @[@"B", @"Q"])
        && BLHasSignature(_client, @"setBrightness:fadeSpeed:commit:forKeyboard:", "B", @[@"f", @"i", @"B", @"Q"]);
    _available = valid;
    _availabilityReason = valid ? @"" : @"Apple changed the keyboard interface. Nighty Keyboard cannot safely control it.";
    return self;
}
- (BOOL)available { return _available; }
- (NSString *)availabilityReason { return _availabilityReason; }
- (NSArray<NSNumber *> *)keyboardIDs {
    if (!_available) return @[];
    @try {
        id result = [_client copyKeyboardBacklightIDs];
        if (![result isKindOfClass:NSArray.class]) return @[];
        NSMutableArray *ids = [NSMutableArray array];
        for (id item in result) if ([item isKindOfClass:NSNumber.class]) [ids addObject:item];
        return ids;
    } @catch (NSException *exception) { return @[]; }
}
- (BOOL)isBuiltIn:(uint64_t)keyboard {
    if (!BLHasSignature(_client, @"isKeyboardBuiltIn:", "B", @[@"Q"])) return NO;
    @try { return [_client isKeyboardBuiltIn:keyboard]; } @catch (NSException *exception) { return NO; }
}
- (float)brightness:(uint64_t)keyboard {
    if (!_available) return -1;
    @try { return [_client brightnessForKeyboard:keyboard]; } @catch (NSException *exception) { return -1; }
}
- (float)backlightLevel:(uint64_t)keyboard {
    if (!BLHasSignature(_client, @"backlightLevelForKeyboard:", "f", @[@"Q"])) return -1;
    @try { return [_client backlightLevelForKeyboard:keyboard]; } @catch (NSException *exception) { return -1; }
}
- (BOOL)automaticBrightness:(uint64_t)keyboard {
    if (!_available) return NO;
    @try { return [_client isAutoBrightnessEnabledForKeyboard:keyboard]; } @catch (NSException *exception) { return NO; }
}
- (BOOL)openWriter {
    if (_writer) return YES;
    Class cls = NSClassFromString(@"BrightnessSystemClient");
    if (!cls) return NO;
    @try { _writer = [[cls alloc] init]; } @catch (NSException *exception) { return NO; }
    if (!BLHasSignature(_writer, @"setProperty:withKey:keyboardID:", "B", @[@"@", @"@", @"Q"])) { _writer = nil; return NO; }
    if (BLHasSignature(_writer, @"activateWithError:", "B", @[@"^@"])) {
        NSError *error = nil;
        if (![_writer activateWithError:&error]) { _writer = nil; return NO; }
    }
    return YES;
}
- (BOOL)setAutomaticBrightness:(BOOL)enabled keyboard:(uint64_t)keyboard {
    if (!_available || ![self openWriter]) return NO;
    @try { return [_writer setProperty:@(enabled) withKey:@"KeyboardBacklightABEnabled" keyboardID:keyboard]; }
    @catch (NSException *exception) { return NO; }
}
- (BOOL)setBrightness:(float)value keyboard:(uint64_t)keyboard {
    if (!_available || !isfinite(value) || value < 0 || value > 1 || ![self openWriter]) return NO;
    @try {
        // Use the normal manual-brightness path. No commit=false fade experiments.
        // Apple supplies a single smooth transition; the app never runs a fade loop.
        return [_writer setProperty:@(value) withKey:@"KeyboardBacklightBrightness" keyboardID:keyboard];
    } @catch (NSException *exception) { return NO; }
}
- (BOOL)restoreBrightness:(float)value keyboard:(uint64_t)keyboard {
    if (!_available || !isfinite(value) || value < 0 || value > 1 || ![self openWriter]) return NO;
    @try {
        // Explicit restoration only: clear idle dimming before a nonzero request.
        // Never used by the fade loop or the sleep handler.
        if (value > 0 && BLHasSignature(_writer, @"copyPropertyForKey:keyboardID:", "@", @[@"@", @"Q"])) {
            id idle = [_writer copyPropertyForKey:@"KeyboardBacklightIdleDimActive" keyboardID:keyboard];
            if ([idle isKindOfClass:NSNumber.class] && [idle boolValue]) {
                if (![_writer setProperty:@NO withKey:@"KeyboardBacklightIdleDimActive" keyboardID:keyboard]) return NO;
            }
        }
        return [_writer setProperty:@(value) withKey:@"KeyboardBacklightBrightness" keyboardID:keyboard];
    } @catch (NSException *exception) { return NO; }
}
- (BOOL)setFade:(float)value milliseconds:(int)milliseconds keyboard:(uint64_t)keyboard {
    if (!_available || !isfinite(value) || value < 0 || value > 1 || milliseconds < 0 || milliseconds > 10000 || ![self openWriter]) return NO;
    @try {
        // Fade property dictionary accepted by CoreBrightness.
        // Commit YES avoids the commit=false automatic-brightness suspension path.
        return [_writer setProperty:@{@"Brightness": @(value), @"FadeSpeed": @(milliseconds), @"Commit": @YES}
                           withKey:@"KeyboardBacklightBrightness" keyboardID:keyboard];
    } @catch (NSException *exception) { return NO; }
}
- (void)releaseManualControl {
    if (BLHasSignature(_writer, @"cancel", "v", @[])) {
        @try { [_writer cancel]; } @catch (NSException *exception) { }
    }
    _writer = nil;
}
- (BOOL)isSuppressed:(uint64_t)keyboard {
    if (!BLHasSignature(_client, @"isBacklightSuppressedOnKeyboard:", "B", @[@"Q"])) return NO;
    @try { return [_client isBacklightSuppressedOnKeyboard:keyboard]; } @catch (NSException *exception) { return NO; }
}
- (BOOL)isIdleDimmed:(uint64_t)keyboard {
    if (!BLHasSignature(_client, @"isBacklightDimmedOnKeyboard:", "B", @[@"Q"])) return NO;
    @try { return [_client isBacklightDimmedOnKeyboard:keyboard]; } @catch (NSException *exception) { return NO; }
}
- (BOOL)supportsIdleSuspension {
    return BLHasSignature(_client, @"isIdleDimmingSuspendedOnKeyboard:", "B", @[@"Q"])
        && BLHasSignature(_client, @"suspendIdleDimming:forKeyboard:", "B", @[@"B", @"Q"]);
}
- (BOOL)idleDimmingSuspended:(uint64_t)keyboard {
    if (![self supportsIdleSuspension]) return NO;
    @try { return [_client isIdleDimmingSuspendedOnKeyboard:keyboard]; } @catch (NSException *exception) { return NO; }
}
- (BOOL)setIdleDimmingSuspended:(BOOL)suspended keyboard:(uint64_t)keyboard {
    if (![self supportsIdleSuspension]) return NO;
    @try { return [_client suspendIdleDimming:suspended forKeyboard:keyboard]; } @catch (NSException *exception) { return NO; }
}

@end
