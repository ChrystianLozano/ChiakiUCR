//
// libchiaki_ucr.mm
// Native SDL2 Virtual DualSense + Mouse/Keyboard UCR Engine for Chiaki-ng on macOS
//

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Carbon/Carbon.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <pthread.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>

#include "chiaki_ucr_shared.h"

// ============================================================================
// SDL2 Dynamic Types & Function Pointers
// ============================================================================

typedef uint8_t  Uint8;
typedef uint16_t Uint16;
typedef int16_t  Sint16;
typedef uint32_t Uint32;

typedef struct SDL_VirtualJoystickDesc {
    Uint16 version;
    Uint16 type;
    Uint16 naxes;
    Uint16 nbuttons;
    Uint16 nhats;
    Uint16 vendor_id;
    Uint16 product_id;
    Uint16 padding;
    Uint32 button_mask;
    Uint32 axis_mask;
    const char *name;
    void *userdata;
    void (*Update)(void *userdata);
    void (*SetPlayerIndex)(void *userdata, int player_index);
    int (*Rumble)(void *userdata, Uint16 low_frequency_rumble, Uint16 high_frequency_rumble);
    int (*RumbleTriggers)(void *userdata, Uint16 left_rumble, Uint16 right_rumble);
    int (*SetLED)(void *userdata, Uint8 red, Uint8 green, Uint8 blue);
    int (*SendEffect)(void *userdata, const void *data, int size);
} SDL_VirtualJoystickDesc;

typedef int   (*pfn_SDL_WasInit)(Uint32 flags);
typedef int   (*pfn_SDL_JoystickAttachVirtualEx)(const SDL_VirtualJoystickDesc *desc);
typedef int   (*pfn_SDL_JoystickDetachVirtual)(int device_index);
typedef void* (*pfn_SDL_JoystickFromInstanceID)(int instance_id);
typedef void* (*pfn_SDL_JoystickOpen)(int device_index);
typedef int   (*pfn_SDL_JoystickSetVirtualAxis)(void *joystick, int axis, Sint16 value);
typedef int   (*pfn_SDL_JoystickSetVirtualButton)(void *joystick, int button, Uint8 value);
typedef int   (*pfn_SDL_SetHint)(const char *name, const char *value);
typedef const char* (*pfn_SDL_GetError)(void);

// SDL_JoystickGUID is a 16-byte struct returned by value
typedef struct { Uint8 data[16]; } UCR_SDL_JoystickGUID;
typedef UCR_SDL_JoystickGUID (*pfn_SDL_JoystickGetDeviceGUID)(int device_index);
typedef void  (*pfn_SDL_JoystickGetGUIDString)(UCR_SDL_JoystickGUID guid, char *psz, int cb);
typedef int   (*pfn_SDL_GameControllerAddMapping)(const char *mapping);

static pfn_SDL_WasInit                  fn_SDL_WasInit = NULL;
static pfn_SDL_JoystickAttachVirtualEx  fn_SDL_JoystickAttachVirtualEx = NULL;
static pfn_SDL_JoystickOpen             fn_SDL_JoystickOpen = NULL;
static pfn_SDL_JoystickSetVirtualAxis   fn_SDL_JoystickSetVirtualAxis = NULL;
static pfn_SDL_JoystickSetVirtualButton fn_SDL_JoystickSetVirtualButton = NULL;
static pfn_SDL_SetHint                  fn_SDL_SetHint = NULL;
static pfn_SDL_GetError                 fn_SDL_GetError = NULL;
static pfn_SDL_JoystickGetDeviceGUID    fn_SDL_JoystickGetDeviceGUID = NULL;
static pfn_SDL_JoystickGetGUIDString    fn_SDL_JoystickGetGUIDString = NULL;
static pfn_SDL_GameControllerAddMapping fn_SDL_GameControllerAddMapping = NULL;

// ============================================================================
// Engine State
// ============================================================================

static ChiakiUCRSharedState *g_shm = NULL;
static void *g_virtual_joy = NULL;
static int   g_virtual_device_index = -1;

static pthread_mutex_t g_input_mutex = PTHREAD_MUTEX_INITIALIZER;
static bool     g_key_down[256] = {false};
static uint64_t g_key_min_hold_until_ns[256] = {0};
static bool     g_cgevent_keystate_supported = false;
static bool     g_app_is_active = true;

static bool  g_mouse_left_down = false;
static bool  g_mouse_right_down = false;
static bool  g_mouse_middle_down = false;
static bool  g_mouse_btn4_down = false;
static bool  g_mouse_btn5_down = false;

static float g_accum_dx = 0.0f;
static float g_accum_dy = 0.0f;
static uint64_t g_last_mouse_move_ns = 0;
static uint64_t g_wheel_up_until_ns = 0;
static uint64_t g_wheel_down_until_ns = 0;

static float g_smooth_rx = 0.0f;
static float g_smooth_ry = 0.0f;

// Weapon Wheel Assist virtual cursor (normalized, clamped to unit circle)
static float g_wheel_x = 0.0f;
static float g_wheel_y = 0.0f;
static bool  g_wheel_mode_prev = false;
static bool  g_cursor_hidden_by_us = false;
static id    g_local_event_monitor = nil;
static dispatch_source_t g_main_tick_timer = nil;

// Overlay HUD label inside Chiaki window
static NSTextField *g_hud_badge = nil;

// ============================================================================
// Time helper
// ============================================================================

static uint64_t now_ns(void) {
    static mach_timebase_info_data_t info = {0, 0};
    if (info.denom == 0) {
        mach_timebase_info(&info);
    }
    return (mach_absolute_time() * info.numer) / info.denom;
}

// ============================================================================
// Sanitize Keybindings (Prevents 0x0000 = kVK_ANSI_A from triggering buttons!)
// ============================================================================

static void sanitize_shared_keybindings(ChiakiUCRSharedState *s) {
    if (!s) return;
    // Keycode 0 on macOS is kVK_ANSI_A ('A' key).
    // If any unused slot was zero-initialized (0x0000) instead of 0xFFFF,
    // pressing 'A' would press every controller button simultaneously!
    if (s->key_move_left == kVK_ANSI_A) {
        if (s->key_l2 == 0) s->key_l2 = UCR_KEY_NONE;
        if (s->key_r2 == 0) s->key_r2 = UCR_KEY_NONE;
        for (int b = 0; b < UCR_BTN_COUNT; b++) {
            if (s->button_key_primary[b] == 0) {
                s->button_key_primary[b] = UCR_KEY_NONE;
            }
            if (s->button_key_secondary[b] == 0) {
                s->button_key_secondary[b] = UCR_KEY_NONE;
            }
        }
    }
}

