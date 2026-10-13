import Foundation

/// The MP3 producer and source report a second concurrent read with this error. It
/// keeps its original type path and case order, so bridged error text is unchanged;
/// the push-model input that first declared it was superseded by NativeMP3PlaybackSource.
enum NativeMP3ProcessingInput {
    enum Failure: Error, Equatable { case cancelled, concurrentRead, concurrentInput, finished }
}
