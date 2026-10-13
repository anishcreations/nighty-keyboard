#import <Foundation/Foundation.h>
#import "../Sources/Hardware/KeyboardBridge.h"
#import <math.h>
// Explicit repair utility; never called by the application or read-only diagnostics.
int main(int argc, char **argv) { @autoreleasepool {
 if (argc != 2) { puts("Usage: RestoreSavedKeyboard <keyboard-session.json>"); return 2; }
 NSError *error = nil;
 NSString *path = [NSString stringWithUTF8String:argv[1]];
 NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&error];
 NSDictionary *saved = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
 if (![saved isKindOfClass:NSDictionary.class] || ![saved[@"keyboardID"] isKindOfClass:NSNumber.class] ||
     ![saved[@"brightness"] isKindOfClass:NSNumber.class] || ![saved[@"automatic"] isKindOfClass:NSNumber.class]) return 2;
 float target = [saved[@"brightness"] floatValue]; uint64_t keyboard = [saved[@"keyboardID"] unsignedLongLongValue];
 if (!isfinite(target) || target < 0 || target > 1) return 2;
 BLKeyboardBridge *bridge = [[BLKeyboardBridge alloc] init];
 if (!bridge.available || ![bridge.keyboardIDs containsObject:@(keyboard)] || ![bridge isBuiltIn:keyboard]) return 2;
 if (![data writeToFile:@"build/recovery-before-repair.json" options:NSDataWritingAtomic error:&error]) return 2;
 BOOL level = [bridge restoreBrightness:target keyboard:keyboard];
 BOOL sensor = [bridge setAutomaticBrightness:[saved[@"automatic"] boolValue] keyboard:keyboard];
 [NSThread sleepForTimeInterval:0.7];
 float actual = [bridge brightness:keyboard];
 BOOL verified = level && sensor && isfinite(actual) && fabsf(actual-target) <= fmaxf(0.00001f,target*0.02f)
     && [bridge automaticBrightness:keyboard] == [saved[@"automatic"] boolValue];
 [bridge releaseManualControl];
 printf("Saved level: %.4f%%; readback: %.4f%%; verified: %s\n",target*100,actual*100,verified ? "yes" : "no");
 // Never remove the recovery file unless the exact saved settings have been verified.
 if (verified && ![[NSFileManager defaultManager] removeItemAtPath:path error:&error]) return 3;
 return verified ? 0 : 1;
} }
