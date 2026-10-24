// Matroska and WebM files for Swift: the video track's format description and
// compressed samples, and the audio track decoded to PCM, both as Core Media
// sample buffers a player can enqueue. Built on the project's own Matroska reader
// (Renderer/Media), the Apple adapter beside it (the format description, VP9's
// supplemental decoder, the AV1 hardware gate) and the sound decoders
// (Renderer/Sound); nothing here decodes video or plays sound. The desktop player
// and the lock-screen extension both read files through it.
//
// A file is opened once and is then immutable. Readers are cheap cursors over
// it: each one keeps its own position and is for one thread at a time.
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const WMWebMErrorDomain;
/// For an unsupported format: the format as a person names it ("VP8", "AV1", "H.264").
FOUNDATION_EXPORT NSErrorUserInfoKey const WMWebMFormatNameKey;

typedef NS_ERROR_ENUM(WMWebMErrorDomain, WMWebMErrorCode) {
  /// The bytes are not Matroska or WebM.
  WMWebMErrorNotMatroska = 1,
  /// A valid file whose video this Mac or this player does not play: VP8, AV1 without
  /// hardware decoding, 4:4:4 chroma, an encrypted track. The error's message begins
  /// with "format not supported" or says what the file uses; `WMWebMFormatNameKey` names the codec.
  WMWebMErrorUnsupportedFormat = 2,
  /// The file is cut off or damaged beyond what the reader tolerates.
  WMWebMErrorDamaged = 3,
  /// The file could not be read at all.
  WMWebMErrorUnreadable = 4,
};

@class WMWebMVideoReader;
@class WMWebMAudioReader;

NS_SWIFT_NAME(WebMFile)
@interface WMWebMFile : NSObject

/// Opens and indexes the file at `url`. Reads headers and block headers only.
+ (nullable instancetype)openAtURL:(NSURL *)url error:(NSError **)error;
/// The same for bytes in memory (tests).
+ (nullable instancetype)openWithData:(NSData *)data error:(NSError **)error;

/// "WebM" or "Matroska", from the file's DocType.
@property (nonatomic, readonly, copy) NSString *containerName;
/// "VP9", "H.264", "HEVC" or "AV1".
@property (nonatomic, readonly, copy) NSString *videoCodecName;
/// What to hand a decoder: the codec's configuration and colour description. VP9's
/// `vpcC` is made from the first key frame, which WebM does not carry.
@property (nonatomic, readonly) CMVideoFormatDescriptionRef videoFormatDescription CF_RETURNS_NOT_RETAINED;
/// The coded picture's size in pixels.
@property (nonatomic, readonly) CGSize codedSize;
/// The size the picture is shown at: the file's display size or pixel aspect applied, then
/// the quarter turn the orientation asks for.
@property (nonatomic, readonly) CGSize presentationSize;
/// The orientation the file asks for, as a transform of the picture drawn at its stored
/// shape (`presentationSize` with its axes exchanged for a quarter turn).
@property (nonatomic, readonly) CGAffineTransform preferredTransform;
/// The same orientation as a transform for a Core Animation layer in a parent whose y axis
/// grows upward, applied about the layer's centre: give the layer the stored shape's bounds
/// (`presentationSize` with its axes exchanged when `transformSwapsAxes`) and this transform.
@property (nonatomic, readonly) CGAffineTransform layerTransform;
/// Whether `preferredTransform` exchanges the picture's width and height.
@property (nonatomic, readonly) BOOL transformSwapsAxes;
/// Bits per luma sample: 8, or 10.
@property (nonatomic, readonly) NSInteger bitDepth;
/// The presentation time of the earliest frame.
@property (nonatomic, readonly) CMTime firstPresentationTime;
/// How long one pass plays: from the earliest frame's time to the end of the last frame.
@property (nonatomic, readonly) CMTime duration;
@property (nonatomic, readonly) NSInteger frameCount;
/// Frames per second from the shortest gap between frames, or 0 when the file has one frame.
@property (nonatomic, readonly) double nominalFrameRate;
/// Human-readable oddities the reader tolerated (a cut-off tail), for the log.
@property (nonatomic, readonly, copy) NSArray<NSString *> *warnings;

