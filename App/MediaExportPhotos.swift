import Foundation

extension MediaBridge {
    func saveExportFile(_ body: [String: Any], allowed: Bool) {
        let req=body["req"] as? String ?? ""
        let generation = mediaAccess.generation
        guard allowed, let request=ExportPhotoRequest(body) else {
            send(["event":"export-save-result","req":req,"saved":false,"reason":"неверный запрос сохранения"])
            return
        }
        let ownedFile: (String) -> URL? = { [weak self] id in
            guard let file = self?.proxyFile(id),
                  file.standardizedFileURL.deletingLastPathComponent()==MediaBridge.userDir.standardizedFileURL,
                  file.lastPathComponent==id+".mp4", FileManager.default.isReadableFile(atPath:file.path) else { return nil }
            return file
        }
        if let file = ownedFile(request.id) { exportOperations.fileReady(request.token, file: file) }
        exportOperations.save(request, resolve: ownedFile, write: NativeExporter.saveToPhotos) { [weak self] ok,error in
            DispatchQueue.main.async {
                self?.send(["event":"export-save-result","req":req,"saved":ok,"reason":error ?? ""], generation: generation)
                if ok {
                    self?.forgetFile(request.id)
                    MediaBridge.fileQueue.async { MediaBridge.removeUserFiles(request.id) }
                }
            }
        }
    }
}
