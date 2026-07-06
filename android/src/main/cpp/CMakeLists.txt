# android/src/main/cpp/CMakeLists.txt
#
# Builds the AEC3 JNI shim (aec3_shim.cpp) and links it against the PREBUILT
# WebRTC AudioProcessing static library that lives, committed, under
# android/src/main/cpp/prebuilt/. That .a is produced reproducibly by the
# sealed CI workflow (produce-prebuilt.yml) from the pinned vendored source.
#
# Only arm64-v8a is shipped (see build.gradle.kts abiFilters).

cmake_minimum_required(VERSION 3.22.1)
project(six_pages_voice_aec3)

# Root of the committed prebuilt artifact (lib + headers), per-ABI.
set(PREBUILT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/${ANDROID_ABI}")

# The one fat static library produced by the sealed CI. It bundles 438 objects
# (WebRTC APM + Abseil) in a SINGLE archive. Those objects reference each other
# circularly (Abseil <-> WebRTC base), so the archive MUST be linked inside a
# --start-group/--end-group. Linked once without a group, the linker can drop
# an object on its first pass and then fail to resolve a symbol needed later.
#
# We therefore link the archive BY PATH inside an explicit link group. This is
# byte-for-byte the same link strategy proven green in CI (prove-shim-link.yml
# and produce-prebuilt.yml both wrapped this archive in --start-group). We do
# NOT use an IMPORTED target here, precisely so the group wrapping is explicit
# and identical to the proven command.
set(WEBRTC_APM_ARCHIVE "${PREBUILT_DIR}/lib/libwebrtc-audio-processing-1.a")

# Fail loudly at configure time if the committed prebuilt is missing for this
# ABI, rather than emitting a confusing link error later.
if(NOT EXISTS "${WEBRTC_APM_ARCHIVE}")
    message(FATAL_ERROR
        "AEC3 prebuilt archive not found for ABI '${ANDROID_ABI}':\n"
        "  ${WEBRTC_APM_ARCHIVE}\n"
        "Only arm64-v8a is shipped. Confirm build.gradle.kts abiFilters is arm64-v8a "
        "and the prebuilt is committed under prebuilt/${ANDROID_ABI}/lib/.")
endif()

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

# Link the fat archive inside an explicit --start-group (see note above), plus
# the Android log lib. Order: shim objects (from the SHARED target) pull symbols
# from the grouped archive; the group re-scans until all cross-refs resolve.
target_link_libraries(six_pages_voice_aec3
    -Wl,--start-group
    "${WEBRTC_APM_ARCHIVE}"
    -Wl,--end-group
    ${log-lib})
