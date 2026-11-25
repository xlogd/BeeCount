import 'package:beecount_business_ui/share_posters.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../services/export/share_poster_types.dart';
import '../../../../services/data/category_service.dart';
import '../../../../utils/category_utils.dart';
import '../../../../utils/currencies.dart';
import '../../branding/app_brand_icon.dart';
import '../../../../utils/project_links.dart';

/// Format amounts and supply project links for share posters.
String posterMoney(double value, AppLocalizations l,
        {String currency = 'CNY', bool hidden = false}) =>
    hidden
        ? '**'
        : '${getCurrencySymbol(currency)}${NumberFormat('#,##0.00', l.localeName).format(value)}';

Widget posterQr({String? campaign}) {
  final url = campaign == null
      ? ProjectLinks.repository
      : Uri.parse(ProjectLinks.repository).replace(queryParameters: {
          'utm_source': 'share_poster',
          'utm_medium': 'qr_code',
          'utm_campaign': campaign,
        }).toString();
  return ColoredBox(
    color: Colors.white,
    child: QrImageView(
      data: url,
      semanticsLabel: url,
      backgroundColor: Colors.white,
      padding: const EdgeInsets.all(5),
    ),
  );
}

Widget posterBrand(AppLocalizations l,
        {double size = 54,
        bool centered = false,
        double? nameSize,
        double? captionSize}) =>
    BeePosterBrand(
        logo: AppBrandIcon(size: size),
        name: l.sharePosterAppName,
        size: size,
        centered: centered,
        nameSize: nameSize,
        captionSize: captionSize);
Widget posterHeader(AppLocalizations l, String caption) =>
    BeePosterHeader(brand: posterBrand(l), caption: caption);
Widget posterFooter(AppLocalizations l, {String? campaign, bool qr = true}) =>
    BeePosterFooter(
        slogan: l.sharePosterSlogan,
        caption: l.appPromoFooterText,
        projectLink: ProjectLinks.repositoryLabel,
        qr: qr ? posterQr(campaign: campaign) : null);

List<BeePosterCategory> posterCategories(
        BuildContext context, List<CategoryTotal> items, AppLocalizations l,
        {String currency = 'CNY',
        bool hidden = false,
        String kind = 'expense'}) =>
    items
        .map((item) => BeePosterCategory(
            name: CategoryUtils.getDisplayName(item.name, context, kind: kind),
            amount:
                posterMoney(item.total, l, currency: currency, hidden: hidden),
            percent: '${(item.percentage * 100).toStringAsFixed(1)}%',
            ratio: item.percentage,
            icon: Icon(CategoryService.getCategoryIcon(item.icon))))
        .toList();

String posterUnit(int value, String unit, AppLocalizations l) =>
    '$value${l.localeName.startsWith('zh') ? '' : ' '}$unit';
