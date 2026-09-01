/******************************************************************************
 * Spine Runtimes License Agreement
 * Last updated April 5, 2025. Replaces all prior versions.
 *
 * Copyright (c) 2013-2025, Esoteric Software LLC
 *
 * Integration of the Spine Runtimes into software or otherwise creating
 * derivative works of the Spine Runtimes is permitted under the terms and
 * conditions of Section 2 of the Spine Editor License Agreement:
 * http://esotericsoftware.com/spine-editor-license
 *
 * Otherwise, it is permitted to integrate the Spine Runtimes into software
 * or otherwise create derivative works of the Spine Runtimes (collectively,
 * "Products"), provided that each user of the Products must obtain their own
 * Spine Editor license and redistribution of the Products in any form must
 * include this license and copyright notice.
 *
 * THE SPINE RUNTIMES ARE PROVIDED BY ESOTERIC SOFTWARE LLC "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL ESOTERIC SOFTWARE LLC BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES,
 * BUSINESS INTERRUPTION, OR LOSS OF USE, DATA, OR PROFITS) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THE SPINE RUNTIMES, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *****************************************************************************/

import Foundation
import MetalKit
import SpineShadersStructs
import Spine
import SpineCppLite

protocol SpineRendererDelegate: AnyObject {
    func spineRendererWillUpdate(_ spineRenderer: SpineRenderer)
    func spineRenderer(_ spineRenderer: SpineRenderer, needsUpdate delta: TimeInterval)
    func spineRendererDidUpdate(_ spineRenderer: SpineRenderer)
    
    func spineRendererWillDraw(_ spineRenderer: SpineRenderer)
    func spineRendererDidDraw(_ spineRenderer: SpineRenderer)
    
    func spineRendererDidUpdate(_ spineRenderer: SpineRenderer, scaleX: CGFloat, scaleY: CGFloat, offsetX: CGFloat, offsetY: CGFloat, size: CGSize)
}

protocol SpineRendererDataSource: AnyObject {
    func isPlaying(_ spineRenderer: SpineRenderer) -> Bool
    func renderCommands(_ spineRenderer: SpineRenderer) -> [RenderCommand]
}

internal enum SpineTextureSampling {
    case nearest
    case linear
}

internal final class SpineRenderer: NSObject, MTKViewDelegate {
    
    private let device: MTLDevice
    private let textures: [MTLTexture]
    private let commandQueue: MTLCommandQueue
    
    private var sizeInPoints: CGSize = .zero
    private var contentScale: CGFloat = 1
    private var viewPortSize = vector_uint2(0, 0)
    private var transform = SpineTransform(
        translation: vector_float2(0, 0),
        scale: vector_float2(1, 1),
        offset: vector_float2(0, 0)
    )
    internal var lastDraw: CFTimeInterval = 0
    internal var waitUntilCompleted = false
    private var pipelineStatesByBlendMode = [Int: MTLRenderPipelineState]()
    
    private static let numberOfBuffers = 3
    private static let defaultBufferSize = 32 * 1024 // 32KB
    
    private var buffers = [MTLBuffer]()
    private let bufferingSemaphore = DispatchSemaphore(value: SpineRenderer.numberOfBuffers)
    private var currentBufferIndex: Int = 0
    
    weak var dataSource: SpineRendererDataSource?
    weak var delegate: SpineRendererDelegate?
    
