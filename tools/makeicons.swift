// Builds AppIcon.appiconset from one source picture.
// Usage: swift makeicons.swift <source.png> <AppIcon.appiconset dir>
// Larger sizes use nearest-neighbour scaling so pixel art stays crisp.
import AppKit

let args = CommandLine.arguments
guard args.count == 3,
      let src = NSImage(contentsOfFile: args[1]),
      let srcCG = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: makeicons <source.png> <appiconset dir>"); exit(1)
}
let outDir = args[2]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = px > srcCG.width ? .none : .high
    ctx.draw(srcCG, in: CGRect(x: 0, y: 0, width: px, height: px))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = pt * scale
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try! render(px).write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
        images.append("""
            {"size":"\(pt)x\(pt)","idiom":"mac","filename":"\(name)","scale":"\(scale)x"}
        """)
    }
}
let json = "{\"images\":[\n" + images.joined(separator: ",\n") + "\n],\"info\":{\"version\":1,\"author\":\"xcode\"}}\n"
try! json.write(toFile: "\(outDir)/Contents.json", atomically: true, encoding: .utf8)
print("wrote \(images.count) icons to \(outDir)")
