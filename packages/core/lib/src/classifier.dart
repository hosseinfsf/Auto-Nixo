/// Classifies a raw message as signal / management update / recap / noise.
///
/// Persian + English. Normalizes digits first. Avoids false positives on
/// common words (e.g. "be").
library;

import 'models.dart';
import 'normalizer.dart';

class ClassificationResult {
  ClassificationResult({
    required this.kind,
    this.action = ManagementAction.none,
    this.confidence = 0.0,
  });

  final SignalKind kind;
  final ManagementAction action;
  final double confidence;
}

class Classifier {
  // --- Management action keywords (English) ---
  static const _moveSlEn = ['move sl', 'move stop', 'sl to', 'stop to', 'adjust sl'];
  static const _breakEvenEn = ['break even', 'breakeven', 'be at', 'move to be', 'to breakeven'];
  static const _closeEn = ['close', 'exit now', 'close all', 'take profit now', 'close trade'];
  static const _cancelEn = ['cancel', 'delete order', 'remove order'];

  // --- Management action keywords (Persian) ---
  static const _moveSlFa = ['حد ضرر', 'استاپ', 'اسال', 'به اسال', 'جابجایی ضرر'];
  static const _breakEvenFa = ['سربهسر', 'سر به سر', 'به سربهسر', 'سربه سر'];
  static const _closeFa = ['ببند', 'بستن', 'ببندین', 'ببندید', 'خروج', 'ببند همه', 'ببندید همه'];
  static const _cancelFa = ['کنسل', 'لغو', 'حذف سفارش', 'حذف'];

  /// Keywords that strongly indicate a trading signal.
  static const _signalEn = ['buy', 'sell', 'long', 'short', 'entry', 'enter', 'sl', 'tp', 'target', 'take profit', 'stop loss', 'tp1', 'tp2', 'tp3', 'lot'];
  static const _signalFa = ['خرید', 'فروش', 'لانگ', 'شورت', 'ورود', 'حد ضرر', 'حد سود', 'تیپی', 'تی پی', 'هدف', 'لوت', 'خرید و فروش'];

  /// Words that strongly indicate recap/result (not a new signal).
  static const _recapEn = ['closed with profit', 'closed at', 'result', 'win', 'loss', 'profit', 'pips', 'summary', 'recap', 'weekly', 'monthly', 'done for today'];
  static const _recapFa = ['سود', 'ضرر', 'نتیجه', 'بسته شد', 'بسته شد با سود', 'پایان', 'خلاصه', 'گزارش', 'هفتگی', 'ماهانه'];

  ClassificationResult classify(String rawText) {
    final text = normalizeText(rawText).toLowerCase();
    if (text.isEmpty) {
      return ClassificationResult(kind: SignalKind.noise, confidence: 0.5);
    }

    // 1. Deleted / empty images with no text -> noise.
    // 2. Management updates first (they act on existing signals).
    final mgmt = _classifyManagement(text);
    if (mgmt != null) {
      return ClassificationResult(
        kind: SignalKind.management,
        action: mgmt,
        confidence: 0.9,
      );
    }

    // 3. Recap/result.
    if (_containsAny(text, _recapEn) || _containsAny(text, _recapFa)) {
      // But a recap that also has buy/sell could be a signal; be careful.
      // If it has strong signal words, prefer signal.
      if (!_containsAny(text, _signalEn) && !_containsAny(text, _signalFa)) {
        return ClassificationResult(kind: SignalKind.recap, confidence: 0.85);
      }
    }

    // 4. Signal detection.
    final signalScore = _signalScore(text);
    if (signalScore >= 2) {
      return ClassificationResult(kind: SignalKind.signal, confidence: 0.9);
    }
    if (signalScore == 1) {
      // Weak signal; may be noise. Only accept if it has a price-ish token.
      if (_hasNumberToken(text)) {
        return ClassificationResult(kind: SignalKind.signal, confidence: 0.6);
      }
    }

    return ClassificationResult(kind: SignalKind.noise, confidence: 0.7);
  }

  ManagementAction? _classifyManagement(String text) {
    // "be" alone is dangerous (English "be"). Require context.
    if (_containsAny(text, _moveSlEn) || _containsAny(text, _moveSlFa)) {
      return ManagementAction.moveSl;
    }
    if (_containsAny(text, _breakEvenEn) || _containsAny(text, _breakEvenFa)) {
      return ManagementAction.breakEven;
    }
    if (_containsAny(text, _closeEn) || _containsAny(text, _closeFa)) {
      return ManagementAction.close;
    }
    if (_containsAny(text, _cancelEn) || _containsAny(text, _cancelFa)) {
      return ManagementAction.cancel;
    }
    return null;
  }

  int _signalScore(String text) {
    var score = 0;
    for (final k in _signalEn) {
      if (text.contains(k)) score++;
    }
    for (final k in _signalFa) {
      if (text.contains(k)) score++;
    }
    return score;
  }

  bool _containsAny(String text, List<String> keywords) {
    for (final k in keywords) {
      // Word-boundary-ish check for English; substring for Persian.
      if (RegExp(r'^[a-z0-9 ]+$').hasMatch(k)) {
        if (RegExp('(^|\\s)${RegExp.escape(k)}(\\s|\$)').hasMatch(text)) {
          return true;
        }
      } else {
        if (text.contains(k)) return true;
      }
    }
    return false;
  }

  bool _hasNumberToken(String text) {
    return RegExp(r'\d').hasMatch(text);
  }
}
