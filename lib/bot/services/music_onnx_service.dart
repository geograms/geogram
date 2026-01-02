/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path/path.dart' as path;
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../../services/log_service.dart';

class MusicOnnxAudio {
  final Float32List samples;
  final int sampleRate;

  const MusicOnnxAudio({
    required this.samples,
    required this.sampleRate,
  });
}

class MusicOnnxService {
  static final MusicOnnxService _instance = MusicOnnxService._internal();
  factory MusicOnnxService() => _instance;
  MusicOnnxService._internal();

  final OnnxRuntime _ort = OnnxRuntime();
  OrtSession? _textEncoder;
  OrtSession? _decoder;
  OrtSession? _decoderWithPast;
  OrtSession? _encodec;
  MusicGenTokenizer? _tokenizer;
  MusicGenConfig? _config;
  String? _modelDir;
  Future<void>? _initFuture;

  bool get isInitialized => _modelDir != null && _config != null;

  Future<void> initialize(String modelDir) async {
    if (_modelDir == modelDir && _config != null) return;
    if (_initFuture != null) return _initFuture;

    _initFuture = _initializeInternal(modelDir);
    try {
      await _initFuture;
    } finally {
      _initFuture = null;
    }
  }

  Future<void> _initializeInternal(String modelDir) async {
    await dispose();
    _modelDir = modelDir;

    final configPath = path.join(modelDir, 'config.json');
    final generationConfigPath = path.join(modelDir, 'generation_config.json');
    final preprocessorPath = path.join(modelDir, 'preprocessor_config.json');

    final configJson = jsonDecode(await File(configPath).readAsString())
        as Map<String, dynamic>;
    final generationJson = jsonDecode(
            await File(generationConfigPath).readAsString())
        as Map<String, dynamic>;
    final preprocessorJson = jsonDecode(await File(preprocessorPath).readAsString())
        as Map<String, dynamic>;

    _config = MusicGenConfig.fromJson(
      configJson: configJson,
      generationJson: generationJson,
      preprocessorJson: preprocessorJson,
    );

    _tokenizer = await MusicGenTokenizer.load(modelDir);

    final textEncoderPath = _resolveFile(modelDir, const [
      'onnx/text_encoder.onnx',
      'onnx/text_encoder_quantized.onnx',
    ]);
    final decoderPath = _resolveFile(modelDir, const [
      'onnx/decoder_model.onnx',
      'onnx/decoder_model_quantized.onnx',
    ]);
    final decoderWithPastPath = _resolveFile(modelDir, const [
      'onnx/decoder_with_past_model.onnx',
      'onnx/decoder_with_past_model_quantized.onnx',
    ]);
    final encodecPath = _resolveFile(modelDir, const [
      'onnx/encodec_decode.onnx',
      'onnx/encodec_decode_quantized.onnx',
    ]);

    _textEncoder = await _ort.createSession(textEncoderPath);
    _decoder = await _ort.createSession(decoderPath);
    _decoderWithPast = await _ort.createSession(decoderWithPastPath);
    _encodec = await _ort.createSession(encodecPath);

    LogService().log('MusicOnnxService: Initialized with $modelDir');
  }

  String _resolveFile(String modelDir, List<String> candidates) {
    for (final candidate in candidates) {
      final fullPath = path.join(modelDir, candidate);
      if (File(fullPath).existsSync()) {
        return fullPath;
      }
    }
    throw StateError('Missing model file. Tried: ${candidates.join(', ')}');
  }

