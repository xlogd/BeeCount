/// Public links for this edition of BeeCount.
abstract final class ProjectLinks {
  static const maintainer = 'LogDancer';
  static const maintainerProfile = 'https://github.com/xlogd';
  static const originalAuthor = 'sunxiao (TNT-Likely)';
  static const originalRepository = 'https://github.com/TNT-Likely/BeeCount';

  static const slug = 'xlogd/BeeCount';
  static const repositoryLabel = 'github.com/$slug';
  static const repository = 'https://$repositoryLabel';
  static const issues = '$repository/issues';
  static const releases = '$repository/releases';
  static const apiRepository = 'https://api.github.com/repos/$slug';
  static const latestReleaseApi = '$apiRepository/releases/latest';
}
