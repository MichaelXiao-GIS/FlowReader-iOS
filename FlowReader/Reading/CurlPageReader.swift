import SwiftUI
import UIKit
import CoreText

/// A flexible Metal paper surface with a native reduced-motion fallback.
/// Pagination, static views and moving textures share the exact same Core Text frames.
struct CurlPageReader: UIViewControllerRepresentable {
    let pagination: ReaderPagination
    @Binding var currentPosition: ReaderTextPosition
    let doublePage: Bool
    let background: UIColor
    let foreground: UIColor
    let bookTitle: String
    let chapterTitle: String
    let onToggleChrome: () -> Void
    let onChapterBoundary: (Int) -> Void
    let reduceMotion: Bool
    let safeAreaInsets: UIEdgeInsets
    let occlusions: [CGRect]

    init(pagination: ReaderPagination, currentPosition: Binding<ReaderTextPosition>, doublePage: Bool,
         background: UIColor, foreground: UIColor, bookTitle: String, chapterTitle: String,
         onToggleChrome: @escaping () -> Void, onChapterBoundary: @escaping (Int) -> Void,
         reduceMotion: Bool = false, safeAreaInsets: UIEdgeInsets = .zero, occlusions: [CGRect] = []) {
        self.pagination = pagination
        _currentPosition = currentPosition
        self.doublePage = doublePage
        self.background = background
        self.foreground = foreground
        self.bookTitle = bookTitle
        self.chapterTitle = chapterTitle
        self.onToggleChrome = onToggleChrome
        self.onChapterBoundary = onChapterBoundary
        self.reduceMotion = reduceMotion
        self.safeAreaInsets = safeAreaInsets
        self.occlusions = occlusions
    }