// ============================================================================
// Default Profile Initialization (Arc Raiders & GTA V Ready)
// ============================================================================

static void init_default_shared_state(ChiakiUCRSharedState *s) {
    if (s->magic == CHIAKI_UCR_MAGIC && s->version == CHIAKI_UCR_VERSION) {
        // Keep user's existing config, sanitize any 0x0000 slots, and reset live runtime state
        sanitize_shared_keybindings(s);
        s->chiaki_pid = (uint32_t)getpid();
        s->capture_active = 0;
        memset(s->axes, 0, sizeof(s->axes));
        memset(s->buttons, 0, sizeof(s->buttons));
        return;
    }

    memset(s, 0, sizeof(ChiakiUCRSharedState));
    s->magic = CHIAKI_UCR_MAGIC;
    s->version = CHIAKI_UCR_VERSION;
    s->chiaki_pid = (uint32_t)getpid();
    s->capture_active = 0;

    strncpy(s->active_profile, "Arc Raiders + GTA Hybrid", sizeof(s->active_profile) - 1);

    // Tuned Mouse -> PS5 Right Stick parameters
    s->sens_x = 18.5f;
    s->sens_y = 18.5f;
    s->ads_multiplier = 0.65f;
    s->deadzone = 0.14f;        // Typical PS5 shooter deadzone (~14%)
    s->anti_deadzone = 0.88f;   // Immediate jump past deadzone when moving mouse
    s->exponent = 0.82f;        // Slight sub-linear curve to counter console stick acceleration
    s->smoothing = 0.12f;       // Subtle EMA smoothing for micro-movements
    s->decay_ms = 24.0f;
    s->invert_y = 0;
    s->left_stick_walk_pct = 45;
    s->toggle_key_code = kVK_F8; // F8 (also Option+M always works)

    // Movement: WASD
    s->key_move_up    = kVK_ANSI_W;      // 13
    s->key_move_down  = kVK_ANSI_S;      // 1
    s->key_move_left  = kVK_ANSI_A;      // 0
    s->key_move_right = kVK_ANSI_D;      // 2
    s->key_walk_mod   = kVK_Control;     // 59 (Left Ctrl for slow walk)

    for (int i = 0; i < UCR_BTN_COUNT; i++) {
        s->button_key_primary[i] = UCR_KEY_NONE;
        s->button_key_secondary[i] = UCR_KEY_NONE;
    }

    // PlayStation Controller Buttons mapped to standard PC Shooter / GTA keys:
    // Cross (X) = Space (Jump / Sprint in GTA)
    s->button_key_primary[UCR_BTN_CROSS]      = kVK_Space;           // 49
    // Circle (O) = C (Crouch / Dodge / Roll)
    s->button_key_primary[UCR_BTN_CIRCLE]     = kVK_ANSI_C;          // 8
    // Square ([]) = R or F (Reload / Interact / Enter Vehicle in GTA)
    s->button_key_primary[UCR_BTN_SQUARE]     = kVK_ANSI_R;          // 15
    s->button_key_secondary[UCR_BTN_SQUARE]   = kVK_ANSI_F;          // 3
    // Triangle (/\) = E (Swap Weapon / Interact / Exit or Enter Vehicle)
    s->button_key_primary[UCR_BTN_TRIANGLE]   = kVK_ANSI_E;          // 14
    // L1 = Q (Gadget / Weapon Wheel in GTA / Ping in Arc Raiders)
    s->button_key_primary[UCR_BTN_L1]         = kVK_ANSI_Q;          // 12
    // R1 = G (Grenade / Cover in GTA / Ability in Arc Raiders)
    s->button_key_primary[UCR_BTN_R1]         = kVK_ANSI_G;          // 5
    // L3 = Left Shift (Sprint)
    s->button_key_primary[UCR_BTN_L3]         = kVK_Shift;           // 56
    // R3 = V or Middle Mouse (Melee / Look Behind / Change Camera)
    s->button_key_primary[UCR_BTN_R3]         = kVK_ANSI_V;          // 9
    // Touchpad Click = Tab (Map / Inventory)
    s->button_key_primary[UCR_BTN_TOUCHPAD]   = kVK_Tab;             // 48
    // Options (Pause) = M or Return/Enter
    s->button_key_primary[UCR_BTN_OPTIONS]    = kVK_ANSI_M;          // 46
    s->button_key_secondary[UCR_BTN_OPTIONS]  = kVK_Return;          // 36
    // Share/Create = F12
    s->button_key_primary[UCR_BTN_SHARE]      = kVK_F12;             // 111
    // PS Home Button = F10
    s->button_key_primary[UCR_BTN_PS]         = kVK_F10;             // 109

    // D-Pad = 1, 2, 3, 4 AND Arrow Keys
    s->button_key_primary[UCR_BTN_DPAD_UP]      = kVK_ANSI_1;        // 18
    s->button_key_secondary[UCR_BTN_DPAD_UP]    = kVK_UpArrow;       // 126
    s->button_key_primary[UCR_BTN_DPAD_RIGHT]   = kVK_ANSI_2;        // 19
    s->button_key_secondary[UCR_BTN_DPAD_RIGHT] = kVK_RightArrow;    // 124
    s->button_key_primary[UCR_BTN_DPAD_DOWN]    = kVK_ANSI_3;        // 20
    s->button_key_secondary[UCR_BTN_DPAD_DOWN]  = kVK_DownArrow;     // 125
    s->button_key_primary[UCR_BTN_DPAD_LEFT]    = kVK_ANSI_4;        // 21
    s->button_key_secondary[UCR_BTN_DPAD_LEFT]  = kVK_LeftArrow;     // 123

    s->key_l2 = UCR_KEY_NONE;
    s->key_r2 = UCR_KEY_NONE;

    // GTA Vehicle mode (toggle with F6): W = R2 (Gas), S = L2 (Brake/Reverse)
    s->gta_W_S_triggers_in_vehicle = 1;
    s->key_vehicle_toggle = kVK_F6; // 97

    // Weapon Wheel Assist (hold L1 -> mouse aims the radial menu)
    s->wheel_assist_enabled = 1;
    s->wheel_sens = 0.8f;
    s->config_seq = 1;
}

