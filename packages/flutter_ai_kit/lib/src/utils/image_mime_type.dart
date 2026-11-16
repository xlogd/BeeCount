/// Detect the encoded format; crop/picker files do not always match their name.
String imageMimeType(List<int> bytes) {
  bool starts(List<int> signature) =>
      bytes.length >= signature.length &&
      Iterable<int>.generate(signature.length)
          .every((index) => bytes[index] == signature[index]);
  if (starts([0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (starts([137, 80, 78, 71, 13, 10, 26, 10])) return 'image/png';
  if (starts([71, 73, 70, 56, 55, 97]) || starts([71, 73, 70, 56, 57, 97])) {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      starts([82, 73, 70, 70]) &&
      bytes[8] == 87 &&
      bytes[9] == 69 &&
      bytes[10] == 66 &&
      bytes[11] == 80) {
    return 'image/webp';
  }
  throw const FormatException('Unsupported image encoding');
}
