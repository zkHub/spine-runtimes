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

//
//  SkeletonDrawableWrapper+BatchRender.swift
//  Spine
//
//  批量皮肤渲染：与逐皮肤调用 `renderToImage` 不同，本方法只创建一次 `SpineRenderer`
//  （atlas 纹理只上传 GPU 一次、渲染管线只创建一次），随后循环切换皮肤、**离屏渲染到各自的
//  MTLTexture**。不依赖 MTKView 的 currentDrawable，因此没有离屏 drawable 池耗尽导致的空白/错位，
//  同时大幅降低“多 atlas + 多皮肤”场景下逐皮肤重建渲染器的开销。
//
//  放置位置：spine-ios/Sources/Spine/Extensions/
//  说明：依赖 `SpineRenderer`、`SpineObjects` 等模块内部成员，必须放在 Spine target 内。
//

import Foundation
import UIKit
import CoreGraphics
import MetalKit
import SpineCppLite

/// 复用单个 Spine drawable 的渲染器和离屏纹理，供逐帧流式导出使用。
/// 调用方负责推进动画状态，并保证 session 与 drawable 只在同一串行队列访问。
public final class SpineOffscreenFrameRenderer {
    private let drawable: SkeletonDrawableWrapper
    private let renderer: SpineRenderer
    private let texture: MTLTexture
    private let bounds: CGRect
    private let sizeInPoints: CGSize
    private let sizeInPixels: CGSize
    private let scaleFactor: CGFloat

    public init(
        drawable: SkeletonDrawableWrapper,
        boundsProvider: BoundsProvider,
        size: CGSize,
        scaleFactor: CGFloat = 1,
        usesLinearSampling: Bool = false
    ) throws {
        let bounds = boundsProvider.computeBounds(for: drawable)
        guard bounds.origin.x.isFinite,
              bounds.origin.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0,
              scaleFactor.isFinite,
              scaleFactor > 0
        else {
            throw NSError(
                domain: "SpineOffscreenFrameRenderer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "invalid render bounds or size"]
            )
        }

        let pixelWidthValue = (size.width * scaleFactor).rounded()
        let pixelHeightValue = (size.height * scaleFactor).rounded()
        guard pixelWidthValue > 0,
              pixelHeightValue > 0,
              pixelWidthValue <= CGFloat(UInt32.max),
              pixelHeightValue <= CGFloat(UInt32.max)
        else {
            throw NSError(
                domain: "SpineOffscreenFrameRenderer",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "invalid render pixel size"]
            )
        }

        let device = SpineObjects.shared.device
        let pixelFormat: MTLPixelFormat = .bgra8Unorm
        let renderer = try SpineRenderer(
            device: device,
            commandQueue: SpineObjects.shared.commandQueue,
            pixelFormat: pixelFormat,
            atlasPages: drawable.atlasPages,
            pma: drawable.atlas.isPma,
            textureSampling: usesLinearSampling ? .linear : .nearest
        )
        renderer.waitUntilCompleted = true

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: Int(pixelWidthValue),
            height: Int(pixelHeightValue),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw NSError(
                domain: "SpineOffscreenFrameRenderer",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "cannot create render texture"]
            )
        }

        self.drawable = drawable
        self.renderer = renderer
        self.texture = texture
        self.bounds = bounds
        self.sizeInPoints = size
        self.sizeInPixels = CGSize(width: pixelWidthValue, height: pixelHeightValue)
        self.scaleFactor = scaleFactor
    }

    /// 将 drawable 当前姿势渲染到复用纹理。返回值只在下一次 render 前保持内容稳定。
    public func render(
        backgroundColor: UIColor = .clear
    ) -> MTLTexture {
        renderer.renderOffscreen(
            renderCommands: drawable.skeletonDrawable.render(),
            to: texture,
            bounds: bounds,
            sizeInPoints: sizeInPoints,
            sizeInPixels: sizeInPixels,
            scaleFactor: scaleFactor,
            clearColor: MTLClearColor(backgroundColor)
        )
        return texture
    }
}

public extension SkeletonDrawableWrapper {

