#import <Foundation/Foundation.h>
#import "PWMBridge.h"

NS_ASSUME_NONNULL_BEGIN
/// A narrow, runtime-checked boundary around Apple's private keyboard interface.
@interface BLKeyboardBridge : NSObject
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly) NSString *availabilityReason;
- (NSArray<NSNumber *> *)keyboardIDs;
- (BOOL)isBuiltIn:(uint64_t)keyboard NS_SWIFT_NAME(isBuiltIn(_:));
- (float)brightness:(uint64_t)keyboard;
- (float)backlightLevel:(uint64_t)keyboard;
- (BOOL)automaticBrightness:(uint64_t)keyboard;
- (BOOL)setAutomaticBrightness:(BOOL)enabled keyboard:(uint64_t)keyboard;
- (BOOL)setBrightness:(float)value keyboard:(uint64_t)keyboard;
- (BOOL)restoreBrightness:(float)value keyboard:(uint64_t)keyboard;
- (BOOL)setFade:(float)value milliseconds:(int)milliseconds keyboard:(uint64_t)keyboard;
- (void)releaseManualControl;
- (BOOL)isSuppressed:(uint64_t)keyboard;
- (BOOL)isIdleDimmed:(uint64_t)keyboard;
- (BOOL)supportsIdleSuspension;
- (BOOL)idleDimmingSuspended:(uint64_t)keyboard;
- (BOOL)setIdleDimmingSuspended:(BOOL)suspended keyboard:(uint64_t)keyboard;
@end
NS_ASSUME_NONNULL_END
