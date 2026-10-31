#!/bin/bash
# Reproduces Sources/COniguruma and Sources/CJQ from the jq and Oniguruma release
# tarballs: downloads them, checks their SHA-256, runs each configure script in a
# scratch folder under $TMPDIR, and copies exactly the files the jq library needs,
# replacing what is there.
#
# Usage: scripts/vendor.sh
set -euo pipefail

JQ_VERSION=1.8.2
JQ_SHA256=71b8d6e8f5fe81f6c6d0d110e3892251f6ce76ed095abd315e26e6e1193af3af
JQ_URL="https://github.com/jqlang/jq/releases/download/jq-$JQ_VERSION/jq-$JQ_VERSION.tar.gz"

ONIG_VERSION=6.9.10
ONIG_SHA256=2a5cfc5ae259e4e97f86b68dfffc152cdaffe94e2060b770cb827238d769fc05
ONIG_URL="https://github.com/kkos/oniguruma/releases/download/v$ONIG_VERSION/onig-$ONIG_VERSION.tar.gz"

# libjq as jq's Makefile.am builds it (LIBJQ_SRC, with the parser and lexer the
# tarball ships), without jq_test.c, which only the jq command uses.
JQ_SOURCES=(
  builtin.c bytecode.c compile.c execute.c jv.c jv_alloc.c jv_aux.c jv_dtoa.c
  jv_dtoa_tsd.c jv_file.c jv_parse.c jv_print.c jv_unicode.c lexer.c linker.c
  locfile.c parser.c util.c
)
JQ_HEADERS=(
  builtin.h bytecode.h compile.h exec_stack.h jq_parser.h jv_alloc.h jv_dtoa.h
  jv_dtoa_tsd.h jv_private.h jv_thread.h jv_unicode.h jv_utf8_tables.h lexer.h
  libm.h linker.h locfile.h opcode_list.h parser.h util.h
)
JQ_PUBLIC_HEADERS=(jq.h jv.h)
DECNUMBER_FILES=(decContext.c decContext.h decNumber.c decNumber.h decNumberLocal.h)

# The part of Oniguruma that jq's regex builtins reach: UTF-8 only, no POSIX or
# GNU API. unicode.c includes the four data files; they are not compiled alone.
ONIG_SOURCES=(
  ascii.c regcomp.c regenc.c regerror.c regexec.c regparse.c regsyntax.c st.c
  unicode.c unicode_fold1_key.c unicode_fold2_key.c unicode_fold3_key.c
  unicode_unfold_key.c utf8.c
)
ONIG_INCLUDED=(unicode_egcb_data.c unicode_fold_data.c unicode_property_data.c unicode_wb_data.c)
ONIG_HEADERS=(regenc.h regint.h regparse.h st.h)

package=$(cd "$(dirname "$0")/.." && pwd)
if [ ! -f "$package/Package.swift" ]; then
  echo "vendor.sh: no Package.swift in $package" >&2
  exit 1
fi

work=$(mktemp -d "${TMPDIR%/}/jq-vendor.XXXXXX")
trap 'rm -rf "$work"' EXIT

fail() {
  echo "vendor.sh: $*" >&2
  exit 1
}

# fetch URL SHA256 FILE
fetch() {
  curl --fail --silent --show-error --location --retry 3 --output "$3" "$1"
  local actual
  actual=$(shasum -a 256 "$3" | cut -d ' ' -f 1)
  [ "$actual" = "$2" ] || fail "SHA-256 of $1 is $actual, expected $2"
}

# configure SOURCE_DIR BUILD_DIR ARGS...
configure() {
  local source=$1 build=$2
  shift 2
  mkdir "$build"
  if ! (cd "$build" && "$source/configure" "$@" > configure.log 2>&1); then
    cat "$build/configure.log" >&2
    fail "configure failed in $source"
  fi
}

echo "Downloading jq $JQ_VERSION and Oniguruma $ONIG_VERSION"
fetch "$JQ_URL" "$JQ_SHA256" "$work/jq.tar.gz"
fetch "$ONIG_URL" "$ONIG_SHA256" "$work/onig.tar.gz"
mkdir "$work/jq-source" "$work/onig-source"
tar -xzf "$work/jq.tar.gz" -C "$work/jq-source"
tar -xzf "$work/onig.tar.gz" -C "$work/onig-source"
jq_src="$work/jq-source/jq-$JQ_VERSION"
onig_src="$work/onig-source/onig-$ONIG_VERSION"

