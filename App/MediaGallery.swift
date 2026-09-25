import UIKit
import Photos
import AVFoundation

// Своя галерея для Ryndi, как у CapCut (владелец, 26.09.2026): вверху
// «Недавние ▾» (стрелка — список альбомов) и «Избранные», ниже «Видео / Фото /
// Живые фото», сетка с длительностью. Раньше было системное окно выбора.
//
// Команды со страницы (ответ — событием с тем же id запроса):
//   gallery-albums — альбомы: { id, title, count, cover } — cover это номер
//                    ролика для картинки; «Недавние» и «Избранное» — id
//                    "recents" и "favorites";
//   gallery-assets — содержимое альбома порциями, новые первыми:
//                    { album, kind: video|photo|live, offset, limit } →
//                    { items: [{ id, duration, w, h, fav }], total };
//   gallery-use    — взять выбранные ролики: { ids } → { items: [{ id, url,
//                    bytes, seconds, w, h, transfer }] }; transfer — "hlg",
//                    "pq" или "" (метка цвета HDR: страница сразу знает цвет,
//                    без двух секунд блёклого кадра);
//   ошибка — gallery-error { id, reason }.
// Картинки для сетки — по схеме: ryndi-media://thumb/<номер>.jpg?s=<точек>
// (MediaServer.swift). Номер ролика тот же, что у выбора (stableId), и сам
// ролик страница показывает по ryndi-media://orig/<номер>.mp4.
extension MediaBridge {

    func galleryCommand(_ cmd: String, _ body: [String: Any]) {
        let req = (body["id"] as? String) ?? ""
        galleryAccess(req) { [weak self] in
            guard let self = self else { return }
            switch cmd {
            case "gallery-albums": self.galleryAlbums(req)
            case "gallery-assets": self.galleryAssets(req, body)
            case "gallery-use":    self.galleryUse(req, (body["ids"] as? [String]) ?? [])
            default: break
            }
        }
    }

