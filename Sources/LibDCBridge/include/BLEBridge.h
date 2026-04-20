#ifndef BLEBridge_h
#define BLEBridge_h

#include <stdio.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __OBJC__
    #if __has_feature(modules)
        @import Foundation;
        @import CoreBluetooth;
    #else
        #import <Foundation/Foundation.h>
        #import <CoreBluetooth/CoreBluetooth.h>
    #endif
#endif

#include "libdivecomputer/common.h"
#include "libdivecomputer/context.h"
#include "libdivecomputer/iostream.h"
#include "libdivecomputer/custom.h"
#include "libdivecomputer/parser.h"
#include "configuredc.h"
#include "CoreBluetoothManagerProtocol.h"

// Array helper functions
static inline uint16_t array_uint16_le(const unsigned char array[]) {
    return array[0] | (array[1] << 8);
}

static inline uint32_t array_uint32_le(const unsigned char array[]) {
    return array[0] | (array[1] << 8) | (array[2] << 16) | (array[3] << 24);
}

static inline uint16_t array_uint16_be(const unsigned char array[]) {
    return (array[0] << 8) | array[1];
}

static inline uint32_t array_uint32_be(const unsigned char array[]) {
    return (array[0] << 24) | (array[1] << 16) | (array[2] << 8) | array[3];
}

// BLE object
typedef struct ble_object {
    void* manager;
    char device_name[32]; // BLE peripheral name (e.g. "FH007706"), set on connect
} ble_object_t;

// BLE object functions
ble_object_t* createBLEObject(void);
void freeBLEObject(ble_object_t* obj);

// BLE operations
dc_status_t ble_set_timeout(ble_object_t *io, int timeout);
dc_status_t ble_ioctl(ble_object_t *io, unsigned int request, void *data, size_t size);
dc_status_t ble_sleep(ble_object_t *io, unsigned int milliseconds);
dc_status_t ble_read(ble_object_t *io, void *data, size_t size, size_t *actual);
dc_status_t ble_write(ble_object_t *io, const void *data, size_t size, size_t *actual);
dc_status_t ble_close(ble_object_t *io);

// BLE setup functions
void initializeBLEManager(void);
bool connectToBLEDevice(ble_object_t *io, const char *deviceAddress);
// Returns false if a reconnect is within the post-close cooldown window
bool ble_can_connect_now(void);
bool discoverServices(ble_object_t *io);
bool enableNotifications(ble_object_t *io);

// Installs a log callback on the libdivecomputer context that forwards every
// internal message (protocol retries, CRC failures, device driver state) to
// the in-app BLE log. Call immediately after dc_context_new.
// Defaults to DC_LOGLEVEL_WARNING — downloads issue thousands of B1 reads and
// logging every one through to JS/disk adds seconds of per-packet overhead.
// Use ble_set_verbose_logging(true) to promote back to DC_LOGLEVEL_ALL for
// debugging sessions.
void installLibDCLogger(dc_context_t *context);

// Toggle verbose BLE tracing (per-packet ble_read/ble_write hex dumps and
// libdc DEBUG-level output). Off by default so bulk memory reads don't fire
// ~20k log events through the RN bridge mid-download.
void ble_set_verbose_logging(bool verbose);

#endif /* BLEBridge_h */
