import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("usage: generate_app_icon.swift OUTPUT.png\n", stderr)
    exit(2)
}

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

NSColor.clear.setFill()
NSRect(origin: .zero, size: size).fill()

let tile = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 220, yRadius: 220)
NSColor(calibratedRed: 230 / 255, green: 1, blue: 92 / 255, alpha: 1).setFill()
tile.fill()
NSColor(calibratedWhite: 23 / 255, alpha: 1).setStroke()
tile.lineWidth = 42
tile.stroke()

let ink = NSColor(calibratedWhite: 23 / 255, alpha: 1)
ink.setStroke()
let queue = NSBezierPath()
queue.lineWidth = 68
queue.move(to: NSPoint(x: 250, y: 669))
queue.line(to: NSPoint(x: 545, y: 669))
queue.move(to: NSPoint(x: 250, y: 414))
queue.line(to: NSPoint(x: 545, y: 414))
queue.stroke()

let play = NSBezierPath()
play.move(to: NSPoint(x: 630, y: 739))
play.line(to: NSPoint(x: 630, y: 329))
play.line(to: NSPoint(x: 850, y: 534))
play.close()
ink.setFill()
play.fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("could not render app icon\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
print(arguments[1])
