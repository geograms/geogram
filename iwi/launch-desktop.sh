#!/bin/sh
cd "$(dirname "$0")" || exit 1
exec /home/brito/flutter/bin/flutter run -d linux
