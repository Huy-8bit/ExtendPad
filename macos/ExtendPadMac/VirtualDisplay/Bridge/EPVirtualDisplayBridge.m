#import "EPVirtualDisplayBridge.h"
#import <objc/message.h>

// Selector signatures verified by runtime introspection on macOS 15.7 (24G517):
//   CGVirtualDisplayDescriptor: -setName:(id) -setMaxPixelsWide:(uint32) -setMaxPixelsHigh:(uint32)
//     -setSizeInMillimeters:(CGSize) -setVendorID:(uint32) -setProductID:(uint32)
//     -setSerialNum:(uint32) -setQueue:(dispatch_queue_t) -setTerminationHandler:(block)
//   CGVirtualDisplay: -initWithDescriptor:(id) -applySettings:(id)->BOOL -displayID->uint32
//   CGVirtualDisplaySettings: -setModes:(NSArray) -setHiDPI:(uint32)
//   CGVirtualDisplayMode: -initWithWidth:(uint32)height:(uint32)refreshRate:(double)

static NSString *const EPErrorDomain = @"com.extendpad.virtualdisplay";

@implementation EPVirtualDisplayModeSpec
+ (instancetype)specWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)refreshRate {
    EPVirtualDisplayModeSpec *s = [[EPVirtualDisplayModeSpec alloc] init];
    s.width = width; s.height = height; s.refreshRate = refreshRate;
    return s;
}
@end

@implementation EPVirtualDisplay {
    id _display;          // CGVirtualDisplay (private)
    CGDirectDisplayID _displayID;
}

+ (NSString *)unsupportedReason {
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    Class desc = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class disp = NSClassFromString(@"CGVirtualDisplay");
    Class sett = NSClassFromString(@"CGVirtualDisplaySettings");
    Class mode = NSClassFromString(@"CGVirtualDisplayMode");
    if (!desc) [missing addObject:@"CGVirtualDisplayDescriptor"];
    if (!disp) [missing addObject:@"CGVirtualDisplay"];
    if (!sett) [missing addObject:@"CGVirtualDisplaySettings"];
    if (!mode) [missing addObject:@"CGVirtualDisplayMode"];
    if (desc) {
        for (NSString *s in @[@"setName:", @"setMaxPixelsWide:", @"setMaxPixelsHigh:", @"setSizeInMillimeters:",
                              @"setVendorID:", @"setProductID:", @"setSerialNum:", @"setQueue:", @"setTerminationHandler:"]) {
            if (![desc instancesRespondToSelector:NSSelectorFromString(s)]) [missing addObject:[@"Descriptor." stringByAppendingString:s]];
        }
    }
    if (disp) {
        for (NSString *s in @[@"initWithDescriptor:", @"applySettings:", @"displayID"]) {
            if (![disp instancesRespondToSelector:NSSelectorFromString(s)]) [missing addObject:[@"Display." stringByAppendingString:s]];
        }
    }
    if (sett) {
        for (NSString *s in @[@"setModes:", @"setHiDPI:"]) {
            if (![sett instancesRespondToSelector:NSSelectorFromString(s)]) [missing addObject:[@"Settings." stringByAppendingString:s]];
        }
    }
    if (mode && ![mode instancesRespondToSelector:@selector(initWithWidth:height:refreshRate:)]) {
        [missing addObject:@"Mode.initWithWidth:height:refreshRate:"];
    }
    if (missing.count == 0) return @"";
    return [@"Missing private CoreGraphics API: " stringByAppendingString:[missing componentsJoinedByString:@", "]];
}

+ (BOOL)isSupported {
    return [self unsupportedReason].length == 0;
}

