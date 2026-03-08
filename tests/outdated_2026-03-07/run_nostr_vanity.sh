#!/usr/bin/env bash
set -euo pipefail

pattern="${1:-}"
threads="${2:-}"

if [[ -z "$pattern" ]]; then
  echo "Usage:"
  echo "  ./tests/run_nostr_vanity.sh PATTERN [threads]"
  echo ""
  echo "Examples:"
  echo "  ./tests/run_nostr_vanity.sh ABCD"
  echo "  ./tests/run_nostr_vanity.sh **xy 8"
  exit 64
fi

args=("$pattern")
if [[ -n "$threads" ]]; then
  args+=("--threads" "$threads")
fi

dart_bin="$(command -v dart || true)"
if [[ -z "$dart_bin" ]]; then
  flutter_bin="$(command -v flutter || true)"
  if [[ -n "$flutter_bin" ]]; then
    flutter_root="$(dirname "$(dirname "$flutter_bin")")"
    dart_candidate="$flutter_root/bin/cache/dart-sdk/bin/dart"
    if [[ -x "$dart_candidate" ]]; then
      dart_bin="$dart_candidate"
    fi
  fi
fi

if [[ -z "$dart_bin" && -n "${FLUTTER_HOME:-}" ]]; then
  dart_candidate="$FLUTTER_HOME/bin/cache/dart-sdk/bin/dart"
  if [[ -x "$dart_candidate" ]]; then
    dart_bin="$dart_candidate"
  fi
fi

if [[ -z "$dart_bin" && -n "${DART_SDK:-}" ]]; then
  dart_candidate="$DART_SDK/bin/dart"
  if [[ -x "$dart_candidate" ]]; then
    dart_bin="$dart_candidate"
  fi
fi

if [[ -z "$dart_bin" ]]; then
  for root in \
    "$HOME/flutter" \
    "$HOME/dev/flutter" \
    "/opt/flutter" \
    "/usr/local/flutter" \
    "$HOME/.flutter" \
    "$HOME/.local/flutter" \
    "$HOME/Applications/flutter"; do
    dart_candidate="$root/bin/cache/dart-sdk/bin/dart"
    if [[ -x "$dart_candidate" ]]; then
      dart_bin="$dart_candidate"
      break
    fi
  done
fi

if [[ -z "$dart_bin" ]]; then
  echo "Error: dart not found in PATH and flutter not available to resolve it."
  echo "Install Dart/Flutter or add dart to PATH."
  exit 127
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/.."
"$dart_bin" run "$script_dir/nostr_vanity_generator.dart" "${args[@]}"
