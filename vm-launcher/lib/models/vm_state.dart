enum VmStatus {
  setup,
  ready,
  starting,
  connected,
  error,
}

enum DownloadStage {
  idle,
  qemu,
  image,
  extracting,
  verifying,
}

class VmState {
  final VmStatus status;
  final double downloadProgress;
  final DownloadStage downloadStage;
  final String? errorMessage;
  final String? errorDetails;

  const VmState({
    this.status = VmStatus.setup,
    this.downloadProgress = 0.0,
    this.downloadStage = DownloadStage.idle,
    this.errorMessage,
    this.errorDetails,
  });

  VmState copyWith({
    VmStatus? status,
    double? downloadProgress,
    DownloadStage? downloadStage,
    String? errorMessage,
    String? errorDetails,
  }) {
    return VmState(
      status: status ?? this.status,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      downloadStage: downloadStage ?? this.downloadStage,
      errorMessage: errorMessage ?? this.errorMessage,
      errorDetails: errorDetails ?? this.errorDetails,
    );
  }
}
