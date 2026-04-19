#import "BLEBridge.h"
#import <Foundation/Foundation.h>

static id<CoreBluetoothManagerProtocol> bleManager = nil;

void initializeBLEManager(void) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    bleManager = [CoreBluetoothManagerClass shared];
}

ble_object_t* createBLEObject(void) {
    ble_object_t* obj = malloc(sizeof(ble_object_t));
    obj->manager = (__bridge void *)bleManager;
    return obj;
}

void freeBLEObject(ble_object_t* obj) {
    if (obj) {
        free(obj);
    }
}

bool connectToBLEDevice(ble_object_t *io, const char *deviceAddress) {
    if (!io || !deviceAddress) {
        NSLog(@"Invalid parameters passed to connectToBLEDevice");
        return false;
    }
    
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    NSString *address = [NSString stringWithUTF8String:deviceAddress];
    
    bool success = [manager connectToDevice:address];
    if (!success) {
        NSLog(@"Failed to connect to device");
        return false;
    }
    
    // Wait for connection to complete by checking peripheral ready state
    NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:10.0]; // 10 second timeout
    while ([[NSDate date] compare:timeout] == NSOrderedAscending) {
        // Check if peripheral is ready using protocol method
        if ([manager getPeripheralReadyState]) {
            NSLog(@"Peripheral is ready for communication");
            break;
        }
        // Small sleep to avoid busy-waiting
        [NSThread sleepForTimeInterval:0.1];
    }
    
    // Final check if we're actually ready
    if (![manager getPeripheralReadyState]) {
        NSLog(@"Timeout waiting for peripheral to be ready");
        [manager close];
        return false;
    }

    // Store the peripheral's BLE name for ble_ioctl (DC_IOCTL_BLE_GET_NAME)
    NSString *peripheralName = [manager getPeripheralName];
    if (peripheralName) {
        const char *cname = [peripheralName UTF8String];
        strncpy(io->device_name, cname, sizeof(io->device_name) - 1);
        io->device_name[sizeof(io->device_name) - 1] = '\0';
        NSLog(@"Stored peripheral name: %s", io->device_name);
    }

    success = [manager discoverServices];
    if (!success) {
        NSLog(@"Service discovery failed");
        [manager close];
        return false;
    }

    success = [manager enableNotifications];
    if (!success) {
        NSLog(@"Failed to enable notifications");
        [manager close];
        return false;
    }
    
    return true;
}

bool discoverServices(ble_object_t *io) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    return [manager discoverServices];
}

bool enableNotifications(ble_object_t *io) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    return [manager enableNotifications];
}

dc_status_t ble_set_timeout(ble_object_t *io, int timeout) {
    return DC_STATUS_SUCCESS;
}

dc_status_t ble_ioctl(ble_object_t *io, unsigned int request, void *data_, size_t size_) {
    // DC_IOCTL_BLE_GET_NAME: return the connected peripheral's BLE name.
    // type='b', nr=0 — used by oceanic_atom2 handshake to build its passphrase.
    unsigned int type = (request >>  8) & 0xFF;
    unsigned int nr   = (request >>  0) & 0xFF;
    if (type == 'b' && nr == 0) {
        if (!io || io->device_name[0] == '\0') return DC_STATUS_IO;
        size_t len = strlen(io->device_name);
        if (len + 1 > size_) return DC_STATUS_INVALIDARGS;
        memcpy(data_, io->device_name, len + 1);
        return DC_STATUS_SUCCESS;
    }
    return DC_STATUS_UNSUPPORTED;
}

dc_status_t ble_sleep(ble_object_t *io, unsigned int milliseconds) {
    [NSThread sleepForTimeInterval:milliseconds / 1000.0];
    return DC_STATUS_SUCCESS;
}

dc_status_t ble_read(ble_object_t *io, void *buffer, size_t requested, size_t *actual)
{
    if (!io || !buffer || !actual) {
        return DC_STATUS_INVALIDARGS;
    }

    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];

    NSLog(@"[BLEBridge] ble_read: requesting %zu bytes", requested);
    NSData *partialData = [manager readDataPartial:(int)requested];

    if (!partialData || partialData.length == 0) {
        NSLog(@"[BLEBridge] ble_read: TIMEOUT/EMPTY — returning DC_STATUS_IO");
        *actual = 0;
        return DC_STATUS_IO;
    }

    const unsigned char *bytes = (const unsigned char *)partialData.bytes;
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger i = 0; i < MIN(partialData.length, 16); i++) {
        [hex appendFormat:@"%02X ", bytes[i]];
    }
    NSLog(@"[BLEBridge] ble_read: got %zu bytes: %@", partialData.length, hex);

    memcpy(buffer, partialData.bytes, partialData.length);
    *actual = partialData.length;
    return DC_STATUS_SUCCESS;
}

dc_status_t ble_write(ble_object_t *io, const void *data, size_t size, size_t *actual) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    NSData *nsData = [NSData dataWithBytes:data length:size];

    const unsigned char *bytes = (const unsigned char *)data;
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger i = 0; i < MIN(size, 16); i++) {
        [hex appendFormat:@"%02X ", bytes[i]];
    }
    NSLog(@"[BLEBridge] ble_write: %zu bytes: %@", size, hex);

    if ([manager writeData:nsData]) {
        NSLog(@"[BLEBridge] ble_write: success");
        *actual = size;
        return DC_STATUS_SUCCESS;
    } else {
        NSLog(@"[BLEBridge] ble_write: FAILED (write returned false)");
        *actual = 0;
        return DC_STATUS_IO;
    }
}

dc_status_t ble_close(ble_object_t *io) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    [manager close];
    return DC_STATUS_SUCCESS;
}
