#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate-icon.swift <output-png-1024>\n", stderr)
    exit(1)
}

let outputPath = CommandLine.arguments[1]
let canvasSize: CGFloat = 1024

func makeSquirclePath(in rect: CGRect, radius: CGFloat) -> CGPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).cgPath
}

func makeFourPointSparkle(center: CGPoint, outerRadius: CGFloat, innerRadius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let points: [CGPoint] = [
        CGPoint(x: center.x, y: center.y + outerRadius),
        CGPoint(x: center.x + outerRadius, y: center.y),
        CGPoint(x: center.x, y: center.y - outerRadius),
        CGPoint(x: center.x - outerRadius, y: center.y)
    ]
    let controls: [CGPoint] = [
        CGPoint(x: center.x + innerRadius, y: center.y + innerRadius),
        CGPoint(x: center.x + innerRadius, y: center.y - innerRadius),
        CGPoint(x: center.x - innerRadius, y: center.y - innerRadius),
        CGPoint(x: center.x - innerRadius, y: center.y + innerRadius)
    ]

    path.move(to: points[0])
    for i in 0..<4 {
        let next = points[(i + 1) % 4]
        let ctrl = controls[i]
        path.addQuadCurve(to: next, control: ctrl)
    }
    path.closeSubpath()
    return path
}

let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: Int(canvasSize),
    height: Int(canvasSize),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Failed to create CGContext\n", stderr)
    exit(1)
}

ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

// macOS Big Sur+ icon proportion: 824x824 centered inside 1024x1024 with ~185px corner radius
let iconInset: CGFloat = 100
let iconRect = CGRect(x: iconInset, y: iconInset, width: canvasSize - iconInset * 2, height: canvasSize - iconInset * 2)
let cornerRadius: CGFloat = 186
let squircle = makeSquirclePath(in: iconRect, radius: cornerRadius)

// 1. Soft outer drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 36, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.48))
ctx.addPath(squircle)
ctx.setFillColor(CGColor(red: 0.04, green: 0.06, blue: 0.11, alpha: 1.0))
ctx.fillPath()
ctx.restoreGState()

// 2. Clipped icon interior
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

// 2a. Deep obsidian-navy linear base gradient
if let baseGrad = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.09, green: 0.13, blue: 0.22, alpha: 1.0),
        CGColor(red: 0.05, green: 0.07, blue: 0.13, alpha: 1.0),
        CGColor(red: 0.03, green: 0.05, blue: 0.09, alpha: 1.0)
    ] as CFArray,
    locations: [0.0, 0.55, 1.0]
) {
    ctx.drawLinearGradient(
        baseGrad,
        start: CGPoint(x: iconRect.minX, y: iconRect.maxY),
        end: CGPoint(x: iconRect.maxX, y: iconRect.minY),
        options: []
    )
}

func drawRadialGlow(center: CGPoint, radius: CGFloat, color: CGColor) {
    let transparent = color.copy(alpha: 0.0) ?? CGColor(red: 0, green: 0, blue: 0, alpha: 0)
    if let grad = CGGradient(
        colorsSpace: colorSpace,
        colors: [color, transparent] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.drawRadialGradient(
            grad,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: []
        )
    }
}

// 2b. Multi-layered aurora nebula
drawRadialGlow(
    center: CGPoint(x: iconRect.minX + iconRect.width * 0.26, y: iconRect.maxY - iconRect.height * 0.24),
    radius: 470,
    color: CGColor(red: 0.10, green: 0.88, blue: 0.62, alpha: 0.46)
)
drawRadialGlow(
    center: CGPoint(x: iconRect.maxX - iconRect.width * 0.18, y: iconRect.maxY - iconRect.height * 0.34),
    radius: 430,
    color: CGColor(red: 0.20, green: 0.58, blue: 1.00, alpha: 0.40)
)
drawRadialGlow(
    center: CGPoint(x: iconRect.midX + 60, y: iconRect.minY + iconRect.height * 0.16),
    radius: 420,
    color: CGColor(red: 0.48, green: 0.38, blue: 0.98, alpha: 0.38)
)

// 2c. Top frosted glass sheen arc
ctx.saveGState()
let glassArcCenter = CGPoint(x: iconRect.midX, y: iconRect.maxY + 260)
drawRadialGlow(
    center: glassArcCenter,
    radius: 620,
    color: CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.16)
)
ctx.restoreGState()

// 3. Precision orbital radar rings
let center = CGPoint(x: canvasSize / 2, y: canvasSize / 2)

// Outer dashed ring
ctx.saveGState()
ctx.setStrokeColor(CGColor(red: 0.30, green: 0.92, blue: 0.72, alpha: 0.32))
ctx.setLineWidth(5)
ctx.setLineDash(phase: 0, lengths: [22, 16])
ctx.addArc(center: center, radius: 298, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.strokePath()
ctx.restoreGState()

// Middle solid subtle track ring
ctx.saveGState()
ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.13))
ctx.setLineWidth(18)
ctx.addArc(center: center, radius: 226, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.strokePath()
ctx.restoreGState()

// Active glowing storage arc 1 (emerald-cyan sweep, ~205 deg)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 24, color: CGColor(red: 0.14, green: 0.90, blue: 0.64, alpha: 0.75))
let arc1 = CGMutablePath()
arc1.addArc(center: center, radius: 226, startAngle: .pi * 0.55, endAngle: -.pi * 0.62, clockwise: true)
let strokedArc1 = arc1.copy(strokingWithWidth: 22, lineCap: .round, lineJoin: .round, miterLimit: 10)
ctx.addPath(strokedArc1)
ctx.clip()
if let arcGrad = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.14, green: 0.94, blue: 0.64, alpha: 1.0),
        CGColor(red: 0.16, green: 0.74, blue: 0.98, alpha: 1.0),
        CGColor(red: 0.44, green: 0.52, blue: 1.00, alpha: 1.0)
    ] as CFArray,
    locations: [0.0, 0.55, 1.0]
) {
    ctx.drawLinearGradient(
        arcGrad,
        start: CGPoint(x: center.x - 240, y: center.y + 240),
        end: CGPoint(x: center.x + 240, y: center.y - 240),
        options: []
    )
}
ctx.restoreGState()