static void setup_shared_memory(void) {
    int fd = open(CHIAKI_UCR_SHM_PATH, O_CREAT | O_RDWR, 0666);
    if (fd < 0) {
        perror("[ChiakiUCR] open shm failed");
        return;
    }
    fchmod(fd, 0666);
    if (ftruncate(fd, sizeof(ChiakiUCRSharedState)) != 0) {
        perror("[ChiakiUCR] ftruncate failed");
    }
    void *ptr = mmap(NULL, sizeof(ChiakiUCRSharedState), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (ptr == MAP_FAILED) {
        perror("[ChiakiUCR] mmap failed");
        return;
    }
    g_shm = (ChiakiUCRSharedState *)ptr;
    init_default_shared_state(g_shm);
}

// ============================================================================
// HUD Badge Overlay on Chiaki's Active Window & Cursor Lock
// ============================================================================

static NSWindow* find_best_chiaki_window(void) {
    if ([NSApp keyWindow] && [[NSApp keyWindow] isVisible]) {
        return [NSApp keyWindow];
    }
    if ([NSApp mainWindow] && [[NSApp mainWindow] isVisible]) {
        return [NSApp mainWindow];
    }
    for (NSWindow *w in [NSApp windows]) {
        if ([w isVisible] && [w canBecomeKeyWindow]) {
            return w;
        }
    }
    for (NSWindow *w in [NSApp windows]) {
        if ([w isVisible]) {
            return w;
        }
    }
    return [NSApp keyWindow] ?: [[NSApp windows] firstObject];
}

static void update_hud_and_cursor_on_main_thread(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_shm) return;
        bool active = (g_shm->capture_active != 0);
        bool vehicle = (g_shm->vehicle_mod_active != 0);

        NSWindow *win = find_best_chiaki_window();

        if (active) {
            if (![NSApp isActive]) {
                [NSApp activateIgnoringOtherApps:YES];
            }
            if (win) {
                if ([win isMiniaturized]) {
                    [win deminiaturize:nil];
                }
                if (![win isKeyWindow]) {
                    [win makeKeyAndOrderFront:nil];
                }
            }
        }

        if (active && [NSApp isActive]) {
            // Prevent CGWarpMouseCursorPosition from freezing keyboard/mouse events for 250ms
            CGEventSourceSetLocalEventsSuppressionInterval(NULL, 0.0);
            CGAssociateMouseAndMouseCursorPosition(false);
            if (!g_cursor_hidden_by_us) {
                [NSCursor hide];
                g_cursor_hidden_by_us = true;
            }
            if (win) {
                NSRect frame = [win frame];
                NSScreen *screen = [win screen] ?: [NSScreen mainScreen];
                NSScreen *primary = [NSScreen screens].firstObject ?: screen;
                CGFloat screenHeight = primary ? primary.frame.size.height : (screen ? screen.frame.size.height : 1080.0);
                CGPoint center = CGPointMake(
                    frame.origin.x + frame.size.width * 0.5,
                    screenHeight - (frame.origin.y + frame.size.height * 0.5)
                );
                CGWarpMouseCursorPosition(center);
            }
        } else if (!active) {
            CGAssociateMouseAndMouseCursorPosition(true);
            if (g_cursor_hidden_by_us) {
                [NSCursor unhide];
                g_cursor_hidden_by_us = false;
            }
        }

        if (win && [win contentView]) {
            NSView *cv = [win contentView];
            if (!g_hud_badge || [g_hud_badge superview] != cv) {
                [g_hud_badge removeFromSuperview];
                g_hud_badge = [[NSTextField alloc] initWithFrame:NSMakeRect(16, cv.bounds.size.height - 42, 460, 26)];
                [g_hud_badge setEditable:NO];
                [g_hud_badge setSelectable:NO];
                [g_hud_badge setBezeled:NO];
                [g_hud_badge setDrawsBackground:YES];
                [g_hud_badge setFont:[NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightBold]];
                [g_hud_badge setAutoresizingMask:NSViewMinYMargin | NSViewMaxXMargin];
                g_hud_badge.wantsLayer = YES;
                g_hud_badge.layer.cornerRadius = 6.0;
                [cv addSubview:g_hud_badge];
            }
            if (active) {
                NSString *modeStr = vehicle ? @"🚗 MODO VEHÍCULO (W/S=R2/L2)" : @"🎯 RATÓN+TECLADO ACTIVO";
                [g_hud_badge setStringValue:[NSString stringWithFormat:@" UCR: %@  [F8 / Opt+M soltar ratón]", modeStr]];
                [g_hud_badge setBackgroundColor:[NSColor colorWithCalibratedRed:0.08 green:0.55 blue:0.28 alpha:0.85]];
                [g_hud_badge setTextColor:[NSColor whiteColor]];
                [g_hud_badge setHidden:NO];
            } else {
                NSString *modeStr = vehicle ? @"🚗 TECLADO ACTIVO (Vehículo)" : @"⌨️ TECLADO ACTIVO";
                [g_hud_badge setStringValue:[NSString stringWithFormat:@" UCR: %@ — Pulsa F8 u Opt+M para capturar Ratón", modeStr]];
                [g_hud_badge setBackgroundColor:[NSColor colorWithCalibratedRed:0.12 green:0.12 blue:0.15 alpha:0.75]];
                [g_hud_badge setTextColor:[NSColor colorWithCalibratedWhite:0.90 alpha:1.0]];
                [g_hud_badge setHidden:NO];
            }
        }
    });
}

static void clear_all_inputs_locked(void) {
    memset(g_key_down, 0, sizeof(g_key_down));
    memset(g_key_min_hold_until_ns, 0, sizeof(g_key_min_hold_until_ns));
    g_mouse_left_down = false;
    g_mouse_right_down = false;
    g_mouse_middle_down = false;
    g_mouse_btn4_down = false;
    g_mouse_btn5_down = false;
    g_accum_dx = 0.0f;
    g_accum_dy = 0.0f;
    g_smooth_rx = 0.0f;
    g_smooth_ry = 0.0f;
}

static void set_capture_active(bool active) {
    if (!g_shm) return;
    pthread_mutex_lock(&g_input_mutex);
    g_shm->capture_active = active ? 1 : 0;
    if (!active) {
        g_mouse_left_down = false;
        g_mouse_right_down = false;
        g_mouse_middle_down = false;
        g_mouse_btn4_down = false;
        g_mouse_btn5_down = false;
        g_accum_dx = 0.0f;
        g_accum_dy = 0.0f;
        g_smooth_rx = 0.0f;
        g_smooth_ry = 0.0f;
    }
    pthread_mutex_unlock(&g_input_mutex);
    update_hud_and_cursor_on_main_thread();
}

// ============================================================================
// SDL2 Virtual DualSense Callbacks
// ============================================================================

static void virtual_ds_update(void *userdata) {
    (void)userdata;
}

static void virtual_ds_set_player_index(void *userdata, int player_index) {
    (void)userdata;
    (void)player_index;
}

