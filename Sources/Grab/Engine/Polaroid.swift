import AppKit
import CoreImage
import SwiftUI

/// How a Polaroid copy looks: its film, frame, handwriting and caption. Chosen in
/// Settings → Formats, with a live preview.
struct PolaroidStyle: Equatable {
    var film: Film = .instant
    var frame: Frame = .white
    var hand: Hand = .marker
    var caption: Caption = .whereAndDate
    var custom = "{site} · {date}"
    var tilt = true
    var grain = true

    enum Film: String, CaseIterable, Identifiable {
        case instant, original, golden, faded, vivid, cool, noir, mono
        var id: String { rawValue }
        var title: String {
            switch self {
            case .instant: "Instant"
            case .original: "Original"
            case .golden: "Golden"
            case .faded: "Faded"
            case .vivid: "Vivid"
            case .cool: "Cool"
            case .noir: "Noir"
            case .mono: "Mono"
            }
        }
        /// Core Image's photo effect for this film (nil keeps the colors as they are).
        var filter: String? {
            switch self {
            case .instant: "CIPhotoEffectInstant"
            case .original: nil
            case .golden: "CIPhotoEffectTransfer"
            case .faded: "CIPhotoEffectFade"
            case .vivid: "CIPhotoEffectChrome"
            case .cool: "CIPhotoEffectProcess"
            case .noir: "CIPhotoEffectNoir"
            case .mono: "CIPhotoEffectMono"
            }
        }
    }

    enum Frame: String, CaseIterable, Identifiable {
        case white, cream, black, blush, sky
        var id: String { rawValue }
        var title: String {
            switch self {
            case .white: "White"
            case .cream: "Cream"
            case .black: "Black"
            case .blush: "Blush"
            case .sky: "Sky"
            }
        }
        /// Top and bottom of the paper (a little light falls off toward the bottom).
        var paper: [Color] {
            switch self {
            case .white: [Color(red: 0.99, green: 0.985, blue: 0.97), Color(red: 0.955, green: 0.95, blue: 0.93)]
            case .cream: [Color(red: 0.98, green: 0.95, blue: 0.87), Color(red: 0.94, green: 0.90, blue: 0.80)]
            case .black: [Color(red: 0.13, green: 0.13, blue: 0.14), Color(red: 0.07, green: 0.07, blue: 0.08)]
            case .blush: [Color(red: 0.99, green: 0.88, blue: 0.89), Color(red: 0.96, green: 0.80, blue: 0.83)]
            case .sky: [Color(red: 0.86, green: 0.93, blue: 0.99), Color(red: 0.77, green: 0.87, blue: 0.97)]
            }
        }
        var ink: Color {
            switch self {
            case .black: Color(red: 0.93, green: 0.92, blue: 0.88)
            case .blush: Color(red: 0.45, green: 0.15, blue: 0.27)
            case .sky: Color(red: 0.10, green: 0.22, blue: 0.42)
            default: Color(red: 0.16, green: 0.18, blue: 0.32)
            }
        }
    }

    enum Hand: String, CaseIterable, Identifiable {
        case marker, pen, felt, typewriter
        var id: String { rawValue }
        var title: String {
            switch self {
            case .marker: "Marker"
            case .pen: "Pen"
            case .felt: "Felt tip"
            case .typewriter: "Typewriter"
            }
        }
        var fontName: String {
            switch self {
            case .marker: "Noteworthy-Bold"
            case .pen: "BradleyHandITCTT-Bold"
            case .felt: "MarkerFelt-Wide"
            case .typewriter: "AmericanTypewriter"
            }
        }
    }

    enum Caption: String, CaseIterable, Identifiable {
        case whereAndDate, place, date, dateAndTime, custom, none
        var id: String { rawValue }
        var title: String {
            switch self {
            case .whereAndDate: "Where and when"
            case .place: "Where"
            case .date: "Date"
            case .dateAndTime: "Date and time"
            case .custom: "Your own…"
            case .none: "Nothing"
            }
        }
    }

    /// The caption written under the photo. `site` is the page's domain or the app's name.
    func captionText(site: String, app: String?, title: String?, at date: Date = Date()) -> String {
        let day = date.formatted(.dateTime.month(.abbreviated).day())
        let time = date.formatted(.dateTime.hour().minute())
        switch caption {
        case .whereAndDate: return "\(site) · \(day)"
        case .place: return site
        case .date: return date.formatted(.dateTime.month(.wide).day().year())
        case .dateAndTime: return "\(day), \(time)"
        case .none: return ""
        case .custom:
            return custom
                .replacingOccurrences(of: "{site}", with: site)
                .replacingOccurrences(of: "{app}", with: app ?? site)
                .replacingOccurrences(of: "{title}", with: title ?? site)
                .replacingOccurrences(of: "{date}", with: day)
                .replacingOccurrences(of: "{time}", with: time)
                .replacingOccurrences(of: "{year}", with: date.formatted(.dateTime.year()))
        }
    }

