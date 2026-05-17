import CoreGraphics
import Foundation
import Testing
@testable import PixelCrusherMacCore

struct SVGDocumentMetricsTests {
    @Test("Canvas size prefers explicit SVG dimensions")
    func usesExplicitDimensions() {
        let svg = #"<svg width="320" height="180" viewBox="0 0 32 18"></svg>"#
        let size = SVGDocumentMetrics.canvasSize(from: Data(svg.utf8))

        #expect(size?.width == 320)
        #expect(size?.height == 180)
    }

    @Test("Canvas size falls back to viewBox when width and height are missing")
    func usesViewBoxFallback() {
        let svg = #"<svg viewBox="0 0 640 360"></svg>"#
        let size = SVGDocumentMetrics.canvasSize(from: Data(svg.utf8))

        #expect(size?.width == 640)
        #expect(size?.height == 360)
    }

    @Test("Canvas size derives missing height from viewBox ratio")
    func derivesMissingHeight() {
        let svg = #"<svg width="400" viewBox="0 0 200 100"></svg>"#
        let size = SVGDocumentMetrics.canvasSize(from: Data(svg.utf8))

        #expect(size?.width == 400)
        #expect(size?.height == 200)
    }

    @Test("Canvas size understands physical units")
    func supportsPhysicalUnits() {
        let svg = #"<svg width="2in" height="1in"></svg>"#
        let size = SVGDocumentMetrics.canvasSize(from: Data(svg.utf8))

        #expect(size?.width == 192)
        #expect(size?.height == 96)
    }
}