static int virtual_ds_rumble(void *userdata, Uint16 low_freq, Uint16 high_freq) {
    (void)userdata;
    if (g_shm) {
        g_shm->rumble_left = low_freq;
        g_shm->rumble_right = high_freq;
    }
    return 0;
}

static int virtual_ds_rumble_triggers(void *userdata, Uint16 left_rumble, Uint16 right_rumble) {
    (void)userdata;
    (void)left_rumble;
    (void)right_rumble;
    return 0;
}

static int virtual_ds_set_led(void *userdata, Uint8 r, Uint8 g, Uint8 b) {
    (void)userdata;
    if (g_shm) {
        g_shm->led_r = r;
        g_shm->led_g = g;
        g_shm->led_b = b;
    }
    return 0;
}

static int virtual_ds_send_effect(void *userdata, const void *data, int size) {
    (void)userdata;
    (void)data;
    (void)size;
    return 0;
}

// ============================================================================
// High-Frequency Translation Engine (Mouse + Keyboard -> DualSense State)
// ============================================================================

static inline bool query_hw_key(uint16_t vk) {
    if (vk >= 256) return false;
    bool down = CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, (CGKeyCode)vk) ||
                CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, (CGKeyCode)vk);
    if (down) {
        g_cgevent_keystate_supported = true;
    }
    return down;
}

// Used for movement keys (WASD + Walk mod + Arrows)
static inline bool is_movement_key_pressed(uint16_t vk, uint64_t t_now) {
    if (vk >= 256) return false;
    if (!g_app_is_active) return false;

    bool hw_down = query_hw_key(vk);
    if (hw_down) {
        g_key_down[vk] = true;
        return true;
    }
    if (g_cgevent_keystate_supported && t_now >= g_key_min_hold_until_ns[vk]) {
        // Hardware says key is released and minimum tap hold expired -> never let it stick!
        g_key_down[vk] = false;
    }
    return g_key_down[vk] || (t_now < g_key_min_hold_until_ns[vk]);
}

// Used for controller buttons (Cross, Circle, Square, Triangle, L1, R1, L2, R2, etc.)
static inline bool is_button_key_pressed(uint16_t vk, uint64_t t_now) {
    if (vk >= 256) return false;
    // Guard against uninitialized 0x0000 (kVK_ANSI_A) triggering controller buttons when A is Move Left
    if (vk == kVK_ANSI_A && g_shm && g_shm->key_move_left == kVK_ANSI_A) {
        return false;
    }
    return is_movement_key_pressed(vk, t_now);
}

static inline Sint16 float_to_axis(float v) {
    if (v > 1.0f) v = 1.0f;
    if (v < -1.0f) v = -1.0f;
    int32_t iv = (int32_t)lrintf(v * 32767.0f);
    if (iv > 32767) iv = 32767;
    if (iv < -32768) iv = -32768;
    return (Sint16)iv;
}

