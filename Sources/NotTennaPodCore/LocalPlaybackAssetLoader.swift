import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// One asset's cancellable consumers of a selected registered document. The
/// application owns document closure; cancelling an asset never revokes siblings.
final class LocalPlaybackAssetLoader: Sendable {
    let asset: AVURLAsset
    private let worker: Worker
    struct Snapshot: Sendable {
        let pendingRequests, completedRequests, cancelledRequests, deliveredBytes, largestRead: Int
        let cancelled: Bool
        let failure: String?
    }
    init(document: LocalPlaybackDocument, onFailure: @escaping @Sendable (Error) -> Void = { _ in }) {
        let ext = (document.context.reference.filename as NSString).pathExtension
        let type = document.context.mimeType.flatMap { UTType(mimeType: $0) }
            ?? UTType(filenameExtension: ext)
        // Neither the provider path nor bookmark appears in the synthetic URL.
        let suffix = ext.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) } ? ext : ""
        let url = URL(string: "antennapod-local://\(UUID().uuidString)/media" + (suffix.isEmpty ? "" : "." + suffix))!
        worker = Worker(document: document, url: url, contentType: type?.identifier, onFailure: onFailure)
        var options: [String: Any] = [:]
        if ext.isEmpty || ext.lowercased() == "media", let mime = document.context.mimeType,
           AVURLAsset.isPlayableExtendedMIMEType(mime) { options[AVURLAssetOverrideMIMETypeKey] = mime }
        asset = AVURLAsset(url: url, options: options)
        asset.resourceLoader.setDelegate(worker, queue: worker.queue)
    }
    deinit { worker.cancel() }
    func cancel() { worker.cancel() }
    func snapshot() async -> Snapshot { await worker.snapshot() }

    /// Foundation loading requests are touched only on this serial delegate
    /// queue. Async tasks carry just a reader/range and return value data here.
    private final class Worker: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
        let queue = DispatchQueue(label: "org.antennapod.local-playback.asset")
        let document: LocalPlaybackDocument
        let url: URL
        let contentType: String?
        let onFailure: @Sendable (Error) -> Void
        private struct Pending {
            let request: AVAssetResourceLoadingRequest
            let reader: LocalPlaybackDocument.Reader
            var task: Task<Void, Never>?
        }
        private var requests: [ObjectIdentifier: Pending] = [:]
        private var cancelled = false
        private var failure: Error?
        private var completedRequests = 0, cancelledRequests = 0, deliveredBytes = 0, largestRead = 0
        init(document: LocalPlaybackDocument, url: URL, contentType: String?, onFailure: @escaping @Sendable (Error) -> Void) {
            self.document = document; self.url = url; self.contentType = contentType; self.onFailure = onFailure
        }
        func snapshot() async -> Snapshot {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: Snapshot(pendingRequests: self.requests.count,
                    completedRequests: self.completedRequests, cancelledRequests: self.cancelledRequests,
                    deliveredBytes: self.deliveredBytes, largestRead: self.largestRead,
                    cancelled: self.cancelled, failure: self.failure?.localizedDescription)) }
            }
        }
        func cancel() {
            queue.async {
                guard !self.cancelled else { return }
                self.cancelled = true
                self.finishAll(error: CancellationError())
            }
        }
        func resourceLoader(_ loader: AVAssetResourceLoader,
                            shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
            dispatchPrecondition(condition: .onQueue(queue))
            if cancelled || failure != nil {
                request.finishLoading(with: failure ?? CancellationError()); return true
            }
            // A nested/redirected URL is a different document. Never answer it
            // with this item's bytes or escape to an unowned provider URL.
            guard request.request.url == url else {
                request.finishLoading(with: URLError(.unsupportedURL))
                fail(URLError(.unsupportedURL)); return true
            }
            let id = ObjectIdentifier(request)
            requests[id] = Pending(request: request, reader: document.makeReader())
            if let info = request.contentInformationRequest {
                info.contentType = contentType
                info.contentLength = document.length
                info.isByteRangeAccessSupported = true
                info.isEntireLengthAvailableOnDemand = true
            }
            pump(id)
            return true
        }
        func resourceLoader(_ loader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
            dispatchPrecondition(condition: .onQueue(queue))
            guard let pending = requests.removeValue(forKey: ObjectIdentifier(request)) else { return }
            cancelledRequests += 1; pending.reader.cancel(); pending.task?.cancel()
        }
        private func pump(_ id: ObjectIdentifier) {
            guard let pending = requests[id] else { return }
            guard let body = pending.request.dataRequest else { finish(id); return }
            guard body.requestedOffset >= 0, body.requestedLength >= 0, body.currentOffset >= body.requestedOffset,
                  Int64(body.requestedLength) <= Int64.max - body.requestedOffset else {
                fail(LocalPlaybackAccess.Failure.invalidRange); return
            }
            let end = body.requestsAllDataToEndOfResource ? document.length
                : min(document.length, body.requestedOffset + Int64(body.requestedLength))
            let offset = body.currentOffset
            guard offset < end else { finish(id); return }
            let count = Int(min(Int64(LocalPlaybackDocument.maximumReadCount), end - offset))
            largestRead = max(largestRead, count)
            let reader = pending.reader
            requests[id]?.task = Task { [weak self] in
                let result: Result<Data, any Error>
                do { result = .success(try await reader.read(at: offset, maximumCount: count)) }
                catch { result = .failure(error) }
                guard let self else { return }
                self.queue.async { self.received(result, id: id) }
            }
        }
        private func received(_ result: Result<Data, any Error>, id: ObjectIdentifier) {
            guard !cancelled, let pending = requests[id], !pending.request.isCancelled else { return }
            requests[id]?.task = nil
            do {
                let bytes = try result.get()
                guard !bytes.isEmpty else { throw MediaDownloadError.wrongSize(expected: document.length,
                    received: pending.request.dataRequest?.currentOffset ?? 0) }
                pending.request.dataRequest?.respond(with: bytes)
                deliveredBytes += bytes.count
                pump(id)
            } catch { fail(error) }
        }
        private func finish(_ id: ObjectIdentifier) {
            guard let pending = requests.removeValue(forKey: id) else { return }
            pending.reader.cancel(); pending.task?.cancel(); completedRequests += 1
            pending.request.finishLoading()
        }
        private func finishAll(error: Error) {
            let retired = requests; requests.removeAll()
            for pending in retired.values {
                pending.reader.cancel(); pending.task?.cancel()
                if !pending.request.isCancelled { pending.request.finishLoading(with: error) }
            }
        }
        private func fail(_ error: Error) {
            guard failure == nil, !cancelled else { return }
            failure = error; finishAll(error: error); onFailure(error)
        }
    }
}
