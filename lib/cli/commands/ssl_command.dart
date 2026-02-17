/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * SSL command: domain, email, request, test, renew, autorenew, selfsigned, enable, disable
 */

import '../../station.dart' show PureRelaySettings, SslCertificateManager;
import 'command.dart';
import 'command_context.dart';
import 'service_interfaces.dart';

/// ssl — manage SSL/TLS certificates
class SslCommand extends Command {
  @override String get name => 'ssl';
  @override String get description => 'Manage SSL certificates (domain|email|request|test|renew|autorenew|selfsigned|enable|disable)';
  @override String get usage => 'ssl <subcommand>';
  @override CommandCategory get category => CommandCategory.ssl;
  @override bool get requiresStation => true;
  @override List<String> get contextPaths => const ['/ssl'];

  @override
  List<SubCommand> get subcommands => [
    SubCommand(
      name: 'domain',
      description: 'Get/set domain for certificate',
      execute: _domain,
    ),
    SubCommand(
      name: 'email',
      description: 'Get/set email for Let\'s Encrypt',
      execute: _email,
    ),
    SubCommand(
      name: 'request',
      description: 'Request production certificate',
      execute: _request,
    ),
    SubCommand(
      name: 'test',
      description: 'Request test certificate (staging)',
      execute: _test,
    ),
    SubCommand(
      name: 'renew',
      description: 'Force certificate renewal',
      execute: _renew,
    ),
    SubCommand(
      name: 'autorenew',
      description: 'Enable/disable auto-renewal',
      execute: _autorenew,
      completer: (_) => ['on', 'off'],
    ),
    SubCommand(
      name: 'selfsigned',
      description: 'Generate self-signed certificate',
      execute: _selfsigned,
    ),
    SubCommand(
      name: 'enable',
      description: 'Enable SSL/HTTPS',
      execute: _enable,
    ),
    SubCommand(
      name: 'disable',
      description: 'Disable SSL/HTTPS',
      execute: _disable,
    ),
  ];

  @override
  Future<void> execute(CommandContext ctx) async {
    // No sub-command — show SSL status
    await _showSslStatus(ctx);
  }

