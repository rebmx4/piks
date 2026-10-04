import SwiftUI
import UIKit
import PiksCore

struct NativeTimeline: UIViewRepresentable {
    let project: Project
    let selected: UUID?
    let playhead: Double
    let thumbnails: [UUID: UIImage]
    let onSelect: (UUID) -> Void
    let onSeek: (Double) -> Void
    func makeUIView(context: Context) -> TimelineView { TimelineView() }
    func updateUIView(_ view: TimelineView, context: Context) {
        view.configure(project: project, selected: selected, playhead: playhead,
                       thumbnails: thumbnails, onSelect: onSelect, onSeek: onSeek)
    }
}

final class TimelineLayout: UICollectionViewLayout {
    var clips: [Clip] = []
    var duration = 0.0
    var pointsPerSecond: CGFloat = 42
    var gutter: CGFloat = 0
    let laneHeight: CGFloat = 62
    private var attributes: [UICollectionViewLayoutAttributes] = []
    private var laneMap: [Int: Int] = [:]
    override func prepare() {
        super.prepare()
        let lanes = Set(clips.map(\.lane)).sorted { a, b in
            if a < 0 && b >= 0 { return false }
            if b < 0 && a >= 0 { return true }
            return a < b
        }
        laneMap = Dictionary(uniqueKeysWithValues: lanes.enumerated().map { ($0.element, $0.offset) })
        attributes = clips.enumerated().map { i, clip in
            let attr = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: i, section: 0))
            attr.frame = CGRect(x: gutter + CGFloat(clip.at) * pointsPerSecond,
                                y: 28 + CGFloat(laneMap[clip.lane] ?? 0) * laneHeight,
                                width: max(14, CGFloat(clip.duration) * pointsPerSecond - 2), height: laneHeight - 8)
            return attr
        }
    }
    override var collectionViewContentSize: CGSize {
        CGSize(width: 2 * gutter + max(1, CGFloat(duration)) * pointsPerSecond,
               height: max(100, 28 + CGFloat(laneMap.count) * laneHeight))
    }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        attributes.filter { $0.frame.intersects(rect) }
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        attributes.indices.contains(indexPath.item) ? attributes[indexPath.item] : nil
    }
    func nearestIndexPath(to point: CGPoint) -> IndexPath? {
        attributes.filter { attribute in
            let frame = attribute.frame
            return frame.insetBy(dx: -max(0, (44 - frame.width) / 2), dy: -max(0, (44 - frame.height) / 2)).contains(point)
        }.min { a, b in abs(a.frame.midX - point.x) < abs(b.frame.midX - point.x) }?.indexPath
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
}

final class TimelineCell: UICollectionViewCell {
    let thumbnail = UIImageView()
    let name = UILabel()
    let durationLabel = UILabel()
    var activate: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 8; contentView.clipsToBounds = true
        thumbnail.contentMode = .scaleAspectFill; thumbnail.clipsToBounds = true
        name.font = .systemFont(ofSize: 10, weight: .semibold); name.textColor = .white; name.numberOfLines = 1
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium); durationLabel.textColor = .white
        contentView.addSubview(thumbnail); contentView.addSubview(name); contentView.addSubview(durationLabel)
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { nil }
    override func accessibilityActivate() -> Bool { activate?(); return activate != nil }
    override func layoutSubviews() {
        super.layoutSubviews()
        thumbnail.frame = CGRect(x: 0, y: 0, width: min(75, bounds.width), height: bounds.height)
        name.frame = CGRect(x: 6, y: 6, width: max(0, bounds.width - 12), height: 16)
        durationLabel.frame = CGRect(x: 6, y: bounds.height - 18, width: max(0, bounds.width - 12), height: 14)
    }
    func set(clip: Clip, asset: MediaAsset?, image: UIImage?, selected: Bool) {
        thumbnail.image = image; thumbnail.alpha = clip.lane < 0 ? 0 : 0.6
        contentView.backgroundColor = clip.lane < 0 ? .systemTeal : .systemIndigo
        contentView.layer.borderWidth = selected ? 3 : 0
        contentView.layer.borderColor = UIColor.systemCyan.cgColor
        name.text = asset?.originalName ?? "Клип"; durationLabel.text = formatTime(clip.duration)
        accessibilityLabel = "\(name.text ?? "Клип"), \(durationLabel.text ?? ""), дорожка \(clip.lane + 1)"
        accessibilityTraits = selected ? [.button, .selected] : .button
        accessibilityIdentifier = "timeline.clip.\(clip.id)"
    }
}