static void tick_ucr_engine(void) {
    if (!g_shm) return;
    g_shm->plugin_alive_counter++;

    // Always sanitize shared memory in case external UI wrote 0x0000 to unused slots
    sanitize_shared_keybindings(g_shm);

    // Ensure SDL2 is initialized before attaching virtual controller
    if (!g_virtual_joy && fn_SDL_WasInit && fn_SDL_JoystickAttachVirtualEx && fn_SDL_JoystickOpen) {
        // 0x2000 = SDL_INIT_GAMECONTROLLER, 0x0200 = SDL_INIT_JOYSTICK
        if (fn_SDL_WasInit(0x2000 | 0x0200) != 0) {
            if (fn_SDL_SetHint) {
                fn_SDL_SetHint("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", "1");
            }
            SDL_VirtualJoystickDesc desc;
            memset(&desc, 0, sizeof(desc));
            desc.version = 1;
            desc.type = 1; // SDL_JOYSTICK_TYPE_GAMECONTROLLER
            desc.naxes = UCR_AXIS_COUNT;
            desc.nbuttons = UCR_BTN_COUNT;
            desc.nhats = 0;
            desc.vendor_id = 0x054c;  // Sony Corp.
            desc.product_id = 0x0ce6; // DualSense Wireless Controller
            desc.button_mask = (1u << UCR_BTN_COUNT) - 1u;
            desc.axis_mask = (1u << UCR_AXIS_COUNT) - 1u;
            desc.name = "DualSense Wireless Controller (Chiaki-UCR)";
            desc.Update = virtual_ds_update;
            desc.SetPlayerIndex = virtual_ds_set_player_index;
            desc.Rumble = virtual_ds_rumble;
            desc.RumbleTriggers = virtual_ds_rumble_triggers;
            desc.SetLED = virtual_ds_set_led;
            desc.SendEffect = virtual_ds_send_effect;

            g_virtual_device_index = fn_SDL_JoystickAttachVirtualEx(&desc);
            if (g_virtual_device_index >= 0) {
                // SDL2's automatic mapping for virtual controllers omits "touchpad", so button 20
                // never reaches chiaki-ng. Register an explicit mapping that includes touchpad:b20.
                if (fn_SDL_JoystickGetDeviceGUID && fn_SDL_JoystickGetGUIDString && fn_SDL_GameControllerAddMapping) {
                    char guid_str[64] = {0};
                    fn_SDL_JoystickGetGUIDString(fn_SDL_JoystickGetDeviceGUID(g_virtual_device_index), guid_str, sizeof(guid_str));
                    char mapping[1024];
                    snprintf(mapping, sizeof(mapping),
                             "%s,%s,a:b0,b:b1,x:b2,y:b3,back:b4,guide:b5,start:b6,leftstick:b7,rightstick:b8,"
                             "leftshoulder:b9,rightshoulder:b10,dpup:b11,dpdown:b12,dpleft:b13,dpright:b14,"
                             "misc1:b15,paddle1:b16,paddle2:b17,paddle3:b18,paddle4:b19,touchpad:b20,"
                             "leftx:a0,lefty:a1,rightx:a2,righty:a3,lefttrigger:a4,righttrigger:a5,",
                             guid_str, desc.name);
                    int rc = fn_SDL_GameControllerAddMapping(mapping);
                    fprintf(stderr, "[ChiakiUCR] Touchpad mapping registered (rc=%d, guid=%s)\n", rc, guid_str);
                }
                g_virtual_joy = fn_SDL_JoystickOpen(g_virtual_device_index);
                if (g_virtual_joy && fn_SDL_JoystickSetVirtualAxis) {
                    // Crucial: In SDL2, raw joystick trigger axes map [-32768 .. +32767] -> [0 .. 32767].
                    // Initialize L2 (axis 4) and R2 (axis 5) to -32768 so they start at 0% (unpressed)!
                    fn_SDL_JoystickSetVirtualAxis(g_virtual_joy, UCR_AXIS_LEFTX, 0);
                    fn_SDL_JoystickSetVirtualAxis(g_virtual_joy, UCR_AXIS_LEFTY, 0);
                    fn_SDL_JoystickSetVirtualAxis(g_virtual_joy, UCR_AXIS_RIGHTX, 0);
                    fn_SDL_JoystickSetVirtualAxis(g_virtual_joy, UCR_AXIS_RIGHTY, 0);
                    fn_SDL_JoystickSetVirtualAxis(g_virtual_joy, UCR_AXIS_TRIGGERLEFT, -32768);
                    fn_SDL_JoystickSetVirtualAxis(g_virtual_joy, UCR_AXIS_TRIGGERRIGHT, -32768);
                }
                fprintf(stderr, "[ChiakiUCR] Attached Virtual DualSense at index %d (handle=%p)\n",
                        g_virtual_device_index, g_virtual_joy);
                update_hud_and_cursor_on_main_thread();
            }
        }
    }

    if (!g_virtual_joy) return;

    g_app_is_active = [NSApp isActive];

    pthread_mutex_lock(&g_input_mutex);

    // If Chiaki is not the active foreground application, release all inputs cleanly so nothing sticks
    if (!g_app_is_active) {
        clear_all_inputs_locked();
        for (int a = 0; a < UCR_AXIS_COUNT; a++) {
            g_shm->axes[a] = 0;
            Sint16 sdl_rest = (a == UCR_AXIS_TRIGGERLEFT || a == UCR_AXIS_TRIGGERRIGHT) ? -32768 : 0;
            fn_SDL_JoystickSetVirtualAxis(g_virtual_joy, a, sdl_rest);
        }
        for (int b = 0; b < UCR_BTN_COUNT; b++) {
            if (g_shm->buttons[b] != 0) {
                g_shm->buttons[b] = 0;
                fn_SDL_JoystickSetVirtualButton(g_virtual_joy, b, 0);
            }
        }
        g_shm->norm_stick_lx = 0.0f;
        g_shm->norm_stick_ly = 0.0f;
        g_shm->norm_stick_rx = 0.0f;
        g_shm->norm_stick_ry = 0.0f;
        pthread_mutex_unlock(&g_input_mutex);
        return;
    }

    // If Command key is held (e.g. Cmd+Tab, Cmd+Q, Cmd+H), do not send game inputs
    if (query_hw_key(kVK_Command) || query_hw_key(kVK_RightCommand)) {
        clear_all_inputs_locked();
        pthread_mutex_unlock(&g_input_mutex);
        return;
    }

    uint64_t t_now = now_ns();
    bool mouse_capture = (g_shm->capture_active != 0);
    bool vehicle_mode = (g_shm->vehicle_mod_active != 0);

    // Sync hardware mouse button state when mouse capture is active so physical mice AND MacBook Trackpad
    // two-finger right-clicks (NSEventTypeRightMouseDown) both work 100% reliably without overwriting each other
    bool hw_left = false, hw_right = false, hw_mid = false;
    if (mouse_capture) {
        hw_left = CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft) ||
                  CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonLeft);
        hw_right = CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonRight) ||
                   CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonRight);
        hw_mid = CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonCenter) ||
                 CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonCenter);
    }

    // 1. Left Stick (WASD - works whenever Chiaki window is active!)
    float lx = 0.0f;
    float ly = 0.0f;
    bool w_pressed = is_movement_key_pressed(g_shm->key_move_up, t_now);
    bool s_pressed = is_movement_key_pressed(g_shm->key_move_down, t_now);
    bool a_pressed = is_movement_key_pressed(g_shm->key_move_left, t_now);
    bool d_pressed = is_movement_key_pressed(g_shm->key_move_right, t_now);

    if (a_pressed) lx -= 1.0f;
    if (d_pressed) lx += 1.0f;

    if (!vehicle_mode || !g_shm->gta_W_S_triggers_in_vehicle) {
        if (w_pressed) ly -= 1.0f;
        if (s_pressed) ly += 1.0f;
    } else {
        // In GTA Vehicle Mode, Arrow Up / Down can pitch aircraft/bikes
        if (is_movement_key_pressed(kVK_UpArrow, t_now))   ly -= 1.0f;
        if (is_movement_key_pressed(kVK_DownArrow, t_now)) ly += 1.0f;
    }

    // Normalize diagonal WASD so magnitude doesn't exceed 1.0
    float l_mag = sqrtf(lx * lx + ly * ly);
    if (l_mag > 1.0f) {
        lx /= l_mag;
        ly /= l_mag;
    }

    // Walk slow modifier (e.g., Left Control)
    bool walk_mod = is_movement_key_pressed(g_shm->key_walk_mod, t_now);
    g_shm->walk_mod_active = walk_mod ? 1 : 0;
    if (walk_mod) {
        float scale = (float)g_shm->left_stick_walk_pct / 100.0f;
        if (scale < 0.15f) scale = 0.45f;
        lx *= scale;
        ly *= scale;
    }

    // 2. Triggers (L2 / R2)
    bool l2_pressed = (mouse_capture && (g_mouse_right_down || hw_right)) || is_button_key_pressed(g_shm->key_l2, t_now);
    bool r2_pressed = (mouse_capture && (g_mouse_left_down  || hw_left))  || is_button_key_pressed(g_shm->key_r2, t_now);

    if (vehicle_mode && g_shm->gta_W_S_triggers_in_vehicle) {
        if (w_pressed) r2_pressed = true; // W = Gas (R2)
        if (s_pressed) l2_pressed = true; // S = Brake/Reverse (L2)
    }

    g_shm->ads_active = l2_pressed ? 1 : 0;

    // 3. Mouse Delta -> Right Stick (Only when mouse capture F8 is active)
    float dx = mouse_capture ? g_accum_dx : 0.0f;
    float dy = mouse_capture ? g_accum_dy : 0.0f;
    g_accum_dx = 0.0f;
    g_accum_dy = 0.0f;

    g_shm->raw_mouse_dx = dx;
    g_shm->raw_mouse_dy = dy;

    // Weapon Wheel Assist: while L1 is held (on foot, mouse captured) the mouse drives a virtual
    // cursor clamped to the unit circle. The Right Stick stays pointed at the chosen slot instead
    // of snapping back to center when the mouse stops, so radial menus are easy to select.
    bool l1_held = is_button_key_pressed(g_shm->button_key_primary[UCR_BTN_L1], t_now) ||
                   is_button_key_pressed(g_shm->button_key_secondary[UCR_BTN_L1], t_now);
    bool wheel_mode = mouse_capture && g_shm->wheel_assist_enabled && l1_held && !vehicle_mode;
    if (wheel_mode != g_wheel_mode_prev) {
        g_wheel_x = 0.0f;
        g_wheel_y = 0.0f;
        g_smooth_rx = 0.0f;
        g_smooth_ry = 0.0f;
        g_wheel_mode_prev = wheel_mode;
    }

    float decay_ns = (g_shm->decay_ms > 4.0f ? g_shm->decay_ms : 22.0f) * 1e6f;
    double elapsed_since_move = (double)(t_now - g_last_mouse_move_ns);

    float target_rx = 0.0f;
    float target_ry = 0.0f;

    if (wheel_mode) {
        float ws = g_shm->wheel_sens;
        if (!(ws >= 0.2f && ws <= 2.0f)) ws = 0.8f;
        // ~180 px of mouse travel reach the wheel edge at sensitivity 1.0
        g_wheel_x += dx * ws / 180.0f;
        g_wheel_y += dy * ws / 180.0f;
        float wm = sqrtf(g_wheel_x * g_wheel_x + g_wheel_y * g_wheel_y);
        if (wm > 1.0f) {
            g_wheel_x /= wm;
            g_wheel_y /= wm;
            wm = 1.0f;
        }
        // Inner dead circle keeps the wheel neutral; beyond it, push the stick fully toward the slot
        if (wm > 0.30f) {
            g_smooth_rx = g_wheel_x / wm;
            g_smooth_ry = g_wheel_y / wm;
        } else {
            g_smooth_rx = 0.0f;
            g_smooth_ry = 0.0f;
        }
    } else if (mouse_capture && (fabsf(dx) > 0.001f || fabsf(dy) > 0.001f || elapsed_since_move < decay_ns)) {
        float sens_x = (g_shm->sens_x > 0.5f) ? g_shm->sens_x : 18.0f;
        float sens_y = (g_shm->sens_y > 0.5f) ? g_shm->sens_y : 18.0f;

        if (l2_pressed) {
            float ads = (g_shm->ads_multiplier > 0.05f) ? g_shm->ads_multiplier : 0.65f;
            sens_x *= ads;
            sens_y *= ads;
        }
        if (g_shm->invert_y) {
            dy = -dy;
        }

        // Convert raw pixel velocity over 8ms tick into normalized [0..1] stick request
        float vx = (dx * sens_x) / 420.0f;
        float vy = (dy * sens_y) / 420.0f;

        float mag = sqrtf(vx * vx + vy * vy);
        if (mag > 0.0001f) {
            float dir_x = vx / mag;
            float dir_y = vy / mag;

            float clamped = fminf(mag, 1.0f);
            float exp_val = (g_shm->exponent > 0.2f && g_shm->exponent < 3.0f) ? g_shm->exponent : 0.85f;
            float curved = powf(clamped, exp_val);

            // Radial Anti-Deadzone compensation (crucial for PS4/PS5 shooters like Arc Raiders & GTA)
            float dz = fminf(fmaxf(g_shm->deadzone, 0.0f), 0.45f);
            float anti_dz = fminf(fmaxf(g_shm->anti_deadzone, 0.0f), 1.0f);
            float eff_dz = dz * anti_dz;

            float final_mag = eff_dz + (1.0f - eff_dz) * curved;
            if (final_mag > 1.0f) final_mag = 1.0f;

            target_rx = dir_x * final_mag;
            target_ry = dir_y * final_mag;
        }
    }

    float smooth = fminf(fmaxf(g_shm->smoothing, 0.0f), 0.85f);
    if (wheel_mode) {
        // Stick already set by the Weapon Wheel Assist above
    } else if (!mouse_capture || (target_rx == 0.0f && target_ry == 0.0f && elapsed_since_move >= decay_ns)) {
        // Snap immediately to 0 when mouse stops so camera never drifts
        g_smooth_rx = 0.0f;
        g_smooth_ry = 0.0f;
    } else {
        g_smooth_rx = g_smooth_rx * smooth + target_rx * (1.0f - smooth);
        g_smooth_ry = g_smooth_ry * smooth + target_ry * (1.0f - smooth);
    }

    // 4. Commit Axes to Shared State & SDL Virtual DualSense
    g_shm->norm_stick_lx = lx;
    g_shm->norm_stick_ly = ly;
    g_shm->norm_stick_rx = g_smooth_rx;
    g_shm->norm_stick_ry = g_smooth_ry;

    // UI telemetry uses [0 .. 32767] for triggers, while SDL_JoystickSetVirtualAxis
    // requires [-32768 .. +32767] because SDL_GameController maps [-32768..32767] -> [0..32767]!
    g_shm->axes[UCR_AXIS_LEFTX]        = float_to_axis(lx);
    g_shm->axes[UCR_AXIS_LEFTY]        = float_to_axis(ly);
    g_shm->axes[UCR_AXIS_RIGHTX]       = float_to_axis(g_smooth_rx);
    g_shm->axes[UCR_AXIS_RIGHTY]       = float_to_axis(g_smooth_ry);
    g_shm->axes[UCR_AXIS_TRIGGERLEFT]  = l2_pressed ? 32767 : 0;
    g_shm->axes[UCR_AXIS_TRIGGERRIGHT] = r2_pressed ? 32767 : 0;

    fn_SDL_JoystickSetVirtualAxis(g_virtual_joy, UCR_AXIS_LEFTX,        g_shm->axes[UCR_AXIS_LEFTX]);
    fn_SDL_JoystickSetVirtualAxis(g_virtual_joy, UCR_AXIS_LEFTY,        g_shm->axes[UCR_AXIS_LEFTY]);
    fn_SDL_JoystickSetVirtualAxis(g_virtual_joy, UCR_AXIS_RIGHTX,       g_shm->axes[UCR_AXIS_RIGHTX]);
    fn_SDL_JoystickSetVirtualAxis(g_virtual_joy, UCR_AXIS_RIGHTY,       g_shm->axes[UCR_AXIS_RIGHTY]);
    fn_SDL_JoystickSetVirtualAxis(g_virtual_joy, UCR_AXIS_TRIGGERLEFT,  l2_pressed ? 32767 : -32768);
    fn_SDL_JoystickSetVirtualAxis(g_virtual_joy, UCR_AXIS_TRIGGERRIGHT, r2_pressed ? 32767 : -32768);

    // 5. Commit Buttons to Shared State & SDL Virtual DualSense
    for (int b = 0; b < UCR_BTN_COUNT; b++) {
        bool pressed = is_button_key_pressed(g_shm->button_key_primary[b], t_now) ||
                       is_button_key_pressed(g_shm->button_key_secondary[b], t_now);

        if (mouse_capture) {
            // Extra Mouse Button conveniences when mouse capture is active:
            if (b == UCR_BTN_R3 && (g_mouse_middle_down || hw_mid)) pressed = true;
            if (b == UCR_BTN_CIRCLE && g_mouse_btn4_down) pressed = true;
            if (b == UCR_BTN_R1 && g_mouse_btn5_down) pressed = true;
            if (b == UCR_BTN_TRIANGLE && t_now < g_wheel_up_until_ns) pressed = true;
            if (b == UCR_BTN_DPAD_RIGHT && t_now < g_wheel_down_until_ns) pressed = true;
        }

        Uint8 val = pressed ? 1 : 0;
        g_shm->buttons[b] = val;
        fn_SDL_JoystickSetVirtualButton(g_virtual_joy, b, val);
    }

    pthread_mutex_unlock(&g_input_mutex);
}

