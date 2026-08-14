// Extended Vulkan probe: queue family capabilities + WSI/extension surface.
// dlopen-based, no vulkan headers needed.
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <dlfcn.h>

#define VK_STRUCTURE_TYPE_APPLICATION_INFO 0
#define VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO 1
#define VK_QUEUE_GRAPHICS_BIT 0x1
#define VK_QUEUE_COMPUTE_BIT  0x2
#define VK_QUEUE_TRANSFER_BIT 0x4

typedef uint32_t VkFlags;
typedef void* VkInstance;
typedef void* VkPhysicalDevice;

typedef struct { uint32_t sType; const void* pNext; const char* pApplicationName;
    uint32_t applicationVersion; const char* pEngineName; uint32_t engineVersion;
    uint32_t apiVersion; } VkApplicationInfo;
typedef struct { uint32_t sType; const void* pNext; VkFlags flags;
    const VkApplicationInfo* pApplicationInfo; uint32_t enabledLayerCount;
    const char* const* ppEnabledLayerNames; uint32_t enabledExtensionCount;
    const char* const* ppEnabledExtensionNames; } VkInstanceCreateInfo;
typedef struct { char extensionName[256]; uint32_t specVersion; } VkExtensionProperties;
typedef struct { uint32_t apiVersion, driverVersion, vendorID, deviceID, deviceType;
    char deviceName[256]; uint8_t uuid[16]; } VkPhysicalDeviceProperties;
typedef struct { VkFlags queueFlags; uint32_t queueCount, timestampValidBits;
    struct { uint32_t w, h, d; } minImageTransferGranularity; } VkQueueFamilyProperties;

int main(void)
{
    void* vk = dlopen("libvulkan.so.1", RTLD_NOW);
    if (!vk) { fprintf(stderr, "no libvulkan: %s\n", dlerror()); return 1; }
    #define SYM(name) __typeof__(*(void(*)(void))0) *p##name = NULL; void *s_##name = dlsym(vk, #name)
    void* sCreate = dlsym(vk, "vkCreateInstance");
    void* sEnumDev = dlsym(vk, "vkEnumeratePhysicalDevices");
    void* sEnumInstExt = dlsym(vk, "vkEnumerateInstanceExtensionProperties");
    void* sEnumDevExt = dlsym(vk, "vkEnumerateDeviceExtensionProperties");
    void* sGetProps = dlsym(vk, "vkGetPhysicalDeviceProperties");
    void* sGetQ = dlsym(vk, "vkGetPhysicalDeviceQueueFamilyProperties");
    (void)0;

    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, 0, "vkprobe", 1, 0, 0, 1<<22 };
    VkInstanceCreateInfo ci = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, 0, 0, &app, 0, 0, 0, 0 };
    VkInstance inst = 0;
    if (((int(*)(const VkInstanceCreateInfo*, const void*, VkInstance*))sCreate)(&ci, 0, &inst) != 0) {
        fprintf(stderr, "vkCreateInstance failed\n"); return 1;
    }

    // instance extensions: WSI surface support
    uint32_t ne = 0;
    ((int(*)(const char*, uint32_t*, VkExtensionProperties*))sEnumInstExt)(0, &ne, 0);
    VkExtensionProperties exts[64]; if (ne > 64) ne = 64;
    ((int(*)(const char*, uint32_t*, VkExtensionProperties*))sEnumInstExt)(0, &ne, exts);
    printf("instance extensions (%u):", ne);
    for (uint32_t i = 0; i < ne; i++)
        if (strstr(exts[i].extensionName, "surface") || strstr(exts[i].extensionName, "display"))
            printf(" %s", exts[i].extensionName);
    printf("\n");

    // find the NVIDIA card
    uint32_t n = 0;
    ((int(*)(VkInstance, uint32_t*, VkPhysicalDevice*))sEnumDev)(inst, &n, 0);
    VkPhysicalDevice devs[8]; if (n > 8) n = 8;
    ((int(*)(VkInstance, uint32_t*, VkPhysicalDevice*))sEnumDev)(inst, &n, devs);
    VkPhysicalDevice gpu = 0;
    for (uint32_t i = 0; i < n; i++) {
        union { VkPhysicalDeviceProperties p; char buf[4096]; } u = {0};
        ((void(*)(VkPhysicalDevice, void*))sGetProps)(devs[i], &u);
        if (u.p.vendorID == 0x10de) { gpu = devs[i]; printf("using device [%u] %s\n", i, u.p.deviceName); }
    }
    if (!gpu) { fprintf(stderr, "no NVIDIA device\n"); return 1; }

    // queue families
    uint32_t nq = 0;
    ((void(*)(VkPhysicalDevice, uint32_t*, void*))sGetQ)(gpu, &nq, 0);
    VkQueueFamilyProperties q[16]; if (nq > 16) nq = 16;
    ((void(*)(VkPhysicalDevice, uint32_t*, void*))sGetQ)(gpu, &nq, q);
    printf("queue families (%u):\n", nq);
    for (uint32_t i = 0; i < nq; i++)
        printf("  [%u] count=%u flags=0x%x  %s%s%s\n", i, q[i].queueCount, q[i].queueFlags,
               (q[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) ? "graphics " : "",
               (q[i].queueFlags & VK_QUEUE_COMPUTE_BIT) ? "compute " : "",
               (q[i].queueFlags & VK_QUEUE_TRANSFER_BIT) ? "transfer" : "");

    // device extensions: is swapchain advertised? (only matters with a surface)
    uint32_t nde = 0;
    ((int(*)(VkPhysicalDevice, const char*, uint32_t*, VkExtensionProperties*))sEnumDevExt)(gpu, 0, &nde, 0);
    VkExtensionProperties* de = __builtin_alloca(nde * sizeof(*de));
    ((int(*)(VkPhysicalDevice, const char*, uint32_t*, VkExtensionProperties*))sEnumDevExt)(gpu, 0, &nde, de);
    int hasSwap = 0;
    for (uint32_t i = 0; i < nde; i++)
        if (!strcmp(de[i].extensionName, "VK_KHR_swapchain")) hasSwap = 1;
    printf("device extensions: %u total, VK_KHR_swapchain %s\n", nde,
           hasSwap ? "present (usable only with a surface; N/A headless)" : "absent");
    return 0;
}