final class TimelineView: UIView, UICollectionViewDataSource, UICollectionViewDelegate, UIScrollViewDelegate {
    private let timelineLayout = TimelineLayout()
    private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: timelineLayout)
    private let needle = UIView()
    private let ruler = UILabel()
    private var project: Project?
    private var selected: UUID?
    private var images: [UUID: UIImage] = [:]
    private var onSelect: ((UUID) -> Void)?
    private var onSeek: ((Double) -> Void)?
    private var lastSeek: CFTimeInterval = 0
    override init(frame: CGRect) {
        super.init(frame: frame)
        collection.dataSource = self; collection.delegate = self
        collection.allowsSelection = false
        collection.register(TimelineCell.self, forCellWithReuseIdentifier: "Clip")
        collection.backgroundColor = .clear; collection.showsHorizontalScrollIndicator = false
        collection.showsVerticalScrollIndicator = true; collection.decelerationRate = .fast
        collection.accessibilityIdentifier = "editor.timeline"
        collection.contentInsetAdjustmentBehavior = .never
        needle.backgroundColor = .systemCyan; needle.isUserInteractionEnabled = false
        ruler.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium); ruler.textColor = .secondaryLabel
        addSubview(collection); addSubview(needle); addSubview(ruler)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(zoom(_:))); addGestureRecognizer(pinch)
        collection.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(selectAtTouch(_:))))
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, bounds.contains(point) else { return nil }
        collection.layoutIfNeeded()
        if let index = timelineLayout.nearestIndexPath(to: collection.convert(point, from: self)),
           let cell = collection.cellForItem(at: index) { return cell }
        return super.hitTest(point, with: event)
    }
    @objc private func selectAtTouch(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended,
              let path = timelineLayout.nearestIndexPath(to: gesture.location(in: collection)),
              let project, project.clips.indices.contains(path.item) else { return }
        onSelect?(project.clips[path.item].id)
        UISelectionFeedbackGenerator().selectionChanged()
    }
    override func layoutSubviews() {
        super.layoutSubviews(); collection.frame = bounds
        timelineLayout.gutter = bounds.width / 2; timelineLayout.invalidateLayout()
        needle.frame = CGRect(x: bounds.midX - 1, y: 24, width: 2, height: max(0, bounds.height - 24))
        ruler.frame = CGRect(x: 12, y: 3, width: bounds.width - 24, height: 18)
    }
    func configure(project: Project, selected: UUID?, playhead: Double, thumbnails: [UUID: UIImage],
                   onSelect: @escaping (UUID) -> Void, onSeek: @escaping (Double) -> Void) {
        let changed = self.project?.revision != project.revision || self.project?.id != project.id || self.selected != selected || images.count != thumbnails.count
        self.project = project; self.selected = selected; images = thumbnails; self.onSelect = onSelect; self.onSeek = onSeek
        if changed {
            timelineLayout.clips = project.clips; timelineLayout.duration = project.duration
            timelineLayout.invalidateLayout(); collection.reloadData()
        }
        ruler.text = "\(formatTime(playhead))  /  \(formatTime(project.duration))"
        if !collection.isDragging && !collection.isDecelerating {
            let x = CGFloat(playhead) * timelineLayout.pointsPerSecond
            if abs(collection.contentOffset.x - x) > 0.5 { collection.setContentOffset(CGPoint(x: x, y: collection.contentOffset.y), animated: false) }
        }
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { project?.clips.count ?? 0 }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "Clip", for: indexPath) as! TimelineCell
        if let project, project.clips.indices.contains(indexPath.item) {
            let clip = project.clips[indexPath.item]
            cell.set(clip: clip, asset: project.assets.first { $0.id == clip.assetID }, image: images[clip.assetID], selected: selected == clip.id)
            cell.activate = { [weak self] in self?.onSelect?(clip.id) }
        }
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let project, project.clips.indices.contains(indexPath.item) else { return }
        onSelect?(project.clips[indexPath.item].id)
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isDragging || scrollView.isDecelerating else { return }
        let now = CACurrentMediaTime()
        guard now - lastSeek > 1.0 / 30 else { return }
        lastSeek = now
        onSeek?(max(0, Double(scrollView.contentOffset.x / timelineLayout.pointsPerSecond)))
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { onSeek?(max(0, Double(scrollView.contentOffset.x / timelineLayout.pointsPerSecond))) }
    @objc private func zoom(_ gesture: UIPinchGestureRecognizer) {
        let time = collection.contentOffset.x / timelineLayout.pointsPerSecond
        timelineLayout.pointsPerSecond = min(240, max(8, timelineLayout.pointsPerSecond * gesture.scale))
        gesture.scale = 1; timelineLayout.invalidateLayout(); collection.layoutIfNeeded()
        collection.contentOffset.x = time * timelineLayout.pointsPerSecond
    }
}