  Future<MusicOnnxAudio> generateAudio({
    required String prompt,
    required Duration duration,
    void Function(double progress)? onProgress,
  }) async {
    if (_modelDir == null || _config == null || _tokenizer == null) {
      throw StateError('MusicOnnxService is not initialized');
    }

    final config = _config!;
    final tokenizer = _tokenizer!;

    final tokenIds = tokenizer.encode(prompt);
    final attentionMask = Int64List(tokenIds.length);
    for (var i = 0; i < attentionMask.length; i++) {
      attentionMask[i] = 1;
    }

    final inputIdsTensor = await OrtValue.fromList(
      Int64List.fromList(tokenIds),
      [1, tokenIds.length],
    );
    final attentionTensor = await OrtValue.fromList(
      attentionMask,
      [1, tokenIds.length],
    );

    OrtValue? encoderHidden;
    OrtValue? encoderAttention;
    Map<String, OrtValue>? pastDecoder;
    Map<String, OrtValue>? pastEncoder;
    try {
      encoderAttention = attentionTensor;
      Map<String, OrtValue> encoderOutputs;
      try {
        encoderOutputs = await _textEncoder!.run({
          'input_ids': inputIdsTensor,
          'attention_mask': attentionTensor,
        });
      } finally {
        await inputIdsTensor.dispose();
      }
      encoderHidden = encoderOutputs['last_hidden_state'];
      for (final entry in encoderOutputs.entries) {
        if (entry.key != 'last_hidden_state') {
          await entry.value.dispose();
        }
      }

      if (encoderHidden == null) {
        await _disposeOutputs(encoderOutputs);
        throw StateError('Text encoder did not return last_hidden_state');
      }

      final targetLength = max(
        1,
        (duration.inMilliseconds / 1000 * config.tokensPerSecond).round(),
      );
      final maxLength = min(config.maxLength, targetLength);

      final startIds = List<List<int>>.generate(
        config.numCodebooks,
        (_) => [config.decoderStartTokenId],
      );

      final delay = _buildDelayPatternMask(
        startIds,
        config.padTokenId,
        maxLength,
        config.numCodebooks,
        config.audioChannels,
      );

      final generated = delay.inputIds
          .map((row) => List<int>.from(row))
          .toList();
      final patternMask = delay.patternMask;

      var currentLength = generated[0].length;
      final totalSteps = maxLength;
      final updateEvery = max(1, (totalSteps / 100).round());

      while (currentLength < totalSteps) {
        final bool isFirst = pastDecoder == null;
        final OrtSession session = isFirst ? _decoder! : _decoderWithPast!;

        final List<int> flatInput;
        final List<int> inputShape;
        if (isFirst) {
          flatInput = _flatten2d(generated);
          inputShape = [generated.length, currentLength];
        } else {
          flatInput = generated.map((row) => row.last).toList();
          inputShape = [generated.length, 1];
        }

        final inputTensor = await OrtValue.fromList(
          Int64List.fromList(flatInput),
          inputShape,
        );

        final inputs = <String, OrtValue>{
          'input_ids': inputTensor,
          'encoder_attention_mask': encoderAttention!,
        };
        if (isFirst) {
          inputs['encoder_hidden_states'] = encoderHidden;
        } else {
          inputs.addAll(pastDecoder!);
          inputs.addAll(pastEncoder!);
        }

        final outputs = await session.run(inputs);
        await inputTensor.dispose();

        final logits = outputs['logits'];
        if (logits == null) {
          await _disposeOutputs(outputs);
          throw StateError('Decoder did not return logits');
        }

        final newPastDecoder = _extractPast(outputs, 'decoder');
        if (isFirst) {
          pastEncoder = _extractPast(outputs, 'encoder');
        }
        await _disposePast(pastDecoder);
        pastDecoder = newPastDecoder;

        final vocabSize = config.vocabSize;
        final lastLogits = await _extractLastLogits(
          logits,
          generated.length,
          isFirst ? currentLength : 1,
          vocabSize,
        );
        await logits.dispose();

        for (var i = 0; i < generated.length; i++) {
          final maskValue = patternMask[i][currentLength];
          final nextToken = maskValue != -1
              ? maskValue
              : _sampleFromLogits(
                  lastLogits[i],
                  topK: config.topK,
                  temperature: config.temperature,
                );
          generated[i].add(nextToken);
        }

        currentLength++;
        if (onProgress != null && currentLength % updateEvery == 0) {
          onProgress(currentLength / totalSteps);
        }
      }

      onProgress?.call(1.0);

      final outputIds = _applyDelayPatternMask(generated, patternMask);
      final filteredRows = _filterPadTokens(outputIds, config.padTokenId);
      if (filteredRows.isEmpty || filteredRows.first.isEmpty) {
        throw StateError('Generated audio codes are empty');
      }

      final frameCount = filteredRows.first.length;
      for (final row in filteredRows) {
        if (row.length != frameCount) {
          throw StateError('Inconsistent audio code lengths');
        }
      }

      final audioCodes = Int64List(frameCount * config.numCodebooks);
      var offset = 0;
      for (var c = 0; c < config.numCodebooks; c++) {
        for (var t = 0; t < frameCount; t++) {
          audioCodes[offset++] = filteredRows[c][t];
        }
      }

      final audioTensor = await OrtValue.fromList(
        audioCodes,
        [1, 1, config.numCodebooks, frameCount],
      );
      final audioOutputs = await _encodec!.run({
        'audio_codes': audioTensor,
      });
      await audioTensor.dispose();

      final audioValues = audioOutputs['audio_values'];
      if (audioValues == null) {
        await _disposeOutputs(audioOutputs);
        throw StateError('EnCodec decode did not return audio_values');
      }

      final audioList = await audioValues.asFlattenedList();
      for (final entry in audioOutputs.entries) {
        if (entry.key != 'audio_values') {
          await entry.value.dispose();
        }
      }
      await audioValues.dispose();

      final samples = Float32List.fromList(
        audioList.map((e) => (e as num).toDouble()).toList(),
      );

      _normalizeInPlace(samples);
      return MusicOnnxAudio(samples: samples, sampleRate: config.sampleRate);
    } finally {
      await _disposePast(pastDecoder);
      await _disposePast(pastEncoder);
      await encoderHidden?.dispose();
      await encoderAttention?.dispose();
    }
  }

