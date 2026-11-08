import Foundation

/// Which of RPCS3's settings and choices make sense on iOS, and how some are better edited on a
/// phone. Every entry says why; each was checked against RPCS3's and MoltenVK's sources.
enum SettingsPolicy {
    /// Settings that cannot do anything on iOS.
    static let hidden: [[String]: String] = [
        // GPU
        ["Video", "Renderer"]: "Vulkan (MoltenVK) is the only renderer; there is no OpenGL on iOS.",
        ["Video", "Vulkan", "Adapter"]: "There is one GPU.",
        ["Video", "Vulkan", "Exclusive Fullscreen Mode"]: "A Windows feature.",
        ["Video", "Vulkan", "Use Re-BAR for GPU uploads"]: "Apple GPUs share memory with the CPU; there is no separate VRAM to map.",
        ["Video", "VSync Mode"]: "iOS always presents in step with the display (MoltenVK can turn display sync off only on macOS).",
        ["Video", "MSAA"]: "RPCS3 needs multisampled storage images for MSAA, which Apple GPUs lack; it turns MSAA off.",
        ["Video", "Force Hardware MSAA Resolve"]: "MSAA is unavailable (see MSAA).",
        ["Video", "Debug output"]: "Needs the Vulkan validation layers, which are not part of the app.",
        ["Video", "Renderdoc Compatibility Mode"]: "RenderDoc does not exist on iOS.",
        ["Video", "Vulkan", "Asynchronous Texture Streaming"]: "Needs passthrough DMA (guest memory imported into Vulkan), which MoltenVK does not support; the renderer would stop. The core keeps it off.",
        ["Video", "Allow Host GPU Labels"]: "Needs passthrough DMA (guest memory imported into Vulkan), which MoltenVK does not support; the renderer would stop. The core keeps it off.",
        ["Video", "Native UI", "Default Font"]: "A font file of the computer's system fonts.",
        ["Video", "Performance Overlay", "Font"]: "A font file name; the bundled one is the only one available.",

        // CPU
        ["Core", "Thread Scheduler Mode"]: "Both RPCS3 schedulers place threads on cores with affinity masks for AMD and Intel CPUs; Apple chips ignore thread affinity.",
        ["Core", "Use LLVM CPU"]: "LLVM targets the iPhone's own CPU; another name produces code that cannot run.",

        // Audio
        ["Audio", "Audio Device"]: "iOS routes audio itself (speaker, headphones, AirPlay from Control Center).",
        ["Audio", "Audio Formats"]: "Only used by the Manual audio format, which needs desktop's format checkboxes.",
        ["Audio", "Microphone Type"]: "Microphones are not supported yet (the core keeps it off).",
        ["Audio", "Microphone Devices"]: "Microphones are not supported yet.",
        ["Audio", "Music Handler"]: "RPCS3's in-game music player needs Qt Multimedia.",

        // Input
        ["Input/Output", "Keyboard"]: "RPCS3's keyboard handler is part of its Qt frontend.",
        ["Input/Output", "Mouse"]: "RPCS3's mouse handlers are part of its Qt frontend.",
        ["Input/Output", "Mouse-based gyro enabled"]: "Needs a mouse.",
        ["Input/Output", "Mouse Debug overlay"]: "No mouse handler.",
        ["Input/Output", "Camera flip"]: "Only the fake camera is available, which has no picture.",
        ["Input/Output", "Camera ID"]: "Only the fake camera is available.",
        ["Input/Output", "SDL Camera ID"]: "Only the fake camera is available.",
        ["Input/Output", "Emulated Midi devices"]: "Needs MIDI instruments connected to a computer.",
        ["Input/Output", "Background input enabled"]: "iOS apps get no input in the background, and games pause there.",

        // Emulator (desktop window and game list)
        ["Miscellaneous", "Exit RPCS3 when process finishes"]: "iOS apps do not quit themselves.",
        ["Miscellaneous", "Pause emulation on RPCS3 focus loss"]: "Games always pause when the app leaves the screen.",
        ["Miscellaneous", "Start games in fullscreen mode"]: "Games always fill the screen.",
        ["Miscellaneous", "Start Big Picture Mode on boot"]: "The app's library replaces it.",
        ["Miscellaneous", "Use native user interface"]: "RPCS3's own dialogs are the only ones on iOS; it stays on.",
        ["Miscellaneous", "Use recursive scan"]: "Desktop's game list scanning.",
        ["Miscellaneous", "Show mouse and keyboard toggle hint"]: "No keyboard or mouse handler.",
        ["Miscellaneous", "GDB Server"]: "A debugger connection for desktop development.",
        ["Miscellaneous", "Window Title Format"]: "There is no window title.",
        ["Miscellaneous", "Enable GameMode"]: "A Linux feature.",
        ["Miscellaneous", "Play music during boot sequence"]: "Boot music needs a media player the app does not have yet; it stays silent.",
    ]