echo "Configuring Oniguruma"
configure "$onig_src" "$work/onig-build" --disable-dependency-tracking

echo "Configuring jq"
# "builtin" stands for the Oniguruma jq bundles, the same release as above; it
# makes configure define HAVE_LIBONIG as a regular jq build does.
configure "$jq_src" "$work/jq-build" --disable-dependency-tracking --disable-docs \
  --with-oniguruma=builtin
make -C "$work/jq-build" src/builtin.inc > /dev/null

# jq's make passes configure's defines on the command line and builds with its
# PTHREAD_CFLAGS, so this header carries both; the CJQ target includes it first.
jq_cc=$(sed -n 's/^CC = //p' "$work/jq-build/Makefile")
pthread_cflags=$(sed -n 's/^PTHREAD_CFLAGS = //p' "$work/jq-build/Makefile")
{
  echo "/* jq $JQ_VERSION configuration, written by scripts/vendor.sh: the defines jq's"
  echo "   configure found (confdefs.h in config.log) and the macros its PTHREAD_CFLAGS"
  echo "   ($pthread_cflags) add. CJQ includes it before every source. Do not edit. */"
  echo
  awk '/^\/\* confdefs\.h \*\/$/ { inside = 1; next }
       /^configure: exit/ { inside = 0 }
       inside && /^#define / { print }' "$work/jq-build/config.log"
  # shellcheck disable=SC2086 # PTHREAD_CFLAGS may hold several flags
  comm -13 <($jq_cc -dM -E - < /dev/null | sort) \
    <($jq_cc $pthread_cflags -dM -E - < /dev/null | sort)
} > "$work/jq_config.h"
grep -q '^#define HAVE_LIBONIG 1$' "$work/jq_config.h" || fail "jq was configured without Oniguruma"
grep -q '^#define USE_DECNUM 1$' "$work/jq_config.h" || fail "jq was configured without decNumber"

echo "Copying sources"
stage="$work/stage"
mkdir -p "$stage/COniguruma/include" "$stage/COniguruma/src" \
  "$stage/CJQ/include" "$stage/CJQ/src" "$stage/CJQ/vendor/decNumber"

for file in "${ONIG_SOURCES[@]}" "${ONIG_INCLUDED[@]}" "${ONIG_HEADERS[@]}"; do
  cp "$onig_src/src/$file" "$stage/COniguruma/src/"
done
cp "$onig_src/src/oniguruma.h" "$stage/COniguruma/include/"
cp "$work/onig-build/src/config.h" "$stage/COniguruma/src/"
cp "$onig_src/COPYING" "$stage/COniguruma/"

for file in "${JQ_SOURCES[@]}" "${JQ_HEADERS[@]}"; do
  cp "$jq_src/src/$file" "$stage/CJQ/src/"
done
for file in "${JQ_PUBLIC_HEADERS[@]}"; do
  cp "$jq_src/src/$file" "$stage/CJQ/include/"
done
for file in "${DECNUMBER_FILES[@]}"; do
  cp "$jq_src/vendor/decNumber/$file" "$stage/CJQ/vendor/decNumber/"
done
cp "$work/jq-build/src/builtin.inc" "$stage/CJQ/src/"
cp "$work/jq_config.h" "$stage/CJQ/"
cp "$jq_src/COPYING" "$stage/CJQ/"

# The one change to jq: the jq command imports ~/.jq into every program it
# compiles. In process that would make every result depend on the user's home
# folder, so the library leaves it out.
linker="$stage/CJQ/src/linker.c"
[ "$(grep -c '^  jv home = get_home();$' "$linker")" = 1 ] || fail "linker.c changed; review the ~/.jq edit"
sed 's|^  jv home = get_home();$|  jv home = jv_invalid(); /* ~/.jq is not imported in process */|' \
  "$linker" > "$linker.edited"
mv "$linker.edited" "$linker"
! grep -q 'get_home()' "$linker" || fail "linker.c still imports ~/.jq"

rm -rf "$package/Sources/COniguruma" "$package/Sources/CJQ"
mkdir -p "$package/Sources"
cp -R "$stage/COniguruma" "$stage/CJQ" "$package/Sources/"

echo "Vendored jq $JQ_VERSION ($(find "$package/Sources/CJQ" -type f | wc -l | tr -d ' ') files)" \
  "and Oniguruma $ONIG_VERSION ($(find "$package/Sources/COniguruma" -type f | wc -l | tr -d ' ') files)"
