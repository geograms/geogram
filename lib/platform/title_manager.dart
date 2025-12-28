import 'title_manager_interface.dart';
import 'title_manager_stub.dart' if (dart.library.html) 'title_manager_web.dart';

TitleManager getTitleManager() => titleManager;