    // Доступ к галерее: спрашиваем один раз; «выбранные фото» тоже годятся.
    private func galleryAccess(_ req: String, _ then: @escaping () -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .authorized || status == .limited { then(); return }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] st in
            DispatchQueue.main.async {
                if st == .authorized || st == .limited { then() }
                else { self?.send(["event": "gallery-error", "id": req, "reason": "нет доступа к галерее"]) }
            }
        }
    }

    // MARK: - Альбомы

    private func galleryAlbums(_ req: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var list: [[String: Any]] = []
            let smart: [PHAssetCollectionSubtype] = [
                .smartAlbumUserLibrary, .smartAlbumRecentlyAdded, .smartAlbumScreenshots, .smartAlbumLivePhotos,
                .smartAlbumVideos, .smartAlbumSelfPortraits, .smartAlbumRAW, .smartAlbumDepthEffect,
                .smartAlbumFavorites, .smartAlbumSlomoVideos, .smartAlbumTimelapses, .smartAlbumPanoramas,
            ]
            for sub in smart {
                let found = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: sub, options: nil)
                found.enumerateObjects { c, _, _ in
                    let key = sub == .smartAlbumUserLibrary ? "recents" : sub == .smartAlbumFavorites ? "favorites" : c.localIdentifier
                    if let row = self.albumRow(c, key: key) { list.append(row) }
                }
            }
            let mine = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            mine.enumerateObjects { c, _, _ in
                if let row = self.albumRow(c, key: c.localIdentifier) { list.append(row) }
            }
            self.send(["event": "gallery-albums", "id": req, "albums": list])
        }
    }

    // Строка альбома: название, сколько в нём и обложка — самое новое. Пустые не показываем.
    private func albumRow(_ c: PHAssetCollection, key: String) -> [String: Any]? {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(in: c, options: opts)
        guard assets.count > 0, let first = assets.firstObject else { return nil }
        return ["id": key, "title": c.localizedTitle ?? "", "count": assets.count,
                "cover": MediaBridge.stableId(first.localIdentifier)]
    }

    private func galleryCollection(_ album: String) -> PHAssetCollection? {
        switch album {
        case "recents":
            return PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil).firstObject
        case "favorites":
            return PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil).firstObject
        default:
            return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album], options: nil).firstObject
        }
    }

    // Что показывать на вкладке: видео, фото (кроме живых) или живые фото.
    private func galleryPredicate(_ kind: String) -> NSPredicate {
        let image = Int(PHAssetMediaType.image.rawValue)
        let live = Int(PHAssetMediaSubtype.photoLive.rawValue)
        switch kind {
        case "photo": return NSPredicate(format: "mediaType == %d AND (mediaSubtypes & %d) == 0", image, live)
        case "live":  return NSPredicate(format: "mediaType == %d AND (mediaSubtypes & %d) != 0", image, live)
        default:      return NSPredicate(format: "mediaType == %d", Int(PHAssetMediaType.video.rawValue))
        }
    }

    // MARK: - Содержимое альбома

    private func galleryAssets(_ req: String, _ body: [String: Any]) {
        let album = (body["album"] as? String) ?? "recents"
        let kind = (body["kind"] as? String) ?? "video"
        let offset = max(0, (body["offset"] as? Int) ?? 0)
        let limit = min(240, max(1, (body["limit"] as? Int) ?? 60))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let opts = PHFetchOptions()
            opts.predicate = self.galleryPredicate(kind)
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let result: PHFetchResult<PHAsset>
            if let c = self.galleryCollection(album) { result = PHAsset.fetchAssets(in: c, options: opts) }
            else { result = PHAsset.fetchAssets(with: opts) }
            var items: [[String: Any]] = []
            let end = min(result.count, offset + limit)
            if offset < end {
                for i in offset..<end {
                    let a = result.object(at: i)
                    items.append(["id": MediaBridge.stableId(a.localIdentifier), "duration": a.duration,
                                  "w": a.pixelWidth, "h": a.pixelHeight, "fav": a.isFavorite])
                }
            }
            self.send(["event": "gallery-assets", "id": req, "items": items, "total": result.count])
        }
    }

    // MARK: - Картинка для сетки

    // JPEG картинки ролика или фото стороной size точек (квадрат, заполнить).
    func galleryThumb(_ id: String, size: Int, done: @escaping (Data?) -> Void) {
        guard let local = MediaBridge.localIdentifier(from: id),
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [local], options: nil).firstObject else {
            done(nil)
            return
        }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = true
        let px = CGFloat(max(64, min(800, size)))
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: px, height: px),
                                              contentMode: .aspectFill, options: opts) { image, _ in
            DispatchQueue.global(qos: .userInitiated).async { done(image?.jpegData(compressionQuality: 0.8)) }
        }
    }

    // MARK: - Взять выбранные

    private func galleryUse(_ req: String, _ ids: [String]) {
        var out: [[String: Any]] = Array(repeating: [:], count: ids.count)
        let group = DispatchGroup()
        for (i, id) in ids.enumerated() {
            guard let local = MediaBridge.localIdentifier(from: id),
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [local], options: nil).firstObject,
                  asset.mediaType == .video else {
                out[i] = ["id": id, "error": "не видео"]
                continue
            }
            group.enter()
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true          // ролик может лежать в iCloud
            opts.deliveryMode = .highQualityFormat
            opts.version = .current
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { [weak self] avAsset, _, _ in
                DispatchQueue.main.async {
                    defer { group.leave() }
                    guard let self = self, let ua = avAsset as? AVURLAsset,
                          FileManager.default.isReadableFile(atPath: ua.url.path) else {
                        out[i] = ["id": id, "error": "ролик недоступен"]
                        return
                    }
                    self.rememberFile(id, ua.url)
                    let attrs = try? FileManager.default.attributesOfItem(atPath: ua.url.path)
                    out[i] = ["id": id, "url": "\(MediaBridge.scheme)://orig/\(id).mp4",
                              "bytes": (attrs?[.size] as? Int) ?? 0,
                              "seconds": CMTimeGetSeconds(ua.duration),
                              "w": asset.pixelWidth, "h": asset.pixelHeight,
                              "transfer": MediaBridge.transferOf(ua)]
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.send(["event": "gallery-use", "id": req, "items": out])
        }
    }

    // Метка цвета HDR дорожки видео: "hlg", "pq" или "".
    static func transferOf(_ asset: AVAsset) -> String {
        guard let track = asset.tracks(withMediaType: .video).first,
              let first = track.formatDescriptions.first else { return "" }
        let desc = first as! CMFormatDescription
        guard let tf = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String else {
            return ""
        }
        if tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { return "hlg" }
        if tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { return "pq" }
        return ""
    }
}
