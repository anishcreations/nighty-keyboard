#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Controls only a verified vendor backlight collection. No keystroke access.
@interface BLPWMBridge : NSObject
@property(nonatomic, readonly) BOOL descriptorAvailable;
@property(nonatomic, readonly) BOOL canAttemptControl;
@property(nonatomic, readonly) NSString *reason;
@property(nonatomic, readonly) uint32_t minimumCount;
@property(nonatomic, readonly) uint32_t maximumCount;
@property(nonatomic, readonly) uint64_t registryID;
/// -1 means firmware readback was unavailable or invalid; never a usable snapshot.
- (int64_t)readCount;
/// Sends one zero-fade report, then requires independent firmware readback.
- (BOOL)setCount:(uint32_t)count;
@end
NS_ASSUME_NONNULL_END
