import AppKit
import AVFoundation

// Interaction and playback design adapted from SunPet (MIT); see LICENSE-SunPet.
struct Clip: Codable {
    let id: Int
    let label: String
    let file: String
    let duration: Double
}

/// 一轮内不重复的随机池。
/// 存 clip.id 而不是下标：轮播内容可以被勾掉，存下标的话池子一变就全错位。
struct ShuffleBag {
    var remaining: [Int] = []
    var last: Int?
    mutating func next(from ids: [Int]) -> Int? {
        guard !ids.isEmpty else { return nil }
        remaining.removeAll { !ids.contains($0) }
        if remaining.isEmpty {
            remaining = ids.shuffled()
            if ids.count > 1, remaining.last == last { remaining.swapAt(0, ids.count - 1) }
        }
        let value = remaining.removeLast()
        last = value
        return value
    }
}

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class PassiveImage: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
final class PassiveLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PetView: NSView {
    weak var owner: AppDelegate?
    let face = PassiveImage()
    let caption = PassiveLabel(labelWithString: "")
    var initialMouse = NSPoint.zero
    var initialWindow = NSPoint.zero
    var dragged = false
    var animationTimer: Timer?
    var phase = 0.0
    var speaking = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        face.imageScaling = .scaleProportionallyUpOrDown
        face.wantsLayer = true
        addSubview(face)
        caption.alignment = .center
        caption.textColor = .white
        caption.font = .systemFont(ofSize: 13, weight: .medium)
        caption.maximumNumberOfLines = 2
        caption.lineBreakMode = .byTruncatingTail
        caption.wantsLayer = true
        caption.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.76).cgColor
        caption.layer?.cornerRadius = 9
        caption.isHidden = true
        addSubview(caption)
        toolTip = "点击随机播放一句 · 拖动移动 · 右键设置"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("好事桌宠，点击随机播放一句，拖动移动，右键设置")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        face.frame = NSRect(x: 8, y: 8, width: bounds.width - 16, height: bounds.height - 52)
        caption.frame = NSRect(x: 3, y: bounds.height - 38, width: bounds.width - 6, height: 34)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        initialMouse = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        initialWindow = window?.frame.origin ?? .zero
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        let current = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        let dx = current.x - initialMouse.x, dy = current.y - initialMouse.y
        if hypot(dx, dy) > 4 { dragged = true }
        if dragged { window?.setFrameOrigin(NSPoint(x: initialWindow.x + dx, y: initialWindow.y + dy)) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragged { owner?.savePosition() } else { owner?.playNext() }
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = owner?.makeMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func accessibilityPerformPress() -> Bool { owner?.playNext(); return true }
    func animate(_ enabled: Bool) {
        speaking = enabled
        animationTimer?.invalidate(); animationTimer = nil
        phase = 0
        face.layer?.transform = CATransform3DIdentity
        guard enabled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase += 0.60
            // Compress vertically by up to 12%, then return to the original height.
            let heightScale = 1.0 - 0.12 * (1.0 - cos(self.phase)) / 2.0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.face.layer?.transform = CATransform3DMakeScale(1.0, heightScale, 1.0)
            CATransaction.commit()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, AVAudioPlayerDelegate {
    var panel: PetPanel!
    var pet: PetView!
    var status: NSStatusItem!
    var player: AVAudioPlayer?
    var clips: [Clip] = []
    var bag = ShuffleBag()
    var lastPlayed: Int?
    var randomMode = true
    var pinnedID: Int?
    /// 从轮播里剔除的句子 id
    var excludedIDs: Set<Int> = []
    var captionWork: DispatchWorkItem?
    var volume: Float = 0.65
    var size: CGFloat = 260
    var imageRatio: CGFloat = 1
    // 捧哏联动：薄肌起头 → 太对了 → 峰哥 → 太对了。
    // peers 是「我听谁」。峰哥只听太对了，而且只在薄肌起的链里接，见 startBridge。
    let bridge = PetBridge(me: .fengge, peers: [.sunpet])
    var bridgeStatus = "联动：接太对了"

    // 接话要用的一整套。和太对了、薄肌那两份是同一套逻辑，只是入口条件不同。
    var companionPool: [Clip] = []
    var companionBag: [Clip] = []
    var companionPlayers: [Int: AVAudioPlayer] = [:]
    var companionLead: [Int: TimeInterval] = [:]
    var companionWork: DispatchWorkItem?
    let companionOverlap: TimeInterval = 0.3
    let selfTest = CommandLine.arguments.contains("--self-test")
    /// 联动自检：真播一句，看对面的桌宠会不会接。测通道用，正常使用不带这个参数。
    let bridgeTest = CommandLine.arguments.contains("--bridge-test")
    let defaults = UserDefaults.standard
    /// --trace 时把联动每一跳的时间、跳数、重叠打到 stdout，用来核对四步链的节奏。
    let trace = CommandLine.arguments.contains("--trace")
    func traceLog(_ text: String) {
        guard trace else { return }
        print("[FENGGE] \(String(format: "%.3f", Date().timeIntervalSince1970)) \(text)")
        fflush(stdout)
    }
    var resources: URL { Bundle.main.resourceURL! }
    var panelSize: NSSize { NSSize(width: size, height: (size - 16) * imageRatio + 52) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // --dump-state 是诊断参数，不建窗口，不该被单实例检测挡掉
        let dumpState = CommandLine.arguments.contains("--dump-state")
        if !selfTest && !bridgeTest && !dumpState, let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != getpid() }
            if !others.isEmpty { NSApp.terminate(nil); return }
        }
        let image: NSImage
        do {
            clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: resources.appendingPathComponent("clips.json")))
            guard !clips.isEmpty, let face = NSImage(contentsOf: resources.appendingPathComponent("face.png")), face.size.width > 0 else {
                throw NSError(domain: "素材缺失", code: 1)
            }
            for clip in clips {
                guard FileManager.default.fileExists(atPath: resources.appendingPathComponent("Clips/\(clip.file)").path) else {
                    throw NSError(domain: "缺少音频：\(clip.file)", code: 2)
                }
            }
            image = face
        } catch {
            if selfTest { print("FAIL: \(error)"); exit(1) }
            let alert = NSAlert(); alert.messageText = "桌宠素材无法读取"; alert.informativeText = error.localizedDescription
            alert.runModal(); NSApp.terminate(nil); return
        }
        imageRatio = image.size.height / image.size.width
        if defaults.object(forKey: "volume") != nil { volume = min(max(defaults.float(forKey: "volume"), 0), 1) }
        if defaults.object(forKey: "size") != nil { size = min(max(CGFloat(defaults.double(forKey: "size")), 160), 400) }
        if defaults.object(forKey: "randomMode") != nil { randomMode = defaults.bool(forKey: "randomMode") }
        if defaults.object(forKey: "pinnedID") != nil { pinnedID = defaults.integer(forKey: "pinnedID") }
        // 注意：defaults.array 拿回来是 [Any] 装 NSNumber，直接 as? [Int] 会失败，
        // 必须逐项取 intValue。踩过：写进去了但读不出来。
        if let raw = defaults.array(forKey: "excludedIDs") {
            excludedIDs = Set(raw.compactMap { entry -> Int? in
                if let number = entry as? NSNumber { return number.intValue }
                if let text = entry as? String { return Int(text) }
                return nil
            })
        }
        if !randomMode && !pinValid() { randomMode = true }
        if CommandLine.arguments.contains("--dump-state") {
            let pin = pinnedID.map { String($0) } ?? "nil"
            print("mode=\(randomMode ? "random" : "fixed") pinned=\(pin) valid=\(pinValid()) excluded=\(excludedIDs.sorted()) clips=\(clips.count) pool=\(clips.count - excludedIDs.count)")
            exit(0)
        }
        panel = PetPanel(contentRect: NSRect(origin: .zero, size: panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "好事桌宠"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        pet = PetView(frame: NSRect(origin: .zero, size: panelSize)); pet.owner = self
        pet.face.image = image; panel.contentView = pet
        restorePosition()
        panel.orderFrontRegardless()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "好事"
        status.button?.toolTip = "好事桌宠 · 点击打开设置"
        status.button?.target = self; status.button?.action = #selector(openStatusMenu)
        updateToolTip()
        // 11 句「这是个好事」全是纯反应，谁说话都能接，不用挑。
        companionPool = clips
        preloadCompanionClips()
        if selfTest { runSelfTest() } else if bridgeTest { startBridge(); runBridgeTest() } else { startBridge(); showCaption("点我说一句 · 右键设置", seconds: 5) }
    }

    // MARK: - 捧哏联动

    func runBridgeTest() {
        showCaption("联动自检：3 秒后播一句", seconds: 3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            print("peer=\(self.bridge.peerIsRunning) status=\(self.bridgeStatus) clips=\(self.clips.count)")
            fflush(stdout)
            if let first = self.clips.first { self.play(first) }
            print("spoke announced at \(Date().timeIntervalSince1970)")
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { exit(0) }
        }
    }

    func startBridge() {
        // 峰哥只在「薄肌起的头」里接话，这是 root 的用处：
        //   薄肌(root=shaolan) → 太对了 → 峰哥 → 太对了
        // 用户自己点峰哥时 root 是 fengge，接一句就停，不会把峰哥自己再带出来一次。
        bridge.onSpoke = { [weak self] from, duration, _, _, hop, root in
            guard let self else { return }
            let willTake = from == .sunpet && root == .shaolan && hop < 3
            let why = willTake ? "接" : (hop >= 3 ? "链到头了" : "不是薄肌起的头")
            self.traceLog("收到 \(from.title) 的话 hop=\(hop) root=\(root.title) — \(why)")
            guard from == .sunpet, root == .shaolan else { return }
            self.scheduleCompanion(after: duration, hop: hop, root: root)
        }
        bridge.start()
        bridgeStatus = "联动：接太对了"
    }

    /// 上一环说完之后排一次接话。
    func scheduleCompanion(after duration: TimeInterval, hop: Int, root: PetRole) {
        guard !selfTest else { return }
        // 链走到第四跳就收住：薄肌0 → 太对了1 → 峰哥2 → 太对了3 → 停
        guard hop < 3 else { return }
        companionWork?.cancel()
        guard let clip = takeCompanionClip() else { return }
        let lead = companionLead[clip.id] ?? 0
        // 第二跳（太对了接完轮到峰哥）比默认压紧 0.1 秒，四步连起来才不拖。
        let overlap = hop == 1 ? max(0.05, companionOverlap - 0.1) : companionOverlap
        let delay = max(0.02, duration - overlap - lead)
        traceLog("排接话 hop=\(hop) root=\(root.title) 重叠=\(String(format: "%.2f", overlap)) 等=\(String(format: "%.2f", delay)) 句=\(clip.id)")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 自己正说着就不叠上去，这一捧算了。
            guard self.player?.isPlaying != true else { return }
            self.traceLog("开口 hop=\(hop + 1) 句=\(clip.id) \(clip.label)")
            self.playCompanion(clip, hop: hop + 1, root: root)
        }
        companionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func takeCompanionClip() -> Clip? {
        if companionBag.isEmpty { companionBag = companionPool.shuffled() }
        return companionBag.popLast()
    }

    func playCompanion(_ clip: Clip, hop: Int, root: PetRole) {
        // 用预解码好的 player 直接起播，绕过「读文件再解码」那几十毫秒。
        if let ready = companionPlayers[clip.id] {
            player?.stop()
            player = ready
            ready.currentTime = 0
            ready.volume = volume
            if ready.play() {
                lastPlayed = clip.id
                pet.animate(true)
                showCaption(clip.label, seconds: ready.duration + 0.5)
                if !selfTest { bridge.announceSpeaking(clipID: clip.id, duration: ready.duration, label: clip.label, hop: hop, root: root) }
                return
            }
        }
        play(clip, hop: hop, root: root)
    }

    func preloadCompanionClips() {
        for clip in companionPool {
            let url = resources.appendingPathComponent("Clips/\(clip.file)")
            guard let audio = try? AVAudioPlayer(contentsOf: url) else { continue }
            audio.delegate = self
            audio.volume = volume
            audio.prepareToPlay()
            companionPlayers[clip.id] = audio
            companionLead[clip.id] = leadingSilence(of: url)
        }
    }

    /// 这句音频开头垫了多少静音。阈值按峰值的百分比取，免得把底噪当成人声。
    func leadingSilence(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let rate = file.processingFormat.sampleRate
        let want = AVAudioFrameCount(min(file.length, AVAudioFramePosition(rate * 0.6)))
        guard want > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: want) else { return 0 }
        do { try file.read(into: buffer) } catch { return 0 }
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var peak: Float = 0
        for i in 0..<count { peak = max(peak, abs(channel[i])) }
        let threshold = max(0.004, peak * 0.06)
        for i in 0..<count where abs(channel[i]) > threshold {
            return Double(i) / rate
        }
        return 0
    }
    func restorePosition() {
        if defaults.object(forKey: "petX") != nil {
            let origin = NSPoint(x: defaults.double(forKey: "petX"), y: defaults.double(forKey: "petY"))
            let rect = NSRect(origin: origin, size: panelSize)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersection(rect).width >= 80 && $0.visibleFrame.intersection(rect).height >= 80 }) {
                panel.setFrameOrigin(origin); return
            }
        }
        placeAtCorner()
    }
    func placeAtCorner() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panelSize.width - 32, y: screen.visibleFrame.minY + 24))
    }
    func savePosition() {
        guard !selfTest, let panel else { return }
        defaults.set(panel.frame.origin.x, forKey: "petX"); defaults.set(panel.frame.origin.y, forKey: "petY")
    }
    @objc func resetPosition() { placeAtCorner(); savePosition() }
    @objc func openStatusMenu() { status.menu = makeMenu(); status.button?.performClick(nil); status.menu = nil }
    func item(_ title: String, _ action: Selector?, tag: Int = 0) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: "")
        result.target = self; result.tag = tag; return result
    }
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let title = item("好事桌宠 · \(clips.count)句原声", nil); title.isEnabled = false; menu.addItem(title)
        let hint = item("点击随机播放 · 一轮内不重复", nil); hint.isEnabled = false; menu.addItem(hint)
        menu.addItem(.separator())
        menu.addItem(item("随机说一句", #selector(playNext)))
        let choose = item("挑一句", nil), choices = NSMenu()
        for clip in clips { choices.addItem(item(String(format: "%02d  %@", clip.id, clip.label), #selector(chooseClip(_:)), tag: clip.id)) }
        choose.submenu = choices; menu.addItem(choose)
        let modeItem = item("播放方式", nil), modes = NSMenu()
        let rand = item("随机一句（一轮不重复）", #selector(modeRandom)); rand.state = randomMode ? .on : .off; modes.addItem(rand)
        let fix = item(modeTitle(), #selector(modeFixed)); fix.state = randomMode ? .off : .on; modes.addItem(fix)
        modeItem.submenu = modes; menu.addItem(modeItem)
        let filters = item("轮播内容", nil), filtersMenu = NSMenu()
        let fhint = item("取消勾选＝不参与随机播", nil); fhint.isEnabled = false; filtersMenu.addItem(fhint); filtersMenu.addItem(.separator())
        // 这里不能做成普通菜单项：菜单项点一下就整个关闭，取消十句得重开十次菜单。
        // 换成真正的 NSButton 控件（menuItem.view），点控件不会关闭菜单，可以连着勾。
        for clip in clips {
            let box = NSButton(checkboxWithTitle: String(format: "%02d  %@", clip.id, clip.label),
                               target: self, action: #selector(toggleExclusionBox(_:)))
            box.tag = clip.id
            box.state = excludedIDs.contains(clip.id) ? .off : .on
            box.font = .systemFont(ofSize: 12)
            box.sizeToFit()
            let holder = NSMenuItem()
            holder.view = box
            filtersMenu.addItem(holder)
        }
        filtersMenu.addItem(.separator()); filtersMenu.addItem(item("全部恢复", #selector(enableAllClips)))
        filters.submenu = filtersMenu; menu.addItem(filters)
        menu.addItem(item("停止播放", #selector(stopPlayback)))
        menu.addItem(.separator())
        let bridgeInfo = item(bridgeStatus, nil); bridgeInfo.isEnabled = false; menu.addItem(bridgeInfo)
        menu.addItem(.separator())
        let volumeItem = item("音量", nil), volumes = NSMenu()
        for value in [0, 25, 50, 65, 80, 100] {
            let option = item(value == 0 ? "静音" : "\(value)%", #selector(setVolume(_:)), tag: value)
            option.state = abs(volume - Float(value)/100) < 0.01 ? .on : .off; volumes.addItem(option)
        }
        volumeItem.submenu = volumes; menu.addItem(volumeItem)
        let sizeItem = item("人物大小", nil), sizes = NSMenu()
        for (name, value) in [("小", 190), ("中", 260), ("大", 340)] {
            let option = item(name, #selector(setSize(_:)), tag: value)
            option.state = Int(size) == value ? .on : .off; sizes.addItem(option)
        }
        sizeItem.submenu = sizes; menu.addItem(sizeItem)
        menu.addItem(item("移回屏幕右下角", #selector(resetPosition)))
        menu.addItem(.separator())
        menu.addItem(item("退出桌宠", #selector(quit)))
        return menu
    }
    @objc func playNext() {
        // 固定模式：永远播钉住的那句，不轮播。
        if !randomMode, let id = pinnedID, let clip = clips.first(where: { $0.id == id }) { play(clip); return }
        let ids = clips.filter { !excludedIDs.contains($0.id) }.map(\.id)
        guard let id = bag.next(from: ids), let clip = clips.first(where: { $0.id == id }) else { return }
        play(clip)
    }
    func play(_ clip: Clip, hop: Int = 0, root: PetRole? = nil) {
        player?.stop(); pet.animate(false)
        do {
            let audio = try AVAudioPlayer(contentsOf: resources.appendingPathComponent("Clips/\(clip.file)"))
            player = audio; audio.delegate = self; audio.volume = volume; audio.prepareToPlay()
            guard audio.play() else { throw NSError(domain: "无法播放音频", code: 3) }
            lastPlayed = clip.id; pet.animate(true); showCaption(clip.label, seconds: audio.duration + 0.4)
            if !selfTest { bridge.announceSpeaking(clipID: clip.id, duration: audio.duration, label: clip.label, hop: hop, root: root) }
        } catch { showCaption("这句暂时无法播放", seconds: 4) }
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player else { return }
        pet.animate(false)
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === self.player else { return }
        stopPlayback(); showCaption("音频读取失败", seconds: 4)
    }
    func showCaption(_ text: String, seconds: Double) {
        captionWork?.cancel(); pet.caption.stringValue = text; pet.caption.isHidden = false
        let work = DispatchWorkItem { [weak self] in self?.pet.caption.isHidden = true }
        captionWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    @objc func chooseClip(_ sender: NSMenuItem) {
        guard let clip = clips.first(where: { $0.id == sender.tag }) else { return }
        if !randomMode { pinnedID = clip.id; defaults.set(clip.id, forKey: "pinnedID"); updateToolTip() }
        play(clip)
    }
    // MARK: - 播放方式与轮播内容

    func pinValid() -> Bool {
        guard let id = pinnedID else { return false }
        return clips.contains { $0.id == id }
    }
    func modeTitle() -> String {
        guard !randomMode, let id = pinnedID, let clip = clips.first(where: { $0.id == id }) else { return "固定播一句" }
        return String(format: "固定播一句（%02d %@）", clip.id, clip.label)
    }
    func updateToolTip() {
        let text = randomMode ? "点击随机播放一句 · 拖动移动 · 右键设置" : "点击播放固定那句 · 拖动移动 · 右键设置"
        pet?.toolTip = text
    }
    @objc func modeRandom() { setMode(random: true) }
    @objc func modeFixed() { setMode(random: false) }
    func setMode(random: Bool) {
        randomMode = random
        if !random, !pinValid() { pinnedID = (clips.first(where: { $0.id == lastPlayed }) ?? clips.first)?.id }
        defaults.set(random, forKey: "randomMode")
        if let pin = pinnedID { defaults.set(pin, forKey: "pinnedID") }
        updateToolTip()
        if random {
            showCaption("随机播放 · 一轮不重复", seconds: 3)
        } else if let clip = clips.first(where: { $0.id == pinnedID }) {
            showCaption(String(format: "已固定：%02d %@", clip.id, clip.label), seconds: 4)
        }
    }
    /// 菜单里的复选框被点。菜单不会因此关闭，所以可以连着取消好几句。
    @objc func toggleExclusionBox(_ sender: NSButton) {
        let id = sender.tag
        if excludedIDs.contains(id) {
            excludedIDs.remove(id)
        } else {
            guard excludedIDs.count < clips.count - 1 else {
                sender.state = .on
                NSSound.beep()
                return
            }
            excludedIDs.insert(id)
        }
        defaults.set(Array(excludedIDs), forKey: "excludedIDs")
        bag.remaining.removeAll()
    }

    /// 勾掉某句：从随机轮播里剔除。至少留一句，否则随机就没东西可播。
    @objc func toggleExclusion(_ sender: NSMenuItem) {
        let id = sender.tag
        if excludedIDs.contains(id) {
            excludedIDs.remove(id)
        } else {
            guard excludedIDs.count < clips.count - 1 else {
                showCaption("至少留一句在轮播里", seconds: 3)
                return
            }
            excludedIDs.insert(id)
        }
        defaults.set(Array(excludedIDs), forKey: "excludedIDs")
        showCaption("轮播里还有 \(clips.count - excludedIDs.count) 句", seconds: 2)
    }
    @objc func enableAllClips() {
        excludedIDs.removeAll()
        defaults.set([Int](), forKey: "excludedIDs")
        showCaption("轮播已恢复全部", seconds: 2)
    }

    @objc func stopPlayback() {
        companionWork?.cancel(); companionWork = nil
        player?.stop(); pet.animate(false); captionWork?.cancel(); pet.caption.isHidden = true
    }
    @objc func setVolume(_ sender: NSMenuItem) {
        volume = Float(sender.tag) / 100; player?.volume = volume; defaults.set(volume, forKey: "volume")
    }
    @objc func setSize(_ sender: NSMenuItem) {
        size = CGFloat(sender.tag); panel.setContentSize(panelSize)
        defaults.set(Double(size), forKey: "size"); savePosition()
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { bridge.stop(); companionWork?.cancel(); savePosition(); player?.stop(); pet?.animate(false) }

    func runSelfTest() {
        var failures: [String] = []
        func check(_ valid: Bool, _ name: String) { print("\(valid ? "OK" : "FAIL") \(name)"); if !valid { failures.append(name) } }
        check(!panel.isOpaque && panel.backgroundColor == .clear && panel.level == .floating, "transparent floating window")
        check(!panel.canBecomeKey && !panel.canBecomeMain, "does not steal keyboard focus")
        if let data = pet.face.image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
            check(bitmap.hasAlpha && (bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.1, "original image transparency")
        } else { check(false, "image decoding") }
        for clip in clips {
            do {
                let audio = try AVAudioPlayer(contentsOf: resources.appendingPathComponent("Clips/\(clip.file)"))
                check(audio.duration > 0.25 && abs(audio.duration - clip.duration) < 0.15, "audio \(clip.id): \(clip.label), \(audio.duration)s")
            } catch { check(false, "audio \(clip.id)") }
        }
        var testBag = ShuffleBag(), previous: Int?
        let allIDs = clips.map(\.id)
        var randomOK = true
        for _ in 0..<100 {
            var cycle: [Int] = []
            for _ in clips {
                let id = testBag.next(from: allIDs)!
                if clips.count > 1 && previous == id { randomOK = false }
                previous = id; cycle.append(id)
            }
            if Set(cycle).count != clips.count { randomOK = false }
        }
        check(randomOK, "100 shuffle rounds: no repeats within a round or at boundary")
        volume = 0
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        pet.mouseDown(with: event); pet.mouseUp(with: event)
        check(player?.isPlaying == true && pet.speaking, "mouse click starts playback and animation")
        let previousPlayer = player
        playNext()
        check(previousPlayer?.isPlaying == false && player?.isPlaying == true, "new click replaces previous audio")
        let beforeDrag = lastPlayed
        pet.mouseDown(with: event)
        let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 30, y: 20), modifierFlags: [], timestamp: 1, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        pet.mouseDragged(with: drag); pet.mouseUp(with: drag)
        check(pet.dragged && lastPlayed == beforeDrag, "drag moves without playing a new clip")

        // 固定模式：每次触发都必须播钉住的那句，不能漂到别的句子
        let savedMode = randomMode, savedPin = pinnedID, savedExcluded = excludedIDs
        randomMode = false
        pinnedID = clips.count > 2 ? clips[2].id : clips.first?.id
        var pinnedOK = true
        for _ in 0..<6 {
            playNext()
            if lastPlayed != pinnedID { pinnedOK = false }
        }
        check(pinnedOK, "fixed mode always replays the pinned clip")

        // 排除：勾掉的句子绝不出现在随机里
        randomMode = true
        excludedIDs = Set(clips.prefix(2).map(\.id))
        var excludedOK = true
        for _ in 0..<40 {
            playNext()
            if let id = lastPlayed, excludedIDs.contains(id) { excludedOK = false }
        }
        check(excludedOK, "excluded clips never play in random mode")

        randomMode = savedMode; pinnedID = savedPin; excludedIDs = savedExcluded
        check(makeMenu().items.first(where: { $0.title == "挑一句" })?.submenu?.items.count == clips.count, "all clips in context menu")
        // 轮播内容必须是真控件（menuItem.view），普通菜单项点了会关菜单，没法连着勾
        let filterBoxes = makeMenu().items.first(where: { $0.title == "轮播内容" })?.submenu?.items.compactMap { $0.view as? NSButton } ?? []
        check(filterBoxes.count == clips.count && filterBoxes.allSatisfy { !$0.title.isEmpty && $0.action != nil }, "rotation list uses real checkboxes")
        stopPlayback()
        check(player?.isPlaying == false && !pet.speaking && pet.caption.isHidden, "stop clears audio, animation and caption")
        if let i = CommandLine.arguments.firstIndex(of: "--preview"), i + 1 < CommandLine.arguments.count {
            showCaption(clips[0].label, seconds: 5)
            pet.layoutSubtreeIfNeeded()
            if let bitmap = pet.bitmapImageRepForCachingDisplay(in: pet.bounds) {
                pet.cacheDisplay(in: pet.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            }
        }
        print(failures.isEmpty ? "PASS" : "FAIL: \(failures)"); fflush(stdout)
        exit(failures.isEmpty ? 0 : 1)
    }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