// ============================================================================
// Cocoa NSEvent Monitor (Zero special permissions required inside Chiaki!)
// ============================================================================

static bool is_mapped_game_key(uint16_t kc) {
    if (!g_shm) return false;
    if (kc == g_shm->key_move_up || kc == g_shm->key_move_down ||
        kc == g_shm->key_move_left || kc == g_shm->key_move_right ||
        kc == g_shm->key_walk_mod || kc == g_shm->key_l2 || kc == g_shm->key_r2) {
        return true;
    }
    for (int b = 0; b < UCR_BTN_COUNT; b++) {
        if (kc == g_shm->button_key_primary[b] || kc == g_shm->button_key_secondary[b]) {
            return true;
        }
    }
    return false;
}

static NSEvent* handle_cocoa_event(NSEvent *event) {
    if (!g_shm) return event;

    NSEventType type = [event type];

    // Check Toggle Hotkey: F8 (or user configured toggle_key_code) or Option + M
    if (type == NSEventTypeKeyDown) {
        unsigned short kc = [event keyCode];
        NSEventModifierFlags flags = [event modifierFlags];
        bool opt_m = ((flags & NSEventModifierFlagOption) != 0) && (kc == kVK_ANSI_M);
        bool toggle_key = (kc == g_shm->toggle_key_code) || (kc == kVK_F8);

        if (toggle_key || opt_m) {
            if (![event isARepeat]) {
                set_capture_active(g_shm->capture_active == 0);
            }
            return nil; // Swallow hotkey
        }

        // Check GTA Vehicle Mode Toggle (F6 by default)
        if (kc == g_shm->key_vehicle_toggle) {
            if (![event isARepeat]) {
                g_shm->vehicle_mod_active = !g_shm->vehicle_mod_active;
                update_hud_and_cursor_on_main_thread();
            }
            return nil;
        }
    }

    // Always handle Keyboard events when Chiaki is open so Chiaki's built-in keyboard handler
    // doesn't fight with UCR or cause system alert beeps, and so keyboard works even before F8!
    if (type == NSEventTypeKeyDown || type == NSEventTypeKeyUp || type == NSEventTypeFlagsChanged) {
        if ([event modifierFlags] & NSEventModifierFlagCommand) {
            if (g_shm->capture_active) {
                set_capture_active(false);
            }
            return event; // Allow Cmd+Q, Cmd+Tab, Cmd+V, etc.
        }

        pthread_mutex_lock(&g_input_mutex);
        if (type == NSEventTypeKeyDown) {
            unsigned short kc = [event keyCode];
            if (kc < 256) {
                g_key_down[kc] = true;
                // Hold for at least 45ms so quick taps are guaranteed to be seen by Chiaki's 60Hz SDL poll
                g_key_min_hold_until_ns[kc] = now_ns() + 45000000ULL;
            }
            bool swallow = (g_shm->capture_active != 0) || is_mapped_game_key(kc);
            pthread_mutex_unlock(&g_input_mutex);
            return swallow ? nil : event;
        } else if (type == NSEventTypeKeyUp) {
            unsigned short kc = [event keyCode];
            if (kc < 256) {
                g_key_down[kc] = false;
            }
            bool swallow = (g_shm->capture_active != 0) || is_mapped_game_key(kc);
            pthread_mutex_unlock(&g_input_mutex);
            return swallow ? nil : event;
        } else if (type == NSEventTypeFlagsChanged) {
            NSEventModifierFlags flags = [event modifierFlags];
            g_key_down[kVK_Shift]        = (flags & NSEventModifierFlagShift) != 0;
            g_key_down[kVK_RightShift]   = (flags & NSEventModifierFlagShift) != 0;
            g_key_down[kVK_Control]      = (flags & NSEventModifierFlagControl) != 0;
            g_key_down[kVK_RightControl] = (flags & NSEventModifierFlagControl) != 0;
            g_key_down[kVK_Option]       = (flags & NSEventModifierFlagOption) != 0;
            g_key_down[kVK_CapsLock]     = (flags & NSEventModifierFlagCapsLock) != 0;
            pthread_mutex_unlock(&g_input_mutex);
            return (g_shm->capture_active != 0) ? nil : event;
        }
        pthread_mutex_unlock(&g_input_mutex);
    }

    if (!g_shm->capture_active) {
        return event;
    }

    // Mouse capture is active: intercept mouse movements, clicks, and wheel
    pthread_mutex_lock(&g_input_mutex);
    switch (type) {
        case NSEventTypeMouseMoved:
        case NSEventTypeLeftMouseDragged:
        case NSEventTypeRightMouseDragged:
        case NSEventTypeOtherMouseDragged: {
            g_accum_dx += (float)[event deltaX];
            g_accum_dy += (float)[event deltaY];
            g_last_mouse_move_ns = now_ns();
            pthread_mutex_unlock(&g_input_mutex);
            return nil;
        }
        case NSEventTypeLeftMouseDown:
            g_mouse_left_down = true;
            pthread_mutex_unlock(&g_input_mutex);
            return nil;
        case NSEventTypeLeftMouseUp:
            g_mouse_left_down = false;
            pthread_mutex_unlock(&g_input_mutex);
            return nil;
        case NSEventTypeRightMouseDown:
            g_mouse_right_down = true;
            pthread_mutex_unlock(&g_input_mutex);
            return nil;
        case NSEventTypeRightMouseUp:
            g_mouse_right_down = false;
            pthread_mutex_unlock(&g_input_mutex);
            return nil;
        case NSEventTypeOtherMouseDown: {
            NSInteger btn = [event buttonNumber];
            if (btn == 2) g_mouse_middle_down = true;
            else if (btn == 3) g_mouse_btn4_down = true;
            else if (btn == 4) g_mouse_btn5_down = true;
            pthread_mutex_unlock(&g_input_mutex);
            return nil;
        }
        case NSEventTypeOtherMouseUp: {
            NSInteger btn = [event buttonNumber];
            if (btn == 2) g_mouse_middle_down = false;
            else if (btn == 3) g_mouse_btn4_down = false;
            else if (btn == 4) g_mouse_btn5_down = false;
            pthread_mutex_unlock(&g_input_mutex);
            return nil;
        }
        case NSEventTypeScrollWheel: {
            CGFloat dy = [event scrollingDeltaY];
            uint64_t pulse_until = now_ns() + 90000000ULL; // 90ms button tap pulse
            if (dy > 0.1) {
                g_wheel_up_until_ns = pulse_until;
            } else if (dy < -0.1) {
                g_wheel_down_until_ns = pulse_until;
            }
            pthread_mutex_unlock(&g_input_mutex);
            return nil;
        }
        default:
            break;
    }
    pthread_mutex_unlock(&g_input_mutex);
    return event;
}

