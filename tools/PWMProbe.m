// Bounded manual probe for the CoreBrightness keyboard interface.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <math.h>
@interface NSObject (NightyProbe)
- (NSArray *)copyKeyboardBacklightIDs;
- (BOOL)isKeyboardBuiltIn:(uint64_t)keyboard;
- (float)brightnessForKeyboard:(uint64_t)keyboard;
- (float)backlightLevelForKeyboard:(uint64_t)keyboard;
- (BOOL)isAutoBrightnessEnabledForKeyboard:(uint64_t)keyboard;
- (BOOL)activateWithError:(NSError **)error;
- (id)copyPropertyForKey:(NSString *)key keyboardID:(uint64_t)keyboard;
- (BOOL)setProperty:(id)value withKey:(NSString *)key keyboardID:(uint64_t)keyboard;
@end
int main(int argc, char **argv) { @autoreleasepool {
 if (!dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)) return 1;
 id reader=[[NSClassFromString(@"KeyboardBrightnessClient") alloc] init];
 id writer=[[NSClassFromString(@"BrightnessSystemClient") alloc] init];
 for (NSString *key in @[@"setProperty:withKey:keyboardID:", @"copyPropertyForKey:keyboardID:"])
  if (![writer respondsToSelector:NSSelectorFromString(key)]) return 1;
 NSError *error=nil; if ([writer respondsToSelector:@selector(activateWithError:)])
  printf("activate=%d\n",[writer activateWithError:&error]);
 NSArray *ids=[reader copyKeyboardBacklightIDs]; NSNumber *chosen=nil;
 for (NSNumber *number in ids) if ([reader isKeyboardBuiltIn:number.unsignedLongLongValue]) { chosen=number; break; }
 if(!chosen) { puts("No built-in keyboard"); return 2; } uint64_t keyboard=chosen.unsignedLongLongValue;
 NSArray *keys=@[@"KeyboardBacklightBrightness", @"KeyboardBacklightLevel", @"KeyboardBacklightABEnabled", @"KeyboardBacklightABSuspend", @"KeyboardBacklightIdleDimTime", @"KeyboardBacklightIdleDimActive", @"KeyboardBacklightSuppressed", @"KeyboardBacklightMuted", @"KeyboardBacklightSuspendDimming", @"KeyboardBacklightMaxUser"];
 for(NSString *key in keys) NSLog(@"%@: %@",key,[writer copyPropertyForKey:key keyboardID:keyboard]);
 if (argc < 2) return 0;
 id original=[writer copyPropertyForKey:@"KeyboardBacklightBrightness" keyboardID:keyboard];
 id automatic=[writer copyPropertyForKey:@"KeyboardBacklightABEnabled" keyboardID:keyboard];
 if(![original isKindOfClass:NSNumber.class] || ![automatic isKindOfClass:NSNumber.class]) { puts("No restorable state; no writes"); return 2; }
 // Write a durable record compatible with the app BEFORE any hardware writes.
 NSString *directory=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Nighty Keyboard"];
 [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error];
 NSString *path=[directory stringByAppendingPathComponent:@"keyboard-session.json"];
 if ([[NSFileManager defaultManager] fileExistsAtPath:path]) { puts("Existing recovery session; no writes"); return 2; }
 NSDictionary *snapshot=@{@"keyboardID":chosen,@"brightness":original,@"automatic":@([automatic boolValue])};
 NSData *record=[NSJSONSerialization dataWithJSONObject:snapshot options:0 error:&error];
 if(![record writeToFile:path options:NSDataWritingAtomic error:&error]) { puts("Recovery save failed; no writes"); return 1; }
 BOOL restored=NO;
 @try {
   for(NSNumber *value in @[@0.0001,@0.001,@0.005,@0.01,@0.0625]) {
     BOOL accepted=[writer setProperty:value withKey:@"KeyboardBacklightBrightness" keyboardID:keyboard];
     [NSThread sleepForTimeInterval:0.12];
     printf("request=%.6f accepted=%d logical=%.6f level=%.6f\n",value.floatValue,accepted,[reader brightnessForKeyboard:keyboard],[reader backlightLevelForKeyboard:keyboard]);
   }
 } @finally {
   BOOL brightnessOK=[writer setProperty:original withKey:@"KeyboardBacklightBrightness" keyboardID:keyboard];
   BOOL autoOK=[writer setProperty:automatic withKey:@"KeyboardBacklightABEnabled" keyboardID:keyboard];
   [NSThread sleepForTimeInterval:0.1];
   restored=brightnessOK && autoOK && fabsf([reader brightnessForKeyboard:keyboard]-[original floatValue])<0.00001 && [reader isAutoBrightnessEnabledForKeyboard:keyboard]==[automatic boolValue];
   if(restored) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
   printf("Restoration verified=%d\n",restored);
 }
 return restored ? 0 : 1;
} }
