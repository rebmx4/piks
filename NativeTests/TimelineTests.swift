import XCTest
import UIKit
import PiksCore
@testable import PiksNative

@MainActor
final class TimelineTests: XCTestCase {
    func testShortClipAcceptsTouchInsideMinimum44PointTarget() {
        let a = MediaAsset(kind: .image, originalName: "short.png", duration: 0, width: 160, height: 160)
        let p = Project(name: "Short clip", assets: [a], clips: [Clip(assetID: a.id, sourceDuration: 0.1)])
        let timeline = TimelineView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        timeline.configure(project: p, selected: nil, playhead: 0, thumbnails: [:], onSelect: { _ in }, onSeek: { _ in })
        timeline.layoutIfNeeded()
        // The visible clip is a few points wide, but its tap area must be 44 pt.
        let target = timeline.hitTest(CGPoint(x: 148, y: 54), with: nil)
        XCTAssertTrue(target is TimelineCell, "A tap 14 pt from the clip centre must select the short clip")
        let empty = timeline.hitTest(CGPoint(x: 100, y: 54), with: nil)
        XCTAssertFalse(empty is TimelineCell, "Do not select a distant clip in empty timeline space")
    }
}
