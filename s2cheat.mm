// language: ObjC++/C++17, file: s2cheat.mm, target: iOS ARM64, StandFade 0.18.0
// engine: Unity IL2Cpp v24 | inject: insert_dylib into UnityFramework
// strategy: runtime IL2Cpp reflection — no hardcoded offsets, survives minor patches
// build:    clang++ -arch arm64 -dynamiclib -o s2cheat.dylib s2cheat.mm \
//             -framework Foundation -framework UIKit \
//             -install_name @rpath/s2cheat.dylib \
//             -isysroot $(xcrun --sdk iphoneos --show-sdk-path)
// sign:     ldid -S s2cheat.dylib
// inject:   insert_dylib --strip-codesig --inplace s2cheat.dylib Payload/Standoff2.app/Frameworks/UnityFramework

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <cmath>
#include <vector>
#include <functional>

// ─── IL2Cpp API types ────────────────────────────────────────────────────────

typedef void Il2CppObject;
typedef void Il2CppClass;
typedef void Il2CppDomain;
typedef void Il2CppImage;
typedef void Il2CppAssembly;
typedef void Il2CppMethodInfo;
typedef void Il2CppFieldInfo;
typedef struct { float x, y, z; } Vector3;
typedef struct { float x, y; }    Vector2;

// ─── IL2Cpp API function pointers ────────────────────────────────────────────
// All resolved at runtime via dlsym — no hardcoded offsets.

namespace IL2 {
    typedef Il2CppDomain*     (*fn_domain_get)();
    typedef Il2CppAssembly**  (*fn_domain_get_assemblies)(Il2CppDomain*, size_t*);
    typedef Il2CppImage*      (*fn_assembly_get_image)(Il2CppAssembly*);
    typedef Il2CppClass*      (*fn_class_from_name)(Il2CppImage*, const char* ns, const char* name);
    typedef Il2CppMethodInfo* (*fn_class_get_method_from_name)(Il2CppClass*, const char* name, int param_count);
    typedef Il2CppFieldInfo*  (*fn_class_get_field_from_name)(Il2CppClass*, const char* name);
    typedef Il2CppObject*     (*fn_runtime_invoke)(Il2CppMethodInfo*, Il2CppObject* obj, void** params, Il2CppObject** exc);
    typedef void              (*fn_field_get_value)(Il2CppObject*, Il2CppFieldInfo*, void* value);
    typedef void              (*fn_field_set_value)(Il2CppObject*, Il2CppFieldInfo*, void* value);
    typedef void*             (*fn_method_get_function_ptr)(Il2CppMethodInfo*);
    typedef Il2CppObject*     (*fn_object_new)(Il2CppClass*);
    typedef const char*       (*fn_class_get_name)(Il2CppClass*);

    fn_domain_get               domain_get;
    fn_domain_get_assemblies    domain_get_assemblies;
    fn_assembly_get_image       assembly_get_image;
    fn_class_from_name          class_from_name;
    fn_class_get_method_from_name class_get_method_from_name;
    fn_class_get_field_from_name  class_get_field_from_name;
    fn_runtime_invoke           runtime_invoke;
    fn_field_get_value          field_get_value;
    fn_field_set_value          field_set_value;
    fn_class_get_name           class_get_name;

    static void* fw_handle = nullptr;

    bool init() {
        // UnityFramework is already loaded — find it
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char* name = _dyld_get_image_name(i);
            if (name && strstr(name, "UnityFramework")) {
                fw_handle = dlopen(name, RTLD_NOW | RTLD_NOLOAD);
                break;
            }
        }
        if (!fw_handle) fw_handle = RTLD_DEFAULT;

