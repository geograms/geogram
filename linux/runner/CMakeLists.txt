cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "bluetooth_classic_plugin.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Find BlueZ/Bluetooth library for Bluetooth Classic support
pkg_check_modules(BLUEZ IMPORTED_TARGET bluez)

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

# Link Bluetooth library if available
if(BLUEZ_FOUND)
  target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::BLUEZ)
  target_compile_definitions(${BINARY_NAME} PRIVATE HAVE_BLUETOOTH=1)
else()
  message(STATUS "BlueZ dev library not found - Bluetooth Classic support will be limited.")
  # Plugin will use DBus-only mode without direct RFCOMM socket support
endif()

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
