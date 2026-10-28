/// The paid blocks this device is holding, kept on the device so a run that
/// is killed mid-session can be settled by the next one.
///
/// A block the app never hands back is kept whole by the server, unused part
/// and all: it cannot know when the app stopped. So while a block is held
/// the app notes it here with the last moment it was known to be streaming,
/// refreshed as it goes, and forgets it once the release has gone through.
/// Anything still here at launch was held by a run that died, and is handed
/// back with that moment as when it ended.
abstract class OpenBlockStore {
  /// Notes [blockId] as held and streaming as of [aliveAt].
  Future<void> remember(String blockId, DateTime aliveAt);

  /// The block was handed back; nothing more to settle.
  Future<void> forget(String blockId);

  /// Every block still noted, with the last moment it was known alive.
  Map<String, DateTime> all();
}
