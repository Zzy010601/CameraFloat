import Cocoa
import AVFoundation

// MARK: - 全局配置

private enum Config {
    static let minWidth: CGFloat = 90
    static let maxWidth: CGFloat = 1600
    static let minHeight: CGFloat = 90
    static let edgeInset: CGFloat = 14          // 边缘拖拽缩放热区
    static let cornerRadius: CGFloat = 14
    static let defaultSize = NSSize(width: 480, height: 270)

    static let frameKey = "camerafloat.windowFrame"
    static let topKey = "camerafloat.alwaysOnTop"
    static let mirrorKey = "camerafloat.mirrored"
    static let zoomKey = "camerafloat.contentZoom"
    static let panXKey = "camerafloat.contentPanX"
    static let panYKey = "camerafloat.contentPanY"
    static let anchorKey = "camerafloat.frameAnchor"
    static let dragModeKey = "camerafloat.dragMode"

    static let minZoom: CGFloat = 1
    static let maxZoom: CGFloat = 6

    static let cameraSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
}

private func symbolImage(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .semibold) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
}

// MARK: - 取景 / 拖动模式

/// 画面在窗口里的贴合方式（窗口与画面比例不一致时怎么处理）
enum FrameAnchor: String, CaseIterable {
    case right      // 右固定：裁掉左边，右侧视角钉住
    case left       // 左固定：裁掉右边
    case center     // 居中裁切：两边都裁
    case contain    // 自适应：整幅画面完整显示，多出来的地方留黑边

    var title: String {
        switch self {
        case .right: return "右固定（裁左边）"
        case .left: return "左固定（裁右边）"
        case .center: return "居中裁切（两边都裁）"
        case .contain: return "自适应（完整显示）"
        }
    }

    var isContain: Bool { self == .contain }
}

/// 鼠标拖动的作用对象
enum DragMode: String, CaseIterable {
    case pan        // 拖动画面视角
    case window     // 拖动整个窗口

    var title: String {
        switch self {
        case .pan: return "拖动画面视角"
        case .window: return "拖动整个窗口"
        }
    }

    var symbol: String {
        switch self {
        case .pan: return "hand.draw.fill"
        case .window: return "arrow.up.and.down.and.arrow.left.and.right"
        }
    }
}

// MARK: - 摄像头控制器

final class CameraController {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camerafloat.capture")
    private var configured = false
    private var input: AVCaptureDeviceInput?
    private(set) var isRunning = false
    private(set) var hasDevice = true
    private(set) var currentDeviceID: String?
    private(set) var currentDeviceName: String = ""
    var onRunningChanged: ((Bool) -> Void)?

    /// 当前设备画面宽高比（宽 / 高），用于右对齐裁切
    var currentAspect: CGFloat {
        guard let device = input?.device else { return 16.0 / 9.0 }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard dims.width > 0, dims.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(dims.width) / CGFloat(dims.height)
    }

    // MARK: 设备枚举

