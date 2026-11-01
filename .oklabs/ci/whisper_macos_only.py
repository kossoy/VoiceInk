#!/usr/bin/env python3
"""Rewrite whisper.cpp's build-xcframework.sh into a macOS-only build.

The upstream script builds iOS, visionOS and tvOS slices as well. VoiceInk only
links the macOS slice, so the fork drops the other platforms to save CI time.
The transform is checked: any leftover non-macOS build step is an error.
"""
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()

other = r"(?:ios|visionos|tvos)"
# cmake configure (multi-line, backslash-continued) + cmake --build for other platforms
s, n_cmake = re.subn(
    r"cmake -B build-" + other + r"[^\n]*\n(?:[^\n]*\\\n)*[^\n]*\ncmake --build build-" + other + r"[^\n]*\n",
    "",
    s,
)
s, n_setup = re.subn(
    r"^(?:setup_framework_structure|combine_static_libraries) \"build-" + other + r"[^\n]*\n",
    "",
    s,
    flags=re.M,
)
s, n_xcf = re.subn(
    r"^[ \t]*-(?:framework|debug-symbols) \$\(pwd\)/build-" + other + r"[^\n]*\n",
    "",
    s,
    flags=re.M,
)

leftover = re.findall(
    r"cmake (?:-B|--build) build-" + other + r"|^(?:setup_framework_structure|combine_static_libraries) \"build-" + other
    + r"|\$\(pwd\)/build-" + other,
    s,
    flags=re.M,
)
if leftover or n_cmake != 6 or n_setup != 12 or "cmake -B build-macos" not in s:
    sys.exit(f"whisper_macos_only: unexpected script shape (cmake={n_cmake} setup={n_setup} xcf={n_xcf} leftover={leftover})")

open(dst, "w").write(s)
print(f"whisper_macos_only: removed {n_cmake} cmake builds, {n_setup} setup lines, {n_xcf} xcframework args")