    internal init(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        pixelFormat: MTLPixelFormat,
        atlasPages: [UIImage],
        pma: Bool,
        textureSampling: SpineTextureSampling = .nearest
    ) throws {
        self.device = device
        self.commandQueue = commandQueue
        
        let bundle: Bundle
        #if SWIFT_PACKAGE // SPM
        bundle = .module
        #else // CocoaPods
        let bundleURL = Bundle(for: SpineRenderer.self).url(forResource: "SpineBundle", withExtension: "bundle")
        bundle = Bundle(url: bundleURL!)!
        #endif
        
        let defaultLibrary = try device.makeDefaultLibrary(bundle: bundle)
        let textureLoader = MTKTextureLoader(device: device)
        textures = try atlasPages
            .compactMap { $0.cgImage }
            .map {
                try textureLoader.newTexture(
                    cgImage: $0,
                    options: [
                        .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                        .SRGB: false,
                    ]
                )
            }
        
        let blendModes = [
            SPINE_BLEND_MODE_NORMAL,
            SPINE_BLEND_MODE_ADDITIVE,
            SPINE_BLEND_MODE_MULTIPLY,
            SPINE_BLEND_MODE_SCREEN
        ]
        for blendMode in blendModes {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = defaultLibrary.makeFunction(name: "vertexShader")
            descriptor.fragmentFunction = defaultLibrary.makeFunction(
                name: textureSampling == .linear ? "fragmentShaderLinear" : "fragmentShader"
            )
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            descriptor.colorAttachments[0].apply(
                blendMode: blendMode,
                with: pma
            )
            pipelineStatesByBlendMode[Int(blendMode.rawValue)] = try device.makeRenderPipelineState(descriptor: descriptor)
        }
        
        super.init()
                
        increaseBuffersSize(to: SpineRenderer.defaultBufferSize)
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard let spineView = view as? SpineUIView else { return }

        contentScale = UIScreen.main.scale
        sizeInPoints = CGSize(width: size.width / contentScale, height: size.height / contentScale)
        viewPortSize = vector_uint2(UInt32(size.width), UInt32(size.height))
        setTransform(
            bounds: spineView.computedBounds,
            mode: spineView.mode,
            alignment: spineView.alignment
        )
    }
    
    func draw(in view: MTKView) {
        guard dataSource?.isPlaying(self) ?? false else {
            lastDraw = CACurrentMediaTime()
            return
        }
        
        callNeedsUpdate()
        
        // Tripple Buffering
        // Source: https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/TripleBuffering.html#//apple_ref/doc/uid/TP40016642-CH5-SW1
        bufferingSemaphore.wait()
        currentBufferIndex = (currentBufferIndex + 1) % SpineRenderer.numberOfBuffers
        
        guard let renderCommands = dataSource?.renderCommands(self),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
	// this can happen if, 
	// - CAMetalLayer is configured with drawable timeout, and CAMetalLayer is run out of Drawable 
	// - CAMetalLayer is added to the window with frame size of zero or incorrect layout constraint -> currentRenderPassDescriptor is null
            bufferingSemaphore.signal()
            return
        }
        
        delegate?.spineRendererWillDraw(self)
        draw(renderCommands: renderCommands, renderEncoder: renderEncoder, in: view)
        delegate?.spineRendererDidDraw(self)
        
