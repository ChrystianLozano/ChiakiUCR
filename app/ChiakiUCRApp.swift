import Cocoa
import SwiftUI
import Carbon

// MARK: - KeyCode Helpers

struct KeyMapEntry: Identifiable, Hashable {
    let code: UInt16
    let name: String
    var id: UInt16 { code }
}

let kAvailableKeys: [KeyMapEntry] = [
    KeyMapEntry(code: 0xFFFF, name: "Ninguna"),
    KeyMapEntry(code: UInt16(kVK_ANSI_W), name: "W"),
    KeyMapEntry(code: UInt16(kVK_ANSI_A), name: "A"),
    KeyMapEntry(code: UInt16(kVK_ANSI_S), name: "S"),
    KeyMapEntry(code: UInt16(kVK_ANSI_D), name: "D"),
    KeyMapEntry(code: UInt16(kVK_Space), name: "Espacio"),
    KeyMapEntry(code: UInt16(kVK_Shift), name: "Shift Izq"),
    KeyMapEntry(code: UInt16(kVK_Control), name: "Ctrl Izq"),
    KeyMapEntry(code: UInt16(kVK_Option), name: "Option / Alt"),
    KeyMapEntry(code: UInt16(kVK_Tab), name: "Tab"),
    KeyMapEntry(code: UInt16(kVK_CapsLock), name: "Caps Lock"),
    KeyMapEntry(code: UInt16(kVK_Return), name: "Enter"),
    KeyMapEntry(code: UInt16(kVK_Delete), name: "Backspace"),
    KeyMapEntry(code: UInt16(kVK_Escape), name: "Escape"),
    KeyMapEntry(code: UInt16(kVK_ANSI_Q), name: "Q"),
    KeyMapEntry(code: UInt16(kVK_ANSI_E), name: "E"),
    KeyMapEntry(code: UInt16(kVK_ANSI_R), name: "R"),
    KeyMapEntry(code: UInt16(kVK_ANSI_F), name: "F"),
    KeyMapEntry(code: UInt16(kVK_ANSI_C), name: "C"),
    KeyMapEntry(code: UInt16(kVK_ANSI_V), name: "V"),
    KeyMapEntry(code: UInt16(kVK_ANSI_G), name: "G"),
    KeyMapEntry(code: UInt16(kVK_ANSI_Z), name: "Z"),
    KeyMapEntry(code: UInt16(kVK_ANSI_X), name: "X"),
    KeyMapEntry(code: UInt16(kVK_ANSI_B), name: "B"),
    KeyMapEntry(code: UInt16(kVK_ANSI_N), name: "N"),
    KeyMapEntry(code: UInt16(kVK_ANSI_M), name: "M"),
    KeyMapEntry(code: UInt16(kVK_ANSI_P), name: "P"),
    KeyMapEntry(code: UInt16(kVK_ANSI_T), name: "T"),
    KeyMapEntry(code: UInt16(kVK_ANSI_Y), name: "Y"),
    KeyMapEntry(code: UInt16(kVK_ANSI_1), name: "1"),
    KeyMapEntry(code: UInt16(kVK_ANSI_2), name: "2"),
    KeyMapEntry(code: UInt16(kVK_ANSI_3), name: "3"),
    KeyMapEntry(code: UInt16(kVK_ANSI_4), name: "4"),
    KeyMapEntry(code: UInt16(kVK_ANSI_5), name: "5"),
    KeyMapEntry(code: UInt16(kVK_UpArrow), name: "Flecha Arriba"),
    KeyMapEntry(code: UInt16(kVK_DownArrow), name: "Flecha Abajo"),
    KeyMapEntry(code: UInt16(kVK_LeftArrow), name: "Flecha Izq"),
    KeyMapEntry(code: UInt16(kVK_RightArrow), name: "Flecha Der"),
    KeyMapEntry(code: UInt16(kVK_F1), name: "F1"),
    KeyMapEntry(code: UInt16(kVK_F2), name: "F2"),
    KeyMapEntry(code: UInt16(kVK_F5), name: "F5"),
    KeyMapEntry(code: UInt16(kVK_F6), name: "F6"),
    KeyMapEntry(code: UInt16(kVK_F8), name: "F8"),
    KeyMapEntry(code: UInt16(kVK_F10), name: "F10"),
    KeyMapEntry(code: UInt16(kVK_F12), name: "F12")
]

