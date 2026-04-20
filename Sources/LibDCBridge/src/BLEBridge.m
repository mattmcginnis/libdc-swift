#import "BLEBridge.h"
#import <Foundation/Foundation.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <libdivecomputer/context.h>

static id<CoreBluetoothManagerProtocol> bleManager = nil;

// Forward decl so ble_can_connect_now (and other early-file users) can call blog.
// Definition is further down alongside the rest of the logging helpers.
static void blog(id<CoreBluetoothManagerProtocol> mgr, NSString *fmt, ...) NS_FORMAT_FUNCTION(2,3);

// C-level reconnect cooldown — set on every close path, checked in ble_packet_open.
// Protects against rapid double-connection that can brick dive computers.
static volatile uint64_t g_lastCloseAbsTime = 0;
static const double kReconnectCooldownSec = 3.0;

static double machAbsToSec(uint64_t t) {
    static mach_timebase_info_data_t info;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&info); });
    return (double)t * info.numer / info.denom / 1e9;
}

bool ble_can_connect_now(void) {
    uint64_t last = g_lastCloseAbsTime;
    if (last == 0) return true;
    uint64_t now = mach_absolute_time();
    double elapsed = machAbsToSec(now > last ? now - last : 0);
    if (elapsed < kReconnectCooldownSec) {
        if (bleManager) {
            blog(bleManager, @"ble_can_connect_now: BLOCKED — %.2fs since last close (cooldown %.2fs). Protecting device from rapid reconnect.", elapsed, kReconnectCooldownSec);
        }
        return false;
    }
    return true;
}

static void ble_record_close(id<CoreBluetoothManagerProtocol> manager) {
    g_lastCloseAbsTime = mach_absolute_time();
    [manager close];
}

// Routes a log message to both NSLog (Xcode console) and the in-app BLE log viewer.
static void blog(id<CoreBluetoothManagerProtocol> mgr, NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[BLEBridge] %@", msg);
    [mgr bleLog:msg];
}

// Hex-encode up to `maxBytes` bytes for logging.
static NSString* hexStr(const void *data, size_t len, size_t maxBytes) {
    const unsigned char *b = (const unsigned char *)data;
    NSMutableString *s = [NSMutableString string];
    size_t n = len < maxBytes ? len : maxBytes;
    for (size_t i = 0; i < n; i++) [s appendFormat:@"%02X ", b[i]];
    if (len > maxBytes) [s appendFormat:@"…(%zu more)", len - maxBytes];
    return s;
}

void initializeBLEManager(void) {
    Class cls = NSClassFromString(@"CoreBluetoothManager");
    bleManager = [cls shared];
    blog(bleManager, @"initializeBLEManager: bleManager=%@", bleManager);
}

// Gates per-packet trace logs in ble_read/ble_write and raises libdc's log
// level from WARNING → ALL. Off by default — every BLE exchange would
// otherwise fire ~6 log lines, each of which marshals across the RN bridge
// and touches the shared BLELogger file handle. During a 3300-read bulk
// download that's ~20k log events, which measurably starves the BLE radio
// from getting the next packet queued in time.
static atomic_bool g_verbose_ble_logging = false;
void ble_set_verbose_logging(bool verbose) {
    atomic_store(&g_verbose_ble_logging, verbose);
}
static inline bool ble_verbose(void) { return atomic_load(&g_verbose_ble_logging); }

// Forwards libdivecomputer's internal log output into the in-app BLE log.
// Extracts just the basename of __FILE__ so lines stay readable.
static void libdc_log_forward(dc_context_t *ctx,
                              dc_loglevel_t loglevel,
                              const char *file,
                              unsigned int line,
                              const char *function,
                              const char *message,
                              void *userdata) {
    (void)ctx;
    (void)userdata;
    const char *levelStr;
    switch (loglevel) {
        case DC_LOGLEVEL_ERROR:   levelStr = "ERR "; break;
        case DC_LOGLEVEL_WARNING: levelStr = "WARN"; break;
        case DC_LOGLEVEL_INFO:    levelStr = "INFO"; break;
        case DC_LOGLEVEL_DEBUG:   levelStr = "DBG "; break;
        case DC_LOGLEVEL_ALL:     levelStr = "ALL "; break;
        default:                  levelStr = "    "; break;
    }
    const char *base = file ? strrchr(file, '/') : NULL;
    base = base ? base + 1 : (file ? file : "?");
    if (bleManager) {
        blog(bleManager, @"[libdc %s] %s:%u %s: %s",
             levelStr, base, line, function ? function : "?", message ? message : "");
    }
}

