import os.log

enum Log {
    private static let subsystem = "com.mmengual.multitool"
    static let keyRemap  = Logger(subsystem: subsystem, category: "KeyRemap")
    static let game      = Logger(subsystem: subsystem, category: "GameDetector")
    static let app       = Logger(subsystem: subsystem, category: "AppDelegate")
    static let clipboard = Logger(subsystem: subsystem, category: "Clipboard")
    static let updates   = Logger(subsystem: subsystem, category: "Updates")
    static let monitor   = Logger(subsystem: subsystem, category: "Monitor")
    static let menuBar   = Logger(subsystem: subsystem, category: "MenuBar")
}