func keyName(for code: UInt16) -> String {
    return kAvailableKeys.first(where: { $0.code == code })?.name ?? "Key(\(code))"
}

// MARK: - ViewModel backed by Shared Memory

final class UCRViewModel: ObservableObject {
    private var shmPtr: UnsafeMutablePointer<ChiakiUCRSharedState>? = nil
    private var timer: Timer?
    private var lastAliveCounter: UInt32 = 0
    private var staleTicks: Int = 0

    @Published var isChiakiConnected: Bool = false
    @Published var chiakiPid: UInt32 = 0
    @Published var captureActive: Bool = false
    @Published var adsActive: Bool = false
    @Published var vehicleModeActive: Bool = false
    @Published var activeProfile: String = "Arc Raiders"

    // Live sticks & triggers
    @Published var leftStickX: Double = 0.0
    @Published var leftStickY: Double = 0.0
    @Published var rightStickX: Double = 0.0
    @Published var rightStickY: Double = 0.0
    @Published var l2Value: Double = 0.0
    @Published var r2Value: Double = 0.0
    @Published var activeButtons: [Bool] = Array(repeating: false, count: Int(UCR_BTN_COUNT.rawValue))

    // Tunable settings
    @Published var sensX: Double = 18.5 { didSet { syncToShm() } }
    @Published var sensY: Double = 18.5 { didSet { syncToShm() } }
    @Published var adsMultiplier: Double = 0.65 { didSet { syncToShm() } }
    @Published var deadzone: Double = 0.14 { didSet { syncToShm() } }
    @Published var antiDeadzone: Double = 0.88 { didSet { syncToShm() } }
    @Published var exponent: Double = 0.82 { didSet { syncToShm() } }
    @Published var smoothing: Double = 0.12 { didSet { syncToShm() } }
    @Published var decayMs: Double = 24.0 { didSet { syncToShm() } }
    @Published var invertY: Bool = false { didSet { syncToShm() } }
    @Published var walkScalePct: Double = 45.0 { didSet { syncToShm() } }
    @Published var gtaWSAsTriggers: Bool = true { didSet { syncToShm() } }

    // Key Bindings
    @Published var btnCrossKey: UInt16 = UInt16(kVK_Space) { didSet { syncToShm() } }
    @Published var btnCircleKey: UInt16 = UInt16(kVK_ANSI_C) { didSet { syncToShm() } }
    @Published var btnSquareKey: UInt16 = UInt16(kVK_ANSI_R) { didSet { syncToShm() } }
    @Published var btnSquareAltKey: UInt16 = UInt16(kVK_ANSI_F) { didSet { syncToShm() } }
    @Published var btnTriangleKey: UInt16 = UInt16(kVK_ANSI_E) { didSet { syncToShm() } }
    @Published var btnL1Key: UInt16 = UInt16(kVK_ANSI_Q) { didSet { syncToShm() } }
    @Published var btnR1Key: UInt16 = UInt16(kVK_ANSI_G) { didSet { syncToShm() } }
    @Published var btnL3Key: UInt16 = UInt16(kVK_Shift) { didSet { syncToShm() } }
    @Published var btnR3Key: UInt16 = UInt16(kVK_ANSI_V) { didSet { syncToShm() } }
    @Published var btnTouchpadKey: UInt16 = UInt16(kVK_Tab) { didSet { syncToShm() } }
    @Published var btnOptionsKey: UInt16 = UInt16(kVK_ANSI_P) { didSet { syncToShm() } }
    @Published var btnPSKey: UInt16 = UInt16(kVK_F10) { didSet { syncToShm() } }
    @Published var btnL2Key: UInt16 = 0xFFFF { didSet { syncToShm() } }
    @Published var btnR2Key: UInt16 = 0xFFFF { didSet { syncToShm() } }

    private var isLoadingFromShm: Bool = false