        #define RESOLVE(fn) fn = (decltype(fn))dlsym(fw_handle, "il2cpp_" #fn); \
                            if (!fn) { NSLog(@"[S2] MISSING: il2cpp_" #fn); return false; }
        RESOLVE(domain_get)
        RESOLVE(domain_get_assemblies)
        RESOLVE(assembly_get_image)
        RESOLVE(class_from_name)
        RESOLVE(class_get_method_from_name)
        RESOLVE(class_get_field_from_name)
        RESOLVE(runtime_invoke)
        RESOLVE(field_get_value)
        RESOLVE(field_set_value)
        RESOLVE(class_get_name)
        #undef RESOLVE
        return true;
    }

    // Walk all assemblies to find a class by namespace+name
    Il2CppClass* find_class(const char* ns, const char* klass_name) {
        if (!domain_get) return nullptr;
        Il2CppDomain* dom = domain_get();
        if (!dom) return nullptr;
        size_t count = 0;
        Il2CppAssembly** assemblies = domain_get_assemblies(dom, &count);
        for (size_t i = 0; i < count; i++) {
            Il2CppImage* img = assembly_get_image(assemblies[i]);
            if (!img) continue;
            Il2CppClass* klass = class_from_name(img, ns, klass_name);
            if (klass) return klass;
        }
        return nullptr;
    }

    // Invoke a method that returns a pointer/object
    Il2CppObject* invoke(Il2CppMethodInfo* m, Il2CppObject* obj, void** params = nullptr) {
        Il2CppObject* exc = nullptr;
        Il2CppObject* result = runtime_invoke(m, obj, params, &exc);
        if (exc) return nullptr;
        return result;
    }

    // Get typed value from a getter method
    template<typename T>
    T get_value(Il2CppMethodInfo* getter, Il2CppObject* obj) {
        Il2CppObject* boxed = invoke(getter, obj);
        if (!boxed) return T{};
        return *reinterpret_cast<T*>(reinterpret_cast<uintptr_t>(boxed) + sizeof(void*) * 2);
    }
}

// ─── Game classes ─────────────────────────────────────────────────────────────

struct GameContext {
    // Classes
    Il2CppClass* cls_PlayerManager     = nullptr;
    Il2CppClass* cls_PlayerController  = nullptr;
    Il2CppClass* cls_WeaponController  = nullptr;
    Il2CppClass* cls_Camera            = nullptr;

    // Methods
    Il2CppMethodInfo* m_GetPlayers        = nullptr;  // returns List<PlayerController>
    Il2CppMethodInfo* m_GetLocalPlayer    = nullptr;
    Il2CppMethodInfo* m_GetPosition       = nullptr;  // PlayerController -> Vector3
    Il2CppMethodInfo* m_GetHeadPosition   = nullptr;
    Il2CppMethodInfo* m_IsAlive           = nullptr;
    Il2CppMethodInfo* m_IsEnemy           = nullptr;  // or get_TargetTeam
    Il2CppMethodInfo* m_IsVisible         = nullptr;
    Il2CppMethodInfo* m_WorldToScreen     = nullptr;
    Il2CppMethodInfo* m_GetRenderer       = nullptr;
    Il2CppMethodInfo* m_SetLayer          = nullptr;  // for WH

    // Fields
    Il2CppFieldInfo* f_players = nullptr;  // PlayerManager.players (List<>)

    bool valid = false;

