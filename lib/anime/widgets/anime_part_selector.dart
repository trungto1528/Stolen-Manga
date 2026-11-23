import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/anime_part_dto.dart';
import '../providers/anime_providers.dart';

class AnimePartSelector extends ConsumerStatefulWidget {
  final String animeUrl;
  final String currentPartName;
  final void Function(String) onPartChanged;

  const AnimePartSelector({
    super.key,
    required this.animeUrl,
    required this.currentPartName,
    required this.onPartChanged,
  });

  @override
  ConsumerState<AnimePartSelector> createState() => _AnimePartSelectorState();
}

class _AnimePartSelectorState extends ConsumerState<AnimePartSelector> {
  late Future<List<AnimePartDTO>> _partsFuture;

  @override
  void initState() {
    super.initState();
    _loadParts();
  }

  @override
  void didUpdateWidget(covariant AnimePartSelector oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.animeUrl != widget.animeUrl) {
      _loadParts();
    }
  }

  void _loadParts() {
    _partsFuture = ref.read(animeServiceProvider).getParts(widget.animeUrl);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<AnimePartDTO>>(
      future: _partsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }

        if (snapshot.hasError || !snapshot.hasData || snapshot.data!.isEmpty) {
          return const SizedBox.shrink();
        }

        final parts = snapshot.data!;

        final selectedPart = parts.where(
          (part) => part.name == widget.currentPartName,
        );

        final displayPartName = selectedPart.isNotEmpty
            ? selectedPart.first.name
            : widget.currentPartName;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Text(
                'Phần:',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: PopupMenuButton<String>(
                  initialValue:
                      parts.any((part) => part.name == widget.currentPartName)
                      ? widget.currentPartName
                      : null,
                  onSelected: widget.onPartChanged,
                  itemBuilder: (context) {
                    return parts.map((part) {
                      final isCurrent = part.name == widget.currentPartName;

                      return PopupMenuItem<String>(
                        value: part.name,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 24,
                              child: isCurrent
                                  ? Icon(
                                      Icons.check,
                                      size: 18,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    )
                                  : null,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                part.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            displayPartName,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w500),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.arrow_drop_down,
                          size: 20,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