    init() {
        openSharedMemory()
        loadFromShm()
        syncToShm()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.pollTelemetry()
        }
    }

    private func openSharedMemory() {
        let fd = open(CHIAKI_UCR_SHM_PATH, O_CREAT | O_RDWR, 0o666)
        guard fd >= 0 else { return }
        fchmod(fd, 0o666)
        ftruncate(fd, off_t(MemoryLayout<ChiakiUCRSharedState>.stride))
        let raw = mmap(nil, MemoryLayout<ChiakiUCRSharedState>.stride, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        close(fd)
        guard raw != MAP_FAILED, let ptr = raw else { return }
        shmPtr = ptr.assumingMemoryBound(to: ChiakiUCRSharedState.self)

        if let s = shmPtr, (s.pointee.magic != UInt32(CHIAKI_UCR_MAGIC) || s.pointee.version != UInt32(CHIAKI_UCR_VERSION)) {
            memset(s, 0, MemoryLayout<ChiakiUCRSharedState>.stride)
            s.pointee.magic = UInt32(CHIAKI_UCR_MAGIC)
            s.pointee.version = UInt32(CHIAKI_UCR_VERSION)
            applyPresetArcRaiders()
        }
    }

    private func loadFromShm() {
        guard let s = shmPtr else { return }
        isLoadingFromShm = true
        defer { isLoadingFromShm = false }

        sensX = Double(s.pointee.sens_x > 0.5 ? s.pointee.sens_x : 18.5)
        sensY = Double(s.pointee.sens_y > 0.5 ? s.pointee.sens_y : 18.5)
        adsMultiplier = Double(s.pointee.ads_multiplier > 0.05 ? s.pointee.ads_multiplier : 0.65)
        deadzone = Double(s.pointee.deadzone)
        antiDeadzone = Double(s.pointee.anti_deadzone > 0.01 ? s.pointee.anti_deadzone : 0.88)
        exponent = Double(s.pointee.exponent > 0.2 ? s.pointee.exponent : 0.82)
        smoothing = Double(s.pointee.smoothing)
        decayMs = Double(s.pointee.decay_ms > 4.0 ? s.pointee.decay_ms : 24.0)
        invertY = (s.pointee.invert_y != 0)
        walkScalePct = Double(s.pointee.left_stick_walk_pct > 10 ? s.pointee.left_stick_walk_pct : 45)
        gtaWSAsTriggers = (s.pointee.gta_W_S_triggers_in_vehicle != 0)
    }

    func syncToShm() {
        guard !isLoadingFromShm, let s = shmPtr else { return }
        s.pointee.sens_x = Float(sensX)
        s.pointee.sens_y = Float(sensY)
        s.pointee.ads_multiplier = Float(adsMultiplier)
        s.pointee.deadzone = Float(deadzone)
        s.pointee.anti_deadzone = Float(antiDeadzone)
        s.pointee.exponent = Float(exponent)
        s.pointee.smoothing = Float(smoothing)
        s.pointee.decay_ms = Float(decayMs)
        s.pointee.invert_y = invertY ? 1 : 0
        s.pointee.left_stick_walk_pct = UInt8(walkScalePct)
        s.pointee.gta_W_S_triggers_in_vehicle = gtaWSAsTriggers ? 1 : 0
        s.pointee.toggle_key_code = UInt16(kVK_F8)
        s.pointee.key_vehicle_toggle = UInt16(kVK_F6)

        s.pointee.key_move_up = UInt16(kVK_ANSI_W)
        s.pointee.key_move_down = UInt16(kVK_ANSI_S)
        s.pointee.key_move_left = UInt16(kVK_ANSI_A)
        s.pointee.key_move_right = UInt16(kVK_ANSI_D)
        s.pointee.key_walk_mod = UInt16(kVK_Control)
        s.pointee.key_l2 = btnL2Key
        s.pointee.key_r2 = btnR2Key

        withUnsafeMutablePointer(to: &s.pointee.button_key_primary) { ptr in
            let buf = UnsafeMutableBufferPointer(
                start: UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: UInt16.self),
                count: Int(UCR_BTN_COUNT.rawValue)
            )
            for i in 0..<Int(UCR_BTN_COUNT.rawValue) {
                buf[i] = 0xFFFF
            }
            buf[Int(UCR_BTN_CROSS.rawValue)] = btnCrossKey
            buf[Int(UCR_BTN_CIRCLE.rawValue)] = btnCircleKey
            buf[Int(UCR_BTN_SQUARE.rawValue)] = btnSquareKey
            buf[Int(UCR_BTN_TRIANGLE.rawValue)] = btnTriangleKey
            buf[Int(UCR_BTN_L1.rawValue)] = btnL1Key
            buf[Int(UCR_BTN_R1.rawValue)] = btnR1Key
            buf[Int(UCR_BTN_L3.rawValue)] = btnL3Key
            buf[Int(UCR_BTN_R3.rawValue)] = btnR3Key
            buf[Int(UCR_BTN_TOUCHPAD.rawValue)] = btnTouchpadKey
            buf[Int(UCR_BTN_OPTIONS.rawValue)] = btnOptionsKey
            buf[Int(UCR_BTN_PS.rawValue)] = btnPSKey
            buf[Int(UCR_BTN_SHARE.rawValue)] = UInt16(kVK_F12)
            buf[Int(UCR_BTN_DPAD_UP.rawValue)] = UInt16(kVK_ANSI_1)
            buf[Int(UCR_BTN_DPAD_RIGHT.rawValue)] = UInt16(kVK_ANSI_2)
            buf[Int(UCR_BTN_DPAD_DOWN.rawValue)] = UInt16(kVK_ANSI_3)
            buf[Int(UCR_BTN_DPAD_LEFT.rawValue)] = UInt16(kVK_ANSI_4)
        }

        withUnsafeMutablePointer(to: &s.pointee.button_key_secondary) { ptr in
            let buf = UnsafeMutableBufferPointer(
                start: UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: UInt16.self),
                count: Int(UCR_BTN_COUNT.rawValue)
            )
            for i in 0..<Int(UCR_BTN_COUNT.rawValue) {
                buf[i] = 0xFFFF
            }
            buf[Int(UCR_BTN_SQUARE.rawValue)] = btnSquareAltKey
            buf[Int(UCR_BTN_TOUCHPAD.rawValue)] = UInt16(kVK_ANSI_M)
            buf[Int(UCR_BTN_OPTIONS.rawValue)] = UInt16(kVK_Return)
            buf[Int(UCR_BTN_DPAD_UP.rawValue)] = UInt16(kVK_UpArrow)
            buf[Int(UCR_BTN_DPAD_RIGHT.rawValue)] = UInt16(kVK_RightArrow)
            buf[Int(UCR_BTN_DPAD_DOWN.rawValue)] = UInt16(kVK_DownArrow)
            buf[Int(UCR_BTN_DPAD_LEFT.rawValue)] = UInt16(kVK_LeftArrow)
        }

        s.pointee.config_seq &+= 1
    }

    private func pollTelemetry() {
        guard let s = shmPtr else { return }
        let counter = s.pointee.plugin_alive_counter
        if counter != lastAliveCounter {
            lastAliveCounter = counter
            staleTicks = 0
            isChiakiConnected = true
        } else {
            staleTicks += 1
            if staleTicks > 15 {
                isChiakiConnected = false
            }
        }

        chiakiPid = s.pointee.chiaki_pid
        captureActive = (s.pointee.capture_active != 0)
        adsActive = (s.pointee.ads_active != 0)
        vehicleModeActive = (s.pointee.vehicle_mod_active != 0)

        leftStickX = Double(s.pointee.norm_stick_lx)
        leftStickY = Double(s.pointee.norm_stick_ly)
        rightStickX = Double(s.pointee.norm_stick_rx)
        rightStickY = Double(s.pointee.norm_stick_ry)

        withUnsafePointer(to: &s.pointee.axes) { ptr in
            let axesBuf = UnsafeBufferPointer(
                start: UnsafeRawPointer(ptr).assumingMemoryBound(to: Int16.self),
                count: Int(UCR_AXIS_COUNT.rawValue)
            )
            l2Value = Double(axesBuf[Int(UCR_AXIS_TRIGGERLEFT.rawValue)]) / 32767.0
            r2Value = Double(axesBuf[Int(UCR_AXIS_TRIGGERRIGHT.rawValue)]) / 32767.0
        }

        withUnsafePointer(to: &s.pointee.buttons) { ptr in
            let btnBuf = UnsafeBufferPointer(
                start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self),
                count: Int(UCR_BTN_COUNT.rawValue)
            )
            for i in 0..<Int(UCR_BTN_COUNT.rawValue) {
                activeButtons[i] = (btnBuf[i] != 0)
            }
        }
    }

    func toggleCapture() {
        guard let s = shmPtr else { return }
        s.pointee.capture_active = (s.pointee.capture_active == 0) ? 1 : 0
    }

    func toggleVehicleMode() {
        guard let s = shmPtr else { return }
        s.pointee.vehicle_mod_active = (s.pointee.vehicle_mod_active == 0) ? 1 : 0
    }

    // MARK: - Game Presets

    func applyPresetArcRaiders() {
        activeProfile = "Arc Raiders (Shooter 3ra Persona)"
        sensX = 19.5
        sensY = 18.0
        adsMultiplier = 0.62
        deadzone = 0.14
        antiDeadzone = 0.90
        exponent = 0.80
        smoothing = 0.10
        decayMs = 22.0
        invertY = false
        walkScalePct = 45.0
        gtaWSAsTriggers = false

        btnCrossKey = UInt16(kVK_Space)     // Jump / Vault
        btnCircleKey = UInt16(kVK_ANSI_C)   // Dodge Roll / Crouch
        btnSquareKey = UInt16(kVK_ANSI_R)   // Reload
        btnSquareAltKey = UInt16(kVK_ANSI_F)// Interact / Loot
        btnTriangleKey = UInt16(kVK_ANSI_E) // Swap Weapon
        btnL1Key = UInt16(kVK_ANSI_Q)       // Ping / Gadget 1
        btnR1Key = UInt16(kVK_ANSI_G)       // Grenade / Gadget 2
        btnL3Key = UInt16(kVK_Shift)        // Sprint
        btnR3Key = UInt16(kVK_ANSI_V)       // Melee / Shoulder Swap
        btnTouchpadKey = UInt16(kVK_Tab)    // Map / Inventory
        if let s = shmPtr {
            s.pointee.vehicle_mod_active = 0
        }
        syncToShm()
    }

    func applyPresetGTAOnFoot() {
        activeProfile = "GTA V / Online (A Pie + Híbrido)"
        sensX = 21.0
        sensY = 19.0
        adsMultiplier = 0.68
        deadzone = 0.16
        antiDeadzone = 0.92
        exponent = 0.78
        smoothing = 0.14
        decayMs = 25.0
        invertY = false
        walkScalePct = 45.0
        gtaWSAsTriggers = true

        btnCrossKey = UInt16(kVK_Shift)     // In GTA, X/Cross is Run/Sprint!
        btnCircleKey = UInt16(kVK_ANSI_R)   // Reload / Melee in GTA
        btnSquareKey = UInt16(kVK_Space)    // Jump / Climb in GTA!
        btnSquareAltKey = UInt16(kVK_ANSI_C)
        btnTriangleKey = UInt16(kVK_ANSI_F) // Enter / Exit Vehicle (F like PC GTA!)
        btnL1Key = UInt16(kVK_Tab)          // Weapon Wheel (Tab like PC GTA!)
        btnR1Key = UInt16(kVK_ANSI_Q)       // Take Cover (Q like PC GTA!)
        btnL3Key = UInt16(kVK_Control)      // Stealth / Horn
        btnR3Key = UInt16(kVK_ANSI_V)       // Look Behind
        btnTouchpadKey = UInt16(kVK_ANSI_M) // Interaction Menu (M like PC GTA!)
        if let s = shmPtr {
            s.pointee.vehicle_mod_active = 0
        }
        syncToShm()
    }

    func applyPresetGTADriving() {
        applyPresetGTAOnFoot()
        activeProfile = "GTA V / Online (Modo Conducción)"
        if let s = shmPtr {
            s.pointee.vehicle_mod_active = 1
        }
    }

    func launchChiakiWithUCR() {
        // Find dylib relative to app bundle, Frameworks, or adjacent plugin folder
        let bundleDylib = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libchiaki_ucr.dylib").path
        let siblingDylib = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("plugin/libchiaki_ucr.dylib").path
        let fallbackDylib = "/Users/chrystian/Documents/REA/ChiakiUCR/plugin/libchiaki_ucr.dylib"

        let dylibPath: String
        if FileManager.default.fileExists(atPath: bundleDylib) {
            dylibPath = bundleDylib
        } else if FileManager.default.fileExists(atPath: siblingDylib) {
            dylibPath = siblingDylib
        } else {
            dylibPath = fallbackDylib
        }

        // Terminate any existing chiaki instance (e.g. a sandboxed or non-UCR instance)
        let killTask = Process()
        killTask.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killTask.arguments = ["chiaki"]
        try? killTask.run()
        killTask.waitUntilExit()

        // Launch via macOS LaunchServices (open -n -a) so chiaki-ng.app runs under its own
        // bundle identity (org.streetpea.chiaking) with full Local Network access to PS5
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [
            "-n",
            "-a", "/Applications/chiaki-ng.app",
            "--env", "DYLD_INSERT_LIBRARIES=\(dylibPath)",
            "--env", "SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1"
        ]
        try? task.run()
    }
}

