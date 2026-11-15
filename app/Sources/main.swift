import AppKit
import AVFoundation
import Foundation
import SQLite3

struct XLog { static func write(_ msg: String) { FileHandle.standardError.write(("[XiezhiPet] " + msg + "\n").data(using: .utf8)!) } }
func xlog(_ msg: String) { XLog.write(msg) }

// MARK: - 自测（XIEZHI_CPU_LOG=1 时每 10 秒打一行自身占用）
//
// 外面看不清常驻桌宠到底吃多少：活动监视器只给个均值，`top`/`ps` 在受限环境
// 里还读不到别人的进程。这里读自己的 task_info + getrusage，改性能前后用
// 同一段代码量，数字才可比。
//
// 配套 XIEZHI_BENCH=1：随机行为整个不跑，固定待机，两个版本在同样负载下对比。

/// 性能对照模式：不跑随机行为，固定待机
let benchMode = ProcessInfo.processInfo.environment["XIEZHI_BENCH"] == "1"

enum Perf {
    static func cpuSeconds() -> Double {
        var ru = rusage()
        guard getrusage(RUSAGE_SELF, &ru) == 0 else { return 0 }
        return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
            + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    }

    /// phys_footprint：和 Activity Monitor 的「内存」列口径一致（含压缩/映射）
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1048576
    }

    static var lastCPU: Double = cpuSeconds()
    static var lastAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    static var peakFootprint: Double = 0

    static func sample(_ tag: String) {
        let now = CFAbsoluteTimeGetCurrent()
        let cpu = cpuSeconds()
        let dt = max(0.001, now - lastAt)
        let pct = (cpu - lastCPU) / dt * 100
        lastCPU = cpu
        lastAt = now
        let mb = footprintMB()
        peakFootprint = max(peakFootprint, mb)
        xlog(String(format: "perf[%@] cpu=%.1f%% mem=%.1fMB peak=%.1fMB avg=%.2f%%",
                    tag, pct, mb, peakFootprint, cpu / max(1, now - startAt) * 100))
    }

    static var startAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
}

// MARK: - 动画资源定义

enum PetState: String {
    case idle, walk, lift, land, pat, daze, yawn, tail, tablet, study, play, hide, hideWait
    case stretch, sleep, wave, pounce, gavel, groom, fish
    case type, page, note, squat
}

struct Animation {
    let folder: String
    let files: [String]
    let fps: Double
    let loop: Bool
    let hold: Double
    var speed: Double = 1.0
}

enum Catalog {
    static var anims: [PetState: Animation] = [:]
    static var blinkFolder = "01_blink"
    static var blinkFiles: [String] = ["blink_01.png", "blink_02.png", "blink_03.png"]
    static var lookLeft = "12_look/look_left.png"
    static var lookMid = "12_look/look_mid.png"
    static var lookRight = "12_look/look_right.png"
    static var hideWaitFile = "hide_02.png"

    static var fallbackIdle: Animation {
        // still/idle.png 一定随 App 打包；帧表读取失败时用它兜底，避免白屏。
        // 原来写的 idle_01.png 等三位/两位混用文件名在 assets/01_idle 里并不存在。
        Animation(folder: "still", files: ["idle.png"], fps: 1.0, loop: true, hold: 0)
    }

    /// 从 assets/sequence.json 读取帧表（构建脚本生成，帧数/中割帧自动生效）
    static func load(root: String) {
        let path = root + "/sequence.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let obj = raw as? [String: Any],
              let states = obj["states"] as? [String: Any] else {
            xlog("sequence.json 读取失败: \(path)")
            return
        }
        for (key, value) in states {
            guard let st = PetState(rawValue: key), let d = value as? [String: Any],
                  let folder = d["folder"] as? String, let files = d["files"] as? [String],
                  !files.isEmpty else { continue }
            let fps = (d["fps"] as? NSNumber)?.doubleValue ?? 6.0
            let loop = (d["loop"] as? NSNumber)?.boolValue ?? true
            let hold = (d["hold"] as? NSNumber)?.doubleValue ?? 0
            let speed = (d["speed"] as? NSNumber)?.doubleValue ?? 1.0
            var a = Animation(folder: folder, files: files, fps: fps, loop: loop, hold: hold)
            a.speed = speed
            anims[st] = a
        }
        if let b = obj["blink"] as? [String: Any] {
            if let f = b["files"] as? [String] { blinkFiles = f }
            if let fo = b["folder"] as? String { blinkFolder = fo }
        }
        if let l = obj["look"] as? [String: String] {
            lookLeft = l["left"] ?? lookLeft
            lookMid = l["mid"] ?? lookMid
            lookRight = l["right"] ?? lookRight
        }
        if let h = obj["hideWait"] as? String { hideWaitFile = h }
        xlog("loaded \(anims.count) states, idle frames=\(anims[.idle]?.files.count ?? 0)")
    }
}

// MARK: - 资源加载

final class Assets {
    static let shared = Assets()
    private var cache: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private let root: String
    /// 视频清单只在首次访问时列一次目录，避免 12Hz 主循环里反复做 fileExists
    private lazy var videoMap: [String: URL] = {
        let dir = root + "/video"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [:] }
        var map: [String: URL] = [:]
        for name in names where name.hasSuffix(".mov") {
            map[(name as NSString).deletingPathExtension] = URL(fileURLWithPath: dir + "/" + name)
        }
        return map
    }()

    init() {
        root = (Bundle.main.resourcePath ?? "") + "/assets"
        let fm = FileManager.default
        let subs = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        xlog("assets root=\(root) folders=\(subs.count)")
        Catalog.load(root: root)
    }

    func image(_ relative: String) -> NSImage? {
        if let c = cache[relative] { return c }
        guard !missing.contains(relative) else { return nil }
        guard let img = NSImage(contentsOfFile: root + "/" + relative) else {
            missing.insert(relative)
            return nil
        }
        cache[relative] = img
        return img
    }

    func frames(_ anim: Animation) -> [NSImage] {
        anim.files.compactMap { image(anim.folder + "/" + $0) }
    }

    /// 末帧静图也走同一份缓存：拖动时每个 tick 都会取，不能每次重新读盘
    func endImage(_ name: String) -> NSImage? {
        image("end/" + name + ".png")
    }

    func videoURL(_ name: String) -> URL? {
        videoMap[name]
    }
}

// MARK: - 台词

enum Lines {
    static let speech = [
        "我要上商法学",
        "我要上知识产权总论",
        "今天记得学民法",
        "法条背不完……但我可以陪你",
        "判例还没看完，别催我",
        "背到第三十条，人已经开始飘了",
        "法学是玄学，背书是修行",
        "摸鱼？不，我在研读法理",
        "别晃鼠标，我在想构成要件",
        "考完试带你去吃小鱼干",
        "这条法条我记得，只是说不出来",
        "卫戍协议，启动！",
        "§433 BGB 复习一下"
    ]
    static let focusStart = "专注模式开始，25 分钟看书"
    static let focusEnd = "休息一下，打个滚！"

    /// 随机台词：连上 Lawlearn 时约四成概率念一条真法条。
    /// 法条查询是 paragraphs 全表扫 + ORDER BY random()，在主线程做会卡住
    /// 12Hz 主循环一两百毫秒（表现就是气泡弹出来时掉帧），所以整条链路异步。
    /// 台词本身要等不到就不弹气泡——宁可晚 0.1 秒，也不要让画面顿一下。
    static func next(_ completion: @escaping (String) -> Void) {
        let forced = ProcessInfo.processInfo.environment["XIEZHI_SAY_LEGAL"] == "1"
        let ratio = (UserDefaults.standard.object(forKey: "lawRatio") as? Double) ?? 0.4
        let wantsLegal = forced || (Lawlearn.shared.connected && Lawlearn.linked
                                    && Double.random(in: 0..<1) < ratio)
        guard wantsLegal else {
            completion(speech.randomElement() ?? "")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let article = Lawlearn.shared.randomArticle()
            DispatchQueue.main.async {
                completion(article ?? speech.randomElement() ?? "")
            }
        }
    }
}

// MARK: - 联通 Lawlearn（只读本机 ~/Library/Application Support/lawlearn/lawlearn.db）

final class Lawlearn {
    static let shared = Lawlearn()
    static let dbPath = NSHomeDirectory() + "/Library/Application Support/lawlearn/lawlearn.db"

    /// 本机是否装了 Lawlearn：有数据库，或 Applications 里有它
    static var installed: Bool {
        if ProcessInfo.processInfo.environment["XIEZHI_FAKE_NO_LAW"] == "1" { return false }
        if FileManager.default.fileExists(atPath: dbPath) { return true }
        let candidates = ["/Applications/Lawlearn.app",
                          NSHomeDirectory() + "/Applications/Lawlearn.app"]
        if candidates.contains(where: { FileManager.default.fileExists(atPath: $0) }) { return true }
        if let list = try? FileManager.default.contentsOfDirectory(atPath: "/Applications"),
           list.contains(where: { $0.lowercased().contains("lawlearn") }) { return true }
        return false
    }

    /// 用户是否开启联动（装了才有意义）
    static var linked: Bool {
        let v = UserDefaults.standard.object(forKey: "lawlearnLinked") as? Bool
        return v ?? true
    }
    private(set) var connected = false
    private var db: OpaquePointer?
    /// 数据库句柄只在这条串行队列上碰：查询挪到后台后，不能和 connect/close 并发
    private let dbQueue = DispatchQueue(label: "com.suzukihnnn.xiezhi-pet.lawlearn")

    func connect() { dbQueue.sync { connectLocked() } }
    func close() { dbQueue.sync { closeLocked() } }
    /// 随机挑一条短条文，返回「民法典·第二条：……」
    func randomArticle() -> String? { dbQueue.sync { randomArticleLocked() } }

    private func connectLocked() {
        guard FileManager.default.fileExists(atPath: Lawlearn.dbPath) else {
            xlog("lawlearn: 没找到数据库，法条台词关闭")
            return
        }
        var handle: OpaquePointer?
        if sqlite3_open_v2(Lawlearn.dbPath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            db = handle
            connected = true
            xlog("lawlearn: 已连接 \(Lawlearn.dbPath)")
        } else {
            if let handle { sqlite3_close(handle) }
            xlog("lawlearn: 打开失败")
        }
    }

    private func closeLocked() {
        if let db { sqlite3_close(db) }
        db = nil
        connected = false
    }

