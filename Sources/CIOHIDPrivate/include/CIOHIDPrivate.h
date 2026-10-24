#ifndef CIOHIDPRIVATE_H
#define CIOHIDPRIVATE_H

// Declarations for the IOHIDEventSystemClient calls that read the temperature sensors (design §8.4,
// plan "Hechos de la fase Navigate"). Part of this API is private: a macOS update can remove or change
// it, and the daemon then reports unknown temperatures and keeps the secondary heat sources.
//
// The private functions are weak imports: if macOS drops one, dyld binds it to NULL instead of refusing
// to start agentmode, so `off`, `uninstall` and the daemon keep working (A1). Check
// `CIOHIDPrivateIsAvailable()` before calling any of them.
//
// The SDK already declares the client and service types publicly; reusing them keeps a single
// definition of each CF type. All functions follow the Create/Copy rule, so with implicit bridging
// Swift releases every returned object.

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <stdbool.h>
#include <stdint.h>

CF_EXTERN_C_BEGIN
CF_IMPLICIT_BRIDGING_ENABLED
CF_ASSUME_NONNULL_BEGIN

/// An event read from a HID service; opaque.
typedef struct CF_BRIDGED_TYPE(id) __IOHIDEvent *IOHIDEventRef;

/// Whether every private function below exists in this macOS.
bool CIOHIDPrivateIsAvailable(void);

/// Private: a client of the HID event system that can see every service, sensors included.
IOHIDEventSystemClientRef _Nullable IOHIDEventSystemClientCreate(CFAllocatorRef _Nullable allocator)
    __attribute__((weak_import));

/// Private: restricts `IOHIDEventSystemClientCopyServices` to the services matching `matching`.
void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching)
    __attribute__((weak_import));

/// Public in the SDK; repeated here so this header lists every call the reader makes.
CFArrayRef _Nullable IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);

/// Public in the SDK; repeated here so this header lists every call the reader makes.
CFTypeRef _Nullable IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);

/// Private: the latest event of `type` (15 = temperature) from `service`.
IOHIDEventRef _Nullable IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type,
                                                    int32_t options, int64_t timestamp)
    __attribute__((weak_import));

/// Private: a float field of `event`; the temperature field is `15 << 16`.
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field) __attribute__((weak_import));

CF_ASSUME_NONNULL_END
CF_IMPLICIT_BRIDGING_DISABLED
CF_EXTERN_C_END

#endif
