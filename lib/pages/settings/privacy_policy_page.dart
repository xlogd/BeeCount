import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import 'support/bindings/support_frame.dart';

class PrivacyPolicyPage extends StatefulWidget {
  const PrivacyPolicyPage({super.key});

  @override
  State<PrivacyPolicyPage> createState() => _PrivacyPolicyPageState();
}

class _PrivacyPolicyPageState extends State<PrivacyPolicyPage> {
  late final Future<String> _policy = rootBundle.loadString('PRIVACY.md');

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final isChinese = Localizations.localeOf(context).languageCode == 'zh';
    return SupportFrame(
      title: l.aboutPrivacyPolicy,
      body: FutureBuilder<String>(
        future: _policy,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text(l.helpCenterLoadFailed));
          }
          final policy = snapshot.data;
          if (policy == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final sections = policy.split('<!-- zh-CN -->');
          return Markdown(
            data: isChinese ? sections.last : sections.first,
            selectable: true,
            onTapLink: (_, href, __) {
              final uri = href == null ? null : Uri.tryParse(href);
              if (uri != null && uri.scheme == 'https') {
                launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
          );
        },
      ),
    );
  }
}