  List<int> _flatten2d(List<List<int>> values) {
    final result = <int>[];
    for (final row in values) {
      result.addAll(row);
    }
    return result;
  }

  Future<List<Float32List>> _extractLastLogits(
    OrtValue logits,
    int batch,
    int seqLen,
    int vocabSize,
  ) async {
    final data = await logits.asFlattenedList();
    final list = Float32List.fromList(
      data.map((e) => (e as num).toDouble()).toList(),
    );

    final results = List<Float32List>.generate(
      batch,
      (_) => Float32List(vocabSize),
    );

    for (var b = 0; b < batch; b++) {
      final offset = ((b * seqLen) + (seqLen - 1)) * vocabSize;
      results[b].setAll(0, list.sublist(offset, offset + vocabSize));
    }

    return results;
  }

  Map<String, OrtValue> _extractPast(
    Map<String, OrtValue> outputs,
    String type,
  ) {
    final past = <String, OrtValue>{};
    final prefix = 'present.';
    final marker = '.$type.';

    for (final entry in outputs.entries) {
      if (entry.key.startsWith(prefix) && entry.key.contains(marker)) {
        final inputName = entry.key.replaceFirst('present.', 'past_key_values.');
        past[inputName] = entry.value;
      }
    }

    return past;
  }

  Future<void> _disposePast(Map<String, OrtValue>? past) async {
    if (past == null) return;
    for (final value in past.values) {
      await value.dispose();
    }
  }

  Future<void> _disposeOutputs(Map<String, OrtValue> outputs) async {
    for (final value in outputs.values) {
      await value.dispose();
    }
  }

  int _sampleFromLogits(
    Float32List logits, {
    required int topK,
    required double temperature,
  }) {
    final temp = temperature <= 0 ? 1.0 : temperature;
    final adjusted = Float32List(logits.length);
    for (var i = 0; i < logits.length; i++) {
      adjusted[i] = logits[i] / temp;
    }

    final indices = List<int>.generate(adjusted.length, (i) => i);
    indices.sort((a, b) => adjusted[b].compareTo(adjusted[a]));
    final k = min(topK, indices.length);

    final topIndices = indices.sublist(0, k);
    var maxLogit = adjusted[topIndices.first];
    for (final idx in topIndices) {
      if (adjusted[idx] > maxLogit) {
        maxLogit = adjusted[idx];
      }
    }

    final expScores = List<double>.filled(k, 0.0);
    var sum = 0.0;
    for (var i = 0; i < k; i++) {
      final value = exp(adjusted[topIndices[i]] - maxLogit);
      expScores[i] = value;
      sum += value;
    }

    final target = _random.nextDouble() * sum;
    var cumulative = 0.0;
    for (var i = 0; i < k; i++) {
      cumulative += expScores[i];
      if (target <= cumulative) {
        return topIndices[i];
      }
    }

    return topIndices.last;
  }

