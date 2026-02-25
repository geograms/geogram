import '../../services/app_args.dart';
import '../../services/log_service.dart';

void telegramDebug(String message) {
  if (!AppArgs().verbose) return;
  LogService().debug('Telegram: $message');
}

void telegramInfo(String message) {
  if (!AppArgs().verbose) return;
  LogService().info('Telegram: $message');
}

void telegramWarn(String message) {
  LogService().warn('Telegram: $message');
}

void telegramError(String message) {
  LogService().error('Telegram: $message');
}
