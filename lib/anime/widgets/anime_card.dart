import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../models/anime.dart';

class AnimeCard extends StatelessWidget {
  final AnimeSearchResult anime;
  final VoidCallback? onTap;

  const AnimeCard({
    super.key,
    required this.anime,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Use width to calculate height based on grid's childAspectRatio (0.78)
            // This ensures we respect the exact size the GridView allocates
            final cardHeight = constraints.maxWidth / 0.78;
            final posterHeight = cardHeight * 0.65;
            final titleHeight = cardHeight - posterHeight;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Poster
                SizedBox(
                  width: constraints.maxWidth,
                  height: posterHeight,
                  child: Stack(
                    fit: StackFit.expand,
                    children: _buildPosterStack(context),
                  ),
                ),
                // Title
                SizedBox(
                  height: titleHeight,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      anime.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w500,
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  List<Widget> _buildPosterStack(BuildContext context) {
    final widgets = <Widget>[
      CachedNetworkImage(
        imageUrl: anime.poster,
        fit: BoxFit.cover,
        placeholder: (_, __) => Container(
          color: Colors.grey[300],
          child: const Center(child: CircularProgressIndicator()),
        ),
        errorWidget: (_, __, ___) => Container(
          color: Colors.grey[300],
          child: const Icon(Icons.image_not_supported, size: 40),
        ),
      ),
    ];

    if (anime.label.isNotEmpty) {
      widgets.add(
        Positioned(
          bottom: 4,
          right: 4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.red,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              anime.label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      );
    }

    if (anime.score.isNotEmpty) {
      widgets.add(
        Positioned(
          top: 4,
          right: 4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.amber,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.star, size: 10, color: Colors.white),
                const SizedBox(width: 2),
                Text(
                  anime.score,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return widgets;
  }
}