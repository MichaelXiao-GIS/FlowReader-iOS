import UIKit
import MetalKit
import QuartzCore

/// Static pages remain ordinary, accessible Core Text views. Only the moving sheet
/// is rasterized once and bent on the GPU; no text is laid out during a drag frame.
@MainActor
final class FlexiblePageController: UIViewController, UIGestureRecognizerDelegate {
    let pageCount: Int
    let doublePage: Bool
    private(set) var displayedIndex: Int
    private(set) var isTransitioning = false
    var onBegin: (() -> Void)?
    var onFinish: ((Int?) -> Void)?
    var onBoundary: ((Int) -> Void)?
    private let paper: UIColor
    private let makeLeaf: (Int) -> ReaderLeafController
    private let renderer: ReaderCurlMetalRenderer
    private let metalView: MTKView
    private let pageContainer = UIView()
    private var leaves: [ReaderLeafController] = []
    private var pan: UIPanGestureRecognizer!
    private var active: Turn?
    private var settling: Settle?
    private var displayLink: CADisplayLink?
    private var observers: [NSObjectProtocol] = []
    private var lastSize = CGSize.zero
    private var pendingBoundary: Int?
    private var textureCache: [Int: TextureEntry] = [:]
    private var textureOrder: [Int] = []
    private let textureBudget = 64 * 1024 * 1024
    private var snapshotTime: Double = 0
    private var cachedBytes = 0

    private struct TextureEntry {
        let texture: MTLTexture
        let cost: Int
    }
    private struct Turn {
        let target: Int
        let direction: Int
        let anchor: CGPoint
        var finger: CGPoint
        let originX: CGFloat
        let width: CGFloat
    }
    private struct Settle {
        let start: CFTimeInterval
        let duration: CFTimeInterval
        let from: CGPoint
        let to: CGPoint
        let commit: Bool
    }
    @MainActor private final class DisplayTarget: NSObject {
        weak var owner: FlexiblePageController?
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }

