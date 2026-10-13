#!/usr/bin/env swift
//
//  生成 App 图标的浅色 / 深色备用变体，以及设置页里那三个预览图。
//
//  为什么要脚本而不是手摆 PNG：备用图标和主图标必须出自同一张原画，
//  手改一次就分叉一次。这里唯一输入是 `AppIcon.appiconset/AppIcon.png`，
//  其余五个文件全部由它推导，重跑一次就能对齐。
//
//  做法：先找出整张图的主色（那块奶油底），从画布边缘向内做连通域生长，
//  长出来的就是「背景」；主体（罐头本体、白标、鱼）不在背景里，一个像素都不动。
//  底色按「相对主色的明度比」重新染色 —— 阴影和暗角保持各自的比例，
//  所以深色版是同一个标志换了夜色底，不是整张图蒙一层黑。
//
//  用法（仓库根目录）：
//    swift scripts/make-app-icon-variants.swift
//
import Foundation
import CoreGraphics
import ImageIO

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let catalog = repoRoot.appendingPathComponent("Saury/Resources/Assets.xcassets", isDirectory: true)
let master = catalog.appendingPathComponent("AppIcon.appiconset/AppIcon.png")

// MARK: - 像素读写

struct Pixels {
    let width: Int
    let height: Int
    var rgba: [UInt8]

    var count: Int { width * height }

    subscript(i: Int) -> (r: Double, g: Double, b: Double) {
        get {
            let o = i * 4
            return (Double(rgba[o]) / 255, Double(rgba[o + 1]) / 255, Double(rgba[o + 2]) / 255)
        }
        set {
            let o = i * 4
            rgba[o] = UInt8(max(0, min(255, newValue.r * 255)).rounded())
            rgba[o + 1] = UInt8(max(0, min(255, newValue.g * 255)).rounded())
            rgba[o + 2] = UInt8(max(0, min(255, newValue.b * 255)).rounded())
            rgba[o + 3] = 255
        }
    }
}

func read(_ url: URL) -> Pixels {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("读不到原画：\(url.path)")
    }
    let w = image.width, h = image.height
    var buffer = [UInt8](repeating: 0, count: w * h * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("建不出位图上下文")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return Pixels(width: w, height: h, rgba: buffer)
}

func write(_ pixels: Pixels, to url: URL, edge: Int? = nil) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    var buffer = pixels.rgba
    guard let context = CGContext(data: &buffer, width: pixels.width, height: pixels.height,
                                  bitsPerComponent: 8, bytesPerRow: pixels.width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let image = context.makeImage() else {
        fatalError("写不出 PNG：\(url.path)")
    }
    var target = image
    if let edge, edge != pixels.width {
        target = resize(image, to: edge)
    }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("造不出图片输出器")
    }
    CGImageDestinationAddImage(dest, target, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG 落盘失败：\(url.path)") }
}

/// 只用系统自带的插值做缩放，不引第三方。
func resize(_ image: CGImage, to edge: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    var buffer = [UInt8](repeating: 0, count: edge * edge * 4)
    let context = CGContext(data: &buffer, width: edge, height: edge, bitsPerComponent: 8,
                            bytesPerRow: edge * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: edge, height: edge))
    return context.makeImage()!
}

// MARK: - 底色识别

typealias RGB = SIMD3<Double>

func distance(_ a: RGB, _ b: RGB) -> Double {
    let d = a - b
    return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
}

/// 整张图出现最多的颜色 = 那块底色。取四角不行：主图标四角是白边，
/// 拿它当底色，染出来的深色版会在罐头周围留一圈亮晕。
func dominantColor(_ pixels: Pixels) -> RGB {
    var buckets: [Int: (sum: RGB, n: Int)] = [:]
    for i in 0..<pixels.count {
        let p = pixels[i]
        let key = (Int(p.r * 15) << 8) | (Int(p.g * 15) << 4) | Int(p.b * 15)
        var bucket = buckets[key] ?? (RGB(0, 0, 0), 0)
        bucket.sum += RGB(p.r, p.g, p.b)
        bucket.n += 1
        buckets[key] = bucket
    }
    let best = buckets.values.max { $0.n < $1.n }!
    return best.sum / Double(best.n)
}

/// 从画布边缘向内做连通域生长。容差按「相邻像素」算而不是按主色算：
/// 暗角和接触阴影是渐变，逐像素只差一点点，长得住；罐头的硬边一次跳出去就停住。
/// 白标上的「SAURY」离边缘不连通，所以不会被当成背景染掉。
func backgroundMask(_ pixels: Pixels, base: RGB, tolerance: Double = 0.055, reach: Double = 0.22) -> [Double] {
    let w = pixels.width, h = pixels.height
    var mask = [Double](repeating: 0, count: pixels.count)
    var queue: [Int] = []
    queue.reserveCapacity(pixels.count / 4)

    func seed(_ i: Int) {
        let p = pixels[i]
        if distance(RGB(p.r, p.g, p.b), base) <= tolerance * 3 {
            mask[i] = 1
            queue.append(i)
        }
    }
    for x in 0..<w { seed(x); seed((h - 1) * w + x) }
    for y in 0..<h { seed(y * w); seed(y * w + w - 1) }

    while let i = queue.popLast() {
        let x = i % w, y = i / w
        let here = RGB(pixels[i].r, pixels[i].g, pixels[i].b)
        for step in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            let nx = x + step.0, ny = y + step.1
            guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
            let j = ny * w + nx
            guard mask[j] == 0 else { continue }
            let there = RGB(pixels[j].r, pixels[j].g, pixels[j].b)
            // 两道闸：离上一像素要近（走得动渐变），离底色要够远就停（走不进罐头本体）。
            // 只有前一道闸的话，金属盖那道由浅到深的渐变会被一级一级走进来。
            if distance(there, here) <= tolerance, distance(there, base) <= reach {
                mask[j] = 1
                queue.append(j)
            }
        }
    }
    return feather(mask, width: w, height: h)   // 一次 3×3 就够，糊两次会把边界啃进主体
}

