# android/src/main/cpp/CMakeLists.txt
#
# Builds the AEC3 JNI shim (aec3_shim.cpp) and links it against the PREBUILT
# WebRTC AudioProcessing static library that lives, committed, under
# android/src/main/cpp/prebuilt/. That .a is produced reproducibly by the
# sealed CI workflow (build-aec3-arm64.yml) from the pinned vendored source.
#
# Only arm64-v8a is shipped (see build.gradle.kts abiFilters).

cmake_minimum_required(VERSION 3.22.1)
project(six_pages_voice_aec3)

# Root of the committed prebuilt artifact (lib + headers), per-ABI.
set(PREBUILT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/${ANDROID_ABI}")

# The static library built by the sealed CI.
add_library(webrtc_apm STATIC IMPORTED)
set_target_properties(webrtc_apm PROPERTIES
    IMPORTED_LOCATION "${PREBUILT_DIR}/lib/libwebrtc-audio-processing-1.a")

# The JNI shim.
add_library(six_pages_voice_aec3 SHARED aec3_shim.cpp)

# Header search paths:
#   - the webrtc-audio-processing-1/ prefix, so the library's own internal
#     includes ("api/...", "modules/...", "rtc_base/...") resolve
#   - the include root, so abseil ("absl/...") resolves
target_include_directories(six_pages_voice_aec3 PRIVATE
    "${PREBUILT_DIR}/include/webrtc-audio-processing-1"
    "${PREBUILT_DIR}/include")

# Android system libs the WebRTC APM needs.
find_library(log-lib log)

target_link_libraries(six_pages_voice_aec3
    webrtc_apm
    ${log-lib})
