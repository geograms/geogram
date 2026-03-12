class DownloadAsset {
  final String url;
  final String filename;
  final int sizeBytes;
  final String sha256;

  const DownloadAsset({
    required this.url,
    required this.filename,
    required this.sizeBytes,
    required this.sha256,
  });
}

class DownloadManifest {
  static const _baseUrl = 'https://p2p.radio/vm';

  static const linuxQemu = DownloadAsset(
    url: '$_baseUrl/qemu-linux-x86_64.tar.gz',
    filename: 'qemu-linux-x86_64.tar.gz',
    sizeBytes: 50 * 1024 * 1024, // ~50MB placeholder
    sha256: '', // populated after first build
  );

  static const windowsQemu = DownloadAsset(
    url: '$_baseUrl/qemu-windows-x86_64.zip',
    filename: 'qemu-windows-x86_64.zip',
    sizeBytes: 80 * 1024 * 1024, // ~80MB placeholder
    sha256: '',
  );

  static const vmImage = DownloadAsset(
    url: '$_baseUrl/geogram-dev.qcow2',
    filename: 'geogram-dev.qcow2',
    sizeBytes: 12 * 1024 * 1024 * 1024, // ~12GB
    sha256: '',
  );
}
