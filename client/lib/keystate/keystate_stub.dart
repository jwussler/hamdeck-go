/// Key state where the platform cannot answer.
///
/// ⚠️ NULL IS NOT "THE KEY IS UP". The caller offers press-to-toggle here and
/// says so, rather than offering a hold whose release can never arrive.
class KeyState {
  KeyState._();
  static final KeyState instance = KeyState._();
  bool knows(String keyName) => false;
  bool get available => false;
  bool? isDown(String keyName) => null;
}
