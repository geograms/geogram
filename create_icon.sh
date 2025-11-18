#!/bin/bash

# Create a custom Geogram icon using ImageMagick
# The icon represents a location marker with network nodes

OUTPUT_FILE="linux/data/app_icon.png"
SIZE=512

echo "Creating Geogram icon..."

# Create icon with gradient background and geometric shapes
convert -size ${SIZE}x${SIZE} xc:none \
  \( -size ${SIZE}x${SIZE} gradient:"#1E88E5-#1565C0" \
     -gravity center -extent ${SIZE}x${SIZE} \) \
  \( -size $((SIZE*7/10))x$((SIZE*7/10)) xc:none \
     -fill white \
     -draw "translate $((SIZE*7/20)),$((SIZE*2/10)) path 'M 0 0 Q $((SIZE*7/20)) $((SIZE*5/10)) 0 $((SIZE*7/10)) Q $((SIZE*-7/20)) $((SIZE*5/10)) 0 0 Z'" \
     -gravity center \) \
  -composite \
  \( -size $((SIZE/6))x$((SIZE/6)) xc:none \
     -fill "#1565C0" \
     -draw "circle $((SIZE/12)),$((SIZE/12)) $((SIZE/12)),0" \
     -gravity center \) \
  -composite \
  \( -size $((SIZE/15))x$((SIZE/15)) xc:none \
     -fill white \
     -draw "circle $((SIZE/30)),$((SIZE/30)) $((SIZE/30)),0" \
     -gravity NorthEast -geometry +$((SIZE/5))+$((SIZE/4)) \) \
  -composite \
  \( -size $((SIZE/15))x$((SIZE/15)) xc:none \
     -fill white \
     -draw "circle $((SIZE/30)),$((SIZE/30)) $((SIZE/30)),0" \
     -gravity NorthWest -geometry +$((SIZE/5))+$((SIZE/4)) \) \
  -composite \
  \( -size $((SIZE/15))x$((SIZE/15)) xc:none \
     -fill white \
     -draw "circle $((SIZE/30)),$((SIZE/30)) $((SIZE/30)),0" \
     -gravity South -geometry +0+$((SIZE/3)) \) \
  -composite \
  ${OUTPUT_FILE}

echo "✅ Icon created at ${OUTPUT_FILE}"
echo "Icon size: $(du -h ${OUTPUT_FILE} | cut -f1)"
