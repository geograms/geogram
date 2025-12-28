import 'dart:html' as html;
import 'title_manager_interface.dart';

final TitleManager titleManager = WebTitleManager();

class WebTitleManager implements TitleManager {
  @override
  Future<String> getTitle() async {
    return html.document.title;
  }

  @override
  Future<void> setTitle(String title) async {
    html.document.title = title;
  }

  @override
  Future<bool> isFocused() async {
    return html.document.hasFocus();
  }
}