/// 硬边抠图会在主体轮廓上留一圈锯齿，一次 3×3 均值把边界糊开。
/// 只糊一次：糊两次会把半透明的边界啃进罐头本体，深色版会多一圈暗边。
func feather(_ mask: [Double], width w: Int, height h: Int) -> [Double] {
    var current = mask
    for _ in 0..<1 {
        var next = current
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0.0
                for dy in -1...1 {
                    let ny = y + dy
                    if ny < 0 || ny >= h { continue }
                    for dx in -1...1 {
                        let nx = x + dx
                        if nx < 0 || nx >= w { continue }
                        sum += current[ny * w + nx]
                    }
                }
                next[y * w + x] = sum / 9
            }
        }
        current = next
    }
    return current
}

// MARK: - 变体

/// 一个变体的全部参数。
struct Variant {
    let name: String
    /// 染完之后底色落在哪儿。
    let background: RGB
    /// 整张图（含主体）的亮度微调。
    let brightness: Double
    /// 底色相对明度比的幂：<1 把暗角/阴影压平（更干净的纸感），>1 让阴影更沉。
    let shadowGamma: Double
}

let variants: [Variant] = [
    // 浅色：底色推到接近纯白并把暗角压平 —— 和主图标那块带渐变的奶油色是两种气质。
    Variant(name: "AppIconLight", background: RGB(0.992, 0.988, 0.980),
            brightness: 1.05, shadowGamma: 0.30),
    // 深色：偏蓝的炭黑，阴影按原比例沉下去；主体收一点，免得白罐子在夜色里过曝。
    Variant(name: "AppIconDark", background: RGB(0.106, 0.114, 0.145),
            brightness: 0.98, shadowGamma: 1.15),
]

func render(_ source: Pixels, _ variant: Variant) -> Pixels {
    let origin = dominantColor(source)
    let mask = backgroundMask(source, base: origin)
    var out = source
    for i in 0..<source.count {
        let p = source[i]
        let here = RGB(p.r, p.g, p.b)
        let key = mask[i]
        var result = here
        if key > 0.001 {
            // 每个通道按「它是底色的几倍」重放到新底色上：阴影还是阴影，暗角还是暗角。
            var recolored = RGB(0, 0, 0)
            for channel in 0..<3 {
                let ratio = min(1.8, here[channel] / max(0.05, origin[channel]))
                recolored[channel] = variant.background[channel] * pow(ratio, variant.shadowGamma)
            }
            result = origin + (recolored - origin) * key
        }
        // 主体不吃「染底」这一步，只吃整体亮度。
        result *= variant.brightness
        out[i] = (result.x, result.y, result.z)
    }
    return out
}

// MARK: - 产出

let previewEdge = 256   // 设置页那三个预览格子（56pt @3x 用不到 1024）

func appiconsetContents(_ name: String) -> String {
    """
    {
      "images" : [
        {
          "filename" : "\(name).png",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """
}

func imagesetContents(_ name: String) -> String {
    """
    {
      "images" : [
        {
          "filename" : "\(name).png",
          "idiom" : "universal",
          "scale" : "1x"
        }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """
}

func emit(_ text: String, to url: URL) {
    try! text.write(to: url, atomically: true, encoding: .utf8)
}

let sourcePixels = read(master)

for variant in variants {
    let dir = catalog.appendingPathComponent("\(variant.name).appiconset", isDirectory: true)
    write(render(sourcePixels, variant), to: dir.appendingPathComponent("\(variant.name).png"))
    emit(appiconsetContents(variant.name), to: dir.appendingPathComponent("Contents.json"))
    print("appiconset \(variant.name).appiconset")
}

// 预览图：设置页里那三块格子。名字与 `AppIconSwitcher` 里 UIImage(named:) 一致。
let previews: [(String, Pixels)] = [
    ("AppIcon-Auto", sourcePixels),
    ("AppIcon-Light", render(sourcePixels, variants[0])),
    ("AppIcon-Dark", render(sourcePixels, variants[1])),
]
for (name, pixels) in previews {
    let dir = catalog.appendingPathComponent("\(name).imageset", isDirectory: true)
    write(pixels, to: dir.appendingPathComponent("\(name).png"), edge: previewEdge)
    emit(imagesetContents(name), to: dir.appendingPathComponent("Contents.json"))
    print("imageset \(name).imageset")
}
