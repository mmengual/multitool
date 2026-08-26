import os.log

enum Log {
    private static let subsystem = "com.mmengual.stopchattering"
    static let keyRemap = Logger(subsystem: subsystem, category: "KeyRemap")
    static let detector = Logger(subsystem: subsystem, category: "KeyboardDetector")
    static let app      = Logger(subsystem: subsystem, category: "AppDelegate")
}