    static func availableDevices() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(contentsOf: [.external, .continuityCamera, .deskViewCamera])
        } else {
            types.append(.externalUnknown)
        }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                         mediaType: .video,
                                                         position: .unspecified)
        return discovery.devices
    }

    static func displayName(for device: AVCaptureDevice) -> String {
        if device.deviceType == .builtInWideAngleCamera { return "内置摄像头" }
        if #available(macOS 14.0, *), device.deviceType == .continuityCamera {
            return "\(device.localizedName)（连续互通）"
        }
        return device.localizedName
    }

    // MARK: 装配

    func prepare(preferredID: String? = nil) {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .high
        attachInput(preferredID: preferredID)
        session.commitConfiguration()
    }

    private func attachInput(preferredID: String?) {
        let devices = Self.availableDevices()
        var target: AVCaptureDevice?
        if let id = preferredID, let match = devices.first(where: { $0.uniqueID == id }) {
            target = match
        }
        if target == nil {
            target = AVCaptureDevice.default(for: .video) ?? devices.first
        }
        guard let device = target,
              let newInput = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(newInput) else {
            hasDevice = false
            return
        }
        if let current = input { session.removeInput(current) }
        session.addInput(newInput)
        input = newInput
        currentDeviceID = device.uniqueID
        currentDeviceName = Self.displayName(for: device)
        hasDevice = true
    }

    /// 切换摄像头（内置 / 外接 USB / iPhone 连续互通）
    func switchDevice(to id: String, completion: @escaping (Bool) -> Void) {
        guard id != currentDeviceID else {
            DispatchQueue.main.async { completion(true) }
            return
        }
        queue.async { [weak self] in
            guard let self = self else { return }
            let wasRunning = self.session.isRunning
            if wasRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            self.attachInput(preferredID: id)
            self.session.commitConfiguration()
            if wasRunning { self.session.startRunning() }
            let ok = self.currentDeviceID == id
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func start() {
        prepare()
        guard hasDevice else {
            DispatchQueue.main.async { self.onRunningChanged?(false) }
            return
        }
        queue.async { [weak self] in
            guard let self = self else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            DispatchQueue.main.async {
                self.isRunning = true
                self.onRunningChanged?(true)
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            DispatchQueue.main.async {
                self.isRunning = false
                self.onRunningChanged?(false)
            }
        }
    }

    static func requestAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }
}

// MARK: - 底部控制条

final class ControlBar: NSView {
    var onToggleCamera: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onClose: (() -> Void)?

    private let toggleButton = NSButton()
    private let pinButton = NSButton()
    private let closeButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 11
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        setup(toggleButton, symbol: "video.fill", action: #selector(toggleTapped))
        setup(pinButton, symbol: "pin.slash", fallback: "pin", action: #selector(pinTapped))
        setup(closeButton, symbol: "xmark", action: #selector(closeTapped))

        let stack = NSStackView(views: [toggleButton, pinButton, closeButton])
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        for button in [toggleButton, pinButton, closeButton] {
            // 宽度用 defaultHigh，窗口被压得很窄时允许按钮自动收窄
            let width = button.widthAnchor.constraint(equalToConstant: 22)
            width.priority = .defaultHigh
            width.isActive = true
            button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup(_ button: NSButton, symbol: String, fallback: String? = nil, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.image = symbolImage(symbol) ?? (fallback.flatMap { symbolImage($0) })
        button.contentTintColor = .white
        button.target = self
        button.action = action
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.setButtonType(.momentaryChange)
        button.toolTip = nil
    }

    func setCameraOn(_ on: Bool) {
        toggleButton.image = symbolImage(on ? "video.fill" : "video.slash.fill")
        toggleButton.toolTip = on ? "关闭摄像头" : "开启摄像头"
    }

    func setMirrored(_ mirrored: Bool) {
        // 镜像入口已移到菜单栏「画面」菜单，控制条不再放这个按钮
    }

    func setPinned(_ pinned: Bool) {
        pinButton.image = symbolImage(pinned ? "pin.fill" : "pin.slash") ?? symbolImage("pin")
        pinButton.contentTintColor = pinned ? .white : NSColor.white.withAlphaComponent(0.5)
        pinButton.layer?.backgroundColor = pinned ? NSColor.systemBlue.cgColor : NSColor.clear.cgColor
        pinButton.layer?.cornerRadius = 6
        pinButton.toolTip = pinned ? "置顶：开（点击关闭）" : "置顶：关（点击开启）"
    }

    @objc private func toggleTapped() { onToggleCamera?() }
    @objc private func pinTapped() { onTogglePin?() }
    @objc private func closeTapped() { onClose?() }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - 画面中央的拖动模式按钮

final class DragModeButton: NSButton {
    var onToggle: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.borderWidth = 0.6
        layer?.borderColor = NSColor.white.withAlphaComponent(0.30).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        target = self
        action = #selector(tapped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(mode: DragMode) {
        image = symbolImage(mode.symbol, size: 14, weight: .semibold)
        contentTintColor = .white
        layer?.backgroundColor = (mode == .window
            ? NSColor.systemBlue.withAlphaComponent(0.92)
            : NSColor.black.withAlphaComponent(0.42)).cgColor
        toolTip = "当前：\(mode.title)（点击切换）"
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    @objc private func tapped() { onToggle?() }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - 占位视图（摄像头关闭 / 无权限）

final class PlaceholderView: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let settingsButton = NSButton(title: "打开系统设置", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.97).cgColor

        iconView.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = NSImage(systemSymbolName: "video.slash", accessibilityDescription: nil)

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.7)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail

        settingsButton.bezelStyle = .rounded
        settingsButton.controlSize = .small
        settingsButton.font = .systemFont(ofSize: 11)
        settingsButton.isHidden = true
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)

        let stack = NSStackView(views: [iconView, label, settingsButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(message: String, symbol: String, needsSettings: Bool) {
        label.stringValue = message
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        settingsButton.isHidden = !needsSettings
        isHidden = false
    }

    @objc private func openSettings() {
        if let url = URL(string: Config.cameraSettingsURL) {
            NSWorkspace.shared.open(url)
        }
    }

    /// 占位层只负责显示，事件穿透到父视图（保证关闭摄像头后仍可拖动/缩放）
    override func hitTest(_ point: NSPoint) -> NSView? {
        if !settingsButton.isHidden {
            let local = convert(point, to: settingsButton)
            if settingsButton.bounds.contains(local) { return settingsButton }
        }
        return nil
    }
}

// MARK: - 边缘缩放手柄

final class ResizeHandleView: NSView {
    private var startFrame: NSRect = .zero
    private var startMouse: NSPoint = .zero
    private var edges: Edge = []

    struct Edge: OptionSet {
        let rawValue: Int
        static let left = Edge(rawValue: 1 << 0)
        static let right = Edge(rawValue: 1 << 1)
        static let bottom = Edge(rawValue: 1 << 2)
        static let top = Edge(rawValue: 1 << 3)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window = window else { return }
        startFrame = window.frame
        startMouse = NSEvent.mouseLocation
        let p = convert(event.locationInWindow, from: nil)
        var detected: Edge = []
        if p.x <= Config.edgeInset { detected.insert(.left) }
        if p.x >= bounds.width - Config.edgeInset { detected.insert(.right) }
        if p.y <= Config.edgeInset { detected.insert(.bottom) }
        if p.y >= bounds.height - Config.edgeInset { detected.insert(.top) }
        edges = detected
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = window, !edges.isEmpty else { return }
        let current = NSEvent.mouseLocation
        var dx = current.x - startMouse.x
        var dy = current.y - startMouse.y
        var frame = startFrame

        if edges.contains(.left) {
            if startFrame.width - dx < Config.minWidth { dx = startFrame.width - Config.minWidth }
            if startFrame.width - dx > Config.maxWidth { dx = startFrame.width - Config.maxWidth }
            frame.origin.x = startFrame.origin.x + dx
            frame.size.width = startFrame.width - dx
        } else if edges.contains(.right) {
            frame.size.width = min(Config.maxWidth, max(Config.minWidth, startFrame.width + dx))
        }

        if edges.contains(.bottom) {
            if startFrame.height - dy < Config.minHeight { dy = startFrame.height - Config.minHeight }
            frame.origin.y = startFrame.origin.y + dy
            frame.size.height = startFrame.height - dy
        } else if edges.contains(.top) {
            frame.size.height = max(Config.minHeight, startFrame.height + dy)
        }

        window.setFrameClamped(frame, display: true)
        NotificationCenter.default.post(name: .cameraFloatDidResize, object: nil)
    }

    /// 只有落在边缘热区时才拦截事件，否则必须返回 nil，
    /// 否则铺满全窗口的手柄会吃掉控制条按钮和拖动窗口的点击。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = superview != nil ? convert(point, from: superview) : point
        if p.x <= Config.edgeInset || p.x >= bounds.width - Config.edgeInset ||
            p.y <= Config.edgeInset || p.y >= bounds.height - Config.edgeInset {
            return self
        }
        return nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let e = Config.edgeInset
        let b = bounds
        addCursorRect(NSRect(x: 0, y: e, width: e, height: max(0, b.height - e * 2)), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: b.width - e, y: e, width: e, height: max(0, b.height - e * 2)), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: e, y: 0, width: max(0, b.width - e * 2), height: e), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: e, y: b.height - e, width: max(0, b.width - e * 2), height: e), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: 0, width: e, height: e), cursor: .crosshair)
        addCursorRect(NSRect(x: b.width - e, y: 0, width: e, height: e), cursor: .crosshair)
        addCursorRect(NSRect(x: 0, y: b.height - e, width: e, height: e), cursor: .crosshair)
        addCursorRect(NSRect(x: b.width - e, y: b.height - e, width: e, height: e), cursor: .crosshair)
    }
}

extension Notification.Name {
    static let cameraFloatDidResize = Notification.Name("cameraFloatDidResize")
}

extension NSWindow {
    /// 设置窗口 frame，同时保证至少 minVisible 的点数留在屏幕可见区域内，
    /// 避免缩放/拖动把窗口推出屏幕后找不回来。
    func setFrameClamped(_ frame: NSRect, display: Bool) {
        guard let screen = self.screen ?? NSScreen.main else {
            setFrame(frame, display: display)
            return
        }
        let visible = screen.visibleFrame
        let minVisible: CGFloat = 80
        var f = frame
        if f.maxX < visible.minX + minVisible { f.origin.x = visible.minX + minVisible - f.width }
        if f.minX > visible.maxX - minVisible { f.origin.x = visible.maxX - minVisible }
        if f.maxY < visible.minY + minVisible { f.origin.y = visible.minY + minVisible - f.height }
        if f.minY > visible.maxY - minVisible { f.origin.y = visible.maxY - minVisible }
        setFrame(f, display: display)
    }
}

// MARK: - 内容视图

final class CameraContentView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    let controlBar = ControlBar()
    let placeholder = PlaceholderView()
    private let resizeHandle = ResizeHandleView()

    var onToggleCamera: (() -> Void)? {
        get { controlBar.onToggleCamera }
        set { controlBar.onToggleCamera = newValue }
    }
    var onTogglePin: (() -> Void)? {
        get { controlBar.onTogglePin }
        set { controlBar.onTogglePin = newValue }
    }
    var onClose: (() -> Void)? {
        get { controlBar.onClose }
        set { controlBar.onClose = newValue }
    }

    /// 拖动模式切换（画面中央按钮 / 菜单）
    var onDragModeChanged: (() -> Void)?

    let modeButton = DragModeButton()

    private var trackingAreaRef: NSTrackingArea?
    private var hideWorkItem: DispatchWorkItem?

    /// 画面宽高比提供者（由 AppDelegate 注入当前设备的真实比例）
    var aspectProvider: (() -> CGFloat)?

    init(frame frameRect: NSRect, session: AVCaptureSession) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = Config.cornerRadius
        layer?.backgroundColor = NSColor.black.cgColor

        previewLayer.session = session
        // 用 .resize 而非 .resizeAspectFill：由我们自己算 frame，
        // 才能在窗口变窄时右对齐裁切（只裁左边），而不是居中裁切。
        previewLayer.videoGravity = .resize
        previewLayer.zPosition = -1
        layer?.addSublayer(previewLayer)

        // 注意顺序：手柄最底 → 占位层 → 中央拖动按钮 → 控制条最上，
        // 保证按钮的点击优先级高于铺满全窗口的缩放手柄。
        addSubview(resizeHandle)
        addSubview(placeholder)
        addSubview(modeButton)
        addSubview(controlBar)

        controlBar.alphaValue = 0
        controlBar.isHidden = false
        modeButton.alphaValue = 0
        modeButton.apply(mode: dragMode)
        modeButton.onToggle = { [weak self] in self?.toggleDragMode() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 窗口不在前台时，第一次点击也要直接作用在画面上（否则这一下只当"激活窗口"被吞掉）
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 中央拖动按钮浮在画面之上，淡出时让点击穿透到画面
        if modeButton.alphaValue > 0.05, modeButton.frame.contains(point) {
            return modeButton
        }
        // 控制条可见且命中时优先交给按钮，避免窗口很窄时被边缘缩放抢走
        let inControlBar = controlBar.alphaValue > 0.05 &&
            controlBar.frame.insetBy(dx: -2, dy: -2).contains(point)
        if !inControlBar,
           point.x <= Config.edgeInset || point.x >= bounds.width - Config.edgeInset ||
            point.y <= Config.edgeInset || point.y >= bounds.height - Config.edgeInset {
            return resizeHandle
        }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        syncLayers()
    }

    func syncLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // 画面按高度铺满、宽度按比例算，再叠加缩放与平移偏移，
        // 默认右边缘钉在窗口右侧（窗口变窄时只裁左边）。
        let rect = videoRect()
        previewLayer.frame = rect
        CATransaction.commit()

        // 把夹紧后的实际位置写回偏移，避免越界后"积攒"无效位移
        let defaultX = defaultX(forWidth: rect.width)
        let defaultY = (bounds.height - rect.height) / 2
        pan = CGSize(width: rect.width > bounds.width + 0.5 ? rect.minX - defaultX : 0,
                     height: rect.height > bounds.height + 0.5 ? rect.minY - defaultY : 0)

        resizeHandle.frame = bounds
        placeholder.frame = bounds
        placeholder.layoutSubtreeIfNeeded()

        // 中央拖动模式按钮
        let side: CGFloat = 34
        modeButton.frame = NSRect(x: (bounds.width - side) / 2,
                                  y: (bounds.height - side) / 2,
                                  width: side, height: side)

        // 窗口被压得很窄时，控制条跟着收窄，避免溢出
        let fitting = controlBar.fittingSize.width
        let width = min(fitting, max(64, bounds.width - 8))
        controlBar.frame = NSRect(x: (bounds.width - width) / 2, y: 16, width: width, height: 30)
    }

    // MARK: 画面取景（画布式平移 / 缩放）

    private var zoom: CGFloat = 1
    private var pan: CGSize = .zero

    /// 画面贴合方式：右固定 / 左固定 / 自适应
    var frameAnchor: FrameAnchor = .right {
        didSet {
            guard oldValue != frameAnchor else { return }
            pan = .zero
            syncLayers()
            onFramingChanged?()
        }
    }

    /// 拖动模式：拖画面视角 / 拖整个窗口
    private(set) var dragMode: DragMode = .pan {
        didSet {
            guard oldValue != dragMode else { return }
            modeButton.apply(mode: dragMode)
            onDragModeChanged?()
        }
    }

    func setDragMode(_ mode: DragMode) {
        dragMode = mode
    }

    func toggleDragMode() {
        dragMode = (dragMode == .pan) ? .window : .pan
        revealControls()
    }

    var onFramingChanged: (() -> Void)?

    var currentZoom: CGFloat { zoom }
    var currentPan: CGSize { pan }

    func restoreFraming(zoom savedZoom: CGFloat, pan savedPan: CGSize) {
        zoom = min(Config.maxZoom, max(Config.minZoom, savedZoom))
        pan = savedPan
        syncLayers()
    }

    /// 画面在窗口内的显示矩形。
    /// - 右固定 / 左固定：按"盖满窗口"算基准尺寸，多出的部分被裁掉
    /// - 自适应：按"整幅可见"算基准尺寸，缺口留黑边
    /// 再乘以缩放系数、叠加平移偏移并夹紧。
    private func videoRect() -> CGRect {
        let base = baseVideoSize()
        let width = base.width * zoom
        let height = base.height * zoom

        var x: CGFloat
        if width <= bounds.width + 0.5 {
            x = (bounds.width - width) / 2
        } else {
            x = min(0, max(bounds.width - width, defaultX(forWidth: width) + pan.width))
        }

        var y: CGFloat
        if height <= bounds.height + 0.5 {
            y = (bounds.height - height) / 2
        } else {
            let defaultY = (bounds.height - height) / 2
            y = min(0, max(bounds.height - height, defaultY + pan.height))
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func defaultX(forWidth width: CGFloat) -> CGFloat {
        switch frameAnchor {
        case .right: return bounds.width - width
        case .left: return 0
        case .center, .contain: return (bounds.width - width) / 2
        }
    }

    private func baseVideoSize() -> CGSize {
        let aspect = max(0.2, aspectProvider?() ?? 16.0 / 9.0)
        let fitsByHeight = bounds.height * aspect <= bounds.width
        if frameAnchor.isContain {   // 自适应：整幅可见（放不下就留黑边）
            return fitsByHeight ? CGSize(width: bounds.height * aspect, height: bounds.height)
                                : CGSize(width: bounds.width, height: bounds.width / aspect)
        }
        // 其余三种：盖满窗口（放不下就裁）
        return fitsByHeight ? CGSize(width: bounds.width, height: bounds.width / aspect)
                            : CGSize(width: bounds.height * aspect, height: bounds.height)
    }

    /// 以鼠标所在点为中心缩放：该点下方的画面内容保持不动，像画布一样
    private func applyZoom(factor: CGFloat, around point: NSPoint) {
        guard bounds.width > 0, bounds.height > 0, factor > 0, factor.isFinite else { return }
        let old = videoRect()
        let target = min(Config.maxZoom, max(Config.minZoom, zoom * factor))
        guard abs(target - zoom) > 0.0005, old.width > 0, old.height > 0 else { return }

        let u = (point.x - old.minX) / old.width
        let v = (point.y - old.minY) / old.height

        zoom = target
        let base = baseVideoSize()
        let width = base.width * zoom
        let height = base.height * zoom
        let defaultX = defaultX(forWidth: width)
        let defaultY = (bounds.height - height) / 2
        pan = CGSize(width: point.x - u * width - defaultX,
                     height: point.y - v * height - defaultY)
        syncLayers()
        onFramingChanged?()
    }

    func resetFraming() {
        guard zoom != 1 || pan != .zero else { return }
        zoom = 1
        pan = .zero
        syncLayers()
        onFramingChanged?()
    }

    /// ⌘ + 滚轮：调整窗口大小（右边缘固定，向左生长 / 收缩）
    private func resizeWindow(by factor: CGFloat) {
        guard let window = window else { return }
        var frame = window.frame
        let rightEdge = frame.maxX
        let centerY = frame.midY
        let ratio = frame.height / max(frame.width, 1)

        var newWidth = frame.width * factor
        newWidth = min(Config.maxWidth, max(Config.minWidth, newWidth))
        var newHeight = newWidth * ratio
        if newHeight < Config.minHeight {
            newHeight = Config.minHeight
            newWidth = newHeight / ratio
        }

        frame.size = NSSize(width: newWidth, height: newHeight)
        frame.origin = NSPoint(x: rightEdge - newWidth, y: centerY - newHeight / 2)
        window.setFrameClamped(frame, display: true)
        syncLayers()
        NotificationCenter.default.post(name: .cameraFloatDidResize, object: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { revealControls() }

    override func mouseExited(with event: NSEvent) {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fadeControls(show: false) }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: item)
    }

    func revealControls() {
        hideWorkItem?.cancel()
        fadeControls(show: true)
        let item = DispatchWorkItem { [weak self] in self?.fadeControls(show: false) }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: item)
    }

    private func fadeControls(show: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            controlBar.animator().alphaValue = show ? 1 : 0
            modeButton.animator().alphaValue = show ? 1 : 0
        }
    }

    private var panStartMouse: NSPoint = .zero
    private var panStartOffset: CGSize = .zero
    private var isPanning = false
    private var isMovingWindow = false
    private var windowStartMouse: NSPoint = .zero
    private var windowStartOrigin: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        // 双击画面：回到默认取景
        if event.clickCount == 2 {
            resetFraming()
            return
        }
        let p = convert(event.locationInWindow, from: nil)

        // ⌘ / ⌥ + 拖动 永远移动窗口；否则按当前拖动模式
        if dragMode == .window ||
            event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            isMovingWindow = true
            windowStartMouse = NSEvent.mouseLocation
            windowStartOrigin = window?.frame.origin ?? .zero
            return
        }

        isPanning = true
        panStartMouse = p
        panStartOffset = pan
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        if isMovingWindow {
            guard let window = window else { return }
            let current = NSEvent.mouseLocation
            let origin = NSPoint(x: windowStartOrigin.x + (current.x - windowStartMouse.x),
                                 y: windowStartOrigin.y + (current.y - windowStartMouse.y))
            window.setFrameOrigin(origin)
            return
        }
        guard isPanning else { return }
        let p = convert(event.locationInWindow, from: nil)
        pan = CGSize(width: panStartOffset.width + (p.x - panStartMouse.x),
                     height: panStartOffset.height + (p.y - panStartMouse.y))
        syncLayers()
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning {
            NSCursor.pop()
            isPanning = false
            onFramingChanged?()
        }
        isMovingWindow = false
        NotificationCenter.default.post(name: .cameraFloatDidResize, object: nil)
    }

    override func scrollWheel(with event: NSEvent) {
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 0.6 : 3.2
        let dx = event.scrollingDeltaX * scale
        let dy = event.scrollingDeltaY * scale

        // ⌘ + 滚轮：缩放窗口本身
        if event.modifierFlags.contains(.command) {
            guard abs(dy) > 0.05 else { return }
            resizeWindow(by: min(1.12, max(0.88, 1 + dy * 0.006)))
            return
        }

        // 双指横向滑动：左右平移画面
        if abs(dx) > abs(dy) * 1.2 {
            pan.width += dx
            syncLayers()
            onFramingChanged?()
            return
        }

        // 纵向滚轮 / 捏合：以光标为中心缩放画面
        guard abs(dy) > 0.01 else { return }
        applyZoom(factor: min(1.14, max(0.87, 1 + dy * 0.01)),
                  around: convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        applyZoom(factor: 1 + event.magnification,
                  around: convert(event.locationInWindow, from: nil))
    }
}