    private func randomArticleLocked() -> String? {
        guard let db else { return nil }
        let sql = """
        SELECT l.short_name, a.label, replace(p.text, char(10), '')
          FROM paragraphs p
          JOIN articles a ON a.id = p.article_id
          JOIN laws l ON l.id = a.law_id
         WHERE l.status = '现行有效'
           AND p.parent_id IS NULL AND p.level = '款'
           AND length(p.text) BETWEEN 14 AND 46
           AND p.text NOT LIKE '%下列%' AND p.text NOT LIKE '%前款%'
           AND p.text NOT LIKE '%本条%' AND p.text NOT LIKE '%如上%'
         ORDER BY random() LIMIT 1
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW else { return nil }
        guard let lawC = sqlite3_column_text(st, 0),
              let labelC = sqlite3_column_text(st, 1),
              let textC = sqlite3_column_text(st, 2) else { return nil }
        let law = String(cString: lawC)
        let label = String(cString: labelC)
        let text = String(cString: textC)
        return "\(law)·\(label)：\(text)"
    }
}

// MARK: - 宠物视图

class PetView: NSView {
    var currentImage: NSImage?
    var faceRight = false
    /// 悬空漂浮时的整体小位移
    var contentOffset = CGPoint.zero
    /// 纸片转身：1 = 正面，0 = 压成一条线（从中心缩放）
    var flipScale: CGFloat = 1

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // 静态图与视频都走 CALayer，这里只作为兜底；没有图就什么都别画，
        // 否则鼠标经过触发 backing store 更新时，透明清屏会让窗口闪一下。
        guard let img = currentImage,
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = NSRect(origin: .zero, size: bounds.size)
        ctx.saveGState()
        ctx.translateBy(x: contentOffset.x, y: contentOffset.y)
        ctx.translateBy(x: bounds.width / 2, y: 0)
        ctx.scaleBy(x: flipScale, y: 1)
        ctx.translateBy(x: -bounds.width / 2, y: 0)
        if faceRight {
            ctx.saveGState()
            ctx.translateBy(x: bounds.width, y: 0)
            ctx.scaleBy(x: -1, y: 1)
            img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            ctx.restoreGState()
        } else {
            img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        ctx.restoreGState()
    }
}

final class EventView: PetView {
    weak var controller: PetController?

    override func mouseDown(with event: NSEvent) {
        controller?.beginDrag()
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.drag()
    }

    override func mouseUp(with event: NSEvent) {
        controller?.endDrag()
    }

    // 右键和滚轮都不再挂功能：
    // 动作菜单里的每一项（说句话 / 专注 / 法条联动 / 躲藏 / 回位置）控制台和菜单栏图标都有，
    // 留着只是让人多点一次；滚轮调大小又太容易误触——滚一下桌面就把宠物缩放了一圈。
}

// MARK: - 气泡

final class BubblePanel: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private let box = NSView()
    private var hideTimer: Timer?
    /// 每次 show 自增：淡出动画和延时的 orderOut 都可能在新气泡弹出之后才回来
    private var showToken = 0
    /// 气泡当前挂在哪块位置上，宠物走动时用来跟着挪
    private var anchorPet: NSRect = .zero
    private var bubbleSize = NSSize.zero

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 46),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.96).cgColor
        box.layer?.cornerRadius = 14
        box.layer?.borderWidth = 2
        box.layer?.borderColor = NSColor(calibratedRed: 0.45, green: 0.28, blue: 0.55, alpha: 1).cgColor

        label.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        label.textColor = NSColor(calibratedRed: 0.30, green: 0.15, blue: 0.38, alpha: 1)
        label.alignment = .center
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byCharWrapping
        label.usesSingleLineMode = false
        box.addSubview(label)
        contentView = box
    }

    func show(_ text: String, above petFrame: NSRect) {
        // 支持多行（法条较长）：按字符换行，最多 4 行
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byCharWrapping
        label.usesSingleLineMode = false
        label.stringValue = text
        let maxTextW: CGFloat = 344
        let attrs: [NSAttributedString.Key: Any] = [.font: label.font ?? NSFont.systemFont(ofSize: 17)]
        var bound = (text as NSString).boundingRect(with: NSSize(width: maxTextW, height: 9999),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                    attributes: attrs)
        bound.size.width = ceil(bound.size.width)
        bound.size.height = ceil(bound.size.height)
        let textW = min(max(bound.width + 26, 118), maxTextW)
        let textH = max(bound.height, 22)
        let padding: CGFloat = 18
        let w = textW + padding * 2
        let h = textH + 24
        label.frame = NSRect(x: padding, y: 12, width: textW, height: textH)
        box.frame = NSRect(x: 0, y: 0, width: w, height: h)
        if let cell = label.cell as? NSTextFieldCell {
            cell.wraps = true
            cell.isScrollable = false
        }
        bubbleSize = NSSize(width: w, height: h)
        anchorPet = petFrame
        layoutBubble(petFrame)
        showToken &+= 1
        let token = showToken
        // 淡入：原来直接 orderFront 是硬切，视觉上「啪」一下
        let wasVisible = isVisible && alphaValue > 0.95
        if !wasVisible { alphaValue = 0 }
        orderFrontRegardless()
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        }

        // 验收用：XIEZHI_DUMP_BUBBLE=<路径> 时把气泡离屏渲染成 PNG（本机截不到 NSPanel）
        if let path = ProcessInfo.processInfo.environment["XIEZHI_DUMP_BUBBLE"] {
            box.layoutSubtreeIfNeeded()
            if let rep = box.bitmapImageRepForCachingDisplay(in: box.bounds) {
                box.cacheDisplay(in: box.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                    xlog("bubble dumped -> \(path) size=\(w)x\(h) text=\(text)")
                }
            }
        }
        // 显示时长按字数自适应，长句留够读完的时间
        let seconds = min(10.0, 2.6 + Double(text.count) * 0.16)
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, self.showToken == token else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.showToken == token else { return }
                self.orderOut(nil)
                self.alphaValue = 1
            })
        }
    }

    /// 宠物走动或被拖走时气泡跟着挪，别把它留在原地飘着
    func follow(_ petFrame: NSRect) {
        guard isVisible, bubbleSize != .zero, !petFrame.equalTo(anchorPet) else { return }
        anchorPet = petFrame
        // display: false —— 内容没变，只是整块窗口平移，不需要每步重绘文字
        layoutBubble(petFrame, display: false)
    }

    /// 定位：默认浮在宠物头顶，但整块气泡必须留在屏幕可见区内
    /// （原来贴到屏幕左/右边缘时 x 会算成负数，气泡有半截跑到屏幕外）
    private func layoutBubble(_ petFrame: NSRect, display: Bool = true) {
        let w = bubbleSize.width, h = bubbleSize.height
        let screen = NSScreen.screens.first { $0.frame.intersects(petFrame) } ?? NSScreen.main
        let v = screen?.visibleFrame ?? petFrame
        var x = petFrame.midX - w / 2
        x = max(v.minX + 6, min(x, v.maxX - w - 6))
        var y = petFrame.maxY - 30
        y = max(v.minY + 4, min(y, v.maxY - h - 4))
        setFrame(NSRect(x: x, y: y, width: w, height: h), display: display)
    }
}

// MARK: - 主控制器

final class PetController: NSObject {
    let window: NSPanel
    let view: EventView
    let bubble = BubblePanel()

    private var anim: Animation = Catalog.anims[.idle] ?? Catalog.fallbackIdle
    private var frames: [NSImage] = []
    private var frameIndex = 0
    private var lastFrameTime = CFAbsoluteTimeGetCurrent()
    private var stateStartTime = CFAbsoluteTimeGetCurrent()
    private var state: PetState = .idle

    private var tickTimer: Timer?
    private var behaviorTimer: Timer?
    private var blinkTimer: Timer?
    private var dragging = false
    private var isFocusing = false
    private var studySession = 0
    private var lastInteractionAt = CFAbsoluteTimeGetCurrent()
    private var lastMousePoint = NSPoint.zero
    private var dragDistance: CGFloat = 0
    private var walkDirection: CGFloat = -1
    /// 走路单独用 60Hz 定时器推进（见 syncWalkTimer），只在走路时存在
    private var walkTimer: Timer?
    private var lastWalkAt: CFAbsoluteTime = 0
    /// 走路用的带小数横坐标锚点（窗口 frame 只保留整点，见 walkStep 里的说明）
    private var walkAnchorX: CGFloat = 0
    /// 帧推进的时间余数：只按 tick 间隔判断条件的话，余数每次都被丢掉，整体会越跑越慢
    private var frameAccum: Double = 0
    /// 台词是异步取的，回包时状态可能已经换了，用它丢弃过期结果
    private var talkToken = 0
    /// 是否已经把窗口设成「不吃鼠标事件」（鼠标落在素材的透明像素上时）
    private var passThrough = false
    private var alphaRepKey: String?
    private var alphaRep: NSBitmapImageRep?
    /// 专注结束的提示音。必须持有引用，否则 NSSound 可能在播完前就被释放
    private var focusChime: NSSound?
    private var blinkingUntil: CFAbsoluteTime = 0
    private var blinkStart: CFAbsoluteTime = 0
    private var blinkImages: [NSImage] = []
    private var faceRight = false

    // 甩飞弹跳的物理状态
    private var physicsTimer: Timer?
    private var isFlying = false
    private var velX: CGFloat = 0
    private var velY: CGFloat = 0
    private var flyStartedAt: CFAbsoluteTime = 0
    private var lastPhysicsAt: CFAbsoluteTime = 0
    private var flyTraceCount = 0
    private var isSuspended = false
    private var suspendedSince: CFAbsoluteTime = 0
    private var isDropping = false
    private var turning = false
    private var turnStart: CFAbsoluteTime = 0
    private var turnTarget: PetState = .idle
    private var turnApplied = false
    private var turnTimer: Timer?
    private var dropTimer: Timer?
    private var manualAction = false
    private let turnDuration: Double = 0.22
    private var manualHoldUntil: CFAbsoluteTime = 0

    // 屏幕参数变化 / 休眠唤醒的通知令牌（两个通知中心不同，分开保存）
    private var screenObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    // 视频动画（HEVC + alpha）
    private var avPlayer: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var videoLayer: AVPlayerLayer?
    private var stillLayer: CALayer?
    private var currentVideoName: String?
    private var currentVideoLoop = false
    private var videoFinished = false
    private var finishedStateName: String?
    private var endObserver: NSObjectProtocol?
    private var lastStillImage: NSImage?
    private var flyScreen: NSScreen?
    /// playBounds 在 60Hz 物理里每帧都调，而 NSScreen.screens 每次都要向 WindowServer 取一遍，
    /// 再加两次 map + 一次 contains，纯属白烧。屏幕变化时由 clampWindowToVisibleArea 立刻作废。
    private var boundsCache: (minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat)?
    private var boundsCacheAt: CFAbsoluteTime = 0
    private var flyTraceFile: FileHandle?
    private var dragSamples: [(t: CFAbsoluteTime, origin: NSPoint)] = []

    private(set) var petSize: CGFloat = 240

    // MARK: 几何缓存
    //
    // window.frame 每读一次都要往 WindowServer 要一遍（IPC），window.screen 同理。
    // 原来 12Hz 主循环里一 tick 读四五次、走路 60Hz 里每步读两次，每秒上百次纯属白烧。
    // 现在所有移动都走 setPetOrigin/setPetFrame，缓存跟着改；另外每 2 秒和窗口
    // 真实值核对一次兜底（只改缓存，不动窗口）。
    private var petFrameCache: NSRect = .zero
    private var frameCheckedAt: CFAbsoluteTime = 0
    /// 当前所在屏幕：命中缓存就不查 window.screen（跨屏时靠 intersects 判断自动失效）
    private var screenCache: NSScreen?

    /// 当前状态有没有对应视频（setState 时算一次，别每 tick 查字典）
    private var stateHasVideo = false

    /// 主循环频率，按「有没有人看得到」在 12 / 4 / 2 Hz 之间切
    private var tickHz: Double = 12
    private var occludedSince: CFAbsoluteTime = 0
    /// 遮挡判定留滞后：切桌面/全屏动画时 occlusionState 会闪一下，不留余地会让视频反复停启
    private var isOccluded = false
    /// 每 tick 取一次鼠标位置，穿透判定和眼神跟随共用
    private var mouseNow: NSPoint = .zero

    // 可在控制台调整的偏好
    private(set) var behaviorInterval: TimeInterval =
        max(3.0, (UserDefaults.standard.object(forKey: "behaviorInterval") as? Double) ?? 9.0)
    private(set) var allowWalk: Bool = UserDefaults.standard.object(forKey: "allowWalk") as? Bool ?? true
    private(set) var allowTalk: Bool = UserDefaults.standard.object(forKey: "allowTalk") as? Bool ?? true
    private(set) var eyeTracking: Bool = UserDefaults.standard.object(forKey: "eyeTracking") as? Bool ?? true
    private(set) var lawRatio: Double = (UserDefaults.standard.object(forKey: "lawRatio") as? Double) ?? 0.4

    override init() {
        let savedSize = (UserDefaults.standard.object(forKey: "petSize") as? Double) ?? 200
        petSize = CGFloat(max(120, min(360, savedSize)))
        let rect = NSRect(x: 0, y: 0, width: petSize, height: petSize)
        window = NSPanel(contentRect: rect,
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        view = EventView(frame: rect)

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false
        window.contentView = view
        window.acceptsMouseMovedEvents = true
        window.disableCursorRects()
        view.wantsLayer = true
        let sl = CALayer()
        sl.frame = view.bounds
        sl.contentsGravity = .resizeAspect
        sl.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        sl.backgroundColor = NSColor.clear.cgColor
        sl.isHidden = true
        view.layer?.addSublayer(sl)
        stillLayer = sl
        let layer = AVPlayerLayer()
        layer.frame = view.bounds
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.clear.cgColor
        view.layer?.addSublayer(layer)
        videoLayer = layer
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        avPlayer = queuePlayer
        layer.player = queuePlayer
        layer.isHidden = true
        super.init()

        petFrameCache = window.frame
        restorePosition()

        view.controller = self
        blinkImages = Catalog.blinkFiles.compactMap { Assets.shared.image(Catalog.blinkFolder + "/" + $0) }
        setState(.idle)
        NSLog("[XiezhiPet] window frame=\(window.frame) idleFrames=\(frames.count) image=\(view.currentImage?.size.debugDescription ?? "nil")")
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.restorePosition()
            NSLog("[XiezhiPet] repositioned frame=\(self.window.frame) screens=\(NSScreen.screens.count)")
        }

        // 容差让系统把这些定时器合并到同一次唤醒里，省电；帧推进按真实 dt 走，被推迟也不影响节奏
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tickTimer?.tolerance = 0.03
        RunLoop.main.add(tickTimer!, forMode: .common)

        startBehaviorTimer()
        startBlinkTimer()

        // 拔外接屏 / 改分辨率 / 休眠唤醒后，把窗口夹回可见区域，别留在屏幕外
        screenObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.clampWindowToVisibleArea()
            })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.clampWindowToVisibleArea()
            })
    }

    deinit {
        screenObservers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    // MARK: 几何缓存（窗口坐标 / 所在屏幕）

    /// 窗口矩形。读缓存，不碰 WindowServer。
    private var petFrame: NSRect { petFrameCache }

    private func setPetOrigin(_ o: NSPoint) {
        petFrameCache.origin = o
        window.setFrameOrigin(o)
    }

    private func setPetFrame(_ r: NSRect, display: Bool) {
        petFrameCache = r
        window.setFrame(r, display: display)
    }

    /// 兜底核对：每 2 秒跟窗口真实值对一次。系统全屏切换、Mission Control
    /// 之类可能绕过我们改位置，只靠缓存会越飘越远；核对一次 2 秒才一次 IPC。
    private func reconcileFrameIfNeeded(_ now: CFAbsoluteTime) {
        guard now - frameCheckedAt > 2 else { return }
        frameCheckedAt = now
        let real = window.frame
        if real.origin != petFrameCache.origin || real.size != petFrameCache.size {
            petFrameCache = real
        }
        if let s = screenCache, !s.frame.intersects(petFrameCache) { screenCache = nil }
    }

    /// 宠物现在在哪块屏。命中缓存直接返回，跨屏后才重新问 window.screen。
    private func currentScreen() -> NSScreen? {
        if let s = screenCache, s.frame.intersects(petFrameCache) { return s }
        let s = window.screen ?? NSScreen.main
        screenCache = s
        return s
    }

    /// 屏幕参数变化或唤醒后，把窗口夹回任一屏幕的可见区域（保留用户当前位置）
    private func clampWindowToVisibleArea() {
        invalidateBoundsCache()
        let f = petFrame
        guard !NSScreen.screens.isEmpty else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(f) } ?? NSScreen.main
        guard let v = screen?.visibleFrame else { return }
        var o = f.origin
        o.x = max(v.minX, min(o.x, v.maxX - f.width))
        o.y = max(v.minY, min(o.y, v.maxY - f.height))
        if o.x != f.origin.x || o.y != f.origin.y {
            setPetOrigin(o)
            // 走路中被动改了位置，锚点要跟上，否则下一步会跳回原处
            if walkTimer != nil { walkAnchorX = o.x }
        }
    }

    /// 上次放在哪儿就放回哪儿；没有记录（或那块屏已经拔了）才落到默认的右下角
    private func restorePosition() {
        // 两个标量键，不用数组：`array(forKey:) as? [NSNumber]` 在这套工具链上
        // 对 __NSCFNumber 的条件转换会失败（返回 nil），踩过。
        let d = UserDefaults.standard
        if d.object(forKey: "lastX") != nil, d.object(forKey: "lastY") != nil {
            let p = NSPoint(x: CGFloat(d.double(forKey: "lastX")), y: CGFloat(d.double(forKey: "lastY")))
            let fits = NSScreen.screens.contains {
                $0.visibleFrame.insetBy(dx: -petSize / 2, dy: -petSize / 2).contains(p)
            }
            if fits {
                setPetOrigin(p)
                return
            }
            xlog("saved origin \(p) 不在任何屏幕内，回默认位置")
        }
        moveToDefaultPosition()
    }

    /// 记住当前位置，下次启动接着放（别每次开机都跳回右下角）
    func savePosition() {
        guard !isFlying, !isDropping, !dragging else { return }
        let o = petFrame.origin
        UserDefaults.standard.set(Double(o.x), forKey: "lastX")
        UserDefaults.standard.set(Double(o.y), forKey: "lastY")
    }

    private func moveToDefaultPosition() {
        let screen = NSScreen.screens.first ?? NSScreen.main
        guard let f = screen?.visibleFrame, f.width > 100 else { return }
        let x = max(f.minX + 20, f.maxX - petSize - 40)
        let y = max(f.minY + 20, f.minY + 40)
        setPetOrigin(NSPoint(x: x, y: y))
    }

    // MARK: 状态切换

    private var lastStateSwitchAt: CFAbsoluteTime = 0
    private var videoReadySince: CFAbsoluteTime = 0
    private var backdropUntil: CFAbsoluteTime = 0
    private var pendingState: PetState?
    private var stateFlushTimer: Timer?

    func setState(_ newState: PetState, immediate: Bool = false) {
        // 连点合并：220ms 内的连续请求只留最后一个，别反复重建播放器
        let now = CFAbsoluteTimeGetCurrent()
        if !immediate, now - lastStateSwitchAt < 0.22 {
            if pendingState == nil {
                stateFlushTimer?.invalidate()
                stateFlushTimer = Timer(timeInterval: 0.22, repeats: false) { [weak self] _ in
                    guard let self, let p = self.pendingState else { return }
                    self.pendingState = nil
                    self.setState(p, immediate: true)
                }
                if let t = stateFlushTimer { RunLoop.main.add(t, forMode: .common) }
            }
            pendingState = newState
            return
        }
        stateFlushTimer?.invalidate()
        stateFlushTimer = nil
        pendingState = nil
        lastStateSwitchAt = now
        if ProcessInfo.processInfo.environment["XIEZHI_STATE_LOG"] == "1" {
            xlog("state -> \(newState.rawValue)")
        }
        state = newState
        finishedStateName = nil
        videoFinished = false
        stateStartTime = CFAbsoluteTimeGetCurrent()
        lastFrameTime = stateStartTime
        frameIndex = 0
        frameAccum = 0
        if newState != .walk { stopWalkTimer() }
        if newState == .hideWait {
            anim = Animation(folder: "13_hide", files: [Catalog.hideWaitFile], fps: 1.0, loop: true, hold: 0)
        } else {
            anim = Catalog.anims[newState] ?? Catalog.anims[.idle] ?? Catalog.fallbackIdle
        }
        // 有视频的状态不走 PNG 序列帧，帧表只用于计时和末帧兜底。
        // 原来整组加载（打字/翻页等 150 帧）会在主线程同步读 150 个文件。
        // 保留首帧，兼容 finishWithTurn 里 frames.first 的兜底路径。
        // 这里算一次「这个状态有没有视频」，主循环里就不用每 tick 再查字典。
        stateHasVideo = Assets.shared.videoURL(newState.rawValue) != nil
        if !stateHasVideo {
            frames = Assets.shared.frames(anim)
        } else if let first = Assets.shared.image(anim.folder + "/" + (anim.files.first ?? "")) {
            frames = [first]
        } else {
            frames = []
        }
        if newState != .walk { faceRight = false }
        updateImage()
    }

    // MARK: 帧循环

    /// 主循环频率按「有没有人看得到」分档：正常 12Hz，被整块盖住 4Hz，整个藏起来 2Hz。
    /// 切档只在跨档时重建定时器，不是每 tick 都动。
    private func setTickHz(_ hz: Double) {
        guard abs(hz - tickHz) > 0.01 else { return }
        tickHz = hz
        tickTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / hz, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // 低频时给更大容差，让系统把这次唤醒并到别的定时器上
        t.tolerance = hz > 6 ? 0.03 : 0.5
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        reconcileFrameIfNeeded(now)

        // 整块藏起来（菜单栏「隐藏」/ 别处 orderOut）：什么都不用算，连视频也别解码。
        // 原来这种状态下 12Hz 照跑，render() 里才发现不可见再收手，空转一整天。
        guard window.isVisible else {
            setTickHz(2)
            stopWalkTimer()          // 看不见还在 60Hz 挪位置，纯属白跑
            if avPlayer?.rate != 0 { pauseVideoIfPlaying() }
            return
        }

        // 被别的窗口整块盖住：屏幕上一个像素都看不见，解码同样是白烧。
        // 滞后 0.6 秒再认，避开切桌面 / 全屏动画时 occlusionState 的抖动。
        let occluded = !window.occlusionState.contains(.visible)
        if occluded {
            if occludedSince == 0 { occludedSince = now }
            if now - occludedSince > 0.6 {
                isOccluded = true
                setTickHz(4)
                stopWalkTimer()
                if avPlayer?.rate != 0 { pauseVideoIfPlaying() }
                return
            }
        } else {
            occludedSince = 0
            if isOccluded {
                isOccluded = false
                // 刚露出来：让媒体层重新判一次（视频恢复播放走 playVideoIfNeeded）
            }
            setTickHz(12)
        }

        // 鼠标位置一 tick 只取一次，穿透判定和眼神跟随共用
        mouseNow = NSEvent.mouseLocation

        // 走路是否该由 60Hz 专用定时器接管，放在早退之前判断
        syncWalkTimer()
        // 透明像素上放开鼠标事件（点击穿透），气泡跟着宠物走
        updateClickThrough()
        bubble.follow(petFrame)

        // 专注看书：彻底静止，不做任何帧推进、位移或眼神变化
        if isFocusing {
            if state != .study { setState(.study) }
            return
        }
        // 纸片转身过渡由 60Hz 定时器推进
        if turning { return }

        // 夹一下：转身/睡眠醒来后 dt 会很大，别让它一次推进几十帧
        let dt = min(0.25, max(0, now - lastFrameTime))
        lastFrameTime = now

        // 按住不动时也持续记位置样本，这样“停顿”能被 releaseVelocity 感知
        if dragging {
            dragSamples.append((now, petFrame.origin))
            while dragSamples.count > 32 { dragSamples.removeFirst() }
        }

        let hasVideo = currentVideoName != nil || stateHasVideo
        if frames.count > 1 && !hasVideo {
            // speed 也要算进去：原来只按 fps 推进，sequence.json 里的 speed 对帧率无效
            let interval = 1.0 / max(0.1, anim.fps * max(0.1, anim.speed))
            frameAccum += dt
            if frameAccum >= interval {
                // 余数留着，不丢掉；一 tick 可能跨多帧
                var advance = Int(frameAccum / interval)
                frameAccum -= Double(advance) * interval
                if advance > frames.count { advance = frames.count }
                for _ in 0..<advance {
                    if frameIndex + 1 < frames.count {
                        frameIndex += 1
                    } else if anim.loop {
                        frameIndex = 0
                    } else {
                        break
                    }
                }
            }
        } else {
            frameAccum = 0
        }
        render()

        if view.contentOffset != .zero {
            view.contentOffset = .zero
            view.needsDisplay = true
        }

        // 拖拽 / 缓落过程中不自动切状态
        if dragging || isDropping { return }

        let elapsed = now - stateStartTime
        if !anim.loop {
            let speed = max(0.3, anim.speed)
            let total = anim.hold + Double(max(frames.count, anim.files.count, 1)) / (anim.fps * speed)
            if elapsed > total {
                if state == .hide {
                    setState(.hideWait)
                } else if isFocusing {
                    setState(.study, immediate: true)
                } else if manualAction {
                    finishWithTurn(to: .idle)
                } else {
                    setState(.idle)
                }
            }
        } else if anim.hold > 0 && state != .walk && state != .idle && state != .study {
            if elapsed > anim.hold {
                if manualAction { finishWithTurn(to: .idle) } else { setState(.idle, immediate: true) }
            }
        }
    }

    private func updateImage() { render() }

    /// 需要临时盖一张静态图的情况：眨眼、眼神跟随
    private func staticOverrideImage() -> NSImage? {
        guard state == .idle, !isFocusing else { return nil }
        if blinkImages.count == 3, CFAbsoluteTimeGetCurrent() < blinkingUntil {
            let dt = CFAbsoluteTimeGetCurrent() - blinkStart
            let idx = dt < 0.05 ? 0 : (dt < 0.11 ? 1 : 2)
            return blinkImages[idx]
        }
        if eyeTracking, let screen = currentScreen() {
            let mouse = mouseNow
            let dx = mouse.x - petFrame.midX
            let dy = abs(mouse.y - petFrame.midY)
            if dy < screen.frame.height * 0.35 && abs(dx) > 55 {
                let key = dx < 0 ? Catalog.lookRight : Catalog.lookLeft
                return Assets.shared.image(key)
            } else if dy < screen.frame.height * 0.35 && abs(dx) < 24 {
                return Assets.shared.image(Catalog.lookMid)
            }
        }
        return nil
    }

    private func render() {
        if turning { return }
        // 窗口被 orderOut 之后 AVPlayer 不会自己停：隐藏一整天就等于解码一整天。
        // 这里直接收手，重新显示后的下一拍会自动从 playVideoIfNeeded 恢复播放。
        if !window.isVisible {
            pauseVideoIfPlaying()
            return
        }
        // 拖动时窗口每帧都在移动，视频层跟着移动会闪；改用静态“被拎起”画面
        if (dragging || isDropping), let liftStill = Assets.shared.endImage("lift") {
            pauseVideoIfPlaying()
            showStill(liftStill)
            return
        }
        // 视频已经出画、也没有静图要盖：这一帧怎么显示已经定了，后面那套换层判定
        // 每 tick 重走一遍全是空转。待机要留着——眨眼和眼神跟随都得靠它。
        if stateHasVideo, state != .idle,
           videoLayer?.isHidden == false, videoLayer?.isReadyForDisplay == true,
           CFAbsoluteTimeGetCurrent() > backdropUntil {
            if avPlayer?.rate == 0 { avPlayer?.rate = Float(max(0.1, anim.speed)) }
            applyVideoMirror()
            return
        }
        let hasVideoForState = stateHasVideo
        guard !frames.isEmpty || hasVideoForState else { return }
        // 一次性动作播完后停在末帧静图（视频层暂停会掉帧，只能用静图兜底）
        if finishedStateName == state.rawValue, let endImg = Assets.shared.endImage(state.rawValue) {
            showStill(endImg)
            return
        }
        if let still = staticOverrideImage() {
            // 只在播放器还在走时暂停一次；原来每个 tick 都 pause()，
            // 会让 HEVC 解码器反复停/启，出现可见掉帧
            pauseVideoIfPlaying()
            showStill(still)
            return
        }
        if stateHasVideo {
            playVideoIfNeeded(state.rawValue, loop: anim.loop, speed: anim.speed)
            // 换 item 后先用同状态首帧单独顶 0.28 秒（这期间视频层藏起来），
            // 只显示一层，避免静图和视频帧错位叠成「两个角色」；之后再切回视频
            let now = CFAbsoluteTimeGetCurrent()
            let still = Assets.shared.image("still/\(state.rawValue).png")
            let ready = videoLayer?.isReadyForDisplay == true
            // 至少顶 0.28 秒静帧避免静图与视频帧错位叠成双影；
            // 之后也必须等视频真正出首帧才切层。原来超时无条件切到未就绪的
            // 视频层会露黑帧（视频损坏或解码慢时尤其明显）。
            if (now < backdropUntil || !ready), let still {
                showStill(still)
            } else {
                // 已经是显的形状就别再提交一次 CA 事务：待机时这可是每个 tick 一次
                if let vl = videoLayer, vl.isHidden {
                    CATransaction.begin(); CATransaction.setDisableActions(true); vl.isHidden = false; CATransaction.commit()
                }
                hideStill()
            }
            return
        }
        // 没有视频的状态（躲藏等待这类静态帧）
        stopVideo()
        let img = frames.isEmpty
            ? Assets.shared.image(state.rawValue == "hideWait" ? "13_hide/" + Catalog.hideWaitFile : anim.folder + "/" + (anim.files.first ?? ""))
            : frames[min(frameIndex, frames.count - 1)]
        guard let img else { return }
        showStill(img)
    }

    private func playVideoIfNeeded(_ name: String, loop: Bool, speed: Double) {
        guard let player = avPlayer else { return }
        // 已经在放这一段：先走最省的那条路（只对一下速率/镜像），别再去解析 URL
        if currentVideoName == name && currentVideoLoop == loop {
            applyVideoMirror()
            if loop {
                if player.rate == 0 { player.rate = Float(speed) }
            } else if !videoFinished && player.rate == 0 {
                player.rate = Float(speed)
            }
            return
        }
        guard let url = Assets.shared.videoURL(name) else {
            xlog("video missing for \(name)")
            return
        }
        if videoLayer?.isHidden != false {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer?.isHidden = false
            CATransaction.commit()
        }
        if let o = endObserver {
            NotificationCenter.default.removeObserver(o)
            endObserver = nil
        }
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
        // 关键：AVPlayerLayer 在换 item 后会残留上一状态的最后一帧，
        // 不清掉就会和新状态的静态首帧叠成「两个角色」
        videoLayer?.player = nil
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 0.5
        currentVideoName = name
        currentVideoLoop = loop
        videoFinished = false
        videoReadySince = 0
        backdropUntil = CFAbsoluteTimeGetCurrent() + 0.28
        if loop {
            looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            // 一次性动作：播完停在最后一帧，不要循环
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.videoFinished = true
                self.finishedStateName = name
                self.avPlayer?.pause()
                self.showStill(Assets.shared.endImage(name))
            }
            player.replaceCurrentItem(with: item)
        }
        videoLayer?.player = player
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.play()
        player.rate = Float(speed)
        applyVideoMirror()
    }

    private func stopVideo() {
        if let o = endObserver {
            NotificationCenter.default.removeObserver(o)
            endObserver = nil
        }
        avPlayer?.pause()
        looper?.disableLooping()
        looper = nil
        avPlayer?.removeAllItems()
        currentVideoName = nil
        currentVideoLoop = false
        videoFinished = false
        videoLayer?.isHidden = true
    }

    /// 静态画面统一走 CALayer，和视频层同一套合成路径
    /// keepVideo=true：静态帧垫在视频层下面当保底，等视频出首帧再撤掉，画面不会空
    private func showStill(_ img: NSImage?, keepVideo: Bool = false) {
        guard let img,
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        // 同一张图已经在显示就别再塞一遍，否则每次 tick 重设 contents 会让图层闪一下
        if stillLayer?.isHidden == false, lastStillImage === img,
           keepVideo || videoLayer?.isHidden == true {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lastStillImage = img
        stillLayer?.contents = cg
        stillLayer?.isHidden = false
        stillLayer?.zPosition = -5
        if !keepVideo {
            videoLayer?.isHidden = true
        }
        videoLayer?.setAffineTransform(CGAffineTransform(scaleX: faceRight ? -1 : 1, y: 1))
        stillLayer?.setAffineTransform(CGAffineTransform(scaleX: faceRight ? -1 : 1, y: 1))
        CATransaction.commit()
        if view.currentImage != nil {
            view.currentImage = nil
            view.needsDisplay = true
        }
    }

    private func hideStill() {
        guard stillLayer?.isHidden == false else {
            lastStillImage = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lastStillImage = nil
        stillLayer?.isHidden = true
        CATransaction.commit()
    }

    /// 转身压扁：视频层与静态层共用同一变换
    private func applyTurnTransform(_ scale: CGFloat) {
        let sx = (faceRight ? -1 : 1) * max(scale, 0.02)
        let tf = CGAffineTransform(scaleX: sx, y: 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer?.setAffineTransform(tf)
        stillLayer?.setAffineTransform(tf)
        CATransaction.commit()
    }

    /// 已暂停就别再发一次 pause()：12Hz 主循环里重复暂停会让解码器反复停/启
    private func pauseVideoIfPlaying() {
        guard let player = avPlayer, player.rate != 0 else { return }
        player.pause()
    }

    private func applyVideoMirror() {
        guard let layer = videoLayer else { return }
        let wanted = faceRight ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        let cur = layer.affineTransform()
        // 12Hz 主循环里每 tick 都写 transform 会白白触发一次 CA 提交
        if abs(cur.a - wanted.a) < 0.0001, abs(cur.b - wanted.b) < 0.0001,
           abs(cur.c - wanted.c) < 0.0001, abs(cur.d - wanted.d) < 0.0001,
           abs(cur.tx - wanted.tx) < 0.0001, abs(cur.ty - wanted.ty) < 0.0001 { return }
        layer.setAffineTransform(wanted)
    }

    private func randomBlink() {
        guard state == .idle, !dragging, !isFocusing else { return }
        blinkStart = CFAbsoluteTimeGetCurrent()
        blinkingUntil = blinkStart + 0.26
    }

    // MARK: 行走

    /// 走路是否该由 60Hz 定时器接管。只在走路时创建，切走就销毁，平时不额外耗电。
    private func syncWalkTimer() {
        let shouldWalk = state == .walk && !dragging && !turning && !isFlying
            && !isDropping && !isFocusing && !isSuspended && !isOccluded
        guard shouldWalk else { stopWalkTimer(); return }
        guard walkTimer == nil else { return }
        lastWalkAt = CFAbsoluteTimeGetCurrent()
        walkAnchorX = petFrame.origin.x
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.walkStep()
        }
        RunLoop.main.add(t, forMode: .common)
        walkTimer = t
    }

    private func stopWalkTimer() {
        guard walkTimer != nil else { return }
        walkTimer?.invalidate()
        walkTimer = nil
        savePosition()
    }

    /// 按真实经过时间位移。原来是 12Hz 下每 tick 挪固定 1.4pt，
    /// 肉眼就是「一格一格」地蹭，而且 Timer 掉一拍就变慢。
    ///
    /// 坑：NSWindow 的 frame 起点会被量化到整点（写入 1249.715，读回 1249.000），
    /// 所以不能拿读回来的窗口坐标当累加器——每步的小数都被丢掉，
    /// 0.28pt 的步进会被截断成整整 1pt，实际速度变成 60pt/s。
    /// 因此另存一个带小数的 walkAnchorX，窗口只负责显示它。
    private func walkStep() {
        guard state == .walk, !dragging, !isFlying, !turning, !isDropping else {
            stopWalkTimer()
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        let dt = min(0.1, max(0, now - lastWalkAt))
        lastWalkAt = now
        guard dt > 0 else { return }

        // 16.8 pt/s：和原来 12Hz × 1.4pt 的设计速度一致，只把步进节奏抹匀
        let speed: CGFloat = 16.8
        var anchor = walkAnchorX + speed * CGFloat(dt) * walkDirection
        guard let screenFrame = (currentScreen() ?? NSScreen.main)?.visibleFrame else { return }
        if anchor < screenFrame.minX {
            anchor = screenFrame.minX
            walkDirection = 1
            faceRight = true
        } else if anchor + petSize > screenFrame.maxX {
            anchor = screenFrame.maxX - petSize
            walkDirection = -1
            faceRight = false
        }
        walkAnchorX = anchor
        setPetOrigin(NSPoint(x: anchor, y: petFrame.origin.y))
    }

    // MARK: 点击穿透 / 滚轮缩放

    /// 素材是 320×320 的方形图，角色只占中间一块，四角是大片纯透明。
    /// 鼠标落在这类像素上时把窗口设成不吃鼠标事件，点击就能落到下面的桌面或窗口。
    /// 判定完全靠自绘的 12Hz 轮询（不依赖全局鼠标监听），失效时最差也只是某块区域点不动。
    /// 上一次命中的条件与结论：鼠标没动、窗口没动、状态没换，结论就一样，
    /// 不用再翻一遍位图。鼠标停在桌宠上不动时这条能省掉全部工作量。
    private var lastHitMouse: NSPoint = NSPoint(x: -10000, y: -10000)
    private var lastHitFrame: NSRect = .zero
    private var lastHitState = ""
    private var lastHitResult = false

    private func updateClickThrough() {
        guard !dragging, !isDropping, !isFlying, !turning, !isFocusing, window.isVisible else {
            setPassThrough(false)
            return
        }
        let mouse = mouseNow
        let wf = petFrame
        guard wf.contains(mouse) else {
            setPassThrough(false)
            lastHitMouse = mouse
            lastHitFrame = wf
            lastHitState = state.rawValue
            lastHitResult = false
            return
        }
        if mouse == lastHitMouse, wf == lastHitFrame, state.rawValue == lastHitState {
            setPassThrough(lastHitResult)
            return
        }
        let result = isTransparent(at: NSPoint(x: mouse.x - wf.minX, y: mouse.y - wf.minY))
        lastHitMouse = mouse
        lastHitFrame = wf
        lastHitState = state.rawValue
        lastHitResult = result
        setPassThrough(result)
    }

    private func setPassThrough(_ on: Bool) {
        guard on != passThrough else { return }
        passThrough = on
        window.ignoresMouseEvents = on
        if ProcessInfo.processInfo.environment["XIEZHI_PASS_LOG"] == "1" {
            let m = NSEvent.mouseLocation
            xlog(String(format: "passthrough=%@ mouse=(%.1f,%.1f) local=(%.1f,%.1f)",
                        on ? "on" : "off", m.x, m.y,
                        m.x - petFrame.minX, m.y - petFrame.minY))
        }
    }

    /// 窗口内某点是不是全透明（坐标是窗口内的点，原点在左下）
    private func isTransparent(at p: NSPoint) -> Bool {
        guard let (data, w, h) = alphaBuffer() else { return false }
        let size = petFrame.size
        guard size.width > 1, size.height > 1 else { return false }
        var u = p.x / size.width
        if faceRight { u = 1 - u }              // 朝右时图层是镜像的
        let v = 1 - p.y / size.height            // 视图非翻转，y=0 在底部；位图第 0 行是顶部
        let px = Int(u * CGFloat(w))
        let py = Int(v * CGFloat(h))
        guard px >= 0, px < w, py >= 0, py < h else { return true }
        return data[(py * w + px) * 4 + 3] < 8
    }

    /// 当前状态首帧的 RGBA 位图，只缓存一张（换状态才重建）。320×320 约 400KB。
    /// 尺寸没变时复用同一块像素内存：换状态只重画，不再每回 malloc 400KB。
    private func alphaBuffer() -> (UnsafeMutablePointer<UInt8>, Int, Int)? {
        let key = state.rawValue
        if alphaRepKey == key, let rep = alphaRep, let d = rep.bitmapData {
            return (d, rep.pixelsWide, rep.pixelsHigh)
        }
        let still = "still/\(key).png"
        let fallback = anim.folder + "/" + (anim.files.first ?? "")
        guard let img = Assets.shared.image(still) ?? Assets.shared.image(fallback),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        let rep: NSBitmapImageRep
        if let old = alphaRep, old.pixelsWide == w, old.pixelsHigh == h, old.bitmapData != nil {
            rep = old
        } else if let fresh = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                               isPlanar: false, colorSpaceName: .deviceRGB,
                                               bytesPerRow: w * 4, bitsPerPixel: 32) {
            rep = fresh
        } else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.cgContext.clear(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        NSGraphicsContext.restoreGraphicsState()
        alphaRep = rep
        alphaRepKey = key
        guard let d = rep.bitmapData else { return nil }
        return (d, w, h)
    }

    // MARK: 随机行为

    private func idleBehavior() {
        if benchMode { return }
        manualAction = false
        if isSuspended { return }
        if CFAbsoluteTimeGetCurrent() < manualHoldUntil { return }
        guard state == .idle, !dragging, !isFocusing else { return }
        // 长时间没人理 -> 打瞌睡
        if CFAbsoluteTimeGetCurrent() - lastInteractionAt > 95 {
            setState(.sleep)
            return
        }
        let roll = Int.random(in: 0..<100)
        if roll < 26 {
            guard allowWalk else { setState(.daze); return }
            let dir: CGFloat = Bool.random() ? -1 : 1
            walkDirection = dir
            faceRight = dir > 0
            setState(.walk)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(Int.random(in: 6...14))) { [weak self] in
                guard let self, self.state == .walk else { return }
                self.finishWithTurn(to: .idle)
            }
        } else if roll < 40 {
            setState(.daze)
        } else if roll < 52 {
            setState(.yawn)
        } else if roll < 62 {
            setState(.tail)
        } else if roll < 69 {
            setState(.play)
        } else if roll < 75 {
            setState(.stretch)
        } else if roll < 82 {
            setState(.wave)
        } else if roll < 87 {
            setState(.pounce)
        } else if roll < 91 {
            setState(.gavel)
        } else if roll < 94 {
            setState(.groom)
        } else if roll < 98 {
            setState(.fish)
        } else {
            guard allowTalk else { setState(.daze); return }
            speakLines()
            setState(.tablet)
        }
    }

    // MARK: 交互

    /// 弹气泡的统一入口。宠物被「显示/隐藏」藏起来时不要弹：
    /// 气泡是独立窗口，看不见宠物却飘着一个气泡很奇怪。
    private func showBubble(_ text: String, above frame: NSRect) {
        guard window.isVisible else { return }
        bubble.show(text, above: frame)
    }

    /// 说一句话。台词可能来自 Lawlearn 法条查询（异步），所以气泡晚一点才弹；
    /// 回包时如果又说了别的，旧结果直接丢掉。
    private func speakLines() {
        talkToken &+= 1
        let token = talkToken
        Lines.next { [weak self] text in
            guard let self, self.talkToken == token else { return }
            self.showBubble(text, above: self.petFrame)
        }
    }

    func beginDrag() {
        cancelTurn()
        if isDropping {
            dropTimer?.invalidate()
            dropTimer = nil
            isDropping = false
        }
        lastInteractionAt = CFAbsoluteTimeGetCurrent()
        // 弹跳中点击 = 一把抓住
        if isFlying { stopFlying(landed: false, silent: true) }
        isSuspended = false
        dragging = true
        dragDistance = 0
        dragSamples.removeAll()
        lastMousePoint = NSEvent.mouseLocation
        if state != .hide && state != .hideWait { setState(.lift) }
    }

    func drag() {
        guard dragging else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - lastMousePoint.x
        let dy = mouse.y - lastMousePoint.y
        dragDistance += abs(dx) + abs(dy)
        lastMousePoint = mouse
        var origin = petFrame.origin
        origin.x += dx
        origin.y += dy
        setPetOrigin(origin)
        bubble.follow(petFrame)

        // 记录最近一小段位移，松手时换算成甩出速度
        dragSamples.append((CFAbsoluteTimeGetCurrent(), petFrame.origin))
        while dragSamples.count > 32 { dragSamples.removeFirst() }
    }

    func endDrag() {
        guard dragging else { return }
        dragging = false
        if dragDistance < 6 {
            pat()
            return
        }
        if let f = (currentScreen() ?? NSScreen.main)?.visibleFrame {
            var origin = petFrame.origin
            origin.y = max(f.minY, min(origin.y, f.maxY - petSize))
            origin.x = max(f.minX, min(origin.x, f.maxX - petSize))
            setPetOrigin(origin)
        }
        savePosition()
        // 甩得够快就进入皮球模式
        let v = releaseVelocity()
        xlog("release v=(\(Int(v.x)),\(Int(v.y)) pt/s dist=\(Int(dragDistance))")
        if abs(v.x) > 90 || abs(v.y) > 90 {
            isSuspended = false
            startFlying(vx: v.x, vy: v.y)
            return
        }
        // 没甩：在空中就立刻缓落回地面，别停在半空
        let ground = (currentScreen() ?? NSScreen.main)?.visibleFrame.minY ?? 0
        isSuspended = false
        if petFrame.minY > ground + 40 {
            if state != .hide && state != .hideWait { setState(.lift) }
            dropToGround()
        } else {
            setState(.land)
        }
    }

    /// 用松手前 ~0.12 秒的位移换算速度（pt/s）；松手前有短暂停顿就视为停住，不甩
    private func releaseVelocity() -> NSPoint {
        let now = CFAbsoluteTimeGetCurrent()
        guard let last = dragSamples.last else { return .zero }
        // 1) 最后一次拖动事件距今超过 80ms = 手停住了，直接不甩
        if now - last.t > 0.08 { return .zero }
        // 2) 松手前 80ms 内位移不到 4pt = 停住了
        let recent = dragSamples.filter { now - $0.t <= 0.08 }
        if let f = recent.first {
            let moved = hypot(last.origin.x - f.origin.x, last.origin.y - f.origin.y)
            if moved < 4 { return .zero }
        }
        // 3) 剩下的才按最近 120ms 的平均速度甩
        let window: [(t: CFAbsoluteTime, origin: NSPoint)] = dragSamples.filter { now - $0.t <= 0.12 }
        guard let first = window.first, last.t - first.t > 0.02, window.count >= 2 else { return .zero }
        let dt = CGFloat(last.t - first.t)
        var vx = (last.origin.x - first.origin.x) / dt
        var vy = (last.origin.y - first.origin.y) / dt
        let limit: CGFloat = 1600
        vx = max(-limit, min(limit, vx * 1.15))
        vy = max(-limit, min(limit, vy * 1.15))
        return NSPoint(x: vx, y: vy)
    }

    /// 一次性动作播完别硬切回待机，先让纸片翻个身
    private func finishWithTurn(to target: PetState) {
        guard !turning, state != target else {
            if state == target { return }
            return
        }
        turning = true
        turnApplied = false
        turnStart = CFAbsoluteTimeGetCurrent()
        turnTarget = target
        manualAction = false
        turnTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self, self.turning else { return }
            self.stepTurn(now: CFAbsoluteTimeGetCurrent())
            if !self.turning {
                self.turnTimer?.invalidate()
                self.turnTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        turnTimer = timer
        avPlayer?.pause()
        if stillLayer?.isHidden != false {
            if let img = Assets.shared.endImage(state.rawValue) {
                showStill(img)
            } else if let img = frames.first {
                showStill(img)
            }
        }
        view.needsDisplay = true
    }

    private func cancelTurn() {
        guard turning else { return }
        turning = false
        turnTimer?.invalidate()
        turnTimer = nil
        view.flipScale = 1
        if !turnApplied {
            turnApplied = true
            setState(turnTarget)
        }
        view.needsDisplay = true
    }

    private func stepTurn(now: CFAbsoluteTime) {
        let t = min(1.0, (now - turnStart) / turnDuration)
        var scale: CGFloat
        if t < 0.5 {
            scale = CGFloat(1 - t * 2)
            applyTurnTransform(scale)
        } else {
            if !turnApplied {
                turnApplied = true
                setState(turnTarget)
                applyStateMedia(turnTarget)
            }
            scale = CGFloat((t - 0.5) * 2)
            applyTurnTransform(scale)
        }
        if ProcessInfo.processInfo.environment["XIEZHI_TURN_LOG"] == "1" {
            xlog(String(format: "turn t=%.2f scale=%.2f", t, Double(scale)))
        }
        if t >= 1 {
            turning = false
            applyTurnTransform(1.0)
            view.flipScale = 1
            view.needsDisplay = true
            if ProcessInfo.processInfo.environment["XIEZHI_TURN_LOG"] == "1" {
                xlog(String(format: "turn done in %.3fs", CFAbsoluteTimeGetCurrent() - turnStart))
            }
        }
    }

    /// 转身中点切换目标状态的画面（视频或静图）
    private func applyStateMedia(_ st: PetState) {
        let a = Catalog.anims[st] ?? Catalog.fallbackIdle
        if Assets.shared.videoURL(st.rawValue) != nil {
            if let still = Assets.shared.image("still/\(st.rawValue).png") {
                showStill(still)
            }
            playVideoIfNeeded(st.rawValue, loop: a.loop, speed: a.speed)
            avPlayer?.rate = Float(a.speed)
            backdropUntil = CFAbsoluteTimeGetCurrent() + 0.28
        } else if let img = Assets.shared.image(a.folder + "/" + (a.files.first ?? "")) {
            showStill(img)
        }
    }

    /// 悬空太久时缓缓落回地面，落地播 land
    private func dropToGround() {
        guard !isDropping else { return }
        isDropping = true
        isSuspended = false
        view.contentOffset = .zero
        view.needsDisplay = true
        guard let screen = currentScreen() ?? NSScreen.main else {
            isDropping = false
            return
        }
        let ground = screen.visibleFrame.minY
        let startY = petFrame.minY
        if ground >= startY - 1 {
            isDropping = false
            setState(.land)
            return
        }
        // 自己逐帧推进下落：NSAnimationContext 会被主循环里的 setFrameOrigin 打断，
        // 打断后 completionHandler 不保证回调，角色就会永远停在半空末帧。
        let t0 = CFAbsoluteTimeGetCurrent()
        let duration: Double = 0.55
        dropTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let p = min(1.0, (CFAbsoluteTimeGetCurrent() - t0) / duration)
            let eased = CGFloat(p * p)
            var f = self.petFrame
            f.origin.y = startY + (ground - startY) * eased
            self.setPetOrigin(f.origin)
            self.render()
            if p >= 1.0 {
                timer.invalidate()
                self.dropTimer = nil
                self.isDropping = false
                self.setState(.land)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dropTimer = timer
    }

    // MARK: 皮球弹跳

    /// 弹跳边界：横向允许跨越所有屏幕，纵向按窗口中心所在那块屏算
    private func playBounds() -> (minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat) {
        // 缓存 0.3 秒：屏幕布局不会在 60Hz 上变；跨屏后最多 0.3 秒拿到新边界，看不出来
        let nowB = CFAbsoluteTimeGetCurrent()
        if let c = boundsCache, nowB - boundsCacheAt < 0.3 {
            return c
        }
        let screens = NSScreen.screens
        let center = NSPoint(x: petFrame.midX, y: petFrame.midY)
        let current = screens.first { $0.frame.contains(center) }
            ?? screens.min { hypot($0.frame.midX - center.x, $0.frame.midY - center.y)
                < hypot($1.frame.midX - center.x, $1.frame.midY - center.y) }
            ?? NSScreen.main
        let gMinX = screens.map { $0.visibleFrame.minX }.min() ?? 0
        let gMaxX = screens.map { $0.visibleFrame.maxX }.max() ?? 1470
        let f = current?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1470, height: 923)
        let result = (gMinX, gMaxX, f.minY, f.maxY)
        boundsCache = result
        boundsCacheAt = nowB
        return result
    }

    /// 屏幕参数变了：缓存立刻作废（不靠 0.3 秒自然过期）
    private func invalidateBoundsCache() {
        boundsCache = nil
    }

    private func startFlying(vx: CGFloat, vy: CGFloat) {
        stopFlying(landed: false, silent: true)
        isFlying = true
        flyStartedAt = CFAbsoluteTimeGetCurrent()
        lastPhysicsAt = flyStartedAt
        velX = vx
        velY = vy
        flyScreen = currentScreen() ?? NSScreen.main
        flyTraceCount = 0
        if ProcessInfo.processInfo.environment["XIEZHI_FLY_TRACE"] == "1" {
            flyTraceFile = nil
            FileManager.default.createFile(atPath: "/tmp/xiezhi_fly.csv", contents: nil)
            flyTraceFile = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/xiezhi_fly.csv"))
            flyTraceFile?.write("t,x,y,vx,vy,bounce\n".data(using: .utf8)!)
        }
        xlog(String(format: "fly start vx=%.0f vy=%.0f screen=%@", vx, vy,
                    (flyScreen?.visibleFrame).debugDescription))

        // 空中姿态沿用「被拎起」的循环帧
        setState(.lift)
        if let f = Catalog.anims[.lift]?.files {
            anim = Animation(folder: "02_lift", files: f, fps: 11.0, loop: true, hold: 0)
            frames = Assets.shared.frames(anim)
        }
        faceRight = vx > 0

        physicsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.physicsStep()
        }
        if let t = physicsTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func physicsStep() {
        guard isFlying else { return }
        // 用真实经过时间推进：Timer 掉帧时不再变成慢动作，卡顿时也不会一次跳很远
        let nowPhysics = CFAbsoluteTimeGetCurrent()
        let dt: CGFloat = min(1.0 / 30.0, max(1.0 / 240.0, CGFloat(nowPhysics - lastPhysicsAt)))
        lastPhysicsAt = nowPhysics
        let gravity: CGFloat = 900          // pt/s²
        let maxSeconds: CFAbsoluteTime = 9  // 兜底，别一直弹

        velY -= gravity * dt
        let b = playBounds()
        let onGroundNow = petFrame.minY <= b.minY + 0.5
        // 空中几乎无阻力，贴地滚动时摩擦明显，避免横着滑很久
        velX *= onGroundNow ? 0.90 : 0.999

        var origin = petFrame.origin
        origin.x += velX * dt
        origin.y += velY * dt

        var bounced = false
        // 左右：允许跨屏，用所有屏幕横向并集
        if origin.x < b.minX {
            origin.x = b.minX
            if velX < 0 { velX = -velX * 0.80; bounced = true }
        } else if origin.x + petSize > b.maxX {
            origin.x = b.maxX - petSize
            if velX > 0 { velX = -velX * 0.80; bounced = true }
        }
        // 上下：按当前所在那块屏的地面与顶边
        if origin.y + petSize > b.maxY {
            origin.y = b.maxY - petSize
            if velY > 0 { velY = -velY * 0.62; bounced = true }
        }
        if origin.y < b.minY {
            origin.y = b.minY
            if velY < 0 {
                // 落地：吸收大部分竖直速度，水平摩擦衰减
                velY = (abs(velY) < 130) ? 0 : -velY * 0.72
                velX *= 0.88
                bounced = true
            }
        }
        setPetOrigin(origin)
        if abs(velX) > 60 { faceRight = velX > 0 }

        if let fh = flyTraceFile {
            flyTraceCount += 1
            let line = String(format: "%.3f,%.1f,%.1f,%.1f,%.1f,%d\n",
                              CFAbsoluteTimeGetCurrent() - flyStartedAt, origin.x, origin.y, velX, velY, bounced ? 1 : 0)
            fh.write(line.data(using: .utf8)!)
        }

        // 停下：贴底且水平很慢，或速度已经几乎没有
        let onGround = origin.y <= b.minY + 0.5
        let slow = abs(velY) < 30 && abs(velX) < 45
        if (onGround && slow) || CFAbsoluteTimeGetCurrent() - flyStartedAt > maxSeconds {
            stopFlying(landed: true, silent: false)
        }
    }

    private func stopFlying(landed: Bool, silent: Bool) {
        physicsTimer?.invalidate()
        physicsTimer = nil
        flyTraceFile?.closeFile()
        flyTraceFile = nil
        guard isFlying || !silent else { return }
        isFlying = false
        if landed {
            let b = playBounds()
            var origin = petFrame.origin
            origin.y = max(b.minY, min(origin.y, b.maxY - petSize))
            origin.x = max(b.minX, min(origin.x, b.maxX - petSize))
            setPetOrigin(origin)
            isSuspended = false
            faceRight = false
            setState(.land)
            xlog(String(format: "fly end at (%.0f, %.0f) after %.2fs", petFrame.minX, petFrame.minY,
                        CFAbsoluteTimeGetCurrent() - flyStartedAt))
        } else if !silent {
            setState(.idle)
        }
    }

    func pat() {
        lastInteractionAt = CFAbsoluteTimeGetCurrent()
        if state == .hide || state == .hideWait { setState(.idle); return }
        manualAction = true
        setState(.pat)
        // 摸头也有台词，同样要受「允许自言自语」约束
        if allowTalk, Bool.random() { speakLines() }
    }

    /// 打开或关闭 Lawlearn 联动
    func setLawlearnLinked(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "lawlearnLinked")
        if on {
            Lawlearn.shared.connect()
        } else {
            Lawlearn.shared.close()
        }
    }

    /// 测试用：暴露专注会话号
    var studySessionForTest: Int { studySession }
    var isFocusingForTest: Bool { isFocusing }
    var stateForTest: String { state.rawValue }

    /// 测试用：验证 Lawlearn 检测与联动开关
    func testLawToggle() {
        xlog("law test: installed=\(Lawlearn.installed) linked=\(Lawlearn.linked) connected=\(Lawlearn.shared.connected)")
        setLawlearnLinked(false)
        xlog("law test: after off -> linked=\(Lawlearn.linked) connected=\(Lawlearn.shared.connected)")
        setLawlearnLinked(true)
        xlog("law test: after on -> linked=\(Lawlearn.linked) connected=\(Lawlearn.shared.connected)")
    }

    /// 测试用：直接把角色抬到半空并当成“松手后悬停”
    func testSuspend() {        guard let screen = currentScreen() ?? NSScreen.main else { return }
        var f = petFrame
        f.origin.y = screen.visibleFrame.minY + 300
        setPetOrigin(f.origin)
        isSuspended = false
        setState(.lift)
        xlog("[XiezhiPet] test suspend at y=\(Int(f.origin.y))")
        dropToGround()
    }

    /// 测试用：按“用户手动点动作”的路径播一次
    func testManualAction(_ st: PetState) {
        manualAction = true
        setState(st)
    }

    // MARK: 控制台设置

    func resize(to size: CGFloat) {
        let clamped = max(120, min(360, size))
        let old = petFrame
        petSize = clamped
        let rect = NSRect(x: old.midX - clamped / 2, y: old.minY, width: clamped, height: clamped)
        setPetFrame(rect, display: true)
        view.frame = NSRect(x: 0, y: 0, width: clamped, height: clamped)
        videoLayer?.frame = NSRect(x: 0, y: 0, width: clamped, height: clamped)
        stillLayer?.frame = NSRect(x: 0, y: 0, width: clamped, height: clamped)   // 静态层不跟着改尺寸，切到静图时大小会跳
        clampToScreen()
        UserDefaults.standard.set(Double(clamped), forKey: "petSize")
        xlog("resize -> view=\(view.frame.size) video=\(videoLayer?.frame.size ?? .zero) still=\(stillLayer?.frame.size ?? .zero)")
        updateImage()
    }

    func setBehaviorInterval(_ seconds: TimeInterval) {
        behaviorInterval = max(3, min(120, seconds))
        UserDefaults.standard.set(behaviorInterval, forKey: "behaviorInterval")
        behaviorTimer?.invalidate()
        behaviorTimer = nil
        startBehaviorTimer()
    }

    func setAllowWalk(_ v: Bool) {
        allowWalk = v
        UserDefaults.standard.set(v, forKey: "allowWalk")
    }

    func setAllowTalk(_ v: Bool) {
        allowTalk = v
        UserDefaults.standard.set(v, forKey: "allowTalk")
    }

    func setEyeTracking(_ v: Bool) {
        eyeTracking = v
        UserDefaults.standard.set(v, forKey: "eyeTracking")
    }

    func setLawRatio(_ v: Double) {
        lawRatio = max(0, min(1, v))
        UserDefaults.standard.set(lawRatio, forKey: "lawRatio")
    }

    private func clampToScreen() {
        guard let f = (currentScreen() ?? NSScreen.main)?.visibleFrame else { return }
        var o = petFrame.origin
        o.x = max(f.minX, min(o.x, f.maxX - petSize))
        o.y = max(f.minY, min(o.y, f.maxY - petSize))
        setPetOrigin(o)
    }

    // MARK: 动作预览

    /// 手动播动作用的分组，控制台「动作预览」下拉就是按这个排的。
    /// 取值和顺序沿用原右键菜单，省得改了之后找不到某个动作。
    static let actionGroups: [(String, [(String, PetState)])] = [
        ("日常", [("发呆", .daze), ("打哈欠", .yawn), ("甩尾", .tail), ("打滚", .play),
                  ("伸懒腰", .stretch), ("挥手", .wave), ("扑跳", .pounce),
                  ("蹲起", .squat), ("睡着", .sleep), ("摸头", .pat),
                  ("缩成毛球", .hide)]),
        ("学习", [("抱平板", .tablet), ("专注看书", .study), ("敲法槌", .gavel),
                  ("敲键盘", .type), ("翻页", .page), ("记笔记", .note)]),
        ("吃喝玩", [("舔毛", .groom), ("小鱼干", .fish), ("走路", .walk),
                    ("待机", .idle), ("被拎起", .lift), ("落地", .land)])
    ]

    /// 手动播一个动作。控制台的「动作预览」下拉选中哪项就走这里。
    func playAction(_ st: PetState) {
        lastInteractionAt = CFAbsoluteTimeGetCurrent()
        // 手动选的动作先播完，别被定时的自动行为立刻顶掉
        manualHoldUntil = CFAbsoluteTimeGetCurrent() + 6
        manualAction = true
        xlog("action: 手动播 \(st.rawValue)")
        switch st {
        case .study:
            startStudy()
        case .walk:
            walkDirection = Bool.random() ? -1 : 1
            faceRight = walkDirection > 0
            setState(.walk)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.state == .walk else { return }
                self.setState(.idle)
            }
        default:
            setState(st)
        }
    }

    /// 回到默认的右下角（位置会被记住，下次启动也在这儿）
    func goHome() {
        lastInteractionAt = CFAbsoluteTimeGetCurrent()
        moveToDefaultPosition()
        savePosition()
        showBubble("回老位置啦", above: petFrame)
    }

    func startStudy() {
        // 已经在专注就别再挂一个 25 分钟定时器，否则多份回调同时到点会来回切状态
        guard !isFocusing else {
            showBubble("已经在专注啦", above: petFrame)
            return
        }
        isFocusing = true
        studySession += 1
        let session = studySession
        setState(.study)
        showBubble(Lines.focusStart, above: petFrame)
        DispatchQueue.main.asyncAfter(deadline: .now() + 25 * 60) { [weak self] in
            guard let self, self.studySession == session else { return }
            self.isFocusing = false
            self.setState(.play)
            // 到点得让人听得见：宠物可能被别的窗口挡住，光弹气泡容易被漏看
            if focusChime == nil { focusChime = NSSound(named: "Glass") }
            focusChime?.play()
            self.showBubble(Lines.focusEnd, above: self.petFrame)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5 * 60) { [weak self] in
                guard let self, self.state == .play else { return }
                self.setState(.idle)
            }
        }
    }

    func stopStudy() {
        guard isFocusing else { return }
        isFocusing = false
        studySession += 1
        lastInteractionAt = CFAbsoluteTimeGetCurrent()
        setState(.idle)
    }

    func toggleVisible() {
        if window.isVisible {
            window.orderOut(nil)
            // 藏起来以后眨眼和随机行为都没意义，定时器一起停掉，减少无谓唤醒；
            // 重新显示时再挂回去（频率与容差沿用原来的口径）
            blinkTimer?.invalidate()
            blinkTimer = nil
            behaviorTimer?.invalidate()
            behaviorTimer = nil
            stopWalkTimer()
            pauseVideoIfPlaying()
        } else {
            window.orderFrontRegardless()
            startBlinkTimer()
            startBehaviorTimer()
            tickHz = 0          // 逼下一拍 setTickHz 把 12Hz 挂回来
            tick()
        }
    }

    private func startBlinkTimer() {
        guard blinkTimer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 5.5, repeats: true) { [weak self] _ in
            self?.randomBlink()
        }
        t.tolerance = 0.8
        RunLoop.main.add(t, forMode: .common)
        blinkTimer = t
    }

    private func startBehaviorTimer() {
        guard behaviorTimer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: behaviorInterval, repeats: true) { [weak self] _ in
            self?.idleBehavior()
        }
        t.tolerance = min(2.0, behaviorInterval * 0.2)
        RunLoop.main.add(t, forMode: .common)
        behaviorTimer = t
    }

    func testFly() {
        startFlying(vx: -760, vy: 640)
    }

    func say() {
        lastInteractionAt = CFAbsoluteTimeGetCurrent()
        speakLines()
        // 专注中只说话，不抢走看书状态；已经在抱平板就只换台词，避免反复重建视频
        if isFocusing || state == .study || state == .tablet { return }
        setState(.tablet)
    }
}


// MARK: - 控制台（菜单栏点开）

/// 顶部为原点的容器：控制台里的 frame 都按「距顶部多少」写，跟读稿顺序一致。
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class ConsoleWindow: NSObject, NSWindowDelegate {
    private weak var controller: PetController?
    private var window: NSPanel?
    private var sizeSlider: NSSlider!
    private var sizeValue: NSTextField!
    private var intervalSlider: NSSlider!
    private var intervalValue: NSTextField!
    private var lawSlider: NSSlider!
    private var lawValue: NSTextField!
    private var walkCheck: NSButton!
    private var talkCheck: NSButton!
    private var eyeCheck: NSButton!
    private var lawCheck: NSButton!
    /// 动作预览的三个下拉（日常 / 学习 / 吃喝玩）
    private var actionPopups: [NSPopUpButton] = []
    /// 快捷操作按钮，按 tag 存取（显示/隐藏那只要跟着宠物可见状态改标题）
    private var quickButtons: [Int: NSButton] = [:]

    init(controller: PetController) {
        self.controller = controller
        super.init()
        build()
    }

    // 面板里的坐标一律「从上往下」：内容视图是 FlippedView，y=0 在顶部，
    // 每块控件的位置由 cursor 依次累加。原来每个控件手写一个 y，改一行文案就得
    // 连着挪下面十几行，很容易压在一起；现在加东西只会在下面顺延。
    private let panelWidth: CGFloat = 440
    private let margin: CGFloat = 24

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                          color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    private func makeSeparator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    private func build() {
        let W = panelWidth
        let M = margin
        let CW = W - M * 2

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: 700),
                            styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
        panel.title = "Scheng · 控制台"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.delegate = self
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: W, height: 700))
        panel.contentView = content

        var y: CGFloat = 18
        // 占一行：返回这一行的顶部 y，并把 cursor 推到下一行
        func take(_ h: CGFloat, _ gap: CGFloat) -> CGFloat {
            let top = y
            y += h + gap
            return top
        }
        // 小节标题 + 右侧数值
        func header(_ title: String, value: NSTextField) {
            let top = take(19, 4)
            let t = makeLabel(title, size: 13, weight: .semibold)
            t.frame = NSRect(x: M, y: top, width: 200, height: 18)
            content.addSubview(t)
            value.alignment = .right
            value.font = NSFont.systemFont(ofSize: 12)
            value.textColor = .secondaryLabelColor
            value.frame = NSRect(x: M, y: top, width: CW, height: 18)
            content.addSubview(value)
        }
        // 灰色小字说明
        func caption(_ s: String, gap: CGFloat = 10) {
            let top = take(15, gap)
            let l = makeLabel(s, size: 11, color: .secondaryLabelColor)
            l.frame = NSRect(x: M, y: top + 1, width: CW, height: 15)
            content.addSubview(l)
        }
        func sliderRow(_ s: NSSlider, gap: CGFloat) {
            let top = take(20, gap)
            s.frame = NSRect(x: M, y: top, width: CW, height: 20)
            content.addSubview(s)
        }
        func checkRow(_ b: NSButton, gap: CGFloat) {
            let top = take(22, gap)
            b.font = NSFont.systemFont(ofSize: 12)
            b.frame = NSRect(x: M - 2, y: top, width: CW + 4, height: 22)
            content.addSubview(b)
        }
        // 分隔线：上下各留一点气口
        func rule(gap: CGFloat = 14) {
            let top = take(15, gap)
            let s = makeSeparator()
            s.frame = NSRect(x: M, y: top + 6, width: CW, height: 1)
            content.addSubview(s)
        }
        func buttonRow(_ items: [(String, Int)], gap: CGFloat) {
            let spacing: CGFloat = 8
            let n = CGFloat(items.count)
            let bw = (CW - spacing * (n - 1)) / n
            let top = take(28, gap)
            for (i, item) in items.enumerated() {
                let b = NSButton(title: item.0, target: self, action: #selector(quickAction(_:)))
                b.tag = item.1
                b.bezelStyle = .rounded
                b.font = NSFont.systemFont(ofSize: 12)
                b.frame = NSRect(x: M + CGFloat(i) * (bw + spacing), y: top, width: bw, height: 28)
                quickButtons[item.1] = b
                content.addSubview(b)
            }
        }

        // ── 顶部说明
        do {
            let top = take(16, 16)
            let l = makeLabel("左键拖拽搬家 · 轻点摸头 · 所有设置自动保存", size: 12, color: .secondaryLabelColor)
            l.frame = NSRect(x: M, y: top, width: CW, height: 16)
            content.addSubview(l)
        }

        // ── 角色大小
        sizeValue = makeLabel("", size: 12)
        header("角色大小", value: sizeValue)
        sizeSlider = NSSlider(value: 240, minValue: 120, maxValue: 360, target: self, action: #selector(sizeChanged))
        sizeSlider.isContinuous = true
        sliderRow(sizeSlider, gap: 8)

        do {
            let presets: [(String, CGFloat)] = [("迷你", 140), ("小", 180), ("标准", 240), ("大", 320)]
            let spacing: CGFloat = 8
            let bw = (CW - spacing * 3) / 4
            let top = take(26, 16)
            for (i, p) in presets.enumerated() {
                let b = NSButton(title: p.0, target: self, action: #selector(presetTapped(_:)))
                b.tag = Int(p.1)
                b.bezelStyle = .rounded
                b.font = NSFont.systemFont(ofSize: 12)
                b.frame = NSRect(x: M + CGFloat(i) * (bw + spacing), y: top, width: bw, height: 26)
                content.addSubview(b)
            }
        }
        rule()

        // ── 桌面行为
        intervalValue = makeLabel("", size: 12)
        header("活动频率", value: intervalValue)
        intervalSlider = NSSlider(value: 9, minValue: 3, maxValue: 60, target: self, action: #selector(intervalChanged))
        intervalSlider.isContinuous = true
        sliderRow(intervalSlider, gap: 4)
        caption("数值越大越安静：3 秒最活跃，60 秒基本不动", gap: 8)

        walkCheck = NSButton(checkboxWithTitle: "允许在桌面上走动", target: self, action: #selector(walkToggled(_:)))
        checkRow(walkCheck, gap: 3)
        talkCheck = NSButton(checkboxWithTitle: "允许自言自语（含法条）", target: self, action: #selector(talkToggled(_:)))
        checkRow(talkCheck, gap: 3)
        eyeCheck = NSButton(checkboxWithTitle: "眼神跟着鼠标走", target: self, action: #selector(eyeToggled(_:)))
        checkRow(eyeCheck, gap: 14)
        rule()

        // ── 法条台词
        lawValue = makeLabel("", size: 12)
        header("法条台词占比", value: lawValue)

        lawCheck = NSButton(checkboxWithTitle: "与 Lawlearn 联动", target: self, action: #selector(lawLinkToggled(_:)))
        checkRow(lawCheck, gap: 4)
        lawSlider = NSSlider(value: 40, minValue: 0, maxValue: 100, target: self, action: #selector(lawChanged))
        lawSlider.isContinuous = true
        sliderRow(lawSlider, gap: 4)
        caption("连着 Lawlearn 时，说话有多大比例是念法条", gap: 14)
        rule()

        // ── 动作预览：三组各一个小下拉，每个最多 11 项，不用滚动。
        do {
            let top = take(19, 10)
            let t = makeLabel("动作预览", size: 13, weight: .semibold)
            t.frame = NSRect(x: M, y: top, width: 200, height: 18)
            content.addSubview(t)

            actionPopups = []
            let spacing: CGFloat = 8
            let bw = (CW - spacing * 2) / 3
            let popTop = take(26, 6)
            for (i, group) in PetController.actionGroups.enumerated() {
                let pop = NSPopUpButton(frame: NSRect(x: M + CGFloat(i) * (bw + spacing), y: popTop,
                                                      width: bw, height: 26),
                                        pullsDown: false)
                pop.bezelStyle = .rounded
                pop.font = NSFont.systemFont(ofSize: 12)
                pop.addItem(withTitle: group.0)
                pop.menu?.addItem(.separator())
                for (title, st) in group.1 {
                    let item = NSMenuItem(title: title, action: #selector(actionChosen(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = i
                    item.representedObject = st.rawValue
                    pop.menu?.addItem(item)
                }
                // 第一项只是组名，不能点。autoenablesItems 必须关掉，
                // 否则菜单一弹出 AppKit 会按 target 校验把 isEnabled=false 又改回 true（踩过）。
                pop.menu?.autoenablesItems = false
                pop.item(at: 0)?.isEnabled = false
                pop.selectItem(at: 0)
                actionPopups.append(pop)
                content.addSubview(pop)
            }
        }
        caption("点两下宠物、或选「待机」就回到默认动作", gap: 14)
        rule()

        // ── 快捷操作：菜单栏原来那几项都在这儿，退出也在这一屏里
        do {
            let top = take(19, 10)
            let t = makeLabel("快捷操作", size: 13, weight: .semibold)
            t.frame = NSRect(x: M, y: top, width: 200, height: 18)
            content.addSubview(t)
        }
        buttonRow([("说句话", 0), ("专注 25 分钟", 1), ("结束专注", 2)], gap: 8)
        buttonRow([("回到右下角", 3), ("显示 / 隐藏", 4), ("退出 Scheng", 5)], gap: 10)
        caption("退出后桌宠和菜单栏天平图标一起关掉，下次从启动台再打开", gap: 0)

        // 面板高度按实际内容收尾，不留多余空白
        let h = y + 16
        content.frame = NSRect(x: 0, y: 0, width: W, height: h)
        panel.setContentSize(NSSize(width: W, height: h))

        window = panel
        syncFromController()
    }

    private func syncFromController() {
        guard let c = controller else { return }
        sizeSlider.doubleValue = Double(c.petSize)
        sizeValue.stringValue = "\(Int(c.petSize)) px"
        intervalSlider.doubleValue = c.behaviorInterval
        intervalValue.stringValue = String(format: "每 %.0f 秒动一次", c.behaviorInterval)
        lawSlider.doubleValue = c.lawRatio * 100
        if !Lawlearn.installed {
            lawSlider.isEnabled = false
            lawValue.stringValue = "本机未安装"
        } else if !Lawlearn.linked {
            lawSlider.isEnabled = false
            lawValue.stringValue = "已关闭联动"
        } else {
            lawSlider.isEnabled = true
            lawValue.stringValue = "\(Int(c.lawRatio * 100))%"
        }
        walkCheck.state = c.allowWalk ? .on : .off
        talkCheck.state = c.allowTalk ? .on : .off
        eyeCheck.state = c.eyeTracking ? .on : .off
        lawCheck.state = Lawlearn.linked ? .on : .off
        lawCheck.isEnabled = Lawlearn.installed
    }

    func show() {
        syncFromController()
        syncVisibleButton()
        guard let w = window else { return }
        placeConsole(w)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        xlog("console shown frame=\(w.frame) visible=\(w.isVisible) key=\(w.isKeyWindow)")
    }

    /// 控制台位置：挪过就记住，没挪过（或那位置已经不在任何屏幕上）才居中到宠物所在那块屏。
    /// 原来每次打开都强制居中，挪开了下次又跑回中间。
    private func placeConsole(_ w: NSWindow) {
        let d = UserDefaults.standard
        if d.object(forKey: "consoleX") != nil, d.object(forKey: "consoleY") != nil {
            let p = NSPoint(x: d.double(forKey: "consoleX"), y: d.double(forKey: "consoleY"))
            let probe = NSRect(origin: p, size: w.frame.size).insetBy(dx: 40, dy: 40)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(probe) }) {
                w.setFrameOrigin(p)
                clampToScreen(w)
                return
            }
        }
        let screen = controller?.window.screen ?? NSScreen.main
        if let f = screen?.visibleFrame {
            w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2, y: f.midY - w.frame.height / 2))
            clampToScreen(w)
        }
    }

    /// 面板现在比原来高一截（多了一排快捷按钮），小屏上居中会顶到菜单栏或 Dock。
    /// 这里把整块夹回可见区，只挪不缩。
    private func clampToScreen(_ w: NSWindow) {
        guard let vf = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
        var o = w.frame.origin
        o.x = min(max(o.x, vf.minX), max(vf.maxX - w.frame.width, vf.minX))
        o.y = min(max(o.y, vf.minY), max(vf.maxY - w.frame.height, vf.minY))
        if o != w.frame.origin { w.setFrameOrigin(o) }
    }

    func windowDidMove(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        let o = w.frame.origin
        UserDefaults.standard.set(Double(o.x), forKey: "consoleX")
        UserDefaults.standard.set(Double(o.y), forKey: "consoleY")
    }

    @objc private func sizeChanged() {
        let v = CGFloat(sizeSlider.doubleValue)
        sizeValue.stringValue = "\(Int(v)) px"
        controller?.resize(to: v)
    }

    @objc private func presetTapped(_ sender: NSButton) {
        let v = CGFloat(sender.tag)
        sizeSlider.doubleValue = Double(v)
        sizeValue.stringValue = "\(Int(v)) px"
        controller?.resize(to: v)
    }

    @objc private func intervalChanged() {
        let v = intervalSlider.doubleValue
        intervalValue.stringValue = String(format: "每 %.0f 秒动一次", v)
        controller?.setBehaviorInterval(v)
    }

    @objc private func lawChanged() {
        let v = lawSlider.doubleValue / 100
        lawValue.stringValue = "\(Int(lawSlider.doubleValue))%"
        controller?.setLawRatio(v)
    }

    @objc private func walkToggled(_ sender: NSButton) { controller?.setAllowWalk(sender.state == .on) }
    @objc private func talkToggled(_ sender: NSButton) { controller?.setAllowTalk(sender.state == .on) }
    @objc private func eyeToggled(_ sender: NSButton) { controller?.setEyeTracking(sender.state == .on) }

    @objc private func lawLinkToggled(_ sender: NSButton) {
        controller?.setLawlearnLinked(sender.state == .on)
        syncFromController()
    }

    /// 测试用：走一遍复选框回调链路
    func testLawCheck() {
        let b = NSButton(checkboxWithTitle: "t", target: nil, action: nil)
        b.state = .off
        lawLinkToggled(b)
        xlog("console check: off -> linked=\(Lawlearn.linked) value=「\(lawValue.stringValue)」 sliderEnabled=\(lawSlider.isEnabled)")
        b.state = .on
        lawLinkToggled(b)
        xlog("console check: on  -> linked=\(Lawlearn.linked) value=「\(lawValue.stringValue)」 sliderEnabled=\(lawSlider.isEnabled)")
    }

    @objc private func quickAction(_ sender: NSButton) {
        switch sender.tag {
        case 0: controller?.say()
        case 1: controller?.startStudy()
        case 2: controller?.stopStudy()
        case 3: controller?.goHome()
        case 4:
            controller?.toggleVisible()
            syncVisibleButton()
        default: NSApp.terminate(nil)
        }
    }

    /// 宠物藏着的时候按钮说「显示」，露着的时候说「隐藏」——比一个「显示 / 隐藏」少猜一次
    private func syncVisibleButton() {
        guard let b = quickButtons[4], let vis = controller?.window.isVisible else { return }
        b.title = vis ? "隐藏 Scheng" : "显示 Scheng"
    }

    /// 动作预览下拉里选了一项
    @objc private func actionChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let st = PetState(rawValue: raw) else { return }
        controller?.playAction(st)
        // 选完把下拉退回组名：按钮上常驻组名比显示某个动作更好认，也不会显得「卡在某一项」
        if sender.tag >= 0, sender.tag < actionPopups.count {
            actionPopups[sender.tag].selectItem(at: 0)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: PetController!
    var statusItem: NSStatusItem!
    private var console: ConsoleWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = PetController()
        Lawlearn.shared.connect()
        console = ConsoleWindow(controller: controller)
        setupMenuBar()
        // 调试用：XIEZHI_AUTO_SAY=1 时启动 2 秒后自动说一句（便于验收气泡排版）
        if ProcessInfo.processInfo.environment["XIEZHI_CPU_LOG"] == "1" {
            Perf.startAt = CFAbsoluteTimeGetCurrent()
            Perf.lastCPU = Perf.cpuSeconds()
            Perf.lastAt = Perf.startAt
            let t = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in Perf.sample("run") }
            RunLoop.main.add(t, forMode: .common)
        }
        if ProcessInfo.processInfo.environment["XIEZHI_OPEN_CONSOLE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.console.show()
            }
        }
        if let st = ProcessInfo.processInfo.environment["XIEZHI_TEST_STATE"], let s = PetState(rawValue: st) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if ProcessInfo.processInfo.environment["XIEZHI_TEST_TURN"] == "1" {
                    self?.controller.testManualAction(s)
                } else {
                    self?.controller.setState(s)
                }
            }
        }
        if ProcessInfo.processInfo.environment["XIEZHI_TEST_LAWCHECK"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                self?.console.testLawCheck()
            }
        }
        if ProcessInfo.processInfo.environment["XIEZHI_TEST_SPAM"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let c = self.controller else { return }
                let n = Int(ProcessInfo.processInfo.environment["XIEZHI_SPAM_N"] ?? "12") ?? 12
                for i in 0..<n {
                    if i % 2 == 0 { c.say() } else { c.startStudy() }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                }
                xlog("spam done: isFocusing=\(c.isFocusingForTest) state=\(c.stateForTest) session=\(c.studySessionForTest)")
            }
        }
        if let sz = ProcessInfo.processInfo.environment["XIEZHI_TEST_SIZE"], let v = Double(sz) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.controller.resize(to: CGFloat(v))
                xlog("test resize -> \(v)")
            }
        }
        if ProcessInfo.processInfo.environment["XIEZHI_TEST_LAW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.controller.testLawToggle()
            }
        }
        if ProcessInfo.processInfo.environment["XIEZHI_TEST_SUSPEND"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.controller.testSuspend()
            }
        }
        if ProcessInfo.processInfo.environment["XIEZHI_TEST_FLY"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.controller.testFly()
            }
        }
        if ProcessInfo.processInfo.environment["XIEZHI_AUTO_SAY"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.controller.say()
            }
        }
    }

    /// 菜单栏天平图标：用矢量绘制，18pt 下比位图清楚，template 自动适配明暗菜单栏
    private func makeScaleIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            // 底座
            NSBezierPath(roundedRect: NSRect(x: 4.8, y: 0.5, width: 8.4, height: 1.7),
                         xRadius: 0.7, yRadius: 0.7).fill()
            // 立柱
            NSBezierPath(rect: NSRect(x: 8.4, y: 1.9, width: 1.2, height: 9.4)).fill()
            // 顶部圆钮
            NSBezierPath(ovalIn: NSRect(x: 8.1, y: 11.1, width: 1.8, height: 1.8)).fill()
            // 横梁（微弧）
            let beam = NSBezierPath()
            beam.lineWidth = 1.1
            beam.move(to: NSPoint(x: 1.7, y: 11.3))
            beam.curve(to: NSPoint(x: 16.3, y: 11.3),
                       controlPoint1: NSPoint(x: 5.8, y: 13.0),
                       controlPoint2: NSPoint(x: 12.2, y: 13.0))
            beam.stroke()
            // 两侧吊绳与托盘
            for x in [CGFloat(2.0), CGFloat(16.0)] {
                let rope = NSBezierPath()
                rope.lineWidth = 0.6
                rope.move(to: NSPoint(x: x, y: 11.2))
                rope.line(to: NSPoint(x: x - 2.0, y: 4.9))
                rope.line(to: NSPoint(x: x, y: 5.6))
                rope.line(to: NSPoint(x: x + 2.0, y: 4.9))
                rope.stroke()
                let bowl = NSBezierPath()
                bowl.lineWidth = 0.9
                bowl.move(to: NSPoint(x: x - 2.1, y: 4.9))
                bowl.curve(to: NSPoint(x: x + 2.1, y: 4.9),
                           controlPoint1: NSPoint(x: x - 1.7, y: 1.7),
                           controlPoint2: NSPoint(x: x + 1.7, y: 1.7))
                bowl.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 天平图标：优先用打包的黑色单色位图（isTemplate 随菜单栏明暗自适应），缺失时退回矢量绘制
        var icon = makeScaleIcon()
        if let url = Bundle.main.url(forResource: "icon_scale", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true
            icon = img
        }
        statusItem.button?.image = icon
        statusItem.button?.imagePosition = .imageOnly

        // 不再挂右键菜单：原来那一份（专注 / 结束专注 / 说话 / 回位 / 显示隐藏 / 退出）
        // 现在全在控制台里，两边各维护一套还要同步置灰状态。点图标只负责开控制台。
        statusItem.button?.target = self
        statusItem.button?.action = #selector(openConsole)
        _ = statusItem.button?.sendAction(on: [.leftMouseUp])
    }

    @objc func openConsole() { console.show() }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前记一下位置，下次启动接着放
        controller?.savePosition()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