    /// Choices that cannot work on iOS, by setting.
    static let unavailableOptions: [[String]: [String: String]] = [
        ["Core", "SPU Decoder"]: ["Recompiler (ASMJIT)": "x86 only; on ARM it stops the game."],
        ["Video", "Shader Mode"]: [
            "Async Recompiler with Shader Interpreter": "Metal compiles the interpreter's pipelines for minutes before the game starts.",
            "Shader Interpreter only": "Metal compiles the interpreter's pipelines for minutes before the game starts.",
        ],
        ["Audio", "Renderer"]: ["Cubeb": "Cubeb has no iOS backend in RPCS3; FAudio plays through Core Audio."],
        ["Audio", "Audio Format"]: ["Manual": "Needs desktop's format checkboxes."],
        ["Input/Output", "Camera"]: ["Qt": "Part of RPCS3's Qt frontend.", "SDL": "Camera access is not supported yet."],
        ["Input/Output", "Move"]: [
            "Real": "Needs a PlayStation Move over USB or Bluetooth HID, which iOS apps cannot open.",
            "Mouse": "Needs a mouse.",
            "Raw Mouse": "Needs a mouse.",
        ],
    ]

    /// Settings desktop edits in other dialogs, placed where they belong: (tab, group, label).
    static let placed: [[String]: (tab: String, group: String, label: String)] = [
        ["Video", "Performance Overlay", "Framerate graph detail level"]: ("Emulator", "Performance Overlay", "Framerate graph detail"),
        ["Video", "Performance Overlay", "Frametime graph detail level"]: ("Emulator", "Performance Overlay", "Frametime graph detail"),
        ["Video", "Performance Overlay", "Body Color (hex)"]: ("Emulator", "Performance Overlay", "Text color"),
        ["Video", "Performance Overlay", "Body Background (hex)"]: ("Emulator", "Performance Overlay", "Background color"),
        ["Video", "Performance Overlay", "Title Color (hex)"]: ("Emulator", "Performance Overlay", "Title color"),
        ["Video", "Performance Overlay", "Title Background (hex)"]: ("Emulator", "Performance Overlay", "Title background color"),
    ]

    static func isHidden(_ path: [String]) -> Bool { hidden[path] != nil }

    static func options(of setting: Setting) -> [String] {
        let unavailable = unavailableOptions[setting.path] ?? [:]
        // The current value always shows, so the picker never has nothing selected
        return (setting.options ?? []).filter { unavailable[$0] == nil || $0 == setting.value }
    }

    /// How a setting is best edited on a phone, where it differs from its type's usual control.
    enum Editor {
        /// System/Console time offset (s): the console's clock as a date and time.
        case consoleClock
        /// An RGBA color written as #RRGGBBAA.
        case color
    }

    static func editor(for path: [String]) -> Editor? {
        if path == ["System", "Console time offset (s)"] { return .consoleClock }
        if path.count == 3, path[1] == "Performance Overlay", path[2].hasSuffix("(hex)") { return .color }
        return nil
    }
}