    static var current: PolaroidStyle {
        let s = Settings.shared
        return PolaroidStyle(film: Film(rawValue: s.polaroidFilm) ?? .instant, frame: Frame(rawValue: s.polaroidFrame) ?? .white,
                             hand: Hand(rawValue: s.polaroidHand) ?? .marker, caption: Caption(rawValue: s.polaroidCaption) ?? .whereAndDate,
                             custom: s.polaroidCustom, tilt: s.polaroidTilt, grain: s.polaroidGrain)
    }
}

enum Polaroid {
    /// The picture as an instant photo, in the given style.
    @MainActor
    static func make(_ image: CGImage, pointSize: CGSize, caption: String, style: PolaroidStyle) -> (image: CGImage, pointSize: CGSize)? {
        let developed = develop(image, film: style.film, grain: style.grain) ?? image
        // A sensible print size, whatever the source.
        let longest = max(pointSize.width, pointSize.height)
        let k = longest > 0 ? min(1, 460 / longest) : 1
        var photo = CGSize(width: max(1, pointSize.width * k), height: max(1, pointSize.height * k))
        if min(photo.width, photo.height) < 160 {
            let up = 160 / max(1, min(photo.width, photo.height))
            photo = CGSize(width: photo.width * up, height: photo.height * up)
        }
        let r = ImageRenderer(content: PrintView(photo: developed, size: photo, caption: caption, style: style))
        r.scale = 2
        guard let out = r.cgImage else { return nil }
        return (out, CGSize(width: CGFloat(out.width) / 2, height: CGFloat(out.height) / 2))
    }

    /// Film color, then (optionally) a little grain and a soft vignette, like a real print.
    static func develop(_ image: CGImage, film: PolaroidStyle.Film, grain: Bool) -> CGImage? {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var ci = CIImage(cgImage: image)
        if let f = film.filter { ci = ci.applyingFilter(f, parameters: [:]) }
        if grain {
            let side = CGFloat(min(image.width, image.height))
            ci = ci.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.55, kCIInputRadiusKey: side * 0.9])
            // Fine monochrome noise, mostly mid-grey, laid over softly.
            let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.07),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                ])
                .cropped(to: extent)
            ci = noise.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: ci])
        }
        return CIContext().createCGImage(ci.cropped(to: extent), from: extent)
    }

    /// A small scene to preview styles on in Settings.
    @MainActor static let sample: CGImage? = {
        let scene = ZStack {
            LinearGradient(colors: [Color(red: 0.98, green: 0.62, blue: 0.36), Color(red: 0.93, green: 0.36, blue: 0.47), Color(red: 0.36, green: 0.27, blue: 0.62)],
                           startPoint: .top, endPoint: .bottom)
            Circle().fill(Color(red: 1, green: 0.88, blue: 0.62)).frame(width: 74).offset(y: -6).blur(radius: 1)
            Path { p in
                p.move(to: CGPoint(x: 0, y: 170)); p.addCurve(to: CGPoint(x: 300, y: 150), control1: CGPoint(x: 90, y: 110), control2: CGPoint(x: 190, y: 190))
                p.addLine(to: CGPoint(x: 300, y: 225)); p.addLine(to: CGPoint(x: 0, y: 225)); p.closeSubpath()
            }
            .fill(Color(red: 0.24, green: 0.16, blue: 0.40))
            Path { p in
                p.move(to: CGPoint(x: 0, y: 200)); p.addCurve(to: CGPoint(x: 300, y: 185), control1: CGPoint(x: 120, y: 170), control2: CGPoint(x: 200, y: 215))
                p.addLine(to: CGPoint(x: 300, y: 225)); p.addLine(to: CGPoint(x: 0, y: 225)); p.closeSubpath()
            }
            .fill(Color(red: 0.14, green: 0.09, blue: 0.26))
        }
        .frame(width: 300, height: 225)
        let r = ImageRenderer(content: scene)
        r.scale = 2
        return r.cgImage
    }()
}

private struct PrintView: View {
    let photo: CGImage
    let size: CGSize
    let caption: String
    let style: PolaroidStyle

    var body: some View {
        let side = max(12, min(size.width, size.height) * 0.06)
        let bottom = max(side * 3.6, 52)
        VStack(spacing: 0) {
            Image(decorative: photo, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
                .overlay(Rectangle().strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
            Text(caption.isEmpty ? " " : caption)
                .font(.custom(style.hand.fontName, size: min(22, max(13, size.width * 0.05))))
                .foregroundStyle(style.frame.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, side * 0.5)
                .frame(width: size.width, height: bottom)
        }
        .padding(.horizontal, side)
        .padding(.top, side)
        .background(LinearGradient(colors: style.frame.paper, startPoint: .top, endPoint: .bottom))
        .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
        .rotationEffect(.degrees(style.tilt ? -2 : 0))
        .padding(26)
    }
}