void installLibDCLogger(dc_context_t *context) {
    if (!context) return;
    dc_loglevel_t level = ble_verbose() ? DC_LOGLEVEL_ALL : DC_LOGLEVEL_WARNING;
    dc_context_set_loglevel(context, level);
    dc_context_set_logfunc(context, libdc_log_forward, NULL);
    if (bleManager) {
        blog(bleManager, @"installLibDCLogger: level=%s on context=%p",
             level == DC_LOGLEVEL_ALL ? "ALL" : "WARNING", (void *)context);
    }
}

ble_object_t* createBLEObject(void) {
    ble_object_t* obj = malloc(sizeof(ble_object_t));
    memset(obj, 0, sizeof(ble_object_t));
    obj->manager = (__bridge void *)bleManager;
    blog(bleManager, @"createBLEObject: obj=%p", obj);
    return obj;
}

void freeBLEObject(ble_object_t* obj) {
    if (obj) {
        blog(bleManager, @"freeBLEObject: obj=%p name='%s'", obj, obj->device_name);
        free(obj);
    }
}

bool connectToBLEDevice(ble_object_t *io, const char *deviceAddress) {
    if (!io || !deviceAddress) {
        blog(bleManager, @"connectToBLEDevice: INVALID PARAMS io=%p addr=%s", io, deviceAddress);
        return false;
    }

    Class cls = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [cls shared];
    NSString *address = [NSString stringWithUTF8String:deviceAddress];
    blog(manager, @"connectToBLEDevice: addr=%@", address);

    bool success = [manager connectToDevice:address];
    blog(manager, @"connectToBLEDevice: connectToDevice returned %s", success ? "YES" : "NO");
    if (!success) return false;

    NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:10.0];
    int polls = 0;
    while ([[NSDate date] compare:timeout] == NSOrderedAscending) {
        if ([manager getPeripheralReadyState]) {
            blog(manager, @"connectToBLEDevice: peripheral ready after %d polls", polls);
            break;
        }
        [NSThread sleepForTimeInterval:0.1];
        polls++;
        if (polls % 10 == 0) blog(manager, @"connectToBLEDevice: still waiting for peripheral ready… poll=%d", polls);
    }

    if (![manager getPeripheralReadyState]) {
        blog(manager, @"connectToBLEDevice: TIMEOUT waiting for peripheral ready (10s)");
        ble_record_close(manager);
        return false;
    }

    NSString *peripheralName = [manager getPeripheralName];
    blog(manager, @"connectToBLEDevice: peripheralName='%@'", peripheralName);
    if (peripheralName) {
        const char *cname = [peripheralName UTF8String];
        strncpy(io->device_name, cname, sizeof(io->device_name) - 1);
        io->device_name[sizeof(io->device_name) - 1] = '\0';
        blog(manager, @"connectToBLEDevice: stored device_name='%s'", io->device_name);
    } else {
        blog(manager, @"connectToBLEDevice: WARNING — peripheralName is nil, device_name will be empty");
    }

    blog(manager, @"connectToBLEDevice: calling discoverServices");
    success = [manager discoverServices];
    blog(manager, @"connectToBLEDevice: discoverServices returned %s", success ? "YES" : "NO");
    if (!success) {
        ble_record_close(manager);
        return false;
    }

    blog(manager, @"connectToBLEDevice: calling enableNotifications");
    success = [manager enableNotifications];
    blog(manager, @"connectToBLEDevice: enableNotifications returned %s", success ? "YES" : "NO");
    if (!success) {
        ble_record_close(manager);
        return false;
    }

    blog(manager, @"connectToBLEDevice: fully ready — returning true");
    return true;
}

bool discoverServices(ble_object_t *io) {
    Class cls = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [cls shared];
    blog(manager, @"discoverServices (standalone call)");
    return [manager discoverServices];
}

bool enableNotifications(ble_object_t *io) {
    Class cls = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [cls shared];
    blog(manager, @"enableNotifications (standalone call)");
    return [manager enableNotifications];
}