/// Whether the file has an audio track this reader can decode: the codec is Opus, Vorbis,
/// AAC or MP3, and Opus is mono or stereo. `audioCodecName` is "Opus", "Vorbis", "AAC" or
/// "MP3" for any audio track the file has, decodable or not.
@property (nonatomic, readonly) BOOL hasPlayableAudio;
@property (nonatomic, readonly, nullable, copy) NSString *audioCodecName;
/// Why the audio is not played, when the file has an audio track that is not decodable.
@property (nonatomic, readonly, nullable, copy) NSString *audioUnavailableReason;

/// A new cursor, positioned at the first key frame.
- (WMWebMVideoReader *)makeVideoReader;
/// A new cursor over the audio, decoded to 32-bit float PCM, positioned at its start;
/// nil with `error` set when the track cannot be decoded (see `audioUnavailableReason`).
- (nullable WMWebMAudioReader *)makeAudioReaderWithError:(NSError **)error;

/// The picture at or before `time`, from the key frame there alone: decoded once, drawn
/// upright. For a poster, not for playback. nil when it cannot be decoded.
- (nullable CGImageRef)copyPosterImageAtTime:(CMTime)time CF_RETURNS_RETAINED;

@end

/// The video track's compressed samples in decode order, as sample buffers whose
/// timing is the file's (nanoseconds) plus `timeOffset`.
NS_SWIFT_NAME(WebMVideoReader)
@interface WMWebMVideoReader : NSObject

/// Added to every sample's presentation and decode time. A looping player raises it by
/// the file's duration at each wrap so time keeps increasing.
@property (nonatomic) CMTime timeOffset;
/// True once the last sample has been returned.
@property (nonatomic, readonly) BOOL atEnd;
/// Set when a sample could not be read: `copyNextSampleBuffer` then returns nil with this error,
/// and `atEnd` stays false.
@property (nonatomic, readonly, nullable) NSError *error;

/// Positions the cursor at the key frame at or before `time` (the first key frame for an
/// earlier time) and returns that frame's presentation time, without `timeOffset`.
- (CMTime)seekToTime:(CMTime)time;
/// The next sample, or nil at the end of the file (`atEnd`) or on an error (`error`).
/// A frame that is not a key frame carries the not-sync attachment; one the container marks
/// invisible carries do-not-display.
- (nullable CMSampleBufferRef)copyNextSampleBuffer CF_RETURNS_RETAINED;

@end

/// The audio track decoded to float PCM, as sample buffers of about a tenth of a second.
NS_SWIFT_NAME(WebMAudioReader)
@interface WMWebMAudioReader : NSObject

@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) NSInteger channelCount;
@property (nonatomic, readonly) CMAudioFormatDescriptionRef formatDescription CF_RETURNS_NOT_RETAINED;
/// Where the audio starts on the file's timeline, before `timeOffset`.
@property (nonatomic, readonly) CMTime startTime;
/// Added to every buffer's presentation time.
@property (nonatomic, readonly) CMTime timeOffset;
@property (nonatomic, readonly) BOOL atEnd;
@property (nonatomic, readonly, nullable) NSError *error;

/// Starts the sound again from its first frame; every buffer after it is `offset` later than
/// the file's own timeline. At most `limit` of audio is returned before `atEnd` (pass an invalid
/// time for no limit): a looping player gives the video's duration, so audio longer than the
/// picture is cut where the picture wraps.
- (void)rewindWithTimeOffset:(CMTime)offset limit:(CMTime)limit;
- (nullable CMSampleBufferRef)copyNextSampleBuffer CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