// Secondary glowing storage arc 2 (amber accent, ~70 deg)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 18, color: CGColor(red: 1.00, green: 0.68, blue: 0.22, alpha: 0.65))
let arc2 = CGMutablePath()
arc2.addArc(center: center, radius: 226, startAngle: -.pi * 0.74, endAngle: -.pi * 1.14, clockwise: true)
let strokedArc2 = arc2.copy(strokingWithWidth: 22, lineCap: .round, lineJoin: .round, miterLimit: 10)
ctx.addPath(strokedArc2)
ctx.clip()
if let amberGrad = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 1.00, green: 0.76, blue: 0.24, alpha: 1.0),
        CGColor(red: 0.98, green: 0.46, blue: 0.20, alpha: 1.0)
    ] as CFArray,
    locations: [0.0, 1.0]
) {
    ctx.drawLinearGradient(
        amberGrad,
        start: CGPoint(x: center.x - 240, y: center.y - 180),
        end: CGPoint(x: center.x - 160, y: center.y + 180),
        options: []
    )
}
ctx.restoreGState()

// Orbital detection dots
let dotAngles: [(CGFloat, CGFloat, CGColor)] = [
    (0.65, 298, CGColor(red: 0.22, green: 0.96, blue: 0.70, alpha: 0.95)),
    (2.55, 298, CGColor(red: 0.42, green: 0.72, blue: 1.00, alpha: 0.90)),
    (-1.05, 298, CGColor(red: 0.72, green: 0.56, blue: 1.00, alpha: 0.85))
]
for (angle, radius, color) in dotAngles {
    let pt = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 16, color: color)
    ctx.setFillColor(color)
    ctx.fillEllipse(in: CGRect(x: pt.x - 10, y: pt.y - 10, width: 20, height: 20))
    ctx.restoreGState()
}

// 4. Central luminous glass disc + AI Clean Sparkle
drawRadialGlow(
    center: center,
    radius: 175,
    color: CGColor(red: 0.16, green: 0.90, blue: 0.68, alpha: 0.34)
)

// Main 4-point sparkle
let mainSparkle = makeFourPointSparkle(
    center: CGPoint(x: center.x - 14, y: center.y - 8),
    outerRadius: 136,
    innerRadius: 24
)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 32, color: CGColor(red: 0.18, green: 0.96, blue: 0.74, alpha: 0.72))
ctx.addPath(mainSparkle)
ctx.clip()
if let starGrad = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1.0),
        CGColor(red: 0.84, green: 0.99, blue: 0.95, alpha: 1.0),
        CGColor(red: 0.58, green: 0.90, blue: 1.00, alpha: 1.0)
    ] as CFArray,
    locations: [0.0, 0.6, 1.0]
) {
    ctx.drawLinearGradient(
        starGrad,
        start: CGPoint(x: center.x - 120, y: center.y + 130),
        end: CGPoint(x: center.x + 120, y: center.y - 130),
        options: []
    )
}
ctx.restoreGState()

// Secondary companion sparkle (top-right)
let miniSparkle = makeFourPointSparkle(
    center: CGPoint(x: center.x + 92, y: center.y + 84),
    outerRadius: 48,
    innerRadius: 10
)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 18, color: CGColor(red: 0.36, green: 0.88, blue: 1.0, alpha: 0.85))
ctx.setFillColor(CGColor(red: 0.94, green: 0.99, blue: 1.0, alpha: 0.96))
ctx.addPath(miniSparkle)
ctx.fillPath()
ctx.restoreGState()

// Tiny accent glint (bottom-right)
let tinySparkle = makeFourPointSparkle(
    center: CGPoint(x: center.x + 106, y: center.y - 64),
    outerRadius: 24,
    innerRadius: 5
)
ctx.saveGState()
ctx.setFillColor(CGColor(red: 0.56, green: 0.98, blue: 0.84, alpha: 0.88))
ctx.addPath(tinySparkle)
ctx.fillPath()
ctx.restoreGState()

// 5. Crisp inner glass specular rim
ctx.restoreGState()
ctx.saveGState()
let rimStroke = squircle.copy(strokingWithWidth: 4.5, lineCap: .round, lineJoin: .round, miterLimit: 10)
ctx.addPath(rimStroke)
ctx.clip()
if let rimGrad = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.42),
        CGColor(red: 0.40, green: 0.92, blue: 0.80, alpha: 0.20),
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.08)
    ] as CFArray,
    locations: [0.0, 0.5, 1.0]
) {
    ctx.drawLinearGradient(
        rimGrad,
        start: CGPoint(x: iconRect.minX, y: iconRect.maxY),
        end: CGPoint(x: iconRect.maxX, y: iconRect.minY),
        options: []
    )
}
ctx.restoreGState()

guard let image = ctx.makeImage() else {
    fputs("Failed to finalize CGImage\n", stderr)
    exit(1)
}

let rep = NSBitmapImageRep(cgImage: image)
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG\n", stderr)
    exit(1)
}

do {
    let url = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try pngData.write(to: url)
} catch {
    fputs("Failed to write PNG: \(error)\n", stderr)
    exit(1)
}
