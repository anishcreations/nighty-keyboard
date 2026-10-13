#import <Foundation/Foundation.h>
#import <dlfcn.h>
@interface NSObject (NightyRepair)
- (NSArray *)copyKeyboardBacklightIDs;
- (BOOL)isKeyboardBuiltIn:(uint64_t)keyboard;
- (BOOL)activateWithError:(NSError **)error;
- (id)copyPropertyForKey:(NSString *)key keyboardID:(uint64_t)keyboard;
- (BOOL)setProperty:(id)value withKey:(NSString *)key keyboardID:(uint64_t)keyboard;
@end
int main(int argc, char **argv) { @autoreleasepool {
 dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY);
 id reader=[[NSClassFromString(@"KeyboardBrightnessClient") alloc] init];
 id client=[[NSClassFromString(@"BrightnessSystemClient") alloc] init];
 if(![client respondsToSelector:@selector(setProperty:withKey:keyboardID:)] || ![client respondsToSelector:@selector(copyPropertyForKey:keyboardID:)]) return 1;
 NSError *error=nil; if([client respondsToSelector:@selector(activateWithError:)]) [client activateWithError:&error];
 NSNumber *chosen=nil; for(NSNumber *item in [reader copyKeyboardBacklightIDs]) if([reader isKeyboardBuiltIn:item.unsignedLongLongValue]) { chosen=item; break; }
 if(!chosen) return 2; uint64_t keyboard=chosen.unsignedLongLongValue;
 NSArray *keys=@[@"KeyboardBacklightBrightness",@"KeyboardBacklightLevel",@"KeyboardBacklightABEnabled",@"KeyboardBacklightABSuspend",@"KeyboardBacklightIdleDimActive",@"KeyboardBacklightSuspendDimming",@"KeyboardBacklightSuppressed",@"KeyboardBacklightMuted",@"KeyboardBacklightIdleDimTime"];
 NSMutableDictionary *before=[NSMutableDictionary dictionary];
 for(NSString *key in keys) before[key]=[client copyPropertyForKey:key keyboardID:keyboard] ?: NSNull.null;
 if(argc<2) { NSLog(@"%@",before); return 0; }
 // A repair of normal macOS control, not a dimming experiment. Preserve a journal.
 NSData *backup=[NSJSONSerialization dataWithJSONObject:before options:NSJSONWritingPrettyPrinted error:&error];
 if(![backup writeToFile:@"build/keyboard-before-repair.json" options:NSDataWritingAtomic error:&error]) { puts("Could not save repair journal; no changes made"); return 1; }
 BOOL idle=[client setProperty:@NO withKey:@"KeyboardBacklightIdleDimActive" keyboardID:keyboard];
 printf("Clear stale idle dim: %d\n",idle);
 BOOL level=[client setProperty:@0.125 withKey:@"KeyboardBacklightBrightness" keyboardID:keyboard];
 printf("Request normal 12.5%% keyboard brightness: %d\n",level);
 [NSThread sleepForTimeInterval:0.5];
 NSMutableDictionary *after=[NSMutableDictionary dictionary];
 for(NSString *key in keys) after[key]=[client copyPropertyForKey:key keyboardID:keyboard] ?: NSNull.null;
 NSLog(@"After repair: %@",after);
 BOOL confirmed=[after[@"KeyboardBacklightBrightness"] isKindOfClass:NSNumber.class] && [after[@"KeyboardBacklightBrightness"] floatValue]>0;
 printf("Normal brightness readback confirmed: %d\n",confirmed);
 return confirmed ? 0 : 2;
} }
