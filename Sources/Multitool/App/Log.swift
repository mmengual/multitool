import os.log

enum Log {
    private static let subsystem = "com.mmengual.multitool"
    static let keyRemap  = Logger(subsystem: subsystem, category: "KeyRemap")
    static let detector  = Logger(subsystem: subsystem, category: "KeyboardDetector")
    static let game      = Logger(subsystem: subsystem, category: "GameDetector")
    static let app       = Logger(subsystem: subsystem, category: "AppDelegate")
    static let clipboard = Logger(subsystem: subsystem, category: "Clipboard")
}
