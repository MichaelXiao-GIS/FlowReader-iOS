import UIKit
import MetalKit
import QuartzCore

@MainActor
final class ReaderCurlMetalRenderer: NSObject, MTKViewDelegate {
    struct Metrics {
        var submittedFrames = 0
        var skippedFrames = 0
        var maximumCPUTime: Double = 0
        var totalCPUTime: Double = 0
        var completedGPUFrames = 0
        var totalGPUTime: Double = 0
        var maximumGPUTime: Double = 0
        var failedGPUFrames = 0
    }

    final class Resources {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
        let shadowPipeline: MTLRenderPipelineState
        let depth: MTLDepthStencilState
        let shadowDepth: MTLDepthStencilState
        let vertices: MTLBuffer
        let indices: MTLBuffer
        let indexCount: Int
        let textureLoader: MTKTextureLoader
        var lastSubmitted: MTLCommandBuffer?

        init?() {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let library = device.makeDefaultLibrary(),
                  let vertex = library.makeFunction(name: "readerCurlVertex"),
                  let fragment = library.makeFunction(name: "readerCurlFragment"),
                  let shadowVertex = library.makeFunction(name: "readerCurlShadowVertex"),
                  let shadowFragment = library.makeFunction(name: "readerCurlShadowFragment") else { return nil }
            self.device = device; self.queue = queue
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.depthAttachmentPixelFormat = .depth32Float
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            do {
                pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
                descriptor.vertexFunction = shadowVertex; descriptor.fragmentFunction = shadowFragment
                shadowPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch { return nil }
            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.depthCompareFunction = .lessEqual
            depthDescriptor.isDepthWriteEnabled = true
            guard let depth = device.makeDepthStencilState(descriptor: depthDescriptor) else { return nil }
            self.depth = depth
            // A bent mesh can overlap its own projected shadow. Depth prevents
            // alpha accumulating into dark triangular patches at those overlaps.
            depthDescriptor.depthCompareFunction = .less
            depthDescriptor.isDepthWriteEnabled = true
            guard let shadowDepth = device.makeDepthStencilState(descriptor: depthDescriptor) else { return nil }
            self.shadowDepth = shadowDepth
            let segments = 64
            var grid: [SIMD2<Float>] = []
            var triangles: [UInt32] = []
            for y in 0...segments { for x in 0...segments {
                grid.append(SIMD2(Float(x) / Float(segments), Float(y) / Float(segments)))
            } }
            for y in 0..<segments { for x in 0..<segments {
                let a = UInt32(y * (segments + 1) + x), b = a + 1, c = a + UInt32(segments + 1), d = c + 1
                triangles += [a, b, c, b, d, c]
            } }
            guard let vertices = device.makeBuffer(bytes: grid, length: grid.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared),
                  let indices = device.makeBuffer(bytes: triangles, length: triangles.count * MemoryLayout<UInt32>.stride, options: .storageModeShared) else { return nil }
            self.vertices = vertices; self.indices = indices; indexCount = triangles.count
            textureLoader = MTKTextureLoader(device: device)
        }
    }

    static let sharedResources = Resources()
    let resources: Resources
    private let inFlight = DispatchSemaphore(value: 3)
    private(set) var metrics = Metrics()
    var uniforms: ReaderCurlUniforms?
    var front: MTLTexture?
    var back: MTLTexture?
    var isEnabled = false
    private var sessionID = UUID()

    init(resources: Resources) { self.resources = resources }

    func makeView() -> MTKView {
        let view = MTKView(frame: .zero, device: resources.device)
        view.delegate = self
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = true
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    func texture(from image: CGImage) throws -> MTLTexture {
        try resources.textureLoader.newTexture(cgImage: image, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft.rawValue])
    }

    func beginSession() { sessionID = UUID(); metrics = Metrics() }
    func clear() { uniforms = nil; front = nil; back = nil }
    func pause() {
        isEnabled = false
        // Apple's background contract requires already-committed work to reach
        // scheduled before returning to the system. This is never a per-frame wait.
        if let command = resources.lastSubmitted,
           command.status == .committed || command.status == .enqueued {
            command.waitUntilScheduled()
        }
        resources.lastSubmitted = nil
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

    func draw(in view: MTKView) {
        guard isEnabled, UIApplication.shared.applicationState == .active,
              var uniforms, let front, let back else { return }
        let start = CACurrentMediaTime()
        guard inFlight.wait(timeout: .now()) == .success else { metrics.skippedFrames += 1; return }
        guard let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = resources.queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { inFlight.signal(); return }
        command.label = "Interactive reader paper curl"
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(resources.vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ReaderCurlUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ReaderCurlUniforms>.stride, index: 1)
        encoder.setFragmentTexture(front, index: 0)
        encoder.setFragmentTexture(back, index: 1)
        encoder.setRenderPipelineState(resources.shadowPipeline)
        encoder.setDepthStencilState(resources.shadowDepth)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: resources.indexCount, indexType: .uint32,
                                      indexBuffer: resources.indices, indexBufferOffset: 0)
        encoder.setRenderPipelineState(resources.pipeline)
        encoder.setDepthStencilState(resources.depth)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: resources.indexCount, indexType: .uint32,
                                      indexBuffer: resources.indices, indexBufferOffset: 0)
        encoder.endEncoding()
        command.present(drawable)
        let semaphore = inFlight
        let id = sessionID
        command.addCompletedHandler { [weak self] buffer in
            semaphore.signal()
            let duration = buffer.gpuEndTime - buffer.gpuStartTime
            let failed = buffer.status == .error
            let errorCode = (buffer.error as NSError?)?.code
            DispatchQueue.main.async {
                guard let self, self.sessionID == id else { return }
                if self.resources.lastSubmitted === buffer { self.resources.lastSubmitted = nil }
                if failed {
                    self.metrics.failedGPUFrames += 1
                    #if DEBUG
                    print("READER_CURL_GPU_ERROR code=\(errorCode ?? -1)")
                    #endif
                }
                guard duration > 0, buffer.status == .completed else { return }
                self.metrics.completedGPUFrames += 1
                self.metrics.totalGPUTime += duration
                self.metrics.maximumGPUTime = max(self.metrics.maximumGPUTime, duration)
            }
        }
        command.commit()
        resources.lastSubmitted = command
        let elapsed = CACurrentMediaTime() - start
        metrics.submittedFrames += 1
        metrics.totalCPUTime += elapsed
        metrics.maximumCPUTime = max(metrics.maximumCPUTime, elapsed)
    }
}