dc_status_t ble_set_timeout(ble_object_t *io, int timeout) {
    blog(bleManager, @"ble_set_timeout: %d ms", timeout);
    return DC_STATUS_SUCCESS;
}

dc_status_t ble_ioctl(ble_object_t *io, unsigned int request, void *data_, size_t size_) {
    unsigned int type = (request >>  8) & 0xFF;
    unsigned int nr   = (request >>  0) & 0xFF;
    blog(bleManager, @"ble_ioctl: request=0x%08X type='%c'(0x%02X) nr=%u size=%zu",
         request, (char)type, type, nr, size_);

    if (type == 'b' && nr == 0) {
        if (!io || io->device_name[0] == '\0') {
            blog(bleManager, @"ble_ioctl GET_NAME: device_name empty — returning IO error");
            return DC_STATUS_IO;
        }
        size_t len = strlen(io->device_name);
        if (len + 1 > size_) {
            blog(bleManager, @"ble_ioctl GET_NAME: buffer too small (need %zu, have %zu)", len+1, size_);
            return DC_STATUS_INVALIDARGS;
        }
        memcpy(data_, io->device_name, len + 1);
        blog(bleManager, @"ble_ioctl GET_NAME: returned '%s'", io->device_name);
        return DC_STATUS_SUCCESS;
    }
    if (type == 'b' && nr == 1) {
        blog(bleManager, @"ble_ioctl GET_PINCODE: returning UNSUPPORTED");
        return DC_STATUS_UNSUPPORTED;
    }
    if (type == 'b' && nr == 2) {
        blog(bleManager, @"ble_ioctl GET/SET_ACCESSCODE: returning UNSUPPORTED");
        return DC_STATUS_UNSUPPORTED;
    }
    blog(bleManager, @"ble_ioctl: unknown request — returning UNSUPPORTED");
    return DC_STATUS_UNSUPPORTED;
}

dc_status_t ble_sleep(ble_object_t *io, unsigned int milliseconds) {
    blog(bleManager, @"ble_sleep: %u ms", milliseconds);
    [NSThread sleepForTimeInterval:milliseconds / 1000.0];
    blog(bleManager, @"ble_sleep: done");
    return DC_STATUS_SUCCESS;
}

dc_status_t ble_read(ble_object_t *io, void *buffer, size_t requested, size_t *actual)
{
    if (!io || !buffer || !actual) {
        blog(bleManager, @"ble_read: INVALID PARAMS");
        return DC_STATUS_INVALIDARGS;
    }

    Class cls = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [cls shared];
    bool verbose = ble_verbose();
    if (verbose) blog(manager, @"ble_read: requesting %zu bytes", requested);

    NSData *partialData = [manager readDataPartial:(int)requested];

    if (!partialData || partialData.length == 0) {
        // Always log timeouts — they matter and are infrequent.
        blog(manager, @"ble_read: TIMEOUT/EMPTY — DC_STATUS_IO");
        *actual = 0;
        return DC_STATUS_IO;
    }

    if (verbose) {
        blog(manager, @"ble_read: received %zu bytes: %@",
             partialData.length, hexStr(partialData.bytes, partialData.length, 20));
    }

    memcpy(buffer, partialData.bytes, partialData.length);
    *actual = partialData.length;
    return DC_STATUS_SUCCESS;
}

dc_status_t ble_write(ble_object_t *io, const void *data, size_t size, size_t *actual) {
    Class cls = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [cls shared];
    NSData *nsData = [NSData dataWithBytes:data length:size];
    bool verbose = ble_verbose();

    if (verbose) blog(manager, @"ble_write: %zu bytes: %@", size, hexStr(data, size, 20));

    if ([manager writeData:nsData]) {
        if (verbose) blog(manager, @"ble_write: write() returned true (queued)");
        *actual = size;
        return DC_STATUS_SUCCESS;
    } else {
        // Always log write failures.
        blog(manager, @"ble_write: write() returned false — no peripheral or characteristic");
        *actual = 0;
        return DC_STATUS_IO;
    }
}

dc_status_t ble_close(ble_object_t *io) {
    Class cls = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [cls shared];
    blog(manager, @"ble_close: calling manager.close()");
    ble_record_close(manager);
    blog(manager, @"ble_close: done");
    return DC_STATUS_SUCCESS;
}