        renderEncoder.endEncoding()
        view.currentDrawable.flatMap {
            commandBuffer.present($0)
        }
        commandBuffer.addCompletedHandler { [bufferingSemaphore] _ in
            bufferingSemaphore.signal()
        }
        commandBuffer.commit()
        if waitUntilCompleted {
            commandBuffer.waitUntilCompleted()
        }
    }
    
    /// 离屏渲染：将给定 renderCommands 渲染到指定纹理，复用已上传的 atlas 纹理与管线。
    /// 不依赖 MTKView 的 currentDrawable，适用于批量缩略图等离屏紧循环场景（无 drawable 池耗尽问题）。
    /// - Parameters:
    ///   - renderCommands: 当前骨架姿势的渲染命令
    ///   - texture: 目标纹理（像素格式需与初始化时的 pixelFormat 一致）
    ///   - bounds: 骨架包围盒（用于 .fit/.center 变换）
    ///   - sizeInPoints: 输出逻辑尺寸。
    ///   - sizeInPixels: 目标纹理的像素尺寸
    ///   - scaleFactor: 逻辑尺寸到纹理像素的缩放倍数。
    internal func renderOffscreen(
        renderCommands: [RenderCommand],
        to texture: MTLTexture,
        bounds: CGRect,
        sizeInPoints: CGSize,
        sizeInPixels: CGSize,
        scaleFactor: CGFloat,
        clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    ) {
        guard sizeInPoints.width > 0,
              sizeInPoints.height > 0,
              sizeInPixels.width > 0,
              sizeInPixels.height > 0,
              scaleFactor > 0
        else { return }

        // 离屏路径由调用方传入逻辑尺寸和缩放倍数，不读取主线程 UI 状态。
        self.sizeInPoints = sizeInPoints
        contentScale = scaleFactor
        viewPortSize = vector_uint2(UInt32(sizeInPixels.width), UInt32(sizeInPixels.height))
        setTransform(bounds: bounds, mode: .fit, alignment: .center)

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = clearColor
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        bufferingSemaphore.wait()
        currentBufferIndex = (currentBufferIndex + 1) % SpineRenderer.numberOfBuffers

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            bufferingSemaphore.signal()
            return
        }
        draw(renderCommands: renderCommands, renderEncoder: renderEncoder)
        renderEncoder.endEncoding()
        commandBuffer.addCompletedHandler { [bufferingSemaphore] _ in
            bufferingSemaphore.signal()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func setTransform(bounds: CGRect, mode: Spine.ContentMode, alignment: Spine.Alignment) {
        let x = -bounds.minX - bounds.width / 2.0
        let y = -bounds.minY - bounds.height / 2.0
        
        var scaleX: CGFloat = 1.0
        var scaleY: CGFloat = 1.0
        
        switch mode {
        case .fit:
            scaleX = min(sizeInPoints.width / bounds.width, sizeInPoints.height / bounds.height)
            scaleY = scaleX
        case .fill:
            scaleX = max(sizeInPoints.width / bounds.width, sizeInPoints.height / bounds.height)
            scaleY = scaleX
        }
        
        let offsetX = abs(sizeInPoints.width - bounds.width * scaleX) / 2 * alignment.x
        let offsetY = abs(sizeInPoints.height - bounds.height * scaleY) / 2 * alignment.y
        
        transform = SpineTransform(
            translation: vector_float2(Float(x), Float(y)),
            scale: vector_float2(Float(scaleX * contentScale), Float(scaleY * contentScale)),
            offset: vector_float2(Float(offsetX * contentScale), Float(offsetY * contentScale))
        )
        
        delegate?.spineRendererDidUpdate(
            self,
            scaleX: scaleX,
            scaleY: scaleY,
            offsetX: x + offsetX / scaleX,
            offsetY: y + offsetY / scaleY,
            size: sizeInPoints
        )
    }
    
    private func callNeedsUpdate() {
        if lastDraw == 0 {
            lastDraw = CACurrentMediaTime()
        }
        let delta = CACurrentMediaTime() - lastDraw
         delegate?.spineRendererWillUpdate(self)
        delegate?.spineRenderer(self, needsUpdate: delta)
        lastDraw = CACurrentMediaTime()
        delegate?.spineRendererDidUpdate(self)
    }
        
    private func draw(renderCommands: [RenderCommand], renderEncoder: MTLRenderCommandEncoder, in view: MTKView? = nil) {
        let allVertices = renderCommands.map { renderCommand in
            Array(renderCommand.getVertices())
        }
        let vertices = allVertices.flatMap { $0 }
        let verticesSize = MemoryLayout<SpineVertex>.stride * vertices.count
        
        guard verticesSize > 0 else {
            return
        }
        
        var vertexBuffer = buffers[currentBufferIndex]
        var vertexBufferSize = vertexBuffer.length
        
        if vertexBufferSize < verticesSize {
            increaseBuffersSize(to: verticesSize)
            vertexBuffer = buffers[currentBufferIndex]
        }
        
        renderEncoder.setViewport(
            MTLViewport(
                originX: 0.0,
                originY: 0.0,
                width: Double(viewPortSize.x),
                height: Double(viewPortSize.y),
                znear: 0.0,
                zfar: 1.0
            )
        )
        
        memcpy(vertexBuffer.contents(), vertices, verticesSize)
        
        renderEncoder.setVertexBuffer(
            vertexBuffer,
            offset: 0,
            index: Int(SpineVertexInputIndexVertices.rawValue)
        )
        renderEncoder.setVertexBytes(
            &transform,
            length: MemoryLayout.size(ofValue: transform),
            index: Int(SpineVertexInputIndexTransform.rawValue)
        )
        renderEncoder.setVertexBytes(
            &viewPortSize,
            length: MemoryLayout.size(ofValue: viewPortSize),
            index: Int(SpineVertexInputIndexViewportSize.rawValue)
        )
        
        // Buffer Bindings
        // https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/BufferBindings.html#//apple_ref/doc/uid/TP40016642-CH28-SW3
        var vertexStart = 0
        for (index, renderCommand) in renderCommands.enumerated() {
            guard let pipelineState = getPipelineState(blendMode: renderCommand.blendMode) else {
                continue
            }
            renderEncoder.setRenderPipelineState(pipelineState)
            
            let vertices = allVertices[index]
            
            let textureIndex = Int(renderCommand.atlasPage)
            if textures.indices.contains(textureIndex) {
                renderEncoder.setFragmentTexture(
                    textures[textureIndex],
                    index: Int(SpineTextureIndexBaseColor.rawValue)
                )
            }
            
            renderEncoder.drawPrimitives(
                type: .triangle,
                vertexStart: vertexStart,
                vertexCount: vertices.count
            )
            vertexStart += vertices.count
        }
    }
    
    private func getPipelineState(blendMode: BlendMode) -> MTLRenderPipelineState? {
        pipelineStatesByBlendMode[Int(blendMode.rawValue)]
    }
    
    private func increaseBuffersSize(to size: Int) {
        buffers = (0 ..< SpineRenderer.numberOfBuffers).map { _ in
            device.makeBuffer(length: size, options: .storageModeShared)!
        }
    }
}