// MARK: - 窗口

final class CameraFloatWindow: NSWindow {
    var handleKey: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if handleKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: CameraFloatWindow!
    private var content: CameraContentView!
    private var statusItem: NSStatusItem!
    private let camera = CameraController()

    private var cameraOn = false
    private var mirrored = UserDefaults.standard.object(forKey: Config.mirrorKey) as? Bool ?? true
    private var alwaysOnTop = UserDefaults.standard.object(forKey: Config.topKey) as? Bool ?? false
    private var permissionGranted = true
    private var frameAnchor = FrameAnchor(rawValue: UserDefaults.standard.string(forKey: Config.anchorKey) ?? "") ?? .right
    private var dragMode = DragMode(rawValue: UserDefaults.standard.string(forKey: Config.dragModeKey) ?? "") ?? .pan

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildWindow()
        buildStatusItem()
        wireCamera()
        checkPermissionAndStart()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 点击 Dock 图标时，若窗口已被隐藏则重新显示
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    /// 菜单栏顶部「配置」菜单：摄像头源 / 镜像 / 贴合方式 / 拖动模式 / 重置
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "摄像头悬浮窗")
        appMenu.addItem(withTitle: "关于 摄像头悬浮窗",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "显示悬浮窗", action: #selector(showWindow), keyEquivalent: "1").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏窗口", action: #selector(hideWindow), keyEquivalent: "w").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 摄像头悬浮窗", action: #selector(quit), keyEquivalent: "q").target = self
        appMenuItem.submenu = appMenu

        // ---- 配置 ----
        let configMenuItem = NSMenuItem()
        mainMenu.addItem(configMenuItem)
        let configMenu = NSMenu(title: "配置")
        appendConfigItems(to: configMenu)
        configMenuItem.submenu = configMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenuItem.submenu = editMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    /// 配置项在「配置」菜单与菜单栏图标菜单里共用
    private func appendConfigItems(to menu: NSMenu) {
        // 摄像头源
        let cameraItem = NSMenuItem(title: "摄像头源", action: nil, keyEquivalent: "")
        let cameraSubmenu = NSMenu()
        let devices = CameraController.availableDevices()
        if devices.isEmpty {
            let empty = cameraSubmenu.addItem(withTitle: "未检测到摄像头", action: nil, keyEquivalent: "")
            empty.isEnabled = false
        }
        for device in devices {
            let item = cameraSubmenu.addItem(withTitle: CameraController.displayName(for: device),
                                              action: #selector(selectDevice(_:)),
                                              keyEquivalent: "")
            item.target = self
            item.representedObject = device.uniqueID
            item.state = (device.uniqueID == camera.currentDeviceID) ? .on : .off
        }
        cameraSubmenu.addItem(.separator())
        let hint = cameraSubmenu.addItem(withTitle: "看右后方：把 iPhone 连续互通相机放到身后", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        cameraItem.submenu = cameraSubmenu
        menu.addItem(cameraItem)

        // 镜像
        let mirrorItem = menu.addItem(withTitle: "镜像画面（后视镜）",
                                      action: #selector(toggleMirrorFromMenu),
                                      keyEquivalent: "")
        mirrorItem.target = self
        mirrorItem.state = mirrored ? .on : .off

        menu.addItem(.separator())

        // 贴合方式：窗口比画面窄/宽时怎么处理
        let anchorItem = NSMenuItem(title: "缩放贴合方式", action: nil, keyEquivalent: "")
        let anchorSubmenu = NSMenu()
        for anchor in FrameAnchor.allCases {
            let item = anchorSubmenu.addItem(withTitle: anchor.title,
                                             action: #selector(selectAnchor(_:)),
                                             keyEquivalent: "")
            item.target = self
            item.representedObject = anchor.rawValue
            item.state = (anchor == frameAnchor) ? .on : .off
        }
        anchorItem.submenu = anchorSubmenu
        menu.addItem(anchorItem)

        // 拖动模式
        let dragItem = NSMenuItem(title: "拖动模式", action: nil, keyEquivalent: "")
        let dragSubmenu = NSMenu()
        for mode in DragMode.allCases {
            let item = dragSubmenu.addItem(withTitle: mode.title,
                                           action: #selector(selectDragMode(_:)),
                                           keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (mode == dragMode) ? .on : .off
        }
        dragItem.submenu = dragSubmenu
        menu.addItem(dragItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "重置取景（缩放/位置）", action: #selector(resetFraming), keyEquivalent: "0").target = self
        menu.addItem(withTitle: alwaysOnTop ? "置顶：开" : "置顶：关", action: #selector(toggleTop), keyEquivalent: "").target = self
        menu.addItem(withTitle: "重置窗口大小", action: #selector(resetSize), keyEquivalent: "").target = self
    }

    /// 配置变更后刷新两个菜单里的勾选状态
    private func refreshMenus() {
        buildMainMenu()
        // 启动阶段状态栏菜单可能还没建好，避免解开未初始化的可选值
        if statusItem != nil { rebuildMenu() }
    }

    // MARK: 构建 UI

    private func buildWindow() {
        camera.prepare()
        let frame = restoredFrame()

        window = CameraFloatWindow(contentRect: frame,
                                   styleMask: [.borderless, .resizable],
                                   backing: .buffered,
                                   defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = alwaysOnTop ? .floating : .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 关键：必须关掉「拖动背景移动窗口」。这个开关由 NSWindow 在窗口层
        // 直接吃掉鼠标拖动，视图里的平移手势根本轮不到，表现就是"拖哪都挪窗口"。
        // 移动窗口改为 ⌘/⌥ + 拖动，由 CameraContentView 自己处理。
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: Config.minWidth, height: Config.minHeight)
        window.animationBehavior = .none
        window.handleKey = { [weak self] event in
            guard let self = self else { return false }
            if event.keyCode == 49 { self.toggleCamera(); return true }              // 空格
            if event.keyCode == 53 { self.hideWindow(); return true }                // Esc
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "q" {
                NSApp.terminate(nil)
                return true
            }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
                self.hideWindow()
                return true
            }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "0" {
                self.content.resetFraming()
                return true
            }
            return false
        }

        content = CameraContentView(frame: NSRect(origin: .zero, size: frame.size), session: camera.session)
        content.autoresizingMask = [.width, .height]
        content.aspectProvider = { [weak self] in self?.camera.currentAspect ?? 16.0 / 9.0 }
        content.onToggleCamera = { [weak self] in self?.toggleCamera() }
        content.onTogglePin = { [weak self] in self?.toggleTop() }
        content.onClose = { [weak self] in self?.hideWindow() }
        content.onFramingChanged = { [weak self] in self?.persistFraming() }
        content.onDragModeChanged = { [weak self] in
            guard let self = self else { return }
            self.dragMode = self.content.dragMode
            UserDefaults.standard.set(self.dragMode.rawValue, forKey: Config.dragModeKey)
            self.refreshMenus()
        }
        content.controlBar.setPinned(alwaysOnTop)
        window.contentView = content

        // 先读存档再应用贴合方式：设置贴合方式会把平移归零并写回存档
        let savedZoom = UserDefaults.standard.object(forKey: Config.zoomKey) as? Double ?? 1
        let savedPanX = UserDefaults.standard.object(forKey: Config.panXKey) as? Double ?? 0
        let savedPanY = UserDefaults.standard.object(forKey: Config.panYKey) as? Double ?? 0
        content.frameAnchor = frameAnchor
        content.setDragMode(dragMode)
        content.restoreFraming(zoom: CGFloat(savedZoom),
                               pan: CGSize(width: savedPanX, height: savedPanY))

        NotificationCenter.default.addObserver(forName: .cameraFloatDidResize, object: nil, queue: .main) { [weak self] _ in
            self?.content.syncLayers()
            self?.persistFrame()
        }
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildMenu()
        }
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleDeviceDisconnected()
        }

        window.makeKeyAndOrderFront(nil)
        content.syncLayers()
        content.revealControls()
        persistFrame()
    }

    private func restoredFrame() -> NSRect {
        if let saved = UserDefaults.standard.string(forKey: Config.frameKey) {
            let rect = NSRectFromString(saved)
            if rect.width >= Config.minWidth, rect.height >= Config.minHeight, isOnSomeScreen(rect) {
                return rect
            }
        }
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: screenFrame.maxX - Config.defaultSize.width - 40,
                      y: screenFrame.maxY - Config.defaultSize.height - 40,
                      width: Config.defaultSize.width,
                      height: Config.defaultSize.height)
    }

    private func isOnSomeScreen(_ rect: NSRect) -> Bool {
        for screen in NSScreen.screens {
            let inter = screen.visibleFrame.intersection(rect)
            if !inter.isNull, inter.width >= 80, inter.height >= 60 { return true }
        }
        return false
    }

    private func persistFrame() {
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Config.frameKey)
    }

    private func persistFraming() {
        UserDefaults.standard.set(Double(content.currentZoom), forKey: Config.zoomKey)
        UserDefaults.standard.set(Double(content.currentPan.width), forKey: Config.panXKey)
        UserDefaults.standard.set(Double(content.currentPan.height), forKey: Config.panYKey)
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: "摄像头悬浮窗")
            button.image?.isTemplate = true
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "显示悬浮窗", action: #selector(showWindow), keyEquivalent: "1").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: cameraOn ? "关闭摄像头" : "开启摄像头", action: #selector(toggleCameraFromMenu), keyEquivalent: "").target = self

        appendConfigItems(to: menu)

        menu.addItem(.separator())
        let dragHint = menu.addItem(withTitle: "拖动＝当前拖动模式　⌘拖动＝移动窗口　滚轮＝缩放",
                                    action: nil, keyEquivalent: "")
        dragHint.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
    }

    // MARK: 摄像头源切换（仅菜单栏入口）

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        selectDevice(byID: id)
    }

    private func handleDeviceDisconnected() {
        rebuildMenu()
        let stillThere = CameraController.availableDevices().contains { $0.uniqueID == camera.currentDeviceID }
        guard !stillThere else { return }
        if let fallback = AVCaptureDevice.default(for: .video) {
            selectDevice(byID: fallback.uniqueID)
        }
    }

    private func selectDevice(byID id: String) {
        camera.switchDevice(to: id) { [weak self] ok in
            guard let self = self else { return }
            if ok, self.cameraOn {
                self.applyMirror()
            }
            self.refreshMenus()
        }
    }

    // MARK: 贴合方式 / 拖动模式

    @objc private func selectAnchor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let anchor = FrameAnchor(rawValue: raw) else { return }
        frameAnchor = anchor
        UserDefaults.standard.set(anchor.rawValue, forKey: Config.anchorKey)
        content.frameAnchor = anchor
        persistFraming()
        refreshMenus()
    }

    @objc private func selectDragMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = DragMode(rawValue: raw) else { return }
        dragMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Config.dragModeKey)
        content.setDragMode(mode)
        refreshMenus()
    }

    // MARK: 摄像头

    private func wireCamera() {
        camera.onRunningChanged = { [weak self] running in
            guard let self = self else { return }
            self.cameraOn = running
            self.content.controlBar.setCameraOn(running)
            if running {
                self.content.placeholder.isHidden = true
                self.applyMirror()
            } else if self.permissionGranted {
                self.content.placeholder.show(message: "摄像头已关闭", symbol: "video.slash", needsSettings: false)
            }
            self.rebuildMenu()
        }
    }

    private func checkPermissionAndStart() {
        CameraController.requestAccess { [weak self] granted in
            guard let self = self else { return }
            self.permissionGranted = granted
            if granted {
                self.camera.start()
            } else {
                self.cameraOn = false
                self.content.controlBar.setCameraOn(false)
                self.content.placeholder.show(message: "未获得摄像头权限", symbol: "lock.fill", needsSettings: true)
                self.rebuildMenu()
            }
        }
    }

    @objc private func toggleCamera() { toggleCameraInternal() }
    @objc private func toggleCameraFromMenu() { toggleCameraInternal() }

    private func toggleCameraInternal() {
        if cameraOn {
            camera.stop()
        } else {
            if permissionGranted {
                camera.start()
            } else {
                checkPermissionAndStart()
            }
        }
    }

    @objc private func toggleMirror() { toggleMirrorInternal() }
    @objc private func toggleMirrorFromMenu() { toggleMirrorInternal() }

    private func toggleMirrorInternal() {
        mirrored.toggle()
        UserDefaults.standard.set(mirrored, forKey: Config.mirrorKey)
        applyMirror()
        refreshMenus()
    }

    private func applyMirror() {
        guard let connection = content.previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }

    // MARK: 窗口操作

    @objc private func showWindow() {
        if !window.isVisible { window.makeKeyAndOrderFront(nil) }
        content.revealControls()
        persistFrame()
    }

    @objc private func hideWindow() {
        persistFrame()
        window.orderOut(nil)
    }

    @objc private func toggleTop() {
        alwaysOnTop.toggle()
        UserDefaults.standard.set(alwaysOnTop, forKey: Config.topKey)
        window.level = alwaysOnTop ? .floating : .normal
        if alwaysOnTop {
            window.orderFrontRegardless()
        } else {
            window.orderFront(nil)
        }
        content.controlBar.setPinned(alwaysOnTop)
        refreshMenus()
    }

    @objc private func resetFraming() {
        content.resetFraming()
        persistFraming()
    }

    @objc private func resetSize() {
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = Config.defaultSize
        let origin = NSPoint(x: screenFrame.maxX - size.width - 40, y: screenFrame.maxY - size.height - 40)
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
        content.syncLayers()
        persistFrame()
        showWindow()
    }

    @objc private func quit() {
        camera.stop()
        NSApp.terminate(nil)
    }
}

// MARK: - 入口

let app = NSApplication.shared
// .regular = 常规应用：出现在程序坞，可 ⌘Tab 切换，有自己的菜单栏
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
