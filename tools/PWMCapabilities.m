#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDLib.h>

// Read-only: never grabs input events, opens keyboard collections, or writes reports.
int main(void) { @autoreleasepool {
 io_iterator_t iterator=0;
 kern_return_t status=IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOHIDDevice"),&iterator);
 if(status!=KERN_SUCCESS) { printf("Enumeration failed: 0x%x\n",status); return 1; }
 NSMutableArray *results=[NSMutableArray array]; io_service_t service;
 while((service=IOIteratorNext(iterator))) {
   NSDictionary *properties=nil; CFMutableDictionaryRef raw=NULL;
   if(IORegistryEntryCreateCFProperties(service,&raw,kCFAllocatorDefault,0)==KERN_SUCCESS) properties=CFBridgingRelease(raw);
   NSString *product=[properties[@"Product"] isKindOfClass:NSString.class] ? properties[@"Product"] : @"";
   NSNumber *page=properties[@"PrimaryUsagePage"], *usage=properties[@"PrimaryUsage"];
   BOOL backlight=[product.lowercaseString containsString:@"backlight"] || (page.unsignedIntValue==0xff00 && usage.unsignedIntValue==0x0f);
   if(backlight || page.unsignedIntValue==0xff00) {
     NSMutableDictionary *entry=[@{@"product":product,@"usagePage":page ?: @0,@"usage":usage ?: @0,@"backlightCandidate":@(backlight)} mutableCopy];
     if(backlight) {
       IOHIDDeviceRef device=IOHIDDeviceCreate(kCFAllocatorDefault,service);
       if(device) {
         NSArray *elements=CFBridgingRelease(IOHIDDeviceCopyMatchingElements(device,NULL,0));
         NSMutableArray *descriptors=[NSMutableArray array];
         for(id value in elements) {
           IOHIDElementRef element=(__bridge IOHIDElementRef)value;
           [descriptors addObject:@{@"usagePage":@(IOHIDElementGetUsagePage(element)),@"usage":@(IOHIDElementGetUsage(element)),@"type":@(IOHIDElementGetType(element)),@"logicalMin":@(IOHIDElementGetLogicalMin(element)),@"logicalMax":@(IOHIDElementGetLogicalMax(element)),@"physicalMin":@(IOHIDElementGetPhysicalMin(element)),@"physicalMax":@(IOHIDElementGetPhysicalMax(element)),@"reportID":@(IOHIDElementGetReportID(element)),@"bits":@(IOHIDElementGetReportSize(element)),@"count":@(IOHIDElementGetReportCount(element))}];
         }
         entry[@"elements"]=descriptors; CFRelease(device);
       }
     }
     [results addObject:entry];
   }
   IOObjectRelease(service);
 }
 IOObjectRelease(iterator);
 NSData *output=[NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
 puts([[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding].UTF8String);
} }