// MARK: - Stick Visualizer Widget

struct StickVisualizer: View {
    let title: String
    let x: Double
    let y: Double
    let deadzone: Double

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .frame(width: 120, height: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray.opacity(0.35), lineWidth: 1)
                    )

                // Outer unit circle
                Circle()
                    .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                    .frame(width: 100, height: 100)

                // Deadzone circle
                if deadzone > 0.01 {
                    Circle()
                        .fill(Color.orange.opacity(0.12))
                        .overlay(Circle().stroke(Color.orange.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3])))
                        .frame(width: CGFloat(deadzone * 100.0), height: CGFloat(deadzone * 100.0))
                }

                // Crosshairs
                Path { path in
                    path.move(to: CGPoint(x: 60, y: 10))
                    path.addLine(to: CGPoint(x: 60, y: 110))
                    path.move(to: CGPoint(x: 10, y: 60))
                    path.addLine(to: CGPoint(x: 110, y: 60))
                }
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)

                // Stick position dot
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 14, height: 14)
                    .shadow(radius: 2)
                    .offset(x: CGFloat(x * 50.0), y: CGFloat(y * 50.0))
            }
            .frame(width: 120, height: 120)

            Text(String(format: "X: %+.2f  Y: %+.2f", x, y))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Main Window View

