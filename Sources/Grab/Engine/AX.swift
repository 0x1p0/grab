import AppKit
import ApplicationServices

/// Attribute names we use that aren't all exported as constants.
enum AXAttr {
    static let role = "AXRole"
    static let subrole = "AXSubrole"
    static let roleDescription = "AXRoleDescription"
    static let title = "AXTitle"
    static let value = "AXValue"
    static let description = "AXDescription"
    static let position = "AXPosition"
    static let size = "AXSize"
    static let parent = "AXParent"
    static let children = "AXChildren"
    static let url = "AXURL"
    static let document = "AXDocument"
    static let filename = "AXFilename"
    static let numberOfCharacters = "AXNumberOfCharacters"

    static let rangeForPosition = "AXRangeForPosition"
    static let boundsForRange = "AXBoundsForRange"
    static let stringForRange = "AXStringForRange"
    static let lineForIndex = "AXLineForIndex"
    static let rangeForLine = "AXRangeForLine"

    static let textMarkerForPosition = "AXTextMarkerForPosition"
    static let leftWord = "AXLeftWordTextMarkerRangeForTextMarker"
    static let rightWord = "AXRightWordTextMarkerRangeForTextMarker"
    static let lineRange = "AXLineTextMarkerRangeForTextMarker"
    static let leftLine = "AXLeftLineTextMarkerRangeForTextMarker"
    static let rightLine = "AXRightLineTextMarkerRangeForTextMarker"
    static let sentenceRange = "AXSentenceTextMarkerRangeForTextMarker"
    static let paragraphRange = "AXParagraphTextMarkerRangeForTextMarker"
    static let stringForMarkerRange = "AXStringForTextMarkerRange"
    static let boundsForMarkerRange = "AXBoundsForTextMarkerRange"
    static let markerRangeForElement = "AXTextMarkerRangeForUIElement"
}

extension AXUIElement {
    func attribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ name: String) -> String? {
        guard let s = attribute(name) as? String, !s.isEmpty else { return nil }
        return s
    }

    func parameterized(_ name: String, _ param: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(self, name as CFString, param, &value) == .success else { return nil }
        return value
    }

    /// Fetches several attributes in one IPC round trip. Missing ones are omitted.
    func attributes(_ names: [String]) -> [String: CFTypeRef] {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(self, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let values = raw as? [AnyObject] else { return [:] }
        var out: [String: CFTypeRef] = [:]
        for (i, name) in names.enumerated() where i < values.count {
            let v = values[i] as CFTypeRef
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { continue }
            if CFGetTypeID(v) == CFNullGetTypeID() { continue }
            out[name] = v
        }
        return out
    }

    var pid: pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(self, &p)
        return p
    }

    @discardableResult
    func set(_ name: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(self, name as CFString, value)
    }
}

enum AXBox {
    static func point(_ p: CGPoint) -> AXValue {
        var p = p
        return AXValueCreate(.cgPoint, &p)!
    }

    static func range(_ r: CFRange) -> AXValue {
        var r = r
        return AXValueCreate(.cfRange, &r)!
    }

    static func rect(_ v: CFTypeRef?) -> CGRect? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &r) else { return nil }
        return r
    }

    static func cgPoint(_ v: CFTypeRef?) -> CGPoint? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        guard AXValueGetValue(v as! AXValue, .cgPoint, &p) else { return nil }
        return p
    }

    static func cgSize(_ v: CFTypeRef?) -> CGSize? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        guard AXValueGetValue(v as! AXValue, .cgSize, &s) else { return nil }
        return s
    }

    static func cfRange(_ v: CFTypeRef?) -> CFRange? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
        return r
    }

    static func url(_ v: CFTypeRef?) -> URL? {
        guard let v else { return nil }
        if CFGetTypeID(v) == CFURLGetTypeID() { return (v as! CFURL) as URL }
        if let s = v as? String { return URL(string: s) }
        return nil
    }
}

/// Wraps an AXUIElement so it can be used as a dictionary key.
struct ElementKey: Hashable {
    let element: AXUIElement
    static func == (a: ElementKey, b: ElementKey) -> Bool { CFEqual(a.element, b.element) }
    func hash(into h: inout Hasher) { h.combine(CFHash(element)) }
}
