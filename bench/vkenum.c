// Minimal Vulkan device enumerator using dlopen - no vulkan headers needed.
// Prints each physical device's name, type, and queue family count.
#include <stdio.h>
#include <stdint.h>
#include <dlfcn.h>

#define VK_SUCCESS 0
#define VK_STRUCTURE_TYPE_APPLICATION_INFO 0
#define VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO 1

typedef uint32_t VkFlags;
typedef uint32_t VkBool32;
typedef uint64_t VkDeviceSize;
typedef void* VkInstance;
typedef void* VkPhysicalDevice;

typedef struct {
    uint32_t sType; const void* pNext; const char* pApplicationName;
    uint32_t applicationVersion; const char* pEngineName;
    uint32_t engineVersion; uint32_t apiVersion;
} VkApplicationInfo;

typedef struct {
    uint32_t sType; const void* pNext; VkFlags flags;
    const VkApplicationInfo* pApplicationInfo;
    uint32_t enabledLayerCount; const char* const* ppEnabledLayerNames;
    uint32_t enabledExtensionCount; const char* const* ppEnabledExtensionNames;
} VkInstanceCreateInfo;

typedef struct {
    uint32_t apiVersion, driverVersion, vendorID, deviceID, deviceType;
    char deviceName[256];
    uint8_t pipelineCacheUUID[16];
} VkPhysicalDeviceProperties;   // truncated; limits/sparse follow but we don't read them

typedef struct {
    VkFlags queueFlags; uint32_t queueCount, timestampValidBits;
    struct { uint32_t w, h, d; } minImageTransferGranularity;
} VkQueueFamilyProperties;

int main(void)
{
    void* vk = dlopen("libvulkan.so.1", RTLD_NOW);
    if (!vk) { fprintf(stderr, "no libvulkan: %s\n", dlerror()); return 1; }

    int (*pvkCreateInstance)(const VkInstanceCreateInfo*, const void*, VkInstance*) =
        dlsym(vk, "vkCreateInstance");
    void (*pvkEnumeratePhysicalDevices)(VkInstance, uint32_t*, VkPhysicalDevice*) =
        dlsym(vk, "vkEnumeratePhysicalDevices");
    void (*pvkGetPhysicalDeviceProperties)(VkPhysicalDevice, VkPhysicalDeviceProperties*) =
        dlsym(vk, "vkGetPhysicalDeviceProperties");
    void (*pvkGetPhysicalDeviceQueueFamilyProperties)(VkPhysicalDevice, uint32_t*, VkQueueFamilyProperties*) =
        dlsym(vk, "vkGetPhysicalDeviceQueueFamilyProperties");

    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, 0, "vkenum", 1, "none", 0, (1<<22) };
    VkInstanceCreateInfo ci = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, 0, 0, &app, 0, 0, 0, 0 };
    VkInstance inst = 0;
    int r = pvkCreateInstance(&ci, 0, &inst);
    if (r != VK_SUCCESS) { fprintf(stderr, "vkCreateInstance failed: %d\n", r); return 1; }

    uint32_t n = 0;
    ((int(*)(VkInstance,uint32_t*,VkPhysicalDevice*))pvkEnumeratePhysicalDevices)(inst, &n, 0);
    printf("%u Vulkan physical device(s):\n", n);
    VkPhysicalDevice devs[8];
    if (n > 8) n = 8;
    ((int(*)(VkInstance,uint32_t*,VkPhysicalDevice*))pvkEnumeratePhysicalDevices)(inst, &n, devs);

    const char* types[] = { "other", "integrated", "discrete", "virtual", "cpu" };
    for (uint32_t i = 0; i < n; i++) {
        /* properties struct is larger than our decl; allocate generously */
        union { VkPhysicalDeviceProperties p; char buf[4096]; } u = {0};
        pvkGetPhysicalDeviceProperties(devs[i], &u.p);
        uint32_t nq = 0;
        pvkGetPhysicalDeviceQueueFamilyProperties(devs[i], &nq, 0);
        printf("  [%u] %s  type=%s vendor=0x%04x device=0x%04x api=%u.%u.%u queues=%u\n",
               i, u.p.deviceName,
               types[u.p.deviceType <= 4 ? u.p.deviceType : 0],
               u.p.vendorID, u.p.deviceID,
               u.p.apiVersion >> 22, (u.p.apiVersion >> 12) & 0x3ff,
               u.p.apiVersion & 0xfff, nq);
    }
    return 0;
}
