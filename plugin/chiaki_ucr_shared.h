#ifndef CHIAKI_UCR_SHARED_H
#define CHIAKI_UCR_SHARED_H

#include <stdint.h>
#include <stdbool.h>

#define CHIAKI_UCR_MAGIC 0x5543524D // "UCRM"
#define CHIAKI_UCR_VERSION 2
#define UCR_KEY_NONE 0xFFFF
#define CHIAKI_UCR_SHM_PATH "/tmp/chiaki_ucr_state.shm"
#define CHIAKI_UCR_CONFIG_PATH "/tmp/chiaki_ucr_config.json"

// SDL_GameControllerButton indices (standard SDL2 order used by Chiaki-ng)
enum UCR_SDL_Button {
    UCR_BTN_CROSS = 0,       // SDL_CONTROLLER_BUTTON_A (Cross / X)
    UCR_BTN_CIRCLE = 1,      // SDL_CONTROLLER_BUTTON_B (Circle / O)
    UCR_BTN_SQUARE = 2,      // SDL_CONTROLLER_BUTTON_X (Square)
    UCR_BTN_TRIANGLE = 3,    // SDL_CONTROLLER_BUTTON_Y (Triangle)
    UCR_BTN_SHARE = 4,       // SDL_CONTROLLER_BUTTON_BACK (Create / Share)
    UCR_BTN_PS = 5,          // SDL_CONTROLLER_BUTTON_GUIDE (PS Button)
    UCR_BTN_OPTIONS = 6,     // SDL_CONTROLLER_BUTTON_START (Options)
    UCR_BTN_L3 = 7,          // SDL_CONTROLLER_BUTTON_LEFTSTICK
    UCR_BTN_R3 = 8,          // SDL_CONTROLLER_BUTTON_RIGHTSTICK
    UCR_BTN_L1 = 9,          // SDL_CONTROLLER_BUTTON_LEFTSHOULDER
    UCR_BTN_R1 = 10,         // SDL_CONTROLLER_BUTTON_RIGHTSHOULDER
    UCR_BTN_DPAD_UP = 11,    // SDL_CONTROLLER_BUTTON_DPAD_UP
    UCR_BTN_DPAD_DOWN = 12,  // SDL_CONTROLLER_BUTTON_DPAD_DOWN
    UCR_BTN_DPAD_LEFT = 13,  // SDL_CONTROLLER_BUTTON_DPAD_LEFT
    UCR_BTN_DPAD_RIGHT = 14, // SDL_CONTROLLER_BUTTON_DPAD_RIGHT
    UCR_BTN_MISC1 = 15,      // Mute / Mic button on DualSense
    UCR_BTN_PADDLE1 = 16,
    UCR_BTN_PADDLE2 = 17,
    UCR_BTN_PADDLE3 = 18,
    UCR_BTN_PADDLE4 = 19,
    UCR_BTN_TOUCHPAD = 20,   // SDL_CONTROLLER_BUTTON_TOUCHPAD
    UCR_BTN_COUNT = 21
};

// SDL_GameControllerAxis indices
enum UCR_SDL_Axis {
    UCR_AXIS_LEFTX = 0,
    UCR_AXIS_LEFTY = 1,
    UCR_AXIS_RIGHTX = 2,
    UCR_AXIS_RIGHTY = 3,
    UCR_AXIS_TRIGGERLEFT = 4,  // L2 (0 .. 32767)
    UCR_AXIS_TRIGGERRIGHT = 5, // R2 (0 .. 32767)
    UCR_AXIS_COUNT = 6
};

typedef struct __attribute__((packed, aligned(8))) {
    uint32_t magic;
    uint32_t version;

    // Runtime status (updated by plugin & UI)
    uint32_t plugin_alive_counter;
    uint32_t chiaki_pid;
    uint8_t  capture_active;     // 1 = Mouse/Keyboard locked & translated to DualSense
    uint8_t  ads_active;         // 1 = Right-click / L2 aiming active
    uint8_t  walk_mod_active;    // 1 = Walk slow modifier active
    uint8_t  vehicle_mod_active; // 1 = GTA Driving mode toggle/hold active

    // Live translated DualSense state (written by plugin/engine, read by UI & SDL virtual joystick)
    int16_t  axes[UCR_AXIS_COUNT];
    uint8_t  buttons[UCR_BTN_COUNT];
    uint8_t  reserved_pad[3];

    // Live mouse telemetry for UI visualizer
    float    raw_mouse_dx;
    float    raw_mouse_dy;
    float    norm_stick_rx;
    float    norm_stick_ry;
    float    norm_stick_lx;
    float    norm_stick_ly;

    // Haptic feedback from Chiaki PS5/PS4 back to UI
    uint16_t rumble_left;
    uint16_t rumble_right;
    uint8_t  led_r;
    uint8_t  led_g;
    uint8_t  led_b;
    uint8_t  pad2;

    // Tunable UCR Configuration (written by UI or loaded by plugin)
    uint32_t config_seq;         // Incremented when UI changes settings
    char     active_profile[64]; // e.g. "Arc Raiders", "GTA V / Online"

    // Mouse -> Right Stick Aiming parameters
    float    sens_x;             // Base X sensitivity (default: 18.0)
    float    sens_y;             // Base Y sensitivity (default: 18.0)
    float    ads_multiplier;     // Multiplier when holding L2/Right-Click (default: 0.65)
    float    deadzone;           // Inner radial deadzone compensation (0.00 .. 0.45, default: 0.14)
    float    anti_deadzone;      // Fraction of deadzone to jump immediately on mouse move (default: 0.85)
    float    exponent;           // Response curve exponent (1.0 = linear, 0.75 = counter game accel, 1.25 = precision)
    float    smoothing;          // EMA smoothing factor (0.0 = raw instant, 0.3 = smooth, default: 0.12)
    float    decay_ms;           // Mouse stop decay timeout in ms (default: 22.0)
    uint8_t  invert_y;           // 1 = Invert vertical look
    uint8_t  left_stick_walk_pct;// Percentage of Left Stick when holding Walk key (default: 45%)
    uint16_t toggle_key_code;    // CGKeyCode to toggle mouse lock (default: 100 = F8, plus Option+M)

    // Customizable Key-to-Button bindings (CGKeyCode, 0xFFFF = unbound)
    // Allows up to 2 keys per controller action
    uint16_t key_move_up;        // Default: W (13)
    uint16_t key_move_down;      // Default: S (1)
    uint16_t key_move_left;      // Default: A (0)
    uint16_t key_move_right;     // Default: D (2)
    uint16_t key_walk_mod;       // Default: Left Control (59) or CapsLock

    uint16_t button_key_primary[UCR_BTN_COUNT];
    uint16_t button_key_secondary[UCR_BTN_COUNT];
    uint16_t key_l2;             // Optional keyboard trigger for L2 (in addition to Right Mouse)
    uint16_t key_r2;             // Optional keyboard trigger for R2 (in addition to Left Mouse)

    // GTA Vehicle Assist mode: steers Left Stick X with Mouse X or smooth A/D, and W/S -> R2/L2 gas/brake
    uint8_t  gta_W_S_triggers_in_vehicle; // When vehicle_mod_active is ON, W=R2 (gas), S=L2 (brake)
    uint8_t  pad3;
    uint16_t key_vehicle_toggle;          // Default: V (9) or F6 (97) to toggle On-Foot vs Driving mode
    uint32_t pad4;
} ChiakiUCRSharedState;

#endif // CHIAKI_UCR_SHARED_H
