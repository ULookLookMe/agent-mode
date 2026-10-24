// The private HID functions live in IOKit.framework; this file only checks that they are there.
#include "CIOHIDPrivate.h"

bool CIOHIDPrivateIsAvailable(void) {
    // Weak imports that dyld could not bind are NULL.
    return IOHIDEventSystemClientCreate != NULL && IOHIDEventSystemClientSetMatching != NULL &&
           IOHIDServiceClientCopyEvent != NULL && IOHIDEventGetFloatValue != NULL;
}
