import AVFoundation
import Foundation

/// Maps AVFoundation errors to platform-independent playback errors.
enum PlaybackErrorMapper {
  static func map(_ error: Error?, sourceId: String) -> PlaybackErrorMessage {
    guard let nsError = error as NSError? else {
      return PlaybackErrorMessage(
        code: "playback_failed",
        message: "Playback failed for source \(sourceId).",
        isRecoverable: false,
        platformCode: nil
      )
    }

    let platformCode = "\(nsError.domain):\(nsError.code)"
    let classified = classify(nsError)
    return PlaybackErrorMessage(
      code: classified.code,
      message: nsError.localizedDescription,
      isRecoverable: classified.isRecoverable,
      platformCode: platformCode
    )
  }

  static func unknown(message: String) -> PlaybackErrorMessage {
    PlaybackErrorMessage(
      code: "playback_failed",
      message: message,
      isRecoverable: false,
      platformCode: nil
    )
  }

  private static func classify(_ error: NSError) -> (code: String, isRecoverable: Bool) {
    if error.domain == NSURLErrorDomain {
      switch error.code {
      case NSURLErrorNotConnectedToInternet,
        NSURLErrorTimedOut,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorDNSLookupFailed:
        return ("network_failed", true)
      case NSURLErrorFileDoesNotExist, NSURLErrorBadURL, NSURLErrorUnsupportedURL:
        return ("source_not_found", false)
      default:
        return ("network_failed", true)
      }
    }

    if error.domain == AVFoundationErrorDomain {
      switch error.code {
      case AVError.fileFormatNotRecognized.rawValue,
        AVError.failedToParse.rawValue,
        AVError.undecodableMediaData.rawValue:
        return ("media_malformed", false)
      case AVError.decoderNotFound.rawValue,
        AVError.decodeFailed.rawValue:
        return ("decoder_failed", false)
      case AVError.noLongerPlayable.rawValue,
        AVError.mediaServicesWereReset.rawValue:
        return ("playback_failed", true)
      default:
        return ("playback_failed", false)
      }
    }

    return ("playback_failed", false)
  }
}
