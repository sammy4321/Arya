const Set<String> supportedAttachmentExtensions = {
  'pdf',
  'txt',
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
};

const Set<String> imageAttachmentExtensions = {
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
};

String extensionFromFileName(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot == fileName.length - 1) return '';
  return fileName.substring(dot + 1).toLowerCase();
}

bool isSupportedAttachmentFile(String fileName) {
  return supportedAttachmentExtensions.contains(
    extensionFromFileName(fileName),
  );
}

bool isImageAttachmentFile(String fileName) {
  return imageAttachmentExtensions.contains(extensionFromFileName(fileName));
}