    static func textSize(for availableSize: CGSize, doublePage: Bool, safeAreaInsets: UIEdgeInsets = .zero, occlusions: [CGRect] = []) -> CGSize {
        CurlPageLayout(size: availableSize, doublePage: doublePage, safeAreaInsets: safeAreaInsets, occlusions: occlusions).textSize
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> ContainerController {
        let controller = ContainerController()
        context.coordinator.attach(to: controller)
        context.coordinator.update(self)
        return controller
    }

    func updateUIViewController(_ uiViewController: ContainerController, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleUIViewController(_ uiViewController: ContainerController, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class ContainerController: UIViewController {
        override func loadView() {
            view = UIView()
            view.clipsToBounds = true
            view.insetsLayoutMarginsFromSafeArea = false
            edgesForExtendedLayout = .all
            extendedLayoutIncludesOpaqueBars = true
            view.accessibilityIdentifier = "reader-content"
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        private var owner: CurlPageReader
        private weak var host: ContainerController?
        private var pager: UIPageViewController?
        private var flexible: FlexiblePageController?
        private var rendered: CurlPageReader?
        private var displayedIndex = 0
        private var transitioning = false
        private var gestureStartPosition: ReaderTextPosition?
        private var boundaryDirection: Int?
        private var tap: UITapGestureRecognizer?
        private var boundaryPan: UIPanGestureRecognizer?

        init(_ owner: CurlPageReader) { self.owner = owner }

        func attach(to host: ContainerController) {
            self.host = host
            host.loadViewIfNeeded()
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.cancelsTouchesInView = false
            host.view.addGestureRecognizer(tap)
            self.tap = tap
            let pan = UIPanGestureRecognizer(target: self, action: #selector(boundarySwiped(_:)))
            pan.cancelsTouchesInView = false
            pan.delegate = self
            host.view.addGestureRecognizer(pan)
            boundaryPan = pan
        }

        func detach() {
            removePager()
            if let tap { host?.view.removeGestureRecognizer(tap) }
            if let boundaryPan { host?.view.removeGestureRecognizer(boundaryPan) }
            host = nil
        }

        func update(_ newOwner: CurlPageReader) {
            owner = newOwner
            guard let host else { return }
            host.view.backgroundColor = owner.background
            let changed = rendered.map { !sameLayout($0, owner) } ?? true
            let target = normalized(owner.pagination.pageIndex(for: owner.currentPosition), double: owner.doublePage)
            // Replacing the native controller cancels a rotation/reflow transition without
            // allowing its late delegate callback to overwrite the saved text position.
            if changed || (transitioning && gestureStartPosition != owner.currentPosition) {
                install(at: target)
            } else if !transitioning && target != displayedIndex {
                displayedIndex = target
                if let flexible { flexible.setIndex(target) }
                else { pager?.setViewControllers(visibleControllers(startingAt: target), direction: .forward, animated: false) }
            }
        }

        private func sameLayout(_ lhs: CurlPageReader, _ rhs: CurlPageReader) -> Bool {
            lhs.pagination.id == rhs.pagination.id && lhs.doublePage == rhs.doublePage && lhs.reduceMotion == rhs.reduceMotion &&
            lhs.bookTitle == rhs.bookTitle && lhs.chapterTitle == rhs.chapterTitle &&
            lhs.safeAreaInsets.top == rhs.safeAreaInsets.top && lhs.safeAreaInsets.bottom == rhs.safeAreaInsets.bottom &&
            lhs.safeAreaInsets.left == rhs.safeAreaInsets.left && lhs.safeAreaInsets.right == rhs.safeAreaInsets.right &&
            lhs.occlusions == rhs.occlusions &&
            lhs.background.isEqual(rhs.background) && lhs.foreground.isEqual(rhs.foreground)
        }

        private func removePager() {
            if let flexible {
                self.flexible = nil
                flexible.stop()
                flexible.willMove(toParent: nil)
                flexible.view.removeFromSuperview()
                flexible.removeFromParent()
            }
            transitioning = false
            gestureStartPosition = nil
            guard let pager else { return }
            pager.dataSource = nil
            pager.delegate = nil
            pager.willMove(toParent: nil)
            pager.view.removeFromSuperview()
            pager.removeFromParent()
            self.pager = nil
            transitioning = false
            gestureStartPosition = nil
        }

        private func install(at index: Int) {
            guard let host else { return }
            removePager()
            rendered = owner
            displayedIndex = index
            if !owner.reduceMotion, let surface = FlexiblePageController(pageCount: owner.pagination.pages.count,
                                                                         doublePage: owner.doublePage, index: index,
                                                                         paper: owner.background, makeLeaf: { [weak self] page in
                guard let self else { preconditionFailure("Reader coordinator must outlive its page controller") }
                return self.leaf(page)
            }) {
                flexible = surface
                boundaryPan?.isEnabled = false
                surface.onBegin = { [weak self, weak surface] in
                    guard let self, self.flexible === surface else { return }
                    self.transitioning = true
                    self.gestureStartPosition = self.owner.currentPosition
                }
                surface.onFinish = { [weak self, weak surface] index in
                    guard let self, self.flexible === surface else { return }
                    self.transitioning = false
                    self.gestureStartPosition = nil
                    if let index { self.publish(index: index) }
                }
                surface.onBoundary = { [weak self, weak surface] direction in
                    guard let self, self.flexible === surface else { return }
                    self.owner.onChapterBoundary(direction)
                }
                host.addChild(surface)
                surface.view.frame = host.view.bounds
                surface.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                host.view.addSubview(surface.view)
                surface.didMove(toParent: host)
                return
            }
            boundaryPan?.isEnabled = true
            let options: [UIPageViewController.OptionsKey: Any] = owner.reduceMotion ? [:] : [
                .spineLocation: NSNumber(value: (owner.doublePage ? UIPageViewController.SpineLocation.mid : .min).rawValue)
            ]
            let pager = UIPageViewController(transitionStyle: owner.reduceMotion ? .scroll : .pageCurl,
                                             navigationOrientation: .horizontal, options: options)
            self.pager = pager
            if !owner.reduceMotion { pager.isDoubleSided = owner.doublePage }
            pager.dataSource = self
            pager.delegate = self
            pager.view.backgroundColor = owner.background
            pager.view.insetsLayoutMarginsFromSafeArea = false
            pager.edgesForExtendedLayout = .all
            pager.extendedLayoutIncludesOpaqueBars = true
            host.addChild(pager)
            pager.view.frame = host.view.bounds
            pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.view.addSubview(pager.view)
            pager.didMove(toParent: host)
            pager.setViewControllers(visibleControllers(startingAt: index), direction: .forward, animated: false)
            // Keep the system's interactive curl pans, but reserve the centre tap for chrome.
            for recognizer in pager.gestureRecognizers where recognizer is UITapGestureRecognizer {
                recognizer.isEnabled = false
            }
        }

        private func normalized(_ index: Int, double: Bool) -> Int {
            let bounded = max(0, min(index, max(0, owner.pagination.pages.count - 1)))
            return double ? bounded - bounded % 2 : bounded
        }

        private func leaf(_ index: Int) -> ReaderLeafController {
            let model = rendered ?? owner
            let page = model.pagination.pages.indices.contains(index) ? model.pagination.pages[index] : nil
            let host = self.host
            return ReaderLeafController(index: index, page: page, count: model.pagination.pages.count,
                                        textSize: model.pagination.textSize, background: model.background,
                                        foreground: model.foreground, column: model.doublePage ? index % 2 : 0,
                                        layout: { [weak host] in
                                            CurlPageLayout(size: host?.view.bounds.size ?? .zero, doublePage: model.doublePage,
                                                           safeAreaInsets: model.safeAreaInsets, occlusions: model.occlusions)
                                        },
                                        title: model.bookTitle + " · " + model.chapterTitle,
                                        onToggle: { [weak self] in self?.owner.onToggleChrome() },
                                        onMove: { [weak self] in self?.advance($0) },
                                        onBoundary: { [weak self] in self?.owner.onChapterBoundary($0) })
        }

        private func visibleControllers(startingAt index: Int) -> [UIViewController] {
            let model = rendered ?? owner
            if model.reduceMotion && model.doublePage {
                return [ReaderSpreadController(startIndex: index, leaves: [leaf(index), leaf(index + 1)])]
            }
            return model.doublePage ? [leaf(index), leaf(index + 1)] : [leaf(index)]
        }

        private func index(of controller: UIViewController) -> Int? {
            (controller as? ReaderLeafController)?.pageIndex ?? (controller as? ReaderSpreadController)?.startIndex
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard pageViewController === pager, let index = index(of: viewController), let model = rendered else { return nil }
            let step = model.reduceMotion && model.doublePage ? 2 : 1
            guard index - step >= 0 else { return nil }
            return step == 2 ? ReaderSpreadController(startIndex: index - 2, leaves: [leaf(index - 2), leaf(index - 1)]) : leaf(index - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard pageViewController === pager, let index = index(of: viewController), let model = rendered else { return nil }
            if model.reduceMotion && model.doublePage {
                guard index + 2 < model.pagination.pages.count else { return nil }
                return ReaderSpreadController(startIndex: index + 2, leaves: [leaf(index + 2), leaf(index + 3)])
            }
            let paddedCount = model.doublePage ? model.pagination.pages.count + model.pagination.pages.count % 2 : model.pagination.pages.count
            guard index + 1 < paddedCount else { return nil }
            return leaf(index + 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            guard pageViewController === pager else { return }
            transitioning = true
            gestureStartPosition = owner.currentPosition
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard pageViewController === pager else { return }
            transitioning = false
            gestureStartPosition = nil
            if completed { publishVisiblePosition() }
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                spineLocationFor orientation: UIInterfaceOrientation) -> UIPageViewController.SpineLocation {
            // SwiftUI supplies the actual viewport, which is more reliable than device orientation.
            rendered?.doublePage == true ? .mid : .min
        }

        private func publishVisiblePosition() {
            guard let model = rendered, let pager,
                  let index = pager.viewControllers?.compactMap({ self.index(of: $0) }).min(),
                  model.pagination.pages.indices.contains(index) else { return }
            publish(index: index)
        }

        private func publish(index: Int) {
            guard let model = rendered, model.pagination.pages.indices.contains(index) else { return }
            displayedIndex = normalized(index, double: model.doublePage)
            owner.currentPosition = model.pagination.pages[displayedIndex].startPosition
            UIAccessibility.post(notification: .pageScrolled,
                                 argument: "第 \(displayedIndex + 1) 页，共 \(model.pagination.pages.count) 页")
        }

        private func advance(_ delta: Int) {
            guard !transitioning else { return }
            if let flexible { flexible.advance(delta); return }
            guard let model = rendered, let pager, !model.pagination.pages.isEmpty else { return }
            let target = displayedIndex + delta * (model.doublePage ? 2 : 1)
            guard target >= 0, target < model.pagination.pages.count else { owner.onChapterBoundary(delta); return }
            transitioning = true
            gestureStartPosition = owner.currentPosition
            pager.setViewControllers(visibleControllers(startingAt: target), direction: delta > 0 ? .forward : .reverse,
                                     animated: !model.reduceMotion) { [weak self, weak pager] finished in
                guard let self, let pager, pager === self.pager else { return }
                self.transitioning = false
                self.gestureStartPosition = nil
                if finished { self.publishVisiblePosition() }
            }
        }

        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = host?.view, gesture.state == .ended else { return }
            let fraction = gesture.location(in: view).x / max(1, view.bounds.width)
            if fraction < 0.24 { advance(-1) }
            else if fraction > 0.76 { advance(1) }
            else { owner.onToggleChrome() }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === boundaryPan, let pan = boundaryPan, let view = host?.view,
                  let model = rendered, !transitioning else { return false }
            let velocity = pan.velocity(in: view)
            guard abs(velocity.x) > abs(velocity.y), abs(velocity.x) > 20 else { return false }
            let direction = velocity.x < 0 ? 1 : -1
            let boundary = direction < 0 ? displayedIndex == 0 : displayedIndex + (model.doublePage ? 2 : 1) >= model.pagination.pages.count
            boundaryDirection = boundary ? direction : nil
            return boundary
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer === boundaryPan || otherGestureRecognizer === boundaryPan
        }

        @objc private func boundarySwiped(_ gesture: UIPanGestureRecognizer) {
            guard let view = host?.view else { return }
            if gesture.state == .ended, let direction = boundaryDirection {
                let translation = gesture.translation(in: view).x
                let velocity = gesture.velocity(in: view).x
                let distance = max(55, view.bounds.width * 0.12)
                let completed = abs(translation) > distance || (abs(translation) > 20 && abs(velocity) > 700)
                if completed && (translation < 0 ? 1 : -1) == direction { owner.onChapterBoundary(direction) }
            }
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed { boundaryDirection = nil }
        }
    }
}

final class ReaderLeafController: UIViewController {
    let pageIndex: Int
    private let page: ReaderPage?
    private let pageCount: Int
    private let textSize: CGSize
    private let paper: UIColor
    private let ink: UIColor
    private let column: Int
    private let pageLayout: () -> CurlPageLayout
    private let runningTitle: String
    private let onToggle: () -> Void
    private let onMove: (Int) -> Void
    private let onBoundary: (Int) -> Void
    private let header = UILabel()
    private let number = UILabel()
    private let textView = ReaderTextCanvas()

    init(index: Int, page: ReaderPage?, count: Int, textSize: CGSize, background: UIColor,
         foreground: UIColor, column: Int, layout: @escaping () -> CurlPageLayout, title: String, onToggle: @escaping () -> Void,
         onMove: @escaping (Int) -> Void, onBoundary: @escaping (Int) -> Void) {
        pageIndex = index; self.page = page; pageCount = count; self.textSize = textSize
        paper = background; ink = foreground; runningTitle = title
        self.column = column; pageLayout = layout
        self.onToggle = onToggle; self.onMove = onMove; self.onBoundary = onBoundary
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = paper
        view.isOpaque = true
        view.clipsToBounds = true
        view.insetsLayoutMarginsFromSafeArea = false
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        guard let page else { view.accessibilityElementsHidden = true; return }
        header.text = runningTitle
        header.font = .systemFont(ofSize: 11, weight: .regular)
        header.textColor = ink.withAlphaComponent(0.48)
        header.lineBreakMode = .byTruncatingMiddle
        header.accessibilityIdentifier = "reader-chapter-title"
        number.text = "\(pageIndex + 1) / \(pageCount)"
        number.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        number.textAlignment = .center
        number.textColor = ink.withAlphaComponent(0.45)
        number.accessibilityLabel = "第 \(pageIndex + 1) 页，共 \(pageCount) 页"
        number.accessibilityIdentifier = "reader-page-number"
        let text = NSMutableAttributedString(attributedString: page.attributedText)
        let range = NSRange(location: 0, length: text.length)
        text.removeAttribute(.foregroundColor, range: range)
        text.removeAttribute(NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String), range: range)
        text.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: ink.cgColor, range: range)
        textView.attributedText = text
        textView.textSize = textSize
        textView.onToggle = onToggle
        textView.onMove = onMove
        textView.accessibilityIdentifier = "reader-page-text"
        textView.accessibilityLabel = text.string
        textView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "上一页", actionHandler: { [weak self] _ in self?.onMove(-1); return true }),
            UIAccessibilityCustomAction(name: "下一页", actionHandler: { [weak self] _ in self?.onMove(1); return true }),
            UIAccessibilityCustomAction(name: "显示或隐藏阅读工具", actionHandler: { [weak self] _ in self?.onToggle(); return true })
        ]
        if pageIndex == 0 {
            textView.accessibilityCustomActions?.append(UIAccessibilityCustomAction(name: "上一章", actionHandler: { [weak self] _ in self?.onBoundary(-1); return true }))
        }
        if pageIndex == pageCount - 1 {
            textView.accessibilityCustomActions?.append(UIAccessibilityCustomAction(name: "下一章", actionHandler: { [weak self] _ in self?.onBoundary(1); return true }))
        }
        view.addSubview(header)
        view.addSubview(textView)
        view.addSubview(number)
    }

    func snapshot(scale: CGFloat) -> CGImage? {
        loadViewIfNeeded()
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.preferredRange = .standard
        format.opaque = true
        let geometry = pageLayout()
        return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { output in
            paper.setFill(); output.fill(view.bounds)
            guard page != nil else { return }
            let headingStyle = NSMutableParagraphStyle()
            headingStyle.lineBreakMode = .byTruncatingMiddle
            (runningTitle as NSString).draw(in: geometry.headerFrame(column: column), withAttributes: [
                .font: UIFont.systemFont(ofSize: 11), .foregroundColor: ink.withAlphaComponent(0.48), .paragraphStyle: headingStyle
            ])
            let numberStyle = NSMutableParagraphStyle(); numberStyle.alignment = .center
            ("\(pageIndex + 1) / \(pageCount)" as NSString).draw(in: geometry.footerFrame(column: column), withAttributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: ink.withAlphaComponent(0.45), .paragraphStyle: numberStyle
            ])
            output.cgContext.saveGState()
            output.cgContext.translateBy(x: geometry.textFrame.minX, y: geometry.textFrame.minY)
            ReaderTextCanvas.drawText(textView.attributedText, size: textSize, context: output.cgContext)
            output.cgContext.restoreGState()
        }.cgImage
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let geometry = pageLayout()
        header.frame = geometry.headerFrame(column: column)
        // The frame origin and the pagination size come from the same layout rule.
        // Preserve the exact published size while UIKit rounds half-page bounds.
        textView.frame = CGRect(origin: geometry.textFrame.origin, size: textSize)
        number.frame = geometry.footerFrame(column: column)
    }
}

private final class ReaderSpreadController: UIViewController {
    let startIndex: Int
    private let leaves: [ReaderLeafController]
    init(startIndex: Int, leaves: [ReaderLeafController]) {
        self.startIndex = startIndex; self.leaves = leaves
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.insetsLayoutMarginsFromSafeArea = false
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        for leaf in leaves { addChild(leaf); view.addSubview(leaf.view); leaf.didMove(toParent: self) }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width / 2
        for (index, leaf) in leaves.enumerated() {
            leaf.view.frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: view.bounds.height)
        }
    }
}

private final class ReaderTextCanvas: UIView {
    var attributedText = NSAttributedString(string: "")
    var textSize = CGSize.zero
    var onToggle: (() -> Void)?
    var onMove: ((Int) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), attributedText.length > 0 else { return }
        Self.drawText(attributedText, size: textSize, context: context)
    }

    static func drawText(_ attributedText: NSAttributedString, size: CGSize, context: CGContext) {
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let setter = CTFramesetterCreateWithAttributedString(attributedText)
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: attributedText.length), path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
    override func accessibilityActivate() -> Bool { onToggle?(); return true }
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        switch direction {
        case .left: onMove?(1); return true
        case .right: onMove?(-1); return true
        default: return false
        }
    }
}
