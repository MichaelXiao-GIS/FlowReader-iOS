import Foundation
import AppKit
import Metal
import MetalKit
import CoreText
import ImageIO

struct Uniforms { var viewportAndPage:SIMD4<Float>; var anchorAndFinger:SIMD4<Float>; var placement:SIMD4<Float>; var paper:SIMD4<Float>; var options:SIMD4<Float> }
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
// Run from the repository root: swift scripts/preview-curl.swift [output-directory].
// This measures only macOS offscreen GPU work, not iPhone frame rate or input latency.
let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputDirectory = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : FileManager.default.temporaryDirectory.appendingPathComponent("flow-curl-preview")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let shader = try String(contentsOf: repository.appendingPathComponent("FlowReader/Reading/ReaderCurl.metal"), encoding:.utf8)
let lib = try device.makeLibrary(source:shader,options:nil)
let desc=MTLRenderPipelineDescriptor();desc.colorAttachments[0].pixelFormat = .bgra8Unorm;desc.depthAttachmentPixelFormat = .depth32Float
let attachment=desc.colorAttachments[0]!;attachment.isBlendingEnabled=true;attachment.sourceRGBBlendFactor = .one;attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha;attachment.sourceAlphaBlendFactor = .one;attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
func pipeline(_ vertex:String,_ fragment:String)throws->MTLRenderPipelineState { desc.vertexFunction=lib.makeFunction(name:vertex);desc.fragmentFunction=lib.makeFunction(name:fragment);return try device.makeRenderPipelineState(descriptor:desc) }
let main=try pipeline("readerCurlVertex","readerCurlFragment"), shadow=try pipeline("readerCurlShadowVertex","readerCurlShadowFragment")
let dd=MTLDepthStencilDescriptor();dd.depthCompareFunction = .lessEqual;dd.isDepthWriteEnabled=true;let depth=device.makeDepthStencilState(descriptor:dd)!
dd.depthCompareFunction = .less;dd.isDepthWriteEnabled=true;let shadowDepth=device.makeDepthStencilState(descriptor:dd)!
let n=64;var grid:[SIMD2<Float>]=[];var ix:[UInt32]=[]
for y in 0...n {for x in 0...n {grid.append(SIMD2(Float(x)/Float(n),Float(y)/Float(n)))}}
for y in 0..<n {for x in 0..<n {let a=UInt32(y*(n+1)+x),b=a+1,c=a+UInt32(n+1),d=c+1;ix += [a,b,c,b,d,c]}}
let vb=device.makeBuffer(bytes:grid,length:grid.count*MemoryLayout<SIMD2<Float>>.stride)!,ib=device.makeBuffer(bytes:ix,length:ix.count*4)!
let width=800,height=700,pageWidth=400
let space=CGColorSpaceCreateDeviceRGB()
func context(_ w:Int,_ h:Int)->CGContext {CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!}
let paper=CGColor(red:0.97,green:0.95,blue:0.90,alpha:1)
func page(_ title:String,_ number:Int)->CGImage {
 let c=context(pageWidth,height);c.setFillColor(paper);c.fill(CGRect(x:0,y:0,width:pageWidth,height:height))
 let words = [title,"","这是一段专为卷页效果编写的原创文字。海边书店的窗子开着，风把蓝色信封轻轻推到桌角。","","阿澄按住纸页，沿着地图上的小径寻找灯塔。纸张从指尖弯起，背面的微光像一片慢慢舒展的帆。","","他读完最后一句，抬头望向窗外。潮水刚刚退去，石阶上留下细小的银色水迹。","","信中没有催促，只写着：等风停了，我们再出发。"]
 let style=NSMutableParagraphStyle();style.lineSpacing=8;style.paragraphSpacing=10
 let text=NSAttributedString(string:words.joined(separator:"\n"),attributes:[.font:NSFont.systemFont(ofSize:21),.foregroundColor:NSColor(calibratedWhite:0.17,alpha:1),.paragraphStyle:style])
 let setter=CTFramesetterCreateWithAttributedString(text);let frame=CTFramesetterCreateFrame(setter,CFRange(location:0,length:text.length),CGPath(rect:CGRect(x:24,y:58,width:352,height:594),transform:nil),nil);CTFrameDraw(frame,c)
 let footer=NSAttributedString(string:"原创试读 · 第 \(number) 页",attributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.gray]);let line=CTLineCreateWithAttributedString(footer);c.textPosition=CGPoint(x:140,y:25);CTLineDraw(line,c)
 return c.makeImage()!
}
let frontImage=page("海边书店 · 蓝色的信",2),backImage=page("海边书店 · 风停以后",3)
let base=context(width,height);base.draw(page("海边书店 · 来信",1),in:CGRect(x:0,y:0,width:400,height:700));base.draw(page("海边书店 · 灯塔",4),in:CGRect(x:400,y:0,width:400,height:700));let baseImage=base.makeImage()!
let loader=MTKTextureLoader(device:device)
let front=try loader.newTexture(cgImage:frontImage,options:[.SRGB:false,.origin:MTKTextureLoader.Origin.topLeft.rawValue]),back=try loader.newTexture(cgImage:backImage,options:[.SRGB:false,.origin:MTKTextureLoader.Origin.topLeft.rawValue])
let td=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false);td.usage=[.renderTarget,.shaderRead];td.storageMode = .shared;let output=device.makeTexture(descriptor:td)!
let z=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float,width:width,height:height,mipmapped:false);z.usage = .renderTarget;z.storageMode = .private;let depthTexture=device.makeTexture(descriptor:z)!
func draw(_ uniforms:Uniforms)->Double {
 var u=uniforms
 let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=output;pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store;pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);pass.depthAttachment.texture=depthTexture;pass.depthAttachment.loadAction = .clear;pass.depthAttachment.storeAction = .dontCare;pass.depthAttachment.clearDepth=1
 let cmd=queue.makeCommandBuffer()!,e=cmd.makeRenderCommandEncoder(descriptor:pass)!;e.setCullMode(.none);e.setVertexBuffer(vb,offset:0,index:0);e.setVertexBytes(&u,length:MemoryLayout<Uniforms>.stride,index:1);e.setFragmentBytes(&u,length:MemoryLayout<Uniforms>.stride,index:1);e.setFragmentTexture(front,index:0);e.setFragmentTexture(back,index:1)
 for (pipe,d) in [(shadow,shadowDepth),(main,depth)] {e.setRenderPipelineState(pipe);e.setDepthStencilState(d);e.drawIndexedPrimitives(type:.triangle,indexCount:ix.count,indexType:.uint32,indexBuffer:ib,indexBufferOffset:0)}
 e.endEncoding();cmd.commit();cmd.waitUntilCompleted();return cmd.gpuEndTime-cmd.gpuStartTime
}
func uniforms(_ ax:Float,_ ay:Float,_ fx:Float,_ fy:Float)->Uniforms {
 let dist=hypot(ax-fx,ay-fy),progress=min(1,max(0,(ax-fx)/(ax*2))),radius=min(64,dist/Float.pi*0.7)*min(1,max(0,(1-progress)*7))
 return Uniforms(viewportAndPage:SIMD4(800,700,400,700),anchorAndFinger:SIMD4(ax,ay,fx,fy),placement:SIMD4(400,1,radius,progress),paper:SIMD4(0.97,0.95,0.9,1),options:SIMD4(1,0,0,0))
}
let samples=[("upper-diagonal",uniforms(370,120,105,295)),("lower-diagonal",uniforms(370,610,105,405)),("middle-flex",uniforms(360,350,100,395))]
for (name,u) in samples {
 _=draw(u)
 var bytes=[UInt8](repeating:0,count:width*height*4);output.getBytes(&bytes,bytesPerRow:width*4,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0)
 let provider=CGDataProvider(data:Data(bytes) as CFData)!
 let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
 let combined=context(width,height);combined.draw(baseImage,in:CGRect(x:0,y:0,width:width,height:height));combined.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
 let url=outputDirectory.appendingPathComponent("reader-curl-\(name).png")
 let dest=CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil)!;CGImageDestinationAddImage(dest,combined.makeImage()!,nil);CGImageDestinationFinalize(dest);print(url.path)
}
var times:[Double]=[];for _ in 0..<120 {times.append(draw(samples[1].1))};times.sort()
print("GPU device=\(device.name) frames=120 viewport=800x700 meshTriangles=\(ix.count/3) passes=2 meanMS=\(times.reduce(0,+)/Double(times.count)*1000) p95MS=\(times[114]*1000) maxMS=\(times.last!*1000)")