  void _normalizeInPlace(Float32List samples) {
    var maxValue = 0.0;
    for (final value in samples) {
      final absValue = value.abs();
      if (absValue > maxValue) {
        maxValue = absValue;
      }
    }

    if (maxValue <= 1.0e-6) return;
    final scale = 1.0 / maxValue;
    for (var i = 0; i < samples.length; i++) {
      samples[i] = (samples[i] * scale).clamp(-1.0, 1.0);
    }
  }

  _DelayPatternResult _buildDelayPatternMask(
    List<List<int>> inputIds,
    int padTokenId,
    int maxLength,
    int numCodebooks,
    int audioChannels,
  ) {
    final batchSize = inputIds.length ~/ numCodebooks;
    final seqLen = inputIds.first.length;

    final reshaped = List.generate(
      batchSize,
      (b) => List.generate(
        numCodebooks,
        (c) => List<int>.from(inputIds[b * numCodebooks + c]),
      ),
    );

    final inputIdsShifted = List.generate(
      batchSize,
      (_) => List.generate(
        numCodebooks,
        (_) => List<int>.filled(maxLength, -1),
      ),
    );

    final channelCodebooks = audioChannels == 2
        ? (numCodebooks ~/ 2)
        : numCodebooks;

    if (maxLength < 2 * channelCodebooks - 1) {
      return _DelayPatternResult(
        inputIds,
        inputIdsShifted.expand((b) => b).toList(),
      );
    }

    for (var codebook = 0; codebook < channelCodebooks; codebook++) {
      for (var b = 0; b < batchSize; b++) {
        if (audioChannels == 1) {
          for (var t = 0; t < seqLen; t++) {
            final targetIndex = codebook + t;
            if (targetIndex < maxLength) {
              inputIdsShifted[b][codebook][targetIndex] = reshaped[b][codebook][t];
            }
          }
        } else {
          for (var t = 0; t < seqLen; t++) {
            final targetIndex = codebook + t;
            if (targetIndex < maxLength) {
              inputIdsShifted[b][2 * codebook][targetIndex] =
                  reshaped[b][2 * codebook][t];
              inputIdsShifted[b][2 * codebook + 1][targetIndex] =
                  reshaped[b][2 * codebook + 1][t];
            }
          }
        }
      }
    }

    final delayPattern = List.generate(
      channelCodebooks,
      (row) => List<bool>.filled(maxLength, false),
    );

    final upperDiagonal = maxLength - channelCodebooks + 1;
    for (var row = 0; row < channelCodebooks; row++) {
      for (var col = 0; col < maxLength; col++) {
        final upper = col >= upperDiagonal + row;
        final lower = col <= row;
        delayPattern[row][col] = upper || lower;
      }
    }

    List<List<bool>> expandedPattern;
    if (audioChannels == 2) {
      expandedPattern = [];
      for (var row = 0; row < delayPattern.length; row++) {
        expandedPattern.add(delayPattern[row]);
        expandedPattern.add(delayPattern[row]);
      }
    } else {
      expandedPattern = delayPattern;
    }

    final masked = List.generate(
      batchSize,
      (b) => List.generate(
        numCodebooks,
        (c) => List<int>.filled(maxLength, padTokenId),
      ),
    );

    for (var b = 0; b < batchSize; b++) {
      for (var c = 0; c < numCodebooks; c++) {
        for (var t = 0; t < maxLength; t++) {
          final allowed = !expandedPattern[c][t];
          final value = inputIdsShifted[b][c][t];
          masked[b][c][t] = allowed ? value : padTokenId;
        }
      }
    }

    final firstCodebook = masked[0][0];
    var firstStartId = seqLen;
    for (var i = 0; i < firstCodebook.length; i++) {
      if (firstCodebook[i] == -1) {
        firstStartId = i;
        break;
      }
    }

    final patternMask = masked
        .expand((b) => b)
        .map((row) => List<int>.from(row))
        .toList();

    final prefix = masked
        .expand((b) => b)
        .map((row) => row.sublist(0, firstStartId))
        .toList();

    return _DelayPatternResult(prefix, patternMask);
  }

