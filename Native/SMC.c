#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <stdint.h>
#include <string.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPowerLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVersion version;
    SMCPowerLimit pLimit;
    SMCKeyInfo keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8) | (uint8_t)s[3];
}

static int smc_call(io_connect_t conn, SMCKeyData *data) {
    size_t outSize = sizeof(*data);
    SMCKeyData out = {0};
    kern_return_t result = IOConnectCallStructMethod(conn, 2, data, sizeof(*data), &out, &outSize);
    if (result != KERN_SUCCESS || outSize != sizeof(out) || out.result != 0) return 0;
    *data = out;
    return 1;
}

// Returns 1 only for plausible Celsius temperature values.
int glassmetrics_read_temperature(const char *key, double *temperature) {
    if (!key || strlen(key) != 4 || !temperature) return 0;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return 0;
    io_connect_t conn = IO_OBJECT_NULL;
    kern_return_t opened = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    if (opened != KERN_SUCCESS) return 0;

    SMCKeyData data = {0};
    data.key = fourcc(key);
    data.data8 = 9; // read key info
    int ok = smc_call(conn, &data);
    uint32_t size = data.keyInfo.dataSize;
    uint32_t type = data.keyInfo.dataType;
    if (ok && size > 0 && size <= 32) {
        memset(&data, 0, sizeof(data));
        data.key = fourcc(key);
        data.keyInfo.dataSize = size;
        data.data8 = 5; // read bytes
        ok = smc_call(conn, &data);
    } else ok = 0;
    IOServiceClose(conn);
    if (!ok) return 0;

    double value = 0;
    if (type == fourcc("flt ") && size == 4) {
        float f;
        memcpy(&f, data.bytes, 4);
        value = f;
    } else if (type == fourcc("sp78") && size == 2) {
        int16_t raw = (int16_t)((data.bytes[0] << 8) | data.bytes[1]);
        value = raw / 256.0;
    } else if (type == fourcc("fpe2") && size == 2) {
        value = ((data.bytes[0] << 8) | data.bytes[1]) / 4.0;
    } else return 0;
    if (!(value >= 10.0 && value <= 120.0)) return 0;
    *temperature = value;
    return 1;
}

typedef struct __IOHIDEvent *GMHIDEventRef;
typedef struct __IOHIDServiceClient *GMHIDServiceRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern GMHIDEventRef IOHIDServiceClientCopyEvent(GMHIDServiceRef, int64_t, int32_t, int64_t);
extern CFStringRef IOHIDServiceClientCopyProperty(GMHIDServiceRef, CFStringRef);
extern double IOHIDEventGetFloatValue(GMHIDEventRef, int32_t);

// Stats uses the same HID temperature service on Apple Silicon.
double glassmetrics_hid_cpu_temperature(void) {
    static IOHIDEventSystemClientRef client = NULL;
    static CFArrayRef services = NULL;
    if (!client) {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!client) return 0;
        int page = 0xff00, usage = 5;
        CFNumberRef pageNumber = CFNumberCreate(NULL, kCFNumberIntType, &page);
        CFNumberRef usageNumber = CFNumberCreate(NULL, kCFNumberIntType, &usage);
        const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
        const void *values[] = { pageNumber, usageNumber };
        CFDictionaryRef match = CFDictionaryCreate(NULL, keys, values, 2,
                                                   &kCFTypeDictionaryKeyCallBacks,
                                                   &kCFTypeDictionaryValueCallBacks);
        IOHIDEventSystemClientSetMatching(client, match);
        services = IOHIDEventSystemClientCopyServices(client);
        CFRelease(match); CFRelease(pageNumber); CFRelease(usageNumber);
    }
    if (!services) {
        CFRelease(client); client = NULL;
        return 0;
    }
    double sum = 0; int count = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
        GMHIDServiceRef service = (GMHIDServiceRef)CFArrayGetValueAtIndex(services, i);
        CFStringRef name = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (!name) continue;
        int isCPU = CFStringHasPrefix(name, CFSTR("pACC MTR Temp")) ||
                    CFStringHasPrefix(name, CFSTR("eACC MTR Temp"));
        CFRelease(name);
        if (!isCPU) continue;
        GMHIDEventRef event = IOHIDServiceClientCopyEvent(service, 15, 0, 0);
        if (!event) continue;
        double value = IOHIDEventGetFloatValue(event, 15 << 16);
        CFRelease(event);
        if (value >= 10 && value <= 120) { sum += value; count++; }
    }
    if (count) return sum / count;
    // Services may change across sleep/wake; reconnect on the next sample.
    CFRelease(services); services = NULL;
    CFRelease(client); client = NULL;
    return 0;
}
