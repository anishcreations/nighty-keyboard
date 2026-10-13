#import "PWMBridge.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDLib.h>

@implementation BLPWMBridge {
    IOHIDDeviceRef _device;
    BOOL _descriptorAvailable;
    BOOL _canAttemptControl;
    NSString *_reason;
    uint32_t _minimumCount;
    uint32_t _maximumCount;
    uint64_t _registryID;
    CFIndex _reportLength;
}
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _reason = @"No compatible keyboard-backlight PWM collection found.";
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(MACH_PORT_NULL, IOServiceMatching("IOHIDDevice"), &iterator) != KERN_SUCCESS) return self;
    io_service_t service;
    NSUInteger matches = 0;
    while ((service = IOIteratorNext(iterator))) {
        CFTypeRef page = IORegistryEntryCreateCFProperty(service, CFSTR(kIOHIDPrimaryUsagePageKey), kCFAllocatorDefault, 0);
        CFTypeRef usage = IORegistryEntryCreateCFProperty(service, CFSTR(kIOHIDPrimaryUsageKey), kCFAllocatorDefault, 0);
        BOOL candidate = page && usage && CFGetTypeID(page) == CFNumberGetTypeID() && CFGetTypeID(usage) == CFNumberGetTypeID()
            && [(__bridge NSNumber *)page unsignedIntValue] == 0xff00 && [(__bridge NSNumber *)usage unsignedIntValue] == 0x0f;
        if (page) CFRelease(page); if (usage) CFRelease(usage);
        if (candidate) {
            matches++;
            if (!_device) {
                _device = IOHIDDeviceCreate(kCFAllocatorDefault, service);
                IORegistryEntryGetRegistryEntryID(service, &_registryID);
            }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    if (!_device) return self;
    if (matches != 1) { _reason = @"Multiple backlight collections found; direct PWM control is disabled."; return self; }
    NSArray *elements = CFBridgingRelease(IOHIDDeviceCopyMatchingElements(_device, NULL, 0));
    NSUInteger featureCount = 0;
    BOOL hasDuty = NO, hasFade = NO;
    for (id object in elements) {
        IOHIDElementRef element = (__bridge IOHIDElementRef)object;
        if (IOHIDElementGetType(element) != kIOHIDElementTypeFeature || IOHIDElementGetReportID(element) != 1) continue;
        featureCount++;
        if (IOHIDElementGetUsagePage(element) != 0xff70 || IOHIDElementGetReportSize(element) != 32 || IOHIDElementGetReportCount(element) != 1) continue;
        CFIndex minimum = IOHIDElementGetLogicalMin(element), maximum = IOHIDElementGetLogicalMax(element);
        if (IOHIDElementGetUsage(element) == 1 && minimum > 0 && maximum > minimum && maximum <= UINT32_MAX) {
            _minimumCount = (uint32_t)minimum; _maximumCount = (uint32_t)maximum; hasDuty = YES;
        }
        if (IOHIDElementGetUsage(element) == 2 && minimum == 0 && maximum == 65535) hasFade = YES;
    }
    if (!hasDuty || !hasFade || featureCount != 2) {
        _reason = @"Backlight report layout is unrecognized. No direct PWM writes will be made."; return self;
    }
    _descriptorAvailable = YES;
    IOReturn opened = IOHIDDeviceOpen(_device, kIOHIDOptionsTypeNone);
    if (opened != kIOReturnSuccess) {
        _reason = [NSString stringWithFormat:@"macOS denied opening the PWM collection (0x%08x).", opened]; return self;
    }
    int64_t current = [self readCount];
    if (current < 0) return self;
    _canAttemptControl = YES;
    _reason = @"PWM report is readable. Writes still require verified firmware readback; frequency is controlled by the keyboard.";
    return self;
}
- (void)dealloc {
    if (_device) { IOHIDDeviceClose(_device, kIOHIDOptionsTypeNone); CFRelease(_device); }
}
- (BOOL)descriptorAvailable { return _descriptorAvailable; }
- (BOOL)canAttemptControl { return _canAttemptControl; }
- (NSString *)reason { return _reason; }
- (uint32_t)minimumCount { return _minimumCount; }
- (uint32_t)maximumCount { return _maximumCount; }
- (uint64_t)registryID { return _registryID; }
- (int64_t)readCount {
    if (!_descriptorAvailable) return -1;
    uint8_t report[9] = {1}; CFIndex length = sizeof(report);
    IOReturn result = IOHIDDeviceGetReport(_device, kIOHIDReportTypeFeature, 1, report, &length);
    if (result != kIOReturnSuccess) {
        _canAttemptControl = NO;
        _reason = [NSString stringWithFormat:@"macOS blocks PWM firmware readback (0x%08x). Direct control is disabled; no reports are written.", result];
        return -1;
    }
    // Only the descriptor-verified report-ID + two uint32 layout is writable.
    NSUInteger offset = 1;
    if (length != 9 || report[0] != 1) { _canAttemptControl = NO; _reason = @"PWM readback has an unexpected layout. Control is disabled."; return -1; }
    uint32_t count = 0, duration = 0;
    for (NSUInteger i = 0; i < 4; i++) {
        count |= (uint32_t)report[offset + i] << (8 * i);
        duration |= (uint32_t)report[offset + 4 + i] << (8 * i);
    }
    if ((count != 0 && (count < _minimumCount || count > _maximumCount)) || duration > 65535) {
        _canAttemptControl = NO; _reason = @"PWM state is outside the declared range. Control is disabled."; return -1;
    }
    _reportLength = length;
    return count;
}
- (BOOL)setCount:(uint32_t)count {
    if (!_canAttemptControl || (count != 0 && (count < _minimumCount || count > _maximumCount))) return NO;
    // Require a fresh restorable state before every write, never trust a cached HID value.
    if ([self readCount] < 0) return NO;
    uint8_t report[9] = {1};
    NSUInteger offset = 1;
    for (NSUInteger i = 0; i < 4; i++) report[offset + i] = (uint8_t)(count >> (8 * i));
    // Remaining four bytes are fade duration = zero. There is no app-side PWM loop.
    IOReturn result = IOHIDDeviceSetReport(_device, kIOHIDReportTypeFeature, 1, report, _reportLength);
    if (result != kIOReturnSuccess) { _reason = [NSString stringWithFormat:@"PWM write denied (0x%08x).", result]; return NO; }
    int64_t readback = [self readCount];
    if (readback != count) { _reason = @"PWM write did not match firmware readback. Direct PWM was not confirmed."; return NO; }
    return YES;
}
@end