struct ContentView: View {
    @ObservedObject var vm: UCRViewModel

    var body: some View {
        VStack(spacing: 14) {
            // Top Status Header
            HStack(spacing: 14) {
                if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "png"),
                   let nsImg = NSImage(contentsOfFile: iconPath) {
                    Image(nsImage: nsImg)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                        .shadow(radius: 2)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(vm.isChiakiConnected ? Color.green : Color.orange)
                            .frame(width: 10, height: 10)
                        Text(vm.isChiakiConnected
                             ? "Conectado a chiaki-ng (PID \(vm.chiakiPid)) — DualSense Virtual Activo"
                             : "chiaki-ng no está abierto con el plugin UCR")
                            .font(.system(size: 13, weight: .bold))
                    }
                    Text("Atajo en juego: Pulsa F8 (u Option+M) para bloquear/liberar el Ratón • F6 alterna Modo Conducción GTA")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if !vm.isChiakiConnected {
                    Button(action: { vm.launchChiakiWithUCR() }) {
                        Label("Abrir chiaki-ng con UCR", systemImage: "gamecontroller.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                } else {
                    Button(action: { vm.toggleCapture() }) {
                        Text(vm.captureActive ? "🔓 Liberar Ratón (F8)" : "🎯 Capturar Ratón (F8)")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(vm.captureActive ? .green : .blue)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.25), lineWidth: 1))

            // Game Profiles Row
            HStack(spacing: 10) {
                Text("Perfiles Rápidos:")
                    .font(.system(size: 12, weight: .semibold))

                Button("🎯 Arc Raiders (Shooter Estándar)") {
                    vm.applyPresetArcRaiders()
                }
                .buttonStyle(.bordered)

                Button("🔫 GTA V / Online (Estilo PC: F=Auto, Tab=Armas, Shift=Correr)") {
                    vm.applyPresetGTAOnFoot()
                }
                .buttonStyle(.bordered)

                Button(vm.vehicleModeActive ? "🚗 Modo Vehículo GTA: ACTIVO (F6)" : "🚗 Activar Modo Vehículo (F6)") {
                    vm.toggleVehicleMode()
                }
                .buttonStyle(.borderedProminent)
                .tint(vm.vehicleModeActive ? .orange : .gray)

                Spacer()
                Text("Perfil: \(vm.activeProfile)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }

            Divider()

            // Main Split Content: Left = Visualizers + Mouse Curve, Right = Key Bindings
            HStack(alignment: .top, spacing: 18) {
                // Left Column: Live DualSense Telemetry & Mouse Aiming Engine
                VStack(alignment: .leading, spacing: 14) {
                    Text("Telemetría DualSense Virtual (125 Hz)")
                        .font(.system(size: 13, weight: .bold))

                    HStack(spacing: 16) {
                        StickVisualizer(title: "Stick Izq (WASD)", x: vm.leftStickX, y: vm.leftStickY, deadzone: 0.0)
                        StickVisualizer(title: "Stick Der (Ratón)", x: vm.rightStickX, y: vm.rightStickY, deadzone: vm.deadzone)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Gatillos")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("L2 (Click Der / Apuntar)")
                                    .font(.system(size: 10))
                                ProgressView(value: vm.l2Value)
                                    .frame(width: 110)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("R2 (Click Izq / Disparar)")
                                    .font(.system(size: 10))
                                ProgressView(value: vm.r2Value)
                                    .frame(width: 110)
                            }
                            Spacer()
                            Text(vm.adsActive ? "🔍 ADS Activo" : "Mirilla libre")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(vm.adsActive ? .orange : .secondary)
                        }
                        .frame(height: 130)
                    }

                    Divider()

                    Text("Motor Ratón → Stick Derecho (Anti-Deadzone PS5)")
                        .font(.system(size: 13, weight: .bold))

                    VStack(spacing: 8) {
                        SliderRow(label: "Sensibilidad X", value: $vm.sensX, range: 2.0...60.0, format: "%.1f")
                        SliderRow(label: "Sensibilidad Y", value: $vm.sensY, range: 2.0...60.0, format: "%.1f")
                        SliderRow(label: "Mult. Apuntado (ADS Click Der)", value: $vm.adsMultiplier, range: 0.20...1.20, format: "%.2fx")
                        SliderRow(label: "Zona Muerta Juego (Deadzone)", value: $vm.deadzone, range: 0.00...0.35, format: "%.2f")
                        SliderRow(label: "Compensación Anti-Deadzone", value: $vm.antiDeadzone, range: 0.00...1.00, format: "%.0f%%", mult: 100)
                        SliderRow(label: "Curva Exponencial (1.0=Lineal)", value: $vm.exponent, range: 0.45...1.50, format: "%.2f")
                        SliderRow(label: "Suavizado (Smoothing)", value: $vm.smoothing, range: 0.00...0.60, format: "%.2f")

                        HStack {
                            Toggle("Invertir Eje Y", isOn: $vm.invertY)
                                .font(.system(size: 12))
                            Spacer()
                            Toggle("En modo Vehículo (F6): W=R2 (Acelerar) / S=L2 (Frenar)", isOn: $vm.gtaWSAsTriggers)
                                .font(.system(size: 12))
                        }
                    }
                }
                .frame(width: 410)

                Divider()

                // Right Column: Key Mapping Table
                VStack(alignment: .leading, spacing: 10) {
                    Text("Mapeo de Teclado y Ratón → DualSense")
                        .font(.system(size: 13, weight: .bold))

                    ScrollView {
                        VStack(spacing: 7) {
                            KeyBindingRow(label: "🎯 L2 Apuntar (Click Der + Tecla)", keySelection: $vm.btnL2Key, active: vm.l2Value > 0.5)
                            KeyBindingRow(label: "🔥 R2 Disparar (Click Izq + Tecla)", keySelection: $vm.btnR2Key, active: vm.r2Value > 0.5)
                            KeyBindingRow(label: "✖️ Cruz (Saltar / Correr GTA)", keySelection: $vm.btnCrossKey, active: vm.activeButtons[Int(UCR_BTN_CROSS.rawValue)])
                            KeyBindingRow(label: "⭕ Círculo (Agacharse / Rodar)", keySelection: $vm.btnCircleKey, active: vm.activeButtons[Int(UCR_BTN_CIRCLE.rawValue)])
                            KeyBindingRow(label: "🟥 Cuadrado (Recargar / Saltar GTA)", keySelection: $vm.btnSquareKey, active: vm.activeButtons[Int(UCR_BTN_SQUARE.rawValue)])
                            KeyBindingRow(label: "🟥 Cuadrado (Tecla Alternativa)", keySelection: $vm.btnSquareAltKey, active: vm.activeButtons[Int(UCR_BTN_SQUARE.rawValue)])
                            KeyBindingRow(label: "🔺 Triángulo (Cambiar Arma / Subir Auto)", keySelection: $vm.btnTriangleKey, active: vm.activeButtons[Int(UCR_BTN_TRIANGLE.rawValue)])
                            KeyBindingRow(label: "L1 (Habilidad / Rueda Armas GTA)", keySelection: $vm.btnL1Key, active: vm.activeButtons[Int(UCR_BTN_L1.rawValue)])
                            KeyBindingRow(label: "R1 (Granada / Cubrirse GTA)", keySelection: $vm.btnR1Key, active: vm.activeButtons[Int(UCR_BTN_R1.rawValue)])
                            KeyBindingRow(label: "L3 (Sprint / Claxon)", keySelection: $vm.btnL3Key, active: vm.activeButtons[Int(UCR_BTN_L3.rawValue)])
                            KeyBindingRow(label: "R3 ( Cuerpo a cuerpo / Mirar atrás)", keySelection: $vm.btnR3Key, active: vm.activeButtons[Int(UCR_BTN_R3.rawValue)])
                            KeyBindingRow(label: "Touchpad Click (Mapa / Menú)", keySelection: $vm.btnTouchpadKey, active: vm.activeButtons[Int(UCR_BTN_TOUCHPAD.rawValue)])
                            KeyBindingRow(label: "Options (Pausa)", keySelection: $vm.btnOptionsKey, active: vm.activeButtons[Int(UCR_BTN_OPTIONS.rawValue)])
                            KeyBindingRow(label: "Botón PS (Home)", keySelection: $vm.btnPSKey, active: vm.activeButtons[Int(UCR_BTN_PS.rawValue)])
                        }
                        .padding(.trailing, 6)
                    }

                    Divider()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Atajos Fijos Incluidos:")
                            .font(.system(size: 11, weight: .bold))
                        Text("• WASD = Stick Izquierdo (Ctrl Izq = Caminar lento)")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                        Text("• Click Izq = R2  |  Click Der = L2  |  Click Central = R3")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                        Text("• Rueda Arriba = Triángulo  |  1, 2, 3, 4 y Flechas = D-Pad")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 560)
    }
}

struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var mult: Double = 1.0

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 195, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: format, value * mult))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 48, alignment: .trailing)
        }
    }
}

struct KeyBindingRow: View {
    let label: String
    @Binding var keySelection: UInt16
    let active: Bool

    var body: some View {
        HStack {
            Circle()
                .fill(active ? Color.green : Color.gray.opacity(0.25))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12))
            Spacer()
            Picker("", selection: $keySelection) {
                ForEach(kAvailableKeys) { item in
                    Text(item.name).tag(item.code)
                }
            }
            .frame(width: 130)
        }
    }
}

// MARK: - App Entry

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let vm = UCRViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = icon
        }
        // Apply custom Finder icon to the launcher script
        if let pngPath = Bundle.main.path(forResource: "AppIcon", ofType: "png"),
           let iconImg = NSImage(contentsOfFile: pngPath) {
            let cmdPath = "/Users/chrystian/Documents/REA/ChiakiUCR/start-chiaki-ucr.command"
            NSWorkspace.shared.setIcon(iconImg, forFile: cmdPath, options: [])
        }

        let contentView = ContentView(vm: vm)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Chiaki-UCR para macOS — DualSense Virtual (Ratón y Teclado)"
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

@main
struct ChiakiUCRApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