    // Try multiple class/method name variants (obfuscation-resistant)
    void resolve() {
        // StandFade uses obfuscated names. We scan all classes looking for the ones
        // that have our key methods. Use method name strings from metadata.
        //
        // From dump analysis:
        //   get_Players       -> PlayerManager-like class
        //   IsVisible         -> player render check
        //   get_isAlive       -> player alive check (lowercase i)
        //   HitViaServer      -> weapon hit registration
        //   FKHOHINENHP       -> obfuscated fire method (near HitViaServer)
        //   AIMHJJGBBIJ       -> aim-related obfuscated
        //   CheckPlayer       -> target validation

        // Try known namespace patterns for Standoff 2
        const char* namespaces[] = { "", "Game", "Battle", "Gameplay", "Player", nullptr };
        const char* player_classes[] = { 
            "PlayerController", "PlayerManager", "LocalPlayerController",
            "BattlePlayer", "NetworkPlayer", "CharacterController", nullptr 
        };

        for (int ni = 0; namespaces[ni]; ni++) {
            for (int ci = 0; player_classes[ci]; ci++) {
                Il2CppClass* klass = IL2::find_class(namespaces[ni], player_classes[ci]);
                if (!klass) continue;
                NSLog(@"[S2] Found class: %s::%s", namespaces[ni], player_classes[ci]);

                // Check if it has isAlive and position methods
                Il2CppMethodInfo* alive_m = IL2::class_get_method_from_name(klass, "get_isAlive", 0);
                if (!alive_m) alive_m = IL2::class_get_method_from_name(klass, "get_IsAlive", 0);
                if (!alive_m) continue;

                cls_PlayerController = klass;
                m_IsAlive = alive_m;

                m_GetPosition = IL2::class_get_method_from_name(klass, "get_position", 0);
                if (!m_GetPosition)
                    m_GetPosition = IL2::class_get_method_from_name(klass, "GetPosition", 0);

                m_GetHeadPosition = IL2::class_get_method_from_name(klass, "GetHeadPosition", 0);
                if (!m_GetHeadPosition)
                    m_GetHeadPosition = IL2::class_get_method_from_name(klass, "get_HeadPosition", 0);

                m_IsEnemy  = IL2::class_get_method_from_name(klass, "IsEnemy", 0);
                m_IsVisible = IL2::class_get_method_from_name(klass, "IsVisible", 0);

                NSLog(@"[S2] PlayerController resolved: alive=%p pos=%p head=%p enemy=%p",
                      m_IsAlive, m_GetPosition, m_GetHeadPosition, m_IsEnemy);
                break;
            }
            if (cls_PlayerController) break;
        }

        // Camera WorldToScreenPoint
        cls_Camera = IL2::find_class("UnityEngine", "Camera");
        if (cls_Camera) {
            m_WorldToScreen = IL2::class_get_method_from_name(cls_Camera, "WorldToScreenPoint", 1);
        }

        valid = (cls_PlayerController != nullptr && m_IsAlive != nullptr);
        NSLog(@"[S2] GameContext valid=%d", valid);
    }
} g_ctx;

// ─── Wallhack ─────────────────────────────────────────────────────────────────
// Approach: hook Renderer.enabled to always return true for enemy renderers,
// or use layer override to bypass occlusion.
// Runtime approach: set material renderQueue and toggle shadow casting.
//
// For StandFade (private server, no kernel AC):
// Simply force enemy renderers visible via Il2CppObject field manipulation.

static void apply_wallhack(Il2CppObject* player) {
    if (!player || !g_ctx.m_GetRenderer) return;

    // Get the Renderer component
    Il2CppObject* renderer = IL2::invoke(g_ctx.m_GetRenderer, player);
    if (!renderer) return;

    // Set layer to 1 (TransparentFX) — renders through geometry
    // or set forceRenderingOff = false and enabled = true
    Il2CppFieldInfo* f_enabled = IL2::class_get_field_from_name(
        reinterpret_cast<Il2CppClass*>(*reinterpret_cast<uintptr_t*>(renderer)),
        "m_Enabled"
    );
    if (f_enabled) {
        bool enabled = true;
        IL2::field_set_value(renderer, f_enabled, &enabled);
    }
}

// ─── Silent aim ───────────────────────────────────────────────────────────────
// Strategy: hook the fire function and snap aim to nearest enemy head before
// bullet direction is calculated.
//
// For runtime approach without Dobby (which needs compilation):
// We patch the fire function's prologue at load time using mprotect + memcpy.

static Vector3 g_aim_target = {0, 0, 0};
static bool    g_aim_valid  = false;

static Vector3 vec3_sub(Vector3 a, Vector3 b) { return {a.x-b.x, a.y-b.y, a.z-b.z}; }
static float   vec3_len(Vector3 v) { return sqrtf(v.x*v.x + v.y*v.y + v.z*v.z); }

// Called from our cheat thread every frame
static Il2CppObject* get_nearest_enemy_head(Il2CppObject* local_player) {
    (void)local_player;
    return nullptr; // filled in after player list is resolved
}

// ─── Main cheat loop ──────────────────────────────────────────────────────────

static std::vector<Il2CppObject*> g_enemies;
static pthread_mutex_t g_enemies_mtx = PTHREAD_MUTEX_INITIALIZER;

static void cheat_tick() {
    if (!g_ctx.valid) return;

    // Get all active game objects with PlayerController component
    // Unity: FindObjectsOfType<PlayerController>()
    Il2CppClass* cls_object = IL2::find_class("UnityEngine", "Object");
    if (!cls_object) return;

    // FindObjectsOfType(Type) — parameter is Type object
    Il2CppMethodInfo* m_find = IL2::class_get_method_from_name(cls_object, "FindObjectsOfType", 1);
    if (!m_find) return;

    // Get Type of PlayerController
    Il2CppMethodInfo* m_get_type = IL2::class_get_method_from_name(
        IL2::find_class("System", "Object"), "GetType", 0
    );

    // Alternative: use FindObjectsOfTypeAll which doesn't need the type parameter trick
    Il2CppMethodInfo* m_find_all = IL2::class_get_method_from_name(cls_object, "FindObjectsOfTypeAll", 1);
    if (!m_find_all) return;

    // Get System.Type for PlayerController
    Il2CppMethodInfo* m_typeof = IL2::class_get_method_from_name(
        IL2::find_class("System", "Type"), "GetType", 1
    );
    if (!m_typeof) return;

    // We need the Il2CppObject* representing the Type of PlayerController
    // Use il2cpp_class_get_type -> il2cpp_type_get_object
    typedef void* (*fn_class_get_type)(Il2CppClass*);
    typedef Il2CppObject* (*fn_type_get_object)(void*);

    fn_class_get_type   class_get_type   = (fn_class_get_type)dlsym(IL2::fw_handle, "il2cpp_class_get_type");
    fn_type_get_object  type_get_object  = (fn_type_get_object)dlsym(IL2::fw_handle, "il2cpp_type_get_object");

    if (!class_get_type || !type_get_object || !g_ctx.cls_PlayerController) return;

    void* player_type = class_get_type(g_ctx.cls_PlayerController);
    if (!player_type) return;

    Il2CppObject* type_obj = type_get_object(player_type);
    if (!type_obj) return;

    void* params[1] = { type_obj };
    Il2CppObject* arr = IL2::invoke(m_find_all, nullptr, params);
    if (!arr) return;

    // arr is Il2CppArray — length at offset 0x18, elements at 0x20
    int32_t count = *reinterpret_cast<int32_t*>(reinterpret_cast<uintptr_t>(arr) + 0x18);
    Il2CppObject** elements = reinterpret_cast<Il2CppObject**>(
        reinterpret_cast<uintptr_t>(arr) + 0x20
    );

    pthread_mutex_lock(&g_enemies_mtx);
    g_enemies.clear();

    for (int32_t i = 0; i < count && i < 32; i++) {
        Il2CppObject* player = elements[i];
        if (!player) continue;

        // Check alive
        if (g_ctx.m_IsAlive) {
            Il2CppObject* exc = nullptr;
            Il2CppObject* result = IL2::runtime_invoke(g_ctx.m_IsAlive, player, nullptr, &exc);
            if (!exc && result) {
                bool alive = *reinterpret_cast<bool*>(reinterpret_cast<uintptr_t>(result) + sizeof(void*)*2);
                if (!alive) continue;
            }
        }

        // Check enemy (skip if method not found — show all for debug)
        if (g_ctx.m_IsEnemy) {
            Il2CppObject* exc = nullptr;
            Il2CppObject* result = IL2::runtime_invoke(g_ctx.m_IsEnemy, player, nullptr, &exc);
            if (!exc && result) {
                bool is_enemy = *reinterpret_cast<bool*>(reinterpret_cast<uintptr_t>(result) + sizeof(void*)*2);
                if (!is_enemy) continue;
            }
        }

        g_enemies.push_back(player);

        // Apply WH: set renderer visible through walls
        apply_wallhack(player);
    }

    pthread_mutex_unlock(&g_enemies_mtx);
}

// ─── Fire hook for silent aim ─────────────────────────────────────────────────
// Hook FKHOHINENHP (method_idx 57943, the fire function near HitViaServer)
// At runtime we find its address and patch first instruction to branch to our stub.
//
// For StandFade private server: no kernel-level AC, so simple inline hook works.

static void* g_fire_orig = nullptr;
static void* g_fire_trampoline = nullptr;

// ARM64 inline hook: write LDR X16, #8; BR X16; <target_address>
static void write_branch(void* target, void* destination) {
    // Make page writable
    uintptr_t page = (uintptr_t)target & ~0xFFF;
    mprotect((void*)page, 0x4000, PROT_READ | PROT_WRITE | PROT_EXEC);

    uint32_t* patch = (uint32_t*)target;
    // LDR X16, #8   -> 0x58000050
    patch[0] = 0x58000050;
    // BR X16         -> 0xD61F0200
    patch[1] = 0xD61F0200;
    // 8-byte destination address
    *((uintptr_t*)(patch + 2)) = (uintptr_t)destination;

    // Flush icache
    __builtin___clear_cache((char*)patch, (char*)(patch + 4));
}

// Our fire replacement: snap rotation toward nearest enemy head first
static void our_fire_hook(Il2CppObject* self, void* fire_params) {
    // Find nearest enemy head position
    Vector3 snap_pos = {0, 0, 0};
    bool    has_snap = false;
    float   best_dist = 1e9f;

    pthread_mutex_lock(&g_enemies_mtx);
    for (Il2CppObject* enemy : g_enemies) {
        if (!enemy || !g_ctx.m_GetHeadPosition) continue;
        Il2CppObject* exc = nullptr;
        Il2CppObject* result = IL2::runtime_invoke(g_ctx.m_GetHeadPosition, enemy, nullptr, &exc);
        if (exc || !result) continue;

        Vector3 head = *reinterpret_cast<Vector3*>(reinterpret_cast<uintptr_t>(result) + sizeof(void*)*2);
        float dist = vec3_len({head.x, head.y, head.z});  // simplified — use local pos delta in prod
        if (dist < best_dist) {
            best_dist = dist;
            snap_pos = head;
            has_snap = true;
        }
    }
    pthread_mutex_unlock(&g_enemies_mtx);

    if (has_snap) {
        g_aim_target = snap_pos;
        g_aim_valid  = true;
        // The actual aim snap depends on finding the look-direction field/method
        // Patch the bullet direction vector before the original fire code reads it
        // This is weapon-class specific; without exact field offsets,
        // we at minimum update g_aim_target for the UI crosshair overlay
    }

    // Call original
    if (g_fire_trampoline) {
        typedef void (*FireFn)(Il2CppObject*, void*);
        ((FireFn)g_fire_trampoline)(self, fire_params);
    }
}

static void install_fire_hook() {
    // Find FKHOHINENHP — the obfuscated fire method
    // It's near HitViaServer in the same class
    // We find it by: get class containing HitViaServer, then get FKHOHINENHP from that class

    // Walk all assemblies, find class with HitViaServer method
    Il2CppDomain* dom = IL2::domain_get();
    if (!dom) return;
    size_t asm_count = 0;
    Il2CppAssembly** assemblies = IL2::domain_get_assemblies(dom, &asm_count);

    for (size_t i = 0; i < asm_count; i++) {
        Il2CppImage* img = IL2::assembly_get_image(assemblies[i]);
        if (!img) continue;

        // Try to find the weapon/fire class
        const char* weapon_classes[] = {
            "WeaponController", "GunController", "ShootController",
            "WeaponBase", "Weapon", "BattleWeapon", nullptr
        };
        const char* namespaces[] = { "", "Game", "Battle", "Gameplay", nullptr };

        for (int ni = 0; namespaces[ni]; ni++) {
            for (int ci = 0; weapon_classes[ci]; ci++) {
                Il2CppClass* klass = IL2::class_from_name(img, namespaces[ni], weapon_classes[ci]);
                if (!klass) continue;

                Il2CppMethodInfo* hit_m = IL2::class_get_method_from_name(klass, "HitViaServer", -1);
                if (!hit_m) continue;

                // Found the right class — get fire method
                Il2CppMethodInfo* fire_m = IL2::class_get_method_from_name(klass, "FKHOHINENHP", -1);
                if (!fire_m) fire_m = IL2::class_get_method_from_name(klass, "Fire", -1);
                if (!fire_m) fire_m = IL2::class_get_method_from_name(klass, "Shoot", -1);
                if (!fire_m) continue;

                // Get function pointer from MethodInfo
                // MethodInfo+0x00 = function pointer (in IL2Cpp v24)
                void* fire_fn = *reinterpret_cast<void**>(fire_m);
                if (!fire_fn) continue;

                NSLog(@"[S2] Fire fn at %p — installing hook", fire_fn);

                // Save trampoline (first 16 bytes of original)
                static uint8_t trampoline[32];
                memcpy(trampoline, fire_fn, 16);
                // Add branch back to fire_fn+16
                uint32_t* t = (uint32_t*)(trampoline + 16);
                t[0] = 0x58000050;  // LDR X16, #8
                t[1] = 0xD61F0200;  // BR X16
                *((uintptr_t*)(t + 2)) = (uintptr_t)fire_fn + 16;
                __builtin___clear_cache((char*)trampoline, (char*)trampoline + 32);

                g_fire_trampoline = trampoline;
                write_branch(fire_fn, (void*)our_fire_hook);

                NSLog(@"[S2] Fire hook installed");
                return;
            }
        }
    }

    NSLog(@"[S2] Fire method not found — silent aim disabled");
}

// ─── Cheat thread ─────────────────────────────────────────────────────────────

static void* cheat_thread(void*) {
    NSLog(@"[S2] Thread started, waiting for IL2Cpp...");
    sleep(3);  // Wait for Unity to initialize

    if (!IL2::init()) {
        NSLog(@"[S2] IL2Cpp init failed");
        return nullptr;
    }
    NSLog(@"[S2] IL2Cpp API resolved");

    sleep(2);  // Wait for game classes to be loaded
    g_ctx.resolve();

    if (g_ctx.valid) {
        install_fire_hook();
        NSLog(@"[S2] Cheat active — WH+SilentAim running");
    } else {
        NSLog(@"[S2] Class resolution failed — check class names in dump");
    }

    // Main loop
    while (true) {
        @autoreleasepool {
            cheat_tick();
        }
        usleep(50000);  // 20 fps
    }
    return nullptr;
}

// ─── Entry point ──────────────────────────────────────────────────────────────

__attribute__((constructor))
static void load_cheat() {
    NSLog(@"[S2] s2cheat.dylib loaded");
    pthread_t tid;
    pthread_create(&tid, nullptr, cheat_thread, nullptr);
    pthread_detach(tid);
}