  static Future<void> _showSslStatus(CommandContext ctx) async {
    final sslManager = ctx.sslManager as SslCertificateManager?;
    if (sslManager == null) {
      ctx.error('SSL manager not initialized');
      return;
    }

    final status = await sslManager.getStatus();

    ctx.writeln();
    ctx.bold('SSL/TLS Certificate Status');
    ctx.writeln('-' * 40);
    ctx.writeln('Domain:         ${status['domain']}');
    ctx.writeln('Email:          ${status['email']}');
    ctx.writeln('SSL Enabled:    ${status['enabled'] == true ? '\x1B[32mYes\x1B[0m' : '\x1B[33mNo\x1B[0m'}');
    ctx.writeln('Auto-Renew:     ${status['autoRenew'] == true ? '\x1B[32mEnabled\x1B[0m' : '\x1B[33mDisabled\x1B[0m'}');
    ctx.writeln('Certificate:    ${status['hasCertificate'] == true ? '\x1B[32mInstalled\x1B[0m' : '\x1B[33mNot installed\x1B[0m'}');

    if (status['hasCertificate'] == true) {
      if (status['expiresAt'] != null) {
        ctx.writeln('Expires:        ${status['expiresAt']}');
        ctx.writeln('Days Left:      ${status['daysUntilExpiry']}');
      }
      if (status['certPath'] != null) {
        ctx.writeln('Cert Path:      ${status['certPath']}');
      }
    }

    ctx.writeln();
    ctx.section('SSL Commands:');
    ctx.writeln('  ssl domain <domain>      Set domain for certificate');
    ctx.writeln('  ssl email <email>        Set email for Let\'s Encrypt');
    ctx.writeln('  ssl request              Request production certificate');
    ctx.writeln('  ssl test                 Request test certificate (staging)');
    ctx.writeln('  ssl renew                Force certificate renewal');
    ctx.writeln('  ssl autorenew <on|off>   Enable/disable auto-renewal');
    ctx.writeln('  ssl selfsigned [domain]  Generate self-signed certificate');
    ctx.writeln('  ssl enable               Enable SSL/HTTPS');
    ctx.writeln('  ssl disable              Disable SSL/HTTPS');
    ctx.writeln();
  }

  static Future<void> _domain(CommandContext ctx) async {
    final station = ctx.station as StationCommandInterface;

    if (ctx.args.isEmpty) {
      ctx.writeln('Current domain: ${station.settings.sslDomain ?? '(not set)'}');
      return;
    }

    final domain = ctx.args[0];
    station.setSetting('sslDomain', domain);
    final sslManager = ctx.sslManager as SslCertificateManager?;
    sslManager?.updateSettings(station.settings as PureRelaySettings);
    ctx.success('SSL domain set to: $domain');
  }

  static Future<void> _email(CommandContext ctx) async {
    final station = ctx.station as StationCommandInterface;

    if (ctx.args.isEmpty) {
      ctx.writeln('Current email: ${station.settings.sslEmail ?? '(not set)'}');
      return;
    }

    final email = ctx.args[0];
    if (!email.contains('@')) {
      ctx.error('Invalid email address');
      return;
    }

    station.setSetting('sslEmail', email);
    final sslManager = ctx.sslManager as SslCertificateManager?;
    sslManager?.updateSettings(station.settings as PureRelaySettings);
    ctx.success('SSL email set to: $email');
  }

  static Future<void> _request(CommandContext ctx) async {
    await _requestCertificate(ctx, staging: false);
  }

  static Future<void> _test(CommandContext ctx) async {
    await _requestCertificate(ctx, staging: true);
  }

  static Future<void> _requestCertificate(CommandContext ctx, {required bool staging}) async {
    final station = ctx.station as StationCommandInterface;
    final sslManager = ctx.sslManager as SslCertificateManager?;
    if (sslManager == null) {
      ctx.error('SSL manager not initialized');
      return;
    }

    final envType = staging ? 'staging (test)' : 'production';
    ctx.writeln('Requesting $envType certificate...');
    ctx.writeln('Domain: ${station.settings.sslDomain}');
    ctx.writeln('Email:  ${station.settings.sslEmail}');
    ctx.writeln();

    try {
      final success = await sslManager.requestCertificate(staging: staging);
      if (success) {
        ctx.success('Certificate request successful!');
        ctx.writeln();
        ctx.writeln('To enable HTTPS, run: ssl enable');
        ctx.writeln('Then restart the station: restart');
      }
    } catch (e) {
      ctx.error('Certificate request failed: $e');
    }
  }

  static Future<void> _renew(CommandContext ctx) async {
    final sslManager = ctx.sslManager as SslCertificateManager?;
    if (sslManager == null) {
      ctx.error('SSL manager not initialized');
      return;
    }

    ctx.writeln('Renewing certificate...');

    try {
      final success = await sslManager.renewCertificate(staging: false);
      if (success) {
        ctx.success('Certificate renewed successfully!');
      }
    } catch (e) {
      ctx.error('Certificate renewal failed: $e');
    }
  }

  static Future<void> _autorenew(CommandContext ctx) async {
    final station = ctx.station as StationCommandInterface;
    final sslManager = ctx.sslManager as SslCertificateManager?;

    if (ctx.args.isEmpty) {
      final current = station.settings.sslAutoRenew ? 'on' : 'off';
      ctx.writeln('Auto-renewal is currently: $current');
      return;
    }

    final value = ctx.args[0].toLowerCase();
    final enabled = value == 'on' || value == 'true' || value == '1';

    station.setSetting('sslAutoRenew', enabled);
    sslManager?.updateSettings(station.settings as PureRelaySettings);

    if (enabled) {
      sslManager?.startAutoRenewal();
      ctx.success('Auto-renewal enabled');
    } else {
      sslManager?.stop();
      ctx.writeln('\x1B[33mAuto-renewal disabled\x1B[0m');
    }
  }

  static Future<void> _selfsigned(CommandContext ctx) async {
    final station = ctx.station as StationCommandInterface;
    final sslManager = ctx.sslManager as SslCertificateManager?;
    if (sslManager == null) {
      ctx.error('SSL manager not initialized');
      return;
    }

    final domain = ctx.args.isNotEmpty ? ctx.args[0] : (station.settings.sslDomain ?? 'localhost');

    ctx.writeln('Generating self-signed certificate for: $domain');

    try {
      final success = await sslManager.generateSelfSigned(domain);
      if (success) {
        ctx.success('Self-signed certificate generated!');
        ctx.writeln('\x1B[33mWarning: Self-signed certificates are not trusted by browsers.\x1B[0m');
        ctx.writeln();
        ctx.writeln('To enable HTTPS, run: ssl enable');
        ctx.writeln('Then restart the station: restart');
      }
    } catch (e) {
      ctx.error('Failed to generate self-signed certificate: $e');
    }
  }

  static Future<void> _enable(CommandContext ctx) async {
    await _toggleSsl(ctx, enable: true);
  }

  static Future<void> _disable(CommandContext ctx) async {
    await _toggleSsl(ctx, enable: false);
  }

  static Future<void> _toggleSsl(CommandContext ctx, {required bool enable}) async {
    final station = ctx.station as StationCommandInterface;
    final sslManager = ctx.sslManager as SslCertificateManager?;
    if (sslManager == null) {
      ctx.error('SSL manager not initialized');
      return;
    }

    if (enable && !sslManager.hasCertificate()) {
      ctx.error('No certificate installed. Run "ssl request" or "ssl selfsigned" first.');
      return;
    }

    station.setSetting('enableSsl', enable);
    station.setSetting('sslCertPath', enable ? sslManager.certPath : null);
    station.setSetting('sslKeyPath', enable ? sslManager.domainKeyPath : null);
    sslManager.updateSettings(station.settings as PureRelaySettings);

    if (enable) {
      ctx.success('SSL/HTTPS enabled');
      ctx.writeln('HTTPS will be available on port ${station.settings.httpsPort} after restart');
    } else {
      ctx.writeln('\x1B[33mSSL/HTTPS disabled\x1B[0m');
    }
    ctx.writeln('Restart the station for changes to take effect: restart');
  }
}
