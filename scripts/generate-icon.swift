import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 0.17, green: 0.32, blue: 0.30, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.setFillColor(CGColor(red: 0.94, green: 0.92, blue: 0.84, alpha: 1))
let left = CGMutablePath()
left.move(to: CGPoint(x: 210, y: 290)); left.addLine(to: CGPoint(x: 210, y: 742))
left.addCurve(to: CGPoint(x: 482, y: 690), control1: CGPoint(x: 318, y: 775), control2: CGPoint(x: 404, y: 750))
left.addLine(to: CGPoint(x: 482, y: 245))
left.addCurve(to: CGPoint(x: 210, y: 290), control1: CGPoint(x: 386, y: 305), control2: CGPoint(x: 292, y: 326)); left.closeSubpath()
context.addPath(left); context.fillPath()
let right = CGMutablePath()
right.move(to: CGPoint(x: 542, y: 245)); right.addLine(to: CGPoint(x: 542, y: 690))
right.addCurve(to: CGPoint(x: 814, y: 742), control1: CGPoint(x: 620, y: 750), control2: CGPoint(x: 716, y: 775))
right.addLine(to: CGPoint(x: 814, y: 290))
right.addCurve(to: CGPoint(x: 542, y: 245), control1: CGPoint(x: 726, y: 326), control2: CGPoint(x: 632, y: 305)); right.closeSubpath()
context.addPath(right); context.fillPath()
let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Icon export failed") }