fileprivate extension BlendMode {
	func sourceRGBBlendFactor(premultipliedAlpha: Bool) -> MTLBlendFactor {
		switch self {
		case SPINE_BLEND_MODE_NORMAL:
			return premultipliedAlpha ? .one : .sourceAlpha
		case SPINE_BLEND_MODE_ADDITIVE:
			// additvie only needs sourceAlpha multiply if it is not pma
			return premultipliedAlpha ? .one : .sourceAlpha
		case SPINE_BLEND_MODE_MULTIPLY:
			return .destinationColor
		case SPINE_BLEND_MODE_SCREEN:
			return .one
		default:
			return .one // Should never be called
		}
	}
	
	var sourceAlphaBlendFactor: MTLBlendFactor {
		// pma and non-pma has no-relation ship with alpha blending
		switch self {
		case SPINE_BLEND_MODE_NORMAL:
			return .one
		case SPINE_BLEND_MODE_ADDITIVE:
			return .one
		case SPINE_BLEND_MODE_MULTIPLY:
			return .oneMinusSourceAlpha
		case SPINE_BLEND_MODE_SCREEN:
			return .oneMinusSourceColor
		default:
			return .one // Should never be called
		}
	}

	var destinationRGBBlendFactor: MTLBlendFactor {
		switch self {
		case SPINE_BLEND_MODE_NORMAL:
			return .oneMinusSourceAlpha
		case SPINE_BLEND_MODE_ADDITIVE:
			return .one
		case SPINE_BLEND_MODE_MULTIPLY:
			return .oneMinusSourceAlpha
		case SPINE_BLEND_MODE_SCREEN:
			return .oneMinusSourceColor
		default:
			return .one // Should never be called
		}
	}

	var destinationAlphaBlendFactor: MTLBlendFactor {
		switch self {
		case SPINE_BLEND_MODE_NORMAL:
			return .oneMinusSourceAlpha
		case SPINE_BLEND_MODE_ADDITIVE:
			return .one
		case SPINE_BLEND_MODE_MULTIPLY:
			return .oneMinusSourceAlpha
		case SPINE_BLEND_MODE_SCREEN:
			return .oneMinusSourceColor
		default:
			return .one // Should never be called
		}
	}
}

fileprivate extension MTLRenderPipelineColorAttachmentDescriptor {
	
	func apply(blendMode: BlendMode, with premultipliedAlpha: Bool) {
		isBlendingEnabled = true
		sourceRGBBlendFactor = blendMode.sourceRGBBlendFactor(premultipliedAlpha: premultipliedAlpha)
		sourceAlphaBlendFactor = blendMode.sourceAlphaBlendFactor
		destinationRGBBlendFactor = blendMode.destinationRGBBlendFactor
		destinationAlphaBlendFactor = blendMode.destinationAlphaBlendFactor
	}
}
