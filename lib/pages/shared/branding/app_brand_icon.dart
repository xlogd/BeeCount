import 'package:flutter/widgets.dart';

class AppBrandIcon extends StatelessWidget {
  const AppBrandIcon({super.key, required this.size});

  static const image = AssetImage('assets/icon/app_icon.png');

  final double size;

  @override
  Widget build(BuildContext context) => Image(
        image: image,
        width: size,
        height: size,
        fit: BoxFit.contain,
        excludeFromSemantics: true,
      );
}
