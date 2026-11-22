// ExtendPad — compatibility shim around Apple's *private* CGVirtualDisplay API.
//
// Every private class and selector is resolved at runtime with NSClassFromString /
// respondsToSelector:, so the app still launches (and reports a clear error) on a
// macOS release where the API was removed or changed. Nothing here disables SIP,
// installs a driver or touches the kernel: the display lives inside WindowServer and is
// destroyed automatically when this process exits or crashes.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface EPVirtualDisplayModeSpec : NSObject
@property (nonatomic) uint32_t width;   // pixels passed to CGVirtualDisplayMode
@property (nonatomic) uint32_t height;
@property (nonatomic) double refreshRate;
+ (instancetype)specWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)refreshRate;
@end

@interface EPVirtualDisplay : NSObject

/// YES when all private classes and selectors required by this shim exist.
+ (BOOL)isSupported;
/// Human-readable description of what is missing (empty when supported).
+ (NSString *)unsupportedReason;

/// Creates a virtual display. Returns nil and fills `error` on failure.
/// `terminationHandler` runs on the main queue if WindowServer terminates the display.
- (nullable instancetype)initWithName:(NSString *)name
                         maxPixelsWide:(uint32_t)maxW
                         maxPixelsHigh:(uint32_t)maxH
                     sizeInMillimeters:(CGSize)sizeMM
                              vendorID:(uint32_t)vendorID
                             productID:(uint32_t)productID
                          serialNumber:(uint32_t)serial
                    terminationHandler:(nullable void (^)(void))terminationHandler
                                 error:(NSError * _Nullable * _Nullable)error;

/// Applies a mode list. hiDPI=YES lets macOS derive Retina "looks like" modes.
- (BOOL)applyModes:(NSArray<EPVirtualDisplayModeSpec *> *)modes hiDPI:(BOOL)hiDPI;

@property (nonatomic, readonly) CGDirectDisplayID displayID;

/// Releases the underlying display. Safe to call more than once.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