    init?(pageCount: Int, doublePage: Bool, index: Int, paper: UIColor, makeLeaf: @escaping (Int) -> ReaderLeafController) {
        guard let resources = ReaderCurlMetalRenderer.sharedResources else { return nil }
        self.pageCount = pageCount; self.doublePage = doublePage; displayedIndex = index
        self.paper = paper; self.makeLeaf = makeLeaf
        renderer = ReaderCurlMetalRenderer(resources: resources)
        metalView = renderer.makeView()
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = paper
        view.clipsToBounds = true
        view.insetsLayoutMarginsFromSafeArea = false
        view.accessibilityIdentifier = "reader-flexible-curl"
        pageContainer.backgroundColor = paper
        view.addSubview(pageContainer)
        view.addSubview(metalView)
        metalView.isHidden = true
        pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop(releaseTextures: true) }
            })
        }
        showPages(startingAt: displayedIndex)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if lastSize != view.bounds.size {
            if isTransitioning { finish(commit: false) }
            clearTextures()
            lastSize = view.bounds.size
        }
        pageContainer.frame = view.bounds
        metalView.frame = view.bounds
        metalView.contentScaleFactor = min(2, max(1, traitCollection.displayScale))
        layoutLeaves()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stop(releaseTextures: true)
    }

    deinit {
        displayLink?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func stop(releaseTextures: Bool = true) {
        renderer.pause()
        pendingBoundary = nil
        displayLink?.invalidate(); displayLink = nil
        if isTransitioning { finish(commit: false) }
        renderer.clear()
        if releaseTextures { clearTextures() }
    }

    func setIndex(_ index: Int) {
        if isTransitioning { finish(commit: false) }
        displayedIndex = bounded(index)
        showPages(startingAt: displayedIndex)
    }

    func advance(_ direction: Int) {
        guard !isTransitioning else { return }
        let delta = direction > 0 ? 1 : -1
        let target = displayedIndex + delta * (doublePage ? 2 : 1)
        guard target >= 0, target < pageCount else { onBoundary?(delta); return }
        let start = CGPoint(x: delta > 0 ? view.bounds.width * 0.92 : view.bounds.width * 0.08,
                            y: view.bounds.height * 0.72)
        guard begin(direction: delta, touch: start) else { return }
        settle(commit: true, velocity: .zero)
    }

    private func bounded(_ index: Int) -> Int {
        let bounded = max(0, min(index, max(0, pageCount - 1)))
        return doublePage ? bounded - bounded % 2 : bounded
    }

    private func showPages(startingAt index: Int) {
        setBasePages(doublePage ? [index, index + 1] : [index], hideAccessibility: false)
    }

    private func setBasePages(_ indices: [Int], hideAccessibility: Bool) {
        for leaf in leaves {
            leaf.willMove(toParent: nil); leaf.view.removeFromSuperview(); leaf.removeFromParent()
        }
        leaves = indices.map(makeLeaf)
        for leaf in leaves {
            addChild(leaf); pageContainer.addSubview(leaf.view); leaf.didMove(toParent: self)
        }
        pageContainer.accessibilityElementsHidden = hideAccessibility
        layoutLeaves()
    }

    private func layoutLeaves() {
        let width = view.bounds.width / CGFloat(doublePage ? 2 : 1)
        for (column, leaf) in leaves.enumerated() {
            leaf.view.frame = CGRect(x: CGFloat(column) * width, y: 0, width: width, height: view.bounds.height)
            leaf.view.setNeedsLayout(); leaf.view.layoutIfNeeded()
        }
    }

    private func texture(page index: Int, width: CGFloat) throws -> MTLTexture {
        if let cached = textureCache[index] {
            textureOrder.removeAll { $0 == index }; textureOrder.append(index)
            return cached.texture
        }
        let start = CACurrentMediaTime()
        let leaf = makeLeaf(index)
        leaf.loadViewIfNeeded()
        leaf.view.frame = CGRect(x: 0, y: 0, width: width, height: view.bounds.height)
        leaf.view.layoutIfNeeded()
        guard let image = leaf.snapshot(scale: min(2, max(1, traitCollection.displayScale))) else { throw SFAPIError.emptyContent }
        let texture = try renderer.texture(from: image)
        let cost = max(texture.allocatedSize, texture.width * texture.height * 4)
        if cost <= textureBudget {
            while textureOrder.count >= 6 || cachedBytes + cost > textureBudget {
                guard !textureOrder.isEmpty else { break }
                let evicted = textureOrder.removeFirst()
                if let old = textureCache.removeValue(forKey: evicted) { cachedBytes -= old.cost }
            }
            textureCache[index] = TextureEntry(texture: texture, cost: cost)
            textureOrder.append(index); cachedBytes += cost
        }
        snapshotTime += CACurrentMediaTime() - start
        return texture
    }

    private func clearTextures() {
        textureCache.removeAll(); textureOrder.removeAll(); cachedBytes = 0
    }

    @discardableResult
    private func begin(direction: Int, touch: CGPoint) -> Bool {
        guard !isTransitioning, view.bounds.width > 0, view.bounds.height > 0,
              UIApplication.shared.applicationState == .active else { return false }
        guard let plan = ReaderCurlPageTurn(index: displayedIndex, direction: direction, pageCount: pageCount, doublePage: doublePage) else {
            pendingBoundary = direction; return false
        }
        pendingBoundary = nil
        let width = view.bounds.width / CGFloat(doublePage ? 2 : 1)
        let originX = doublePage && direction > 0 ? width : 0
        let localX = direction > 0 ? touch.x - originX : width - touch.x
        let anchor = CGPoint(x: min(width, max(width * 0.35, localX)), y: min(max(8, touch.y), view.bounds.height - 8))
        snapshotTime = 0
        do {
            renderer.front = try texture(page: plan.front, width: width)
            renderer.back = try texture(page: plan.back, width: width)
        } catch { renderer.clear(); return false }
        active = Turn(target: plan.target, direction: direction, anchor: anchor, finger: anchor, originX: originX, width: width)
        isTransitioning = true
        onBegin?()
        setBasePages(plan.basePages, hideAccessibility: true)
        renderer.beginSession()
        renderer.isEnabled = true
        updateUniforms()
        metalView.isHidden = false
        metalView.draw()
        startDisplayLink()
        return true
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let target = DisplayTarget(); target.owner = self
        let link = CADisplayLink(target: target, selector: #selector(DisplayTarget.tick(_:)))
        let maximum = Float(view.window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func updateUniforms() {
        guard let turn = active else { return }
        let geometry = ReaderCurlGeometry(pageSize: CGSize(width: turn.width, height: view.bounds.height), anchor: turn.anchor, finger: turn.finger)
        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
        paper.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        renderer.uniforms = ReaderCurlUniforms(
            viewportAndPage: SIMD4(Float(view.bounds.width), Float(view.bounds.height), Float(turn.width), Float(view.bounds.height)),
            anchorAndFinger: SIMD4(Float(turn.anchor.x), Float(turn.anchor.y), Float(turn.finger.x), Float(turn.finger.y)),
            placement: SIMD4(Float(turn.originX), Float(turn.direction), Float(geometry.radius), Float(geometry.progress)),
            paper: SIMD4(Float(red), Float(green), Float(blue), 1), options: SIMD4(doublePage ? 1 : 0, 0, 0, 0))
    }

    private func settle(commit: Bool, velocity: CGPoint) {
        guard let turn = active else { return }
        let target = commit ? CGPoint(x: -turn.anchor.x, y: turn.anchor.y) : turn.anchor
        let remaining = hypot(target.x - turn.finger.x, target.y - turn.finger.y) / max(1, turn.width * 2)
        let duration = min(0.44, max(0.18, Double(remaining) * 0.36))
        settling = Settle(start: CACurrentMediaTime(), duration: duration, from: turn.finger, to: target, commit: commit)
        startDisplayLink()
    }

    private func tick(_ link: CADisplayLink) {
        guard UIApplication.shared.applicationState == .active else { stop(); return }
        if let settle = settling, var turn = active {
            let t = min(1, max(0, (CACurrentMediaTime() - settle.start) / settle.duration))
            let eased = 1 - pow(1 - t, 3)
            turn.finger = CGPoint(x: settle.from.x + (settle.to.x - settle.from.x) * eased,
                                  y: settle.from.y + (settle.to.y - settle.from.y) * eased)
            active = turn
            updateUniforms()
            if t >= 1 { finish(commit: settle.commit); return }
        }
        metalView.draw()
    }

    private func finish(commit: Bool) {
        guard let turn = active else { return }
        renderer.isEnabled = false
        displayLink?.invalidate(); displayLink = nil
        active = nil; settling = nil; isTransitioning = false
        if commit { displayedIndex = turn.target }
        showPages(startingAt: displayedIndex)
        metalView.isHidden = true
        renderer.clear()
        #if DEBUG
        let metrics = renderer.metrics
        let cpu = metrics.totalCPUTime * 1000 / Double(max(1, metrics.submittedFrames))
        let gpu = metrics.totalGPUTime * 1000 / Double(max(1, metrics.completedGPUFrames))
        print("READER_CURL_METRICS frames=\(metrics.submittedFrames) skipped=\(metrics.skippedFrames) cpuMeanMS=\(String(format: "%.3f", cpu)) cpuMaxMS=\(String(format: "%.3f", metrics.maximumCPUTime * 1000)) gpuSamples=\(metrics.completedGPUFrames) gpuMeanMS=\(String(format: "%.3f", gpu)) gpuMaxMS=\(String(format: "%.3f", metrics.maximumGPUTime * 1000)) gpuErrors=\(metrics.failedGPUFrames) snapshotMS=\(String(format: "%.3f", snapshotTime * 1000)) cacheBytes=\(cachedBytes) committed=\(commit)")
        #endif
        onFinish?(commit ? displayedIndex : nil)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, !isTransitioning else { return false }
        let velocity = pan.velocity(in: view)
        return abs(velocity.x) > 12 && abs(velocity.x) > abs(velocity.y) * 0.35
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .began:
            let direction = gesture.velocity(in: view).x < 0 ? 1 : -1
            let point = gesture.location(in: view)
            _ = begin(direction: direction, touch: CGPoint(x: point.x - translation.x, y: point.y - translation.y))
            fallthrough
        case .changed:
            guard var turn = active, settling == nil else { return }
            let travel = min(0, translation.x * CGFloat(turn.direction))
            let verticalWeight = min(1, -travel / 16)
            turn.finger = CGPoint(x: turn.anchor.x + travel,
                                  y: turn.anchor.y + min(max(translation.y, -view.bounds.height * 0.8), view.bounds.height * 0.8) * verticalWeight)
            active = turn
            updateUniforms()
        case .ended:
            let velocity = gesture.velocity(in: view)
            if let boundary = pendingBoundary {
                pendingBoundary = nil
                if ReaderCurlGeometry.shouldCommit(translation: translation, velocity: velocity,
                                                    pageWidth: view.bounds.width * 0.5, direction: boundary) { onBoundary?(boundary) }
                return
            }
            guard let turn = active else { return }
            settle(commit: ReaderCurlGeometry.shouldCommit(translation: translation, velocity: velocity, pageWidth: turn.width, direction: turn.direction), velocity: velocity)
        case .cancelled, .failed: pendingBoundary = nil; settle(commit: false, velocity: .zero)
        default: break
        }
    }
}