    /// 批量渲染多个皮肤为 `CGImage`：`SpineRenderer` 只创建一次（纹理/管线复用），
    /// 每个皮肤离屏渲染到独立的 `MTLTexture`，避免 MTKView drawable 生命周期问题。
    ///
    /// 注意：
    /// - 可在串行后台队列调用，但同一个 drawable 不得被其他线程同时读写。
    /// - 会修改本 drawable 的 `skeleton.skin`，请使用独立 drawable，避免污染正在显示的骨架。
    ///
    /// - Parameters:
    ///   - skinNames: 需要渲染的皮肤名（按顺序逐个设置到骨架；找不到的皮肤会跳过）。
    ///   - size: 输出尺寸。`nil` 表示按每个皮肤的包围盒自适应（与 `renderToImage` 行为一致）；
    ///           非 `nil` 表示所有皮肤渲染到固定尺寸（`.fit` 缩放）。
    ///   - backgroundColor: 背景色，默认透明。
    ///   - scaleFactor: 缩放因子，默认 1。
    ///   - isCancelled: 可选取消回调；每个皮肤渲染前检查，返回 `true` 则提前结束。
    ///   - onEach: 每个皮肤渲染完成回调（皮肤名, 图），便于渐进式刷新 UI。
    /// - Returns: skinName -> CGImage 的字典。
    func renderSkinsToImages(
        skinNames: [String],
        size: CGSize? = nil,
        backgroundColor: UIColor = .clear,
        scaleFactor: CGFloat = 1,
        isCancelled: (() -> Bool)? = nil,
        onEach: ((String, CGImage) -> Void)? = nil
    ) throws -> [String: CGImage] {
        guard !skinNames.isEmpty else { return [:] }

        let device = SpineObjects.shared.device
        let pixelFormat: MTLPixelFormat = .bgra8Unorm

        // 仅在此处创建一次：上传 atlas 纹理、创建渲染管线
        let renderer = try SpineRenderer(
            device: device,
            commandQueue: SpineObjects.shared.commandQueue,
            pixelFormat: pixelFormat,
            atlasPages: atlasPages,
            pma: atlas.isPma
        )
        renderer.waitUntilCompleted = true

        let boundsProvider = SetupPoseBounds()
        let clearColor = MTLClearColor(backgroundColor)
        var result: [String: CGImage] = [:]

        for skinName in skinNames {
            if isCancelled?() == true { break }
            guard let skin = skeletonData.findSkin(name: skinName) else { continue }

            // 切换皮肤并摆到设置姿势，计算当前皮肤包围盒
            skeleton.skin = skin
            skeleton.setToSetupPose()
            skeleton.update(delta: 0)
            skeleton.updateWorldTransform(physics: SPINE_PHYSICS_UPDATE)

            let bounds = boundsProvider.computeBounds(for: self)
            guard Self.isValidRenderBounds(bounds) else { continue }
            let targetSize = size ?? CGSize(width: bounds.width, height: bounds.height)
            guard let pixelSize = Self.pixelSize(
                for: targetSize,
                scaleFactor: scaleFactor
            ) else { continue }
            let pixelWidth = pixelSize.width
            let pixelHeight = pixelSize.height

            // 为当前皮肤创建独立的离屏目标纹理（每帧独立，无 drawable 复用问题）
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: pixelWidth,
                height: pixelHeight,
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { continue }

            let renderCommands = skeletonDrawable.render()
            renderer.renderOffscreen(
                renderCommands: renderCommands,
                to: texture,
                bounds: bounds,
                sizeInPoints: targetSize,
                sizeInPixels: CGSize(width: pixelWidth, height: pixelHeight),
                scaleFactor: scaleFactor,
                clearColor: clearColor
            )

            if let cgImage = Self.makeCGImage(from: texture) {
                result[skinName] = cgImage
                onEach?(skinName, cgImage)
            }
        }

        return result
    }

