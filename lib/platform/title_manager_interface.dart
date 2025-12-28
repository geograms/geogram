abstract class TitleManager {
  Future<String> getTitle();
  Future<void> setTitle(String title);
  Future<bool> isFocused();
}
