import 'package:flutter/material.dart';
import '../../../shared/branding/app_brand_icon.dart';

/// Use the same original bee and dark-mode backing as the other brand entries.
class MineDefaultAvatar extends StatelessWidget {
  const MineDefaultAvatar({super.key});

  @override
  Widget build(BuildContext context) => AppBrandIcon(size: 48);
}