  List<List<int>> _applyDelayPatternMask(
    List<List<int>> inputIds,
    List<List<int>> patternMask,
  ) {
    final seqLen = inputIds.first.length;
    final result = List.generate(
      inputIds.length,
      (i) => List<int>.filled(seqLen, 0),
    );

    for (var i = 0; i < inputIds.length; i++) {
      for (var t = 0; t < seqLen; t++) {
        final maskValue = patternMask[i][t];
        result[i][t] = maskValue == -1 ? inputIds[i][t] : maskValue;
      }
    }

    return result;
  }

  List<List<int>> _filterPadTokens(List<List<int>> inputIds, int padTokenId) {
    final filtered = <List<int>>[];
    for (final row in inputIds) {
      final cleaned = <int>[];
      for (final token in row) {
        if (token != padTokenId) {
          cleaned.add(token);
        }
      }
      filtered.add(cleaned);
    }
    return filtered;
  }

  Future<void> dispose() async {
    await _textEncoder?.close();
    await _decoder?.close();
    await _decoderWithPast?.close();
    await _encodec?.close();
    _textEncoder = null;
    _decoder = null;
    _decoderWithPast = null;
    _encodec = null;
    _tokenizer = null;
    _config = null;
    _modelDir = null;
  }
}

class MusicGenConfig {
  final int numCodebooks;
  final int audioChannels;
  final int vocabSize;
  final int maxLength;
  final int padTokenId;
  final int decoderStartTokenId;
  final int sampleRate;
  final int topK;
  final double temperature;
  final double tokensPerSecond;

  const MusicGenConfig({
    required this.numCodebooks,
    required this.audioChannels,
    required this.vocabSize,
    required this.maxLength,
    required this.padTokenId,
    required this.decoderStartTokenId,
    required this.sampleRate,
    required this.topK,
    required this.temperature,
    required this.tokensPerSecond,
  });

  factory MusicGenConfig.fromJson({
    required Map<String, dynamic> configJson,
    required Map<String, dynamic> generationJson,
    required Map<String, dynamic> preprocessorJson,
  }) {
    final decoder = configJson['decoder'] as Map<String, dynamic>;
    final audioEncoder =
        configJson['audio_encoder'] as Map<String, dynamic>;

    final numCodebooks = (decoder['num_codebooks'] as num?)?.toInt() ?? 4;
    final audioChannels = (decoder['audio_channels'] as num?)?.toInt() ?? 1;
    final vocabSize = (decoder['vocab_size'] as num?)?.toInt() ?? 2048;
    final maxLength = (generationJson['max_length'] as num?)?.toInt() ?? 1500;
    final padTokenId = (generationJson['pad_token_id'] as num?)?.toInt() ?? 2048;
    final decoderStartTokenId =
        (generationJson['decoder_start_token_id'] as num?)?.toInt() ??
            (generationJson['bos_token_id'] as num?)?.toInt() ??
            padTokenId;
    final sampleRate = (preprocessorJson['sampling_rate'] as num?)?.toInt() ??
        (audioEncoder['sampling_rate'] as num?)?.toInt() ??
        32000;
    final topK = (decoder['top_k'] as num?)?.toInt() ?? 50;
    final temperature = (decoder['temperature'] as num?)?.toDouble() ?? 1.0;

    return MusicGenConfig(
      numCodebooks: numCodebooks,
      audioChannels: audioChannels,
      vocabSize: vocabSize,
      maxLength: maxLength,
      padTokenId: padTokenId,
      decoderStartTokenId: decoderStartTokenId,
      sampleRate: sampleRate,
      topK: topK,
      temperature: temperature,
      tokensPerSecond: 50.0,
    );
  }
}

class MusicGenTokenizer {
  static const String _metaspace = '\u2581';
  final Map<String, int> tokenToId;
  final List<double> tokenScores;
  final int unkId;
  final int eosId;
  final int padId;
  final _TrieNode _trie;