// ============================================================================
// Bootstrap Thread & Main-Queue 125Hz Engine Timer
// ============================================================================

static void* ucr_bootstrap_thread(void *arg) {
    (void)arg;
    // Wait until SDL2 symbols are resolved
    while (!fn_SDL_JoystickAttachVirtualEx) {
        void *sdl = dlopen("@executable_path/../Frameworks/libSDL2-2.0.0.dylib", RTLD_LAZY | RTLD_NOLOAD);
        if (!sdl) {
            sdl = dlopen(NULL, RTLD_LAZY);
        }
        if (sdl) {
            fn_SDL_WasInit                  = (pfn_SDL_WasInit)dlsym(sdl, "SDL_WasInit");
            fn_SDL_JoystickAttachVirtualEx  = (pfn_SDL_JoystickAttachVirtualEx)dlsym(sdl, "SDL_JoystickAttachVirtualEx");
            fn_SDL_JoystickOpen             = (pfn_SDL_JoystickOpen)dlsym(sdl, "SDL_JoystickOpen");
            fn_SDL_JoystickSetVirtualAxis   = (pfn_SDL_JoystickSetVirtualAxis)dlsym(sdl, "SDL_JoystickSetVirtualAxis");
            fn_SDL_JoystickSetVirtualButton = (pfn_SDL_JoystickSetVirtualButton)dlsym(sdl, "SDL_JoystickSetVirtualButton");
            fn_SDL_SetHint                  = (pfn_SDL_SetHint)dlsym(sdl, "SDL_SetHint");
            fn_SDL_GetError                 = (pfn_SDL_GetError)dlsym(sdl, "SDL_GetError");
            fn_SDL_JoystickGetDeviceGUID    = (pfn_SDL_JoystickGetDeviceGUID)dlsym(sdl, "SDL_JoystickGetDeviceGUID");
            fn_SDL_JoystickGetGUIDString    = (pfn_SDL_JoystickGetGUIDString)dlsym(sdl, "SDL_JoystickGetGUIDString");
            fn_SDL_GameControllerAddMapping = (pfn_SDL_GameControllerAddMapping)dlsym(sdl, "SDL_GameControllerAddMapping");
        }
        usleep(50000);
    }

    // Install Cocoa NSEvent monitors and 125Hz SDL update timer on the main queue
    // Running tick_ucr_engine on the main queue eliminates all thread races with SDL_PollEvent!
    dispatch_async(dispatch_get_main_queue(), ^{
        // Disable macOS Press-and-Hold accent menu so holding W/A/S/D/E/C never freezes key repeat
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"ApplePressAndHoldEnabled"];
        CGEventSourceSetLocalEventsSuppressionInterval(NULL, 0.0);

        NSEventMask mask = NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged |
                           NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged |
                           NSEventMaskRightMouseDragged | NSEventMaskOtherMouseDragged |
                           NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp |
                           NSEventMaskRightMouseDown | NSEventMaskRightMouseUp |
                           NSEventMaskOtherMouseDown | NSEventMaskOtherMouseUp |
                           NSEventMaskScrollWheel;

        g_local_event_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
            return handle_cocoa_event(event);
        }];

        // When Chiaki becomes active, re-sync capture state & hide/lock cursor if capture is enabled
        [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            (void)note;
            if (g_shm && g_shm->capture_active) {
                update_hud_and_cursor_on_main_thread();
            }
        }];

        // Automatically release mouse lock & clear stuck keys if Chiaki loses focus (Cmd+Tab)
        [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidResignActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            (void)note;
            pthread_mutex_lock(&g_input_mutex);
            clear_all_inputs_locked();
            pthread_mutex_unlock(&g_input_mutex);
            if (g_shm && g_shm->capture_active) {
                set_capture_active(false);
            }
        }];

        // 125Hz (8ms) high-precision timer on main queue
        g_main_tick_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, dispatch_get_main_queue());
        dispatch_source_set_timer(g_main_tick_timer, DISPATCH_TIME_NOW, 8 * NSEC_PER_MSEC, 1 * NSEC_PER_MSEC);
        __block uint8_t last_observed_capture = 0;
        __block BOOL last_observed_app_active = NO;
        dispatch_source_set_event_handler(g_main_tick_timer, ^{
            BOOL app_active = [NSApp isActive];
            if (g_shm && (g_shm->capture_active != last_observed_capture || app_active != last_observed_app_active)) {
                bool just_released = (last_observed_capture != 0) && (g_shm->capture_active == 0);
                last_observed_capture = g_shm->capture_active;
                last_observed_app_active = app_active;
                if (just_released) {
                    pthread_mutex_lock(&g_input_mutex);
                    g_mouse_left_down = false;
                    g_mouse_right_down = false;
                    g_mouse_middle_down = false;
                    g_mouse_btn4_down = false;
                    g_mouse_btn5_down = false;
                    g_accum_dx = 0.0f;
                    g_accum_dy = 0.0f;
                    g_smooth_rx = 0.0f;
                    g_smooth_ry = 0.0f;
                    pthread_mutex_unlock(&g_input_mutex);
                }
                update_hud_and_cursor_on_main_thread();
            }
            tick_ucr_engine();
        });
        dispatch_resume(g_main_tick_timer);
    });

    return NULL;
}

__attribute__((constructor))
static void chiaki_ucr_plugin_init(void) {
    fprintf(stderr, "[ChiakiUCR] Initializing Virtual DualSense & Mouse/KB Engine v2 for Chiaki-ng...\n");
    setup_shared_memory();
    pthread_t tid;
    pthread_create(&tid, NULL, ucr_bootstrap_thread, NULL);
    pthread_detach(tid);
}