- (nullable instancetype)initWithName:(NSString *)name
                         maxPixelsWide:(uint32_t)maxW
                         maxPixelsHigh:(uint32_t)maxH
                     sizeInMillimeters:(CGSize)sizeMM
                              vendorID:(uint32_t)vendorID
                             productID:(uint32_t)productID
                          serialNumber:(uint32_t)serial
                    terminationHandler:(nullable void (^)(void))terminationHandler
                                 error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    NSString *reason = [EPVirtualDisplay unsupportedReason];
    if (reason.length > 0) {
        if (error) *error = [NSError errorWithDomain:EPErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: reason}];
        return nil;
    }

    @try {
        id desc = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        ((void (*)(id, SEL, id))objc_msgSend)(desc, NSSelectorFromString(@"setName:"), name);
        ((void (*)(id, SEL, uint32_t))objc_msgSend)(desc, NSSelectorFromString(@"setMaxPixelsWide:"), maxW);
        ((void (*)(id, SEL, uint32_t))objc_msgSend)(desc, NSSelectorFromString(@"setMaxPixelsHigh:"), maxH);
        ((void (*)(id, SEL, CGSize))objc_msgSend)(desc, NSSelectorFromString(@"setSizeInMillimeters:"), sizeMM);
        ((void (*)(id, SEL, uint32_t))objc_msgSend)(desc, NSSelectorFromString(@"setVendorID:"), vendorID);
        ((void (*)(id, SEL, uint32_t))objc_msgSend)(desc, NSSelectorFromString(@"setProductID:"), productID);
        ((void (*)(id, SEL, uint32_t))objc_msgSend)(desc, NSSelectorFromString(@"setSerialNum:"), serial);
        ((void (*)(id, SEL, id))objc_msgSend)(desc, NSSelectorFromString(@"setQueue:"), dispatch_get_main_queue());
        void (^handler)(id, id) = ^(id a, id b) { if (terminationHandler) terminationHandler(); };
        ((void (*)(id, SEL, id))objc_msgSend)(desc, NSSelectorFromString(@"setTerminationHandler:"), handler);

        id display = ((id (*)(id, SEL, id))objc_msgSend)([NSClassFromString(@"CGVirtualDisplay") alloc],
                                                          NSSelectorFromString(@"initWithDescriptor:"), desc);
        if (!display) {
            if (error) *error = [NSError errorWithDomain:EPErrorDomain code:2
                                                userInfo:@{NSLocalizedDescriptionKey: @"WindowServer refused to create the virtual display (CGVirtualDisplay init returned nil)."}];
            return nil;
        }
        _display = display;
        _displayID = ((uint32_t (*)(id, SEL))objc_msgSend)(display, NSSelectorFromString(@"displayID"));
        if (_displayID == 0 || _displayID == kCGNullDirectDisplay) {
            _display = nil;
            if (error) *error = [NSError errorWithDomain:EPErrorDomain code:3
                                                userInfo:@{NSLocalizedDescriptionKey: @"Virtual display was created without a valid CGDirectDisplayID."}];
            return nil;
        }
    } @catch (NSException *ex) {
        _display = nil;
        if (error) *error = [NSError errorWithDomain:EPErrorDomain code:4
                                            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Private API raised %@: %@", ex.name, ex.reason]}];
        return nil;
    }
    return self;
}

- (BOOL)applyModes:(NSArray<EPVirtualDisplayModeSpec *> *)modes hiDPI:(BOOL)hiDPI {
    if (!_display || modes.count == 0) return NO;
    @try {
        NSMutableArray *cgModes = [NSMutableArray arrayWithCapacity:modes.count];
        Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
        for (EPVirtualDisplayModeSpec *m in modes) {
            id cgMode = ((id (*)(id, SEL, uint32_t, uint32_t, double))objc_msgSend)([modeClass alloc],
                            @selector(initWithWidth:height:refreshRate:), m.width, m.height, m.refreshRate);
            if (cgMode) [cgModes addObject:cgMode];
        }
        id settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
        ((void (*)(id, SEL, uint32_t))objc_msgSend)(settings, NSSelectorFromString(@"setHiDPI:"), hiDPI ? 1u : 0u);
        ((void (*)(id, SEL, id))objc_msgSend)(settings, NSSelectorFromString(@"setModes:"), cgModes);
        return ((BOOL (*)(id, SEL, id))objc_msgSend)(_display, NSSelectorFromString(@"applySettings:"), settings);
    } @catch (NSException *ex) {
        NSLog(@"[ExtendPad] applySettings raised %@: %@", ex.name, ex.reason);
        return NO;
    }
}

- (CGDirectDisplayID)displayID { return _displayID; }

- (void)invalidate {
    _display = nil;   // releasing the CGVirtualDisplay removes it from WindowServer
    _displayID = 0;
}

- (void)dealloc { _display = nil; }

@end