  MusicGenTokenizer._({
    required this.tokenToId,
    required this.tokenScores,
    required this.unkId,
    required this.eosId,
    required this.padId,
    required _TrieNode trie,
  }) : _trie = trie;

  static Future<MusicGenTokenizer> load(String modelDir) async {
    final tokenizerPath = path.join(modelDir, 'tokenizer.json');
    final configPath = path.join(modelDir, 'tokenizer_config.json');

    final tokenizerJson = jsonDecode(
        await File(tokenizerPath).readAsString()) as Map<String, dynamic>;
    final model = tokenizerJson['model'] as Map<String, dynamic>;
    final vocab = model['vocab'] as List<dynamic>;

    final tokenToId = <String, int>{};
    final tokenScores = List<double>.filled(vocab.length, 0.0);
    for (var i = 0; i < vocab.length; i++) {
      final entry = vocab[i] as List<dynamic>;
      final token = entry[0] as String;
      final score = (entry[1] as num).toDouble();
      tokenToId[token] = i;
      tokenScores[i] = score;
    }

    final configJson = jsonDecode(await File(configPath).readAsString())
        as Map<String, dynamic>;
    final padToken = configJson['pad_token'] as String? ?? '<pad>';
    final eosToken = configJson['eos_token'] as String? ?? '</s>';

    final unkId = (model['unk_id'] as num?)?.toInt() ??
        tokenToId['<unk>'] ??
        0;
    final padId = tokenToId[padToken] ?? 0;
    final eosId = tokenToId[eosToken] ?? 1;

    final trie = _TrieNode();
    tokenToId.forEach((token, id) {
      trie.insert(token, id);
    });

    return MusicGenTokenizer._(
      tokenToId: tokenToId,
      tokenScores: tokenScores,
      unkId: unkId,
      eosId: eosId,
      padId: padId,
      trie: trie,
    );
  }

  List<int> encode(String text) {
    final normalized = unorm.nfkc(text).trim();
    if (normalized.isEmpty) {
      return [eosId];
    }

    final pieces = normalized.split(RegExp(r'\s+'));
    final tokens = <int>[];
    for (final piece in pieces) {
      final prefixed = '$_metaspace$piece';
      tokens.addAll(_encodeUnigram(prefixed));
    }
    tokens.add(eosId);
    return tokens;
  }

  List<int> _encodeUnigram(String text) {
    final runes = text.runes.toList();
    final length = runes.length;
    final dp = List<double>.filled(length + 1, double.negativeInfinity);
    final backId = List<int>.filled(length + 1, -1);
    final backPos = List<int>.filled(length + 1, -1);
    dp[0] = 0.0;

    for (var i = 0; i < length; i++) {
      if (dp[i].isInfinite) continue;

      var node = _trie;
      for (var j = i; j < length; j++) {
        node = node.children[runes[j]] ?? _TrieNode.empty;
        if (node.isEmpty) break;

        if (node.tokenId != null) {
          final tokenId = node.tokenId!;
          final score = dp[i] + tokenScores[tokenId];
          if (score > dp[j + 1]) {
            dp[j + 1] = score;
            backId[j + 1] = tokenId;
            backPos[j + 1] = i;
          }
        }
      }
    }

    if (dp[length].isInfinite) {
      return [unkId];
    }

    final ids = <int>[];
    var pos = length;
    while (pos > 0) {
      final tokenId = backId[pos];
      if (tokenId < 0) {
        return [unkId];
      }
      ids.add(tokenId);
      pos = backPos[pos];
    }

    return ids.reversed.toList();
  }
}

class _TrieNode {
  final Map<int, _TrieNode> children = {};
  int? tokenId;
  bool get isEmpty => this == empty;

  static final _TrieNode empty = _TrieNode._empty();

  _TrieNode();

  _TrieNode._empty();

  void insert(String token, int id) {
    var node = this;
    for (final rune in token.runes) {
      node = node.children.putIfAbsent(rune, () => _TrieNode());
    }
    node.tokenId = id;
  }
}

class _DelayPatternResult {
  final List<List<int>> inputIds;
  final List<List<int>> patternMask;

  const _DelayPatternResult(this.inputIds, this.patternMask);
}

final Random _random = Random();
