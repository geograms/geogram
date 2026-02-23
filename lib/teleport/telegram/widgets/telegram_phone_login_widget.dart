/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Phone number + SMS code + optional 2FA password login widget.
 */

import 'package:flutter/material.dart';

import '../models/telegram_auth_state.dart';
import '../telegram_auth_service.dart';

class TelegramPhoneLoginWidget extends StatefulWidget {
  final TelegramAuthService authService;
  final TelegramAuthState authState;

  const TelegramPhoneLoginWidget({
    super.key,
    required this.authService,
    required this.authState,
  });

  @override
  State<TelegramPhoneLoginWidget> createState() =>
      _TelegramPhoneLoginWidgetState();
}

class _TelegramPhoneLoginWidgetState extends State<TelegramPhoneLoginWidget> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submitPhone() async {
    final phone = _phoneController.text.trim();
    if (phone.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.authService.setPhoneNumber(phone);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submitCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.authService.checkCode(code);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submitPassword() async {
    final password = _passwordController.text;
    if (password.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.authService.checkPassword(password);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_error != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _error!,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer),
              ),
            ),
            const SizedBox(height: 16),
          ],
          _buildCurrentStep(),
        ],
      ),
    );
  }

  Widget _buildCurrentStep() {
    switch (widget.authState) {
      case TelegramAuthState.waitingPhone:
        return _buildPhoneStep();
      case TelegramAuthState.waitingCode:
        return _buildCodeStep();
      case TelegramAuthState.waitingPassword:
        return _buildPasswordStep();
      default:
        return const Center(child: CircularProgressIndicator());
    }
  }

  Widget _buildPhoneStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Enter your phone number',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Include the country code (e.g. +1 for US)',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _phoneController,
          decoration: const InputDecoration(
            labelText: 'Phone number',
            hintText: '+1234567890',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.phone),
          ),
          keyboardType: TextInputType.phone,
          onSubmitted: (_) => _submitPhone(),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _loading ? null : _submitPhone,
            child: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Send Code'),
          ),
        ),
      ],
    );
  }

  Widget _buildCodeStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Enter verification code',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'A code was sent to your Telegram app or via SMS',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _codeController,
          decoration: const InputDecoration(
            labelText: 'Code',
            hintText: '12345',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.lock_outline),
          ),
          keyboardType: TextInputType.number,
          onSubmitted: (_) => _submitCode(),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _loading ? null : _submitCode,
            child: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Verify'),
          ),
        ),
      ],
    );
  }

  Widget _buildPasswordStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Two-factor authentication',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Your account has 2FA enabled. Enter your password.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _passwordController,
          decoration: const InputDecoration(
            labelText: 'Password',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.password),
          ),
          obscureText: true,
          onSubmitted: (_) => _submitPassword(),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _loading ? null : _submitPassword,
            child: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Submit'),
          ),
        ),
      ],
    );
  }
}
