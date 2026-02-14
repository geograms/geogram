Import("env")
import os
import re

def patch_legacy_driver(filepath, driver_name):
    """
    Patch an ESP-IDF legacy driver to disable the conflict check.
    This is needed because ESP-Mesh-Lite/iot_bridge pulls in new drivers,
    but the legacy drivers are also compiled, causing runtime conflicts.
    """
    if not os.path.exists(filepath):
        return False

    with open(filepath, 'r') as f:
        content = f.read()

    # Check if already patched
    if "GEOGRAM_PATCHED" in content:
        return True

    # Pattern to match ESP_EARLY_LOGE with any tag name, capturing the tag
    # Match: ESP_EARLY_LOGE(SOMETHING, "CONFLICT..."); abort();
    pattern = r'(\s+)ESP_EARLY_LOGE\(([^,]+),\s*"CONFLICT[^"]*"\);\s*abort\(\);'

    def replacement(m):
        indent = m.group(1)
        tag = m.group(2)
        return f'{indent}// GEOGRAM_PATCHED: Conflict check disabled for ESP-Mesh-Lite compatibility\n{indent}ESP_EARLY_LOGW({tag}, "GEOGRAM_PATCHED: {driver_name} driver coexistence allowed");'

    new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)

    if new_content != content:
        with open(filepath, 'w') as f:
            f.write(new_content)
        print(f"[Geogram] Patched ESP-IDF legacy {driver_name} driver")
        return True

    return False

def patch_all_legacy_drivers():
    """Patch all legacy drivers that have conflict checks."""
    framework_dir = env.PioPlatform().get_package_dir("framework-espidf")
    deprecated_dir = os.path.join(framework_dir, "components", "driver", "deprecated")
    driver_dir = os.path.join(framework_dir, "components", "driver")

    # List of legacy drivers with conflict checks
    # ESP-IDF 5.x has many legacy drivers that abort if new driver is also present
    deprecated_drivers = [
        ("deprecated/rtc_temperature_legacy.c", "temp_sensor"),
        ("deprecated/rmt_legacy.c", "rmt"),
        ("deprecated/mcpwm_legacy.c", "mcpwm"),
        ("deprecated/pcnt_legacy.c", "pcnt"),
        ("deprecated/timer_legacy.c", "timer"),
        ("deprecated/i2s_legacy.c", "i2s"),
        ("deprecated/dac_common_legacy.c", "dac"),
        ("deprecated/sigma_delta_legacy.c", "sigma_delta"),
        ("deprecated/adc_legacy.c", "adc"),
        ("deprecated/adc_dma_legacy.c", "adc_dma"),
        # I2C driver is in main directory but also has conflict check
        ("i2c/i2c.c", "i2c"),
        ("spi/gpspi/spi_common.c", "spi"),
    ]

    for filepath_rel, driver_name in deprecated_drivers:
        filepath = os.path.join(driver_dir, filepath_rel)
        if os.path.exists(filepath):
            patch_legacy_driver(filepath, driver_name)

def sync_version_from_pubspec():
    """
    Read the project version from ../pubspec.yaml and inject it as a build flag.
    This keeps the ESP32 firmware version in sync with the main Flutter project.
    """
    project_dir = env.subst("$PROJECT_DIR")
    pubspec_path = os.path.join(project_dir, "..", "pubspec.yaml")

    if not os.path.exists(pubspec_path):
        print("[Geogram] pubspec.yaml not found, using default version from app_config.h")
        return

    with open(pubspec_path, 'r') as f:
        for line in f:
            match = re.match(r'^version:\s*(\d+\.\d+\.\d+)', line)
            if match:
                version = match.group(1)
                flag = f'-DGEOGRAM_VERSION=\\"{version}\\"'
                env.Append(BUILD_FLAGS=[flag])
                print(f"[Geogram] Version synced from pubspec.yaml: {version}")
                return

    print("[Geogram] Could not parse version from pubspec.yaml, using default")

def pre_build_action(source, target, env):
    """
    Pre-build script for environment setup
    """
    board_model = None
    for flag in env.get("BUILD_FLAGS", []):
        if "BOARD_MODEL=" in flag:
            board_model = flag.split("=")[1]
            break

    if board_model:
        print(f"[Geogram] Building for board model: {board_model}")

    # Ensure firmware output directory exists
    firmware_dir = os.path.join(env.subst("$PROJECT_DIR"), "firmware")
    os.makedirs(firmware_dir, exist_ok=True)

# Apply patches early
patch_all_legacy_drivers()

# Sync version from main project pubspec.yaml
sync_version_from_pubspec()

env.AddPreAction("buildprog", pre_build_action)
