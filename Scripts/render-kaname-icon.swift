#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: render-kaname-icon.swift OUTPUT.png\n".utf8))
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else {
    FileHandle.standardError.write(Data("unable to create icon graphics context\n".utf8))
    exit(1)
}

let canvas = CGRect(origin: .zero, size: size)
let shape = CGPath(
    roundedRect: canvas.insetBy(dx: 54, dy: 54),
    cornerWidth: 218,
    cornerHeight: 218,
    transform: nil
)
context.addPath(shape)
context.clip()

let colors = [
    NSColor(red: 136 / 255, green: 192 / 255, blue: 208 / 255, alpha: 1).cgColor,
    NSColor(red: 94 / 255, green: 129 / 255, blue: 172 / 255, alpha: 1).cgColor,
    NSColor(red: 59 / 255, green: 66 / 255, blue: 82 / 255, alpha: 1).cgColor,
] as CFArray
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: colors,
    locations: [0, 0.58, 1]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 170, y: 930),
    end: CGPoint(x: 850, y: 90),
    options: []
)

context.setFillColor(NSColor.white.withAlphaComponent(0.09).cgColor)
context.fillEllipse(in: CGRect(x: 610, y: 600, width: 470, height: 470))
context.setFillColor(NSColor.black.withAlphaComponent(0.12).cgColor)
context.fillEllipse(in: CGRect(x: -80, y: -120, width: 560, height: 560))

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 520, weight: .bold),
    .foregroundColor: NSColor(red: 236 / 255, green: 239 / 255, blue: 244 / 255, alpha: 1),
    .paragraphStyle: paragraph,
    .kern: -14,
]
let mark = NSAttributedString(string: "要", attributes: attributes)
mark.draw(in: CGRect(x: 130, y: 210, width: 764, height: 635))

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("unable to encode icon PNG\n".utf8))
    exit(1)
}
try png.write(to: outputURL, options: .atomic)
