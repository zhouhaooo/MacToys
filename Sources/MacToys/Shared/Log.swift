// SPDX-License-Identifier: MIT

import os

/// 日志。用“控制台”应用按子系统 app.mactoys.MacToys 过滤查看。
enum Log {
    private static let subsystem = "app.mactoys.MacToys"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let keyboard = Logger(subsystem: subsystem, category: "keyboard")
    static let mouse = Logger(subsystem: subsystem, category: "mouse")
    static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
    static let thumbnails = Logger(subsystem: subsystem, category: "thumbnails")
}
