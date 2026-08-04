import AppKit

enum ColorLuminance {
    private static func linearize(_ c: CGFloat) -> CGFloat {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// W3C WCAG 2.x relative luminance (0.0 = black, 1.0 = white).
    /// If the color has alpha < 1.0, composites against black in linear space
    /// (conservative estimate for glass over typical dark wallpapers).
    static func relativeLuminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB) ?? color
        let a = c.alphaComponent
        return 0.2126 * linearize(c.redComponent) * a
             + 0.7152 * linearize(c.greenComponent) * a
             + 0.0722 * linearize(c.blueComponent) * a
    }

    /// Returns true when the background is light enough that dark text is needed.
    /// Threshold 0.179 is the WCAG 4.5:1 contrast boundary against pure white.
    static func prefersDarkText(for background: NSColor) -> Bool {
        relativeLuminance(background) > 0.179
    }

    /// Compute the effective chrome tint color from themeColor + glassOpacity.
    /// Replicates GlassTheme.chromeTint logic so GhosttyBridge can call this
    /// without depending on the Views layer.
    static func effectiveChromeTint(themeColor: NSColor, glassOpacity: Double) -> NSColor {
        let c = themeColor.usingColorSpace(.sRGB) ?? themeColor
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let tintAlpha = 0.20 + (max(0.0, min(1.0, glassOpacity)) * 0.80)
        if s < 0.05 {
            return NSColor(hue: 0, saturation: 0, brightness: b, alpha: tintAlpha)
        }
        return NSColor(hue: h, saturation: s, brightness: b, alpha: tintAlpha)
    }
}
