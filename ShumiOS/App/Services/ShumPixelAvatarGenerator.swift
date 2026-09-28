import CryptoKit
import UIKit

/// A seed always produces the same portrait. Rendered pixels stay local to this device.
@MainActor
enum ShumPixelAvatarGenerator {
    // Version 1 is a wire contract. Keep its palette, PRNG and drawing rules
    // unchanged; introduce a separate renderer/version for future designs.
    nonisolated static let version = 1

    nonisolated static func seed(for publicKey: Data) -> UInt64 {
        let digest = SHA256.hash(data: Data("shum.pixel-avatar.v1\0".utf8) + publicKey)
        return digest.prefix(8).enumerated().reduce(UInt64.zero) {
            $0 | (UInt64($1.element) << (UInt64($1.offset) * 8))
        }
    }

    private static var renderedData: [UInt64: Data] = [:]

    static func data(seed: UInt64) -> Data? {
        if let cached = renderedData[seed] { return cached }
        guard let result = image(seed: seed).pngData() else { return nil }
        if renderedData.count >= 500 { renderedData.removeAll(keepingCapacity: true) }
        renderedData[seed] = result
        return result
    }
    enum Kind: CaseIterable, Hashable {
        case person, animal, alien, robot
    }

    private struct Random {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }

        mutating func pick(_ count: Int) -> Int { Int(next() % UInt64(count)) }
    }

    private static func color(_ red: Int, _ green: Int, _ blue: Int) -> UIColor {
        UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255, alpha: 1)
    }

    static func kind(for seed: UInt64) -> Kind {
        var random = Random(state: seed ^ 0xA6C8C7D1E3F09245)
        switch random.pick(10) {
        case 0..<4: return .person
        case 4..<7: return .animal
        case 7..<9: return .alien
        default: return .robot
        }
    }

    static func image(seed: UInt64) -> UIImage {
        var random = Random(state: seed)
        let kind = kind(for: seed)
        let backgrounds = [
            color(84, 111, 94), color(91, 91, 124), color(125, 87, 101),
            color(92, 103, 122), color(117, 102, 85), color(78, 112, 116),
            color(124, 96, 122), color(79, 106, 132), color(130, 100, 79),
            color(87, 116, 105), color(104, 93, 119), color(119, 110, 89)
        ]
        let skins = [
            color(245, 198, 156), color(229, 168, 117), color(199, 132, 86),
            color(157, 96, 62), color(111, 68, 46), color(239, 184, 150),
            color(212, 148, 102), color(178, 110, 73)
        ]
        let hairs = [
            color(34, 30, 32), color(80, 48, 34), color(178, 121, 63),
            color(218, 174, 95), color(121, 61, 43), color(59, 58, 63),
            color(53, 42, 54), color(101, 67, 52), color(191, 153, 107),
            color(42, 52, 59)
        ]
        let shirts = [
            color(61, 87, 89), color(142, 75, 81), color(80, 89, 134),
            color(101, 76, 109), color(179, 117, 83), color(68, 100, 75),
            color(187, 150, 92), color(74, 110, 125), color(156, 88, 118),
            color(71, 86, 121), color(118, 115, 83), color(150, 103, 81)
        ]
        let background = backgrounds[random.pick(backgrounds.count)]
        let backdropDetail = backgrounds[random.pick(backgrounds.count)]
        let skin = skins[random.pick(skins.count)]
        let hair = hairs[random.pick(hairs.count)]
        let shirt = shirts[random.pick(shirts.count)]
        let headwearColor = shirts[random.pick(shirts.count)]
        let hairstyle = random.pick(8)
        let fringe = random.pick(4)
        let faceShape = random.pick(3)
        let browStyle = random.pick(3)
        let eyeStyle = random.pick(3)
        let mouthStyle = random.pick(4)
        let eyewear = random.pick(5)
        let facialHair = random.pick(8)
        let freckles = random.pick(6)
        let neckline = random.pick(4)
        let backdropPattern = random.pick(16)
        let headwear = random.pick(10)
        let accessory = random.pick(8)
        let characterVariant = random.pick(5)
        let expression = random.pick(4)
        let detailVariant = random.pick(6)
        let furColors = [
            color(193, 127, 65), color(128, 101, 82), color(198, 182, 153),
            color(86, 91, 101), color(222, 153, 83), color(72, 65, 68),
            color(176, 119, 100), color(233, 205, 163)
        ]
        let alienColors = [
            color(118, 194, 129), color(139, 159, 217), color(179, 129, 207),
            color(87, 178, 167), color(214, 150, 178), color(188, 202, 118)
        ]
        let metalColors = [
            color(137, 164, 173), color(150, 142, 169), color(179, 151, 119),
            color(119, 155, 151), color(158, 166, 134)
        ]
        let fur = furColors[random.pick(furColors.count)]
        let creature = alienColors[random.pick(alienColors.count)]
        let metal = metalColors[random.pick(metalColors.count)]

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 360, height: 360), format: format)
            .image { renderer in
                let context = renderer.cgContext
                context.interpolationQuality = .none
                func block(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ fill: UIColor) {
                    fill.setFill()
                    context.fill(CGRect(x: x * 20, y: y * 20,
                                        width: width * 20, height: height * 20))
                }
                func detail(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ fill: UIColor) {
                    fill.setFill()
                    context.fill(CGRect(x: x * 10, y: y * 10,
                                        width: width * 10, height: height * 10))
                }

                block(0, 0, 18, 18, background)
                let decor = backdropDetail.withAlphaComponent(0.38)
                if backdropPattern & 1 != 0 {
                    block(2, 3, 2, 2, decor)
                    block(14, 12, 2, 2, decor)
                }
                if backdropPattern & 2 != 0 {
                    block(14, 3, 2, 2, decor)
                    block(2, 12, 2, 2, decor)
                }
                if backdropPattern & 4 != 0 {
                    block(1, 8, 2, 2, decor)
                    block(15, 8, 2, 2, decor)
                }
                if backdropPattern & 8 != 0 {
                    block(4, 1, 2, 1, decor)
                    block(12, 1, 2, 1, decor)
                }
                let dark = color(40, 37, 41)
                switch kind {
                case .animal:
                    let muzzle = color(235, 212, 184)
                    let innerEar = color(191, 124, 126)
                    block(4, 15, 10, 3, shirt)
                    block(3, 16, 12, 2, shirt)
                    block(7, 12, 4, 4, fur)
                    switch characterVariant {
                    case 0: // Cat
                        block(4, 2, 3, 5, fur)
                        block(11, 2, 3, 5, fur)
                        block(5, 3, 1, 2, innerEar)
                        block(12, 3, 1, 2, innerEar)
                    case 1: // Dog
                        block(3, 5, 3, 8, fur)
                        block(12, 5, 3, 8, fur)
                    case 2: // Fox
                        block(4, 2, 3, 5, fur)
                        block(11, 2, 3, 5, fur)
                        block(5, 3, 1, 2, innerEar)
                        block(12, 3, 1, 2, innerEar)
                    case 3: // Rabbit
                        block(5, 1, 2, 7, fur)
                        block(11, 1, 2, 7, fur)
                        block(5, 2, 1, 4, innerEar)
                        block(12, 2, 1, 4, innerEar)
                    default: // Bear
                        block(4, 3, 3, 4, fur)
                        block(11, 3, 3, 4, fur)
                        block(5, 4, 1, 2, innerEar)
                        block(12, 4, 1, 2, innerEar)
                    }
                    block(5, 5, 8, 8, fur)
                    block(4, 7, 10, 5, fur)
                    if characterVariant == 2 {
                        block(5, 10, 3, 2, muzzle)
                        block(10, 10, 3, 2, muzzle)
                    }
                    block(7, 8, 1, expression == 1 ? 2 : 1, dark)
                    block(10, 8, 1, expression == 1 ? 2 : 1, dark)
                    block(7, 10, 4, 2, muzzle)
                    block(8, 10, 2, 1, dark)
                    if expression == 2 {
                        block(8, 12, 2, 1, color(153, 78, 88))
                    } else {
                        detail(17, 23, 2, 1, dark)
                    }
                    if characterVariant == 0 || characterVariant == 2 {
                        detail(8, 20, 5, 1, muzzle)
                        detail(23, 20, 5, 1, muzzle)
                    }
                    if detailVariant < 3 {
                        block(6, 14, 6, 1, headwearColor)
                        block(8, 15, 2, 1, color(222, 197, 113))
                    }
                    if accessory == 1 { block(8, 13, 2, 1, innerEar) }
                    return

                case .alien:
                    block(4, 15, 10, 3, shirt)
                    block(3, 16, 12, 2, shirt)
                    block(7, 12, 4, 4, creature)
                    switch characterVariant {
                    case 0, 1:
                        block(6, 2, 1, 4, creature)
                        block(11, 2, 1, 4, creature)
                        block(5, 1, 3, 2, creature)
                        block(10, 1, 3, 2, creature)
                    case 2:
                        block(4, 2, 2, 5, creature)
                        block(12, 2, 2, 5, creature)
                    case 3:
                        block(7, 1, 1, 5, creature)
                        block(10, 1, 1, 5, creature)
                        block(6, 1, 3, 2, headwearColor)
                        block(9, 1, 3, 2, headwearColor)
                    default:
                        block(4, 4, 2, 4, creature)
                        block(12, 4, 2, 4, creature)
                    }
                    block(5, 5, 8, 8, creature)
                    block(4, 7, 10, 4, creature)
                    if characterVariant == 4 {
                        block(8, 7, 2, 3, dark)
                        detail(17, 15, 2, 2, color(221, 238, 224))
                    } else {
                        block(6, 8, 2, 2, dark)
                        block(10, 8, 2, 2, dark)
                        detail(13, 16, 2, 1, color(221, 238, 224))
                        detail(21, 16, 2, 1, color(221, 238, 224))
                        if characterVariant == 1 { block(8, 6, 2, 1, dark) }
                    }
                    switch expression {
                    case 0: block(8, 11, 2, 1, dark)
                    case 1: block(7, 11, 4, 1, dark)
                    case 2:
                        block(8, 11, 2, 2, dark)
                        detail(17, 23, 2, 1, color(222, 222, 211))
                    default: block(8, 12, 2, 1, color(161, 69, 116))
                    }
                    if detailVariant < 3 {
                        block(5, 7, 1, 1, headwearColor)
                        block(12, 7, 1, 1, headwearColor)
                    }
                    block(6, 14, 6, 1, color(218, 220, 204))
                    return

                case .robot:
                    let display = color(52, 67, 73)
                    let lights = [color(99, 232, 177), color(251, 201, 101),
                                  color(134, 206, 242), color(242, 137, 164)]
                    let light = lights[detailVariant % lights.count]
                    block(4, 14, 10, 4, shirt)
                    block(3, 16, 12, 2, shirt)
                    block(8, 2, 2, 3, metal)
                    block(8, 1, 2, 1, light)
                    if characterVariant > 1 {
                        block(3, 5, 2, 7, metal)
                        block(13, 5, 2, 7, metal)
                    }
                    block(5, 4, 8, 9, metal)
                    block(6, 6, 6, 5, display)
                    switch characterVariant {
                    case 0:
                        block(7, 8, 1, 1, light)
                        block(10, 8, 1, 1, light)
                    case 1:
                        block(6, 8, 2, 1, light)
                        block(10, 8, 2, 1, light)
                    case 2:
                        block(8, 7, 2, 2, light)
                    default:
                        block(7, 8, 4, 1, light)
                    }
                    block(8, 10, 2, 1, expression == 0 ? light : color(216, 224, 219))
                    if detailVariant < 3 {
                        block(5, 12, 8, 1, color(83, 100, 107))
                    }
                    block(7, 15, 4, 1, light)
                    return

                case .person:
                    break
                }
                block(4, 15, 10, 3, shirt)
                block(3, 16, 12, 2, shirt)
                block(7, 13, 4, 3, skin)

                switch hairstyle {
                case 0: block(5, 3, 8, 9, hair)
                case 1:
                    block(4, 3, 10, 11, hair)
                    block(3, 6, 2, 8, hair)
                    block(13, 6, 2, 8, hair)
                case 2:
                    block(4, 4, 10, 8, hair)
                    block(5, 2, 3, 3, hair)
                    block(9, 2, 4, 3, hair)
                    block(3, 5, 2, 4, hair)
                    block(13, 5, 2, 4, hair)
                case 3:
                    block(5, 3, 8, 9, hair)
                    block(4, 5, 2, 6, hair)
                    block(12, 5, 2, 6, hair)
                case 4:
                    block(5, 4, 8, 7, hair)
                    block(4, 5, 2, 5, hair)
                case 5:
                    block(4, 2, 10, 10, hair)
                    block(3, 4, 2, 6, hair)
                    block(13, 4, 2, 6, hair)
                case 6:
                    block(5, 3, 8, 10, hair)
                    block(4, 7, 2, 6, hair)
                    block(12, 7, 2, 6, hair)
                default:
                    block(5, 4, 8, 7, hair)
                    block(6, 2, 6, 3, hair)
                }

                block(6, 5, 6, 7, skin)
                block(5, 7, 1, 3, skin)
                block(12, 7, 1, 3, skin)
                switch faceShape {
                case 0: block(7, 12, 4, 1, skin)
                case 1: block(6, 12, 6, 1, skin)
                default: block(8, 12, 2, 1, skin)
                }
                switch fringe {
                case 0: block(5, 4, 8, 1, hair)
                case 1: block(5, 4, 7, 2, hair)
                case 2:
                    block(5, 4, 4, 2, hair)
                    block(10, 4, 3, 1, hair)
                default:
                    block(5, 4, 8, 1, hair)
                    block(10, 5, 3, 2, hair)
                }

                switch headwear {
                case 6: // Beanie
                    block(5, 2, 8, 3, headwearColor)
                    block(4, 4, 10, 2, headwearColor)
                    block(7, 1, 4, 1, headwearColor)
                case 7: // Cap
                    block(5, 2, 8, 3, headwearColor)
                    block(4, 5, 10, 1, headwearColor)
                    block(10, 6, 5, 1, headwearColor)
                case 8: // Bucket hat
                    block(5, 2, 8, 3, headwearColor)
                    block(3, 5, 12, 1, headwearColor)
                    block(4, 4, 10, 1, headwearColor)
                case 9: // Headband
                    block(5, 4, 8, 1, headwearColor)
                    block(4, 5, 2, 1, headwearColor)
                default: break
                }

                let eye = color(39, 35, 37)
                if browStyle > 0 {
                    block(7, 7, 1, 1, hair)
                    block(10, 7, 1, 1, hair)
                    if browStyle == 2 { block(8, 7, 1, 1, hair) }
                }
                block(7, 8, 1, 1, eye)
                block(10, 8, 1, 1, eye)
                if eyeStyle == 1 {
                    block(6, 8, 1, 1, eye)
                    block(11, 8, 1, 1, eye)
                } else if eyeStyle == 2 {
                    block(7, 9, 1, 1, skin)
                    block(10, 9, 1, 1, skin)
                }
                if eyewear == 1 || eyewear == 2 {
                    let frame = color(67, 54, 51)
                    if eyewear == 2 {
                        let lens = color(70, 95, 105).withAlphaComponent(0.85)
                        detail(14, 16, 2, 3, lens)
                        detail(20, 16, 2, 3, lens)
                    }
                    for x in [13, 19] {
                        detail(x, 15, 4, 1, frame)
                        detail(x, 19, 4, 1, frame)
                        detail(x, 16, 1, 3, frame)
                        detail(x + 3, 16, 1, 3, frame)
                    }
                    detail(17, 16, 2, 1, frame)
                } else if eyewear == 3 {
                    block(5, 10, 1, 1, color(220, 193, 112))
                    block(12, 10, 1, 1, color(220, 193, 112))
                } else if eyewear == 4 {
                    block(6, 7, 2, 1, color(171, 115, 92))
                    block(10, 7, 2, 1, color(171, 115, 92))
                }
                let accessoryColor = color(226, 193, 111)
                switch accessory {
                case 1:
                    block(5, 10, 1, 1, accessoryColor)
                    block(12, 10, 1, 1, accessoryColor)
                case 2:
                    block(4, 10, 1, 2, accessoryColor)
                    block(13, 10, 1, 2, accessoryColor)
                case 3:
                    block(4, 5, 2, 1, accessoryColor)
                case 4:
                    block(12, 5, 2, 1, accessoryColor)
                case 5:
                    block(11, 10, 1, 1, accessoryColor)
                case 6:
                    block(4, 8, 1, 3, color(208, 210, 204))
                    block(13, 8, 1, 3, color(208, 210, 204))
                case 7:
                    block(6, 13, 6, 1, accessoryColor)
                default: break
                }
                if freckles == 1 || freckles == 2 {
                    let freckle = color(153, 87, 68)
                    block(6, 10, 1, 1, freckle)
                    block(11, 10, 1, 1, freckle)
                    if freckles == 2 { block(7, 10, 1, 1, freckle) }
                }
                if facialHair == 5 || facialHair == 7 {
                    block(6, 11, 6, 2, hair)
                    block(7, 11, 4, 1, skin)
                }
                if facialHair == 6 || facialHair == 7 {
                    block(7, 10, 4, 1, hair)
                    block(8, 10, 2, 1, skin)
                }
                let lip = color(151, 75, 74)
                switch mouthStyle {
                case 0: block(8, 11, 2, 1, lip)
                case 1: block(7, 11, 4, 1, lip)
                case 2:
                    block(8, 11, 2, 1, lip)
                    block(7, 10, 1, 1, lip)
                    block(10, 10, 1, 1, lip)
                default: block(8, 11, 2, 1, eye)
                }
                let collar = color(226, 226, 217)
                switch neckline {
                case 0:
                    block(6, 14, 2, 1, collar)
                    block(10, 14, 2, 1, collar)
                case 1: block(7, 15, 4, 1, collar)
                case 2:
                    block(6, 15, 2, 1, collar)
                    block(10, 15, 2, 1, collar)
                default:
                    block(5, 16, 8, 1, collar.withAlphaComponent(0.35))
                }
            }
    }
}
