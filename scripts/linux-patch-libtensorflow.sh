#!/usr/bin/env sh

# This script exists to patch a small issue with `libtensorflow.so` on Linux.
# Invoke it with the path to `libtensorflow.so` as the first argument.
#
# If the path to `libtensorflow.so` needs root permissions to modify,
# then you need to invoke this script with `sudo`.
#
# This script is idempotent - you may run it more than once, and the resulting
# patched file will be equivalent at each subsequent run.
#
# This patch is intended to fix the following lld linker error:
#   ld.lld: error: corrupt input file: version definition index 0 for symbol curl_jmpenv is out of bounds
#   >>> defined in /usr/local/lib/libtensorflow.so
#
# So, libtensorflow (when compiled for Linux) is currently compiled with gcc.
# And gcc (when compiling libtensorflow) generates an ELF version info for the
# `curl_jmpenv` dynamic symbol that clang/lld sees as incorrect/invalid.
#
# That is, gcc indicates that this symbol's version info is local (byte zero),
# but lld chokes unless its version info is marked as global (byte one).
#
# See <https://refspecs.linuxfoundation.org/LSB_1.3.0/gLSB/gLSB/symversion.html>
# See <https://github.com/llvm/llvm-project/blob/8dfdcc7b7bf66834a761bd8de445840ef68e4d1a/lld/ELF/InputFiles.cpp#L1480-L1485>
#
# I don't know who's right (gcc or clang), but because Savi uses lld internally,
# we need to fix it up so that lld sees it as correct/valid.
#
# To do this, we use the `readelf` utility to get the address of this
# troublesome byte, and we use `dd` to directly patch it with a one byte.

set -eu
echo

if [ -z "$1" ]; then
  echo "Failed to patch!"
  echo "Please specify the path to libtensorflow.so as the argument to this script"
  exit 1
fi

lib_path=`realpath "$1"`
echo "Found $lib_path"

table_index=`readelf --dyn-syms "$lib_path" | grep curl_jmpenv | sed 's/ *//' | cut -d ':' -f 1`
echo "  - the curl_jmpenv dynamic symbol is at table index ${table_index}"

version_table_offset_hex=`readelf --sections "$lib_path" | grep '.gnu.version ' | rev | cut -d ' ' -f 1 | rev`
echo "  - the .gnu.version table is at hex offset: 0x${version_table_offset_hex}"

version_table_offset=`bash -c 'echo $((16#'$version_table_offset_hex'))'`
echo "    (that is, offset ${version_table_offset} in decimal)"

patch_offset=`bash -c 'echo $((2 * '$table_index' + '$version_table_offset'))'`
echo "  - therefore the curl_jmpenv version info uint16_t is at offset ${patch_offset}"

echo "  - patching a one byte into that position (assuming little-endian ELF)..."
`which printf` '\x01' | sudo dd of="$lib_path" bs=1 seek=$patch_offset count=1 conv=notrunc
