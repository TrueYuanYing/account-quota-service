import 'package:flutter/material.dart';
import '../../core/widgets/app_widgets.dart';

/// Purchase values always come from the server catalog; existing orders retain
/// their own quota snapshot. This widget has no charging or promotion logic.
class QuotaProductCard extends StatelessWidget {
  const QuotaProductCard({super.key, required this.product, this.onBuy});
  final Map<String, dynamic> product;
  final VoidCallback? onBuy;
  static const names = {
    'answer': '答题',
    'correct': '云端纠错',
    'translate': '翻译',
    'summary': '课堂摘要'
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recommended = product['id'] == 'topup_2999';
    final price = ((product['price_cents'] as num) / 100).toStringAsFixed(2);
    return GlassCard(
        child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (recommended) ...[
          Wrap(
              spacing: 10,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DecoratedBox(
                    decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12)),
                    child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        child: Text('超值选择',
                            style: theme.textTheme.labelLarge?.copyWith(
                                color: theme.colorScheme.onPrimaryContainer)))),
                Text('一次省心',
                    style: theme.textTheme.titleSmall?.copyWith(
                        fontStyle: FontStyle.italic, letterSpacing: 1)),
              ]),
          const SizedBox(height: 12),
        ],
        Text(product['name']?.toString() ?? '额度包',
            style: theme.textTheme.titleMedium),
        if (recommended && product['price_cents'] == 2999) ...[
          const SizedBox(height: 8),
          Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('活动价 ¥$price', style: theme.textTheme.titleLarge),
                Text('¥49.99',
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        decoration: TextDecoration.lineThrough)),
                Text('活动后价格',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ]),
        ],
        const SizedBox(height: 12),
        Wrap(spacing: 18, runSpacing: 10, children: [
          for (final entry in names.entries)
            Text('${entry.value} ${(product['quotas'] as Map)[entry.key]} 次'),
        ]),
        const SizedBox(height: 18),
        FilledButton(
            onPressed: onBuy,
            child: Text(
                product['purchasable'] == true ? '¥$price · 支付宝购买' : '支付接入中')),
      ],
    ));
  }
}