    /// 批量渲染动画帧为 `CGImage` 数组：`SpineRenderer` 与离屏纹理只创建一次，
    /// 循环内逐帧推进 `animationState` 并 `renderOffscreen`，避免每帧重建 `SpineUIView`。
    ///
    /// 注意：
    /// - 可在串行后台队列调用，但同一个 drawable 不得被其他线程同时读写。
    /// - 调用前需自行设置好皮肤、染色，并通过 `animationState.setAnimation(..., loop: true)` 启动动画。
    /// - 请使用独立 drawable，避免污染正在显示的骨架。
    ///
    /// - Parameters:
    ///   - frameCount: 需要渲染的帧数。
    ///   - delta: 每帧时间步长（秒），与导出 fps 对应（1/fps）。
    ///   - boundsProvider: 视口包围盒（导出场景使用 `RawBounds` 与 `renderToImage` 对齐）。
    ///   - size: 输出尺寸（点）；配合 `scaleFactor` 决定纹理像素大小。
    ///   - backgroundColor: 离屏清屏色，默认透明（导出合成时再铺白底）。
    ///   - scaleFactor: 缩放因子，默认 1。
    ///   - usesLinearSampling: 是否使用线性纹理采样；导出帧可启用以减少缩放锯齿。
    ///   - stepAnimation: 是否在每帧推进动画；无动画的静态层设为 `false`。
    ///   - isCancelled: 可选取消回调；每个帧渲染前检查。
    ///   - onEach: 每帧渲染完成回调（帧索引, 图），便于渐进式更新进度。
    /// - Returns: 按帧顺序排列的 `CGImage` 数组。
    func renderFramesToImages(
        frameCount: Int,
        delta: Float,
        boundsProvider: BoundsProvider,
        size: CGSize,
        backgroundColor: UIColor = .clear,
        scaleFactor: CGFloat = 1,
        usesLinearSampling: Bool = false,
        stepAnimation: Bool = true,
        isCancelled: (() -> Bool)? = nil,
        onEach: ((Int, CGImage) -> Void)? = nil
    ) throws -> [CGImage] {
        guard frameCount > 0 else { return [] }

        let device = SpineObjects.shared.device
        let pixelFormat: MTLPixelFormat = .bgra8Unorm

        let renderer = try SpineRenderer(
            device: device,
            commandQueue: SpineObjects.shared.commandQueue,
            pixelFormat: pixelFormat,
            atlasPages: atlasPages,
            pma: atlas.isPma,
            textureSampling: usesLinearSampling ? .linear : .nearest
        )
        renderer.waitUntilCompleted = true

        let bounds = boundsProvider.computeBounds(for: self)
        guard Self.isValidRenderBounds(bounds),
              let pixelSize = Self.pixelSize(for: size, scaleFactor: scaleFactor)
        else {
            return []
        }
        let pixelWidth = pixelSize.width
        let pixelHeight = pixelSize.height

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: pixelWidth,
            height: pixelHeight,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return [] }

        let clearColor = MTLClearColor(backgroundColor)
        let sizeInPixels = CGSize(width: pixelWidth, height: pixelHeight)
        var result: [CGImage] = []
        result.reserveCapacity(frameCount)

        for frameIndex in 0..<frameCount {
            if isCancelled?() == true { break }

            if stepAnimation {
                animationState.update(delta: delta)
                animationState.apply(skeleton: skeleton)
            }
            skeleton.update(delta: stepAnimation ? delta : 0)
            skeleton.updateWorldTransform(physics: SPINE_PHYSICS_UPDATE)

            let renderCommands = skeletonDrawable.render()
            renderer.renderOffscreen(
                renderCommands: renderCommands,
                to: texture,
                bounds: bounds,
                sizeInPoints: size,
                sizeInPixels: sizeInPixels,
                scaleFactor: scaleFactor,
                clearColor: clearColor
            )

            if let cgImage = Self.makeCGImage(from: texture) {
                result.append(cgImage)
                onEach?(frameIndex, cgImage)
            }
        }

        return result
    }

    /// 空皮肤没有可参与计算的顶点，底层会返回哨兵值和无穷宽高，不能继续参与渲染变换。
    private static func isValidRenderBounds(_ bounds: CGRect) -> Bool {
        bounds.origin.x.isFinite
            && bounds.origin.y.isFinite
            && bounds.width.isFinite
            && bounds.height.isFinite
            && bounds.width > 0
            && bounds.height > 0
    }

    /// 在转换为整数前校验缩放结果，避免非有限值或越界值触发 Swift 运行时错误。
    private static func pixelSize(
        for size: CGSize,
        scaleFactor: CGFloat
    ) -> (width: Int, height: Int)? {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0,
              scaleFactor.isFinite,
              scaleFactor > 0
        else {
            return nil
        }

        let width = (size.width * scaleFactor).rounded()
        let height = (size.height * scaleFactor).rounded()
        let maximumDimension = CGFloat(UInt32.max)
        guard width.isFinite,
              height.isFinite,
              width > 0,
              height > 0,
              width <= maximumDimension,
              height <= maximumDimension
        else {
            return nil
        }

        return (Int(width), Int(height))
    }

    /// 从 Metal 纹理读取像素并生成 `CGImage`（与 `renderToImage` 内部逻辑一致）。
    private static func makeCGImage(from texture: MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        guard width > 0, height > 0 else { return nil }
        let rowBytes = width * 4
        let data = UnsafeMutableRawPointer.allocate(
            byteCount: rowBytes * height,
            alignment: MemoryLayout<UInt8>.alignment
        )
        defer { data.deallocate() }

        let region = MTLRegionMake2D(0, 0, width, height)
        texture.getBytes(data, bytesPerRow: rowBytes, from: region, mipmapLevel: 0)

        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
        ).union(.byteOrder32Little)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: rowBytes,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ), let cgImage = context.makeImage() else {
            return nil
        }
        return cgImage
    }
}
