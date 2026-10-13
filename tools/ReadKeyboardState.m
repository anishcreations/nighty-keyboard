#import <Foundation/Foundation.h>
#import <dlfcn.h>
@interface NSObject (NightyReadOnly)
- (NSArray *)copyKeyboardBacklightIDs;
- (BOOL)isKeyboardBuiltIn:(uint64_t)keyboard;
- (id)copyPropertyForKey:(NSString *)key keyboardID:(uint64_t)keyboard;
@end
int main(void) { @autoreleasepool {
 dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY);
 id reader=[[NSClassFromString(@"KeyboardBrightnessClient") alloc] init];
 id client=[[NSClassFromString(@"BrightnessSystemClient") alloc] init];
 if(![client respondsToSelector:@selector(copyPropertyForKey:keyboardID:)]) return 1;
 for(NSNumber *item in [reader copyKeyboardBacklightIDs]) {
  if(![reader isKeyboardBuiltIn:item.unsignedLongLongValue]) continue;
  NSMutableDictionary *state=[NSMutableDictionary dictionary];
  for(NSString *key in @[@"KeyboardBacklightBrightness",@"KeyboardBacklightLevel",@"KeyboardBacklightABEnabled",@"KeyboardBacklightABSuspend",@"KeyboardBacklightIdleDimActive",@"KeyboardBacklightSuspendDimming",@"KeyboardBacklightSuppressed",@"KeyboardBacklightMuted",@"KeyboardBacklightIdleDimTime"]) {
   state[key]=[client copyPropertyForKey:key keyboardID:item.unsignedLongLongValue] ?: NSNull.null;
  }
  NSData *data=[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil];
  puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
 }
 return 0;
} }
