#!/usr/bin/env bash
# Rebuild the entire ghc-in-browser rootfs from scratch, with extra packages
# (miso) baked in. Everything — the in-browser compiler (libplayground001.so),
# the GHC boot libs, and miso — is built with ONE pinned wasm GHC, so it's all
# ABI-consistent by construction.
#
# Adapted from the upstream recipe:
#   ghc/testsuite/tests/ghc-api-browser/{playground001.hs,playground001.sh}
#
# Requires: nix, zstd. Run from the repo root: ./build-rootfs.sh
# Outputs: rootfs.tar.zst  (and updates the hardcoded searchdir in index.html
#          + refreshes dyld/post-link/prelude .mjs to match the new GHC).

set -euo pipefail
# set -x

# Pinned wasm toolchain. rev 22fedfa => GHC 9.14.0.20251101. Bump this to move
# the whole playground to a newer GHC; everything stays self-consistent.
FLAKE="git+https://gitlab.haskell.org/ghc/ghc-wasm-meta?rev=22fedfad9958d195a69431fa8156710b862be821"
EXTRA_BUILD_DEPS="base, miso"   # third-party libs to bake into the rootfs

REPO="$(cd "$(dirname "$0")" && pwd)"
OUT="$REPO/rootfs.tar.zst"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$REPO/playground001.hs" ] || { echo "ERROR: $REPO/playground001.hs missing" >&2; exit 1; }
cp "$REPO/playground001.hs" "$WORK/playground001.hs"
printf '%s\n' "$EXTRA_BUILD_DEPS" > "$WORK/extra-deps"

echo "==> work dir: $WORK"
echo "==> toolchain: $FLAKE"

# ── the heavy lifting runs inside the pinned nix shell (verbatim, no host
#    expansion — config is passed via the files staged above) ──────────────────
cat > "$WORK/inner.sh" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail

# Use /tmp for the build and store to avoid path length issues and filesystem 
# quirks that cause Cabal's atomic rename operations to fail.
BUILD_DIR="/tmp/ghc-in-browser-build-$$"
STORE_DIR="/tmp/ghc-in-browser-store-$$"
trap 'rm -rf "$BUILD_DIR" "$STORE_DIR"' EXIT

TEST_HC=$(command -v wasm32-wasi-ghc)
GHC_PKG=$(command -v wasm32-wasi-ghc-pkg)
TEST_CC=$(command -v wasm32-wasi-clang)
GHC_VER=$("$TEST_HC" --numeric-version)
echo "==> building everything with GHC $GHC_VER"

mkdir -p tmp

# 1. the in-browser compiler ──────────────────────────────────────────────────
echo "==> [1/6] libplayground001.so"
"$TEST_HC" -v0 -package ghc -shared -dynamic \
  -no-keep-hi-files -no-keep-o-files -O2 \
  playground001.hs -o ./tmp/libplayground001.so
rm -f ./*_stub.h

# 2. /tmp/clib — wasi-sysroot dynamic C/C++ libs ──────────────────────────────
echo "==> [2/6] /tmp/clib"
SYSROOT="$(dirname "$TEST_CC")/../share/wasi-sysroot/lib/wasm32-wasi"
cp -rL "$SYSROOT" ./tmp/clib
chmod -R u+w ./tmp/clib
find ./tmp/clib -type f ! -name "*.so" -delete
rm -f ./tmp/clib/libsetjmp.so ./tmp/clib/libwasi-emulated-*.so
# GHC/miso may request the C++ ABI lib under the double-prefixed name liblibc++abi.so
[ -f ./tmp/clib/libc++abi.so ] && cp ./tmp/clib/libc++abi.so ./tmp/clib/liblibc++abi.so || true

# 3. /tmp/hslib/lib — the GHC libdir (+ stash the runtime .mjs) ────────────────
echo "==> [3/6] /tmp/hslib/lib"
mkdir -p ./tmp/hslib
cp -rL "$("$TEST_HC" --print-libdir)" ./tmp/hslib/lib
chmod -R u+w ./tmp/hslib/lib
mkdir -p mjs && cp ./tmp/hslib/lib/*.mjs mjs/ 2>/dev/null || true
PKGDB="$PWD/tmp/hslib/lib/package.conf.d"

# Unregister Cabal if it exists (suppress errors if it doesn't)
"$GHC_PKG" --no-user-package-db --global-package-db="$PKGDB" unregister --force Cabal Cabal-syntax 2>/dev/null || true

# 4. build the extra packages (miso) with the SAME compiler ────────────────────
echo "==> [4/6] building extra packages (miso, base)"

rm -rf "$BUILD_DIR" "$STORE_DIR"
mkdir -p "$BUILD_DIR/proj" "$STORE_DIR"

cat > "$BUILD_DIR/proj/cabal.project" <<EOF
packages: .
package *
  shared: True
  library-for-ghci: False
EOF
cat > "$BUILD_DIR/proj/pkgs.cabal" <<EOF
cabal-version: 3.0
name: pkgs
version: 1.0
library
  build-depends: base, miso
  default-language: Haskell2010
EOF

# Run cabal with -j1 to prevent concurrent store write races
( cd "$BUILD_DIR/proj" && \
  wasm32-wasi-cabal update && \
  wasm32-wasi-cabal --store-dir="$STORE_DIR" -j1 build all )

# Cabal appends an ABI hash to the store directory name. Dynamically find it.
STORE=$(find "$STORE_DIR" -maxdepth 1 -type d -name "ghc-${GHC_VER}*" | head -1)
if [ -z "$STORE" ]; then
  echo "ERROR: Cabal store directory not found in $STORE_DIR" >&2
  exit 1
fi
PKGDB_STORE="$STORE/package.db"

# 5. inject the new packages into the libdir (relocatable ${pkgroot} confs) ────
echo "==> [5/6] injecting packages"
SEARCHDIR=$(find ./tmp/hslib/lib -name "libHSbase-*-ghc${GHC_VER}.so" -printf '%h\n' | head -1)
[ -n "$SEARCHDIR" ] || { echo "ERROR: could not locate the boot-lib searchdir" >&2; exit 1; }
INPLACE=$(basename "$SEARCHDIR")
echo "    searchdir: $SEARCHDIR"

# Use find + basename to get package IDs, avoiding any parsing issues with id: fields
mapfile -t EXISTING < <(find "$PKGDB" -maxdepth 1 -name "*.conf" -exec basename {} .conf \;)
injected=0
for conf in "$PKGDB_STORE"/*.conf; do
  [ -f "$conf" ] || continue
  
  # The package ID is exactly the filename without the .conf extension
  pid=$(basename "$conf" .conf)
  
  # Safely check if package is already in the global DB
  if [ ${#EXISTING[@]} -gt 0 ]; then
    if printf '%s\n' "${EXISTING[@]}" | grep -qxF "$pid"; then
      continue
    fi
  fi
  
  echo "    + $pid"

  # Copy shared library if it exists (no need to parse hs-libraries field)
  so=$(find "$STORE/$pid" -name "libHS*-ghc${GHC_VER}.so" -print -quit)
  if [ -n "$so" ]; then
    cp "$so" "$SEARCHDIR/$(basename "$so")"
  fi

  # Copy interface files — find the shallowest dir containing .dyn_hi (= import root)
  hidir=$(find "$STORE/$pid" -name '*.dyn_hi' -printf '%h\n' \
            | awk 'BEGIN{min=-1} {n=gsub(/\//,"/"); if(min<0||n<min){min=n;best=$0}} END{print best}')
  [ -n "$hidir" ] || { echo "ERROR: no .dyn_hi for $pid" >&2; exit 1; }
  mkdir -p "$SEARCHDIR/$pid"
  cp -r "$hidir/." "$SEARCHDIR/$pid/"

  # Rewrite paths in the .conf file to be relocatable
  INPLACE="$INPLACE" PID="$pid" python3 - "$conf" > "$PKGDB/$pid.conf" <<'PY'
import sys, os, re
src = sys.argv[1]
inplace = os.environ['INPLACE']
pid = os.environ['PID']
base = "$topdir/" + inplace

# Read file and strip any carriage returns to prevent ghc-pkg issues
t = open(src).read().replace('\r', '')

t = re.sub(r'(?m)^import-dirs:.*(\n    .*)*',          'import-dirs:\n    ' + base + '/' + pid, t)
t = re.sub(r'(?m)^library-dirs:.*(\n    .*)*',         'library-dirs:\n    ' + base + '/' + pid, t)
t = re.sub(r'(?m)^library-dirs-static:.*(\n    .*)*',  'library-dirs-static:\n    ' + base + '/' + pid, t)
t = re.sub(r'(?m)^dynamic-library-dirs:.*(\n    .*)*', 'dynamic-library-dirs:\n    ' + base, t)
t = re.sub(r'(?m)^haddock-.*(\n    .*)*\n?', '', t)
t = re.sub(r'(?m)^data-dir:.*(\n    .*)*\n?', '', t)
t = re.sub(r'(?m)^pkgroot:.*\n?', '', t)
sys.stdout.write(t)
PY
  injected=$((injected + 1))
done
[ "$injected" -gt 0 ] || { echo "ERROR: no packages injected" >&2; exit 1; }

# 6. recache, validate, trim ──────────────────────────────────────────────────
echo "==> [6/6] recache + validate + trim"
"$GHC_PKG" --no-user-package-db --global-package-db="$PKGDB" recache
"$GHC_PKG" --no-user-package-db --global-package-db="$PKGDB" check || true
"$GHC_PKG" --no-user-package-db --global-package-db="$PKGDB" list --simple-output \
  | tr ' ' '\n' | grep -qi '^miso-' \
  || { echo "ERROR: miso did not register in the rootfs package db" >&2; exit 1; }

find ./tmp/hslib/lib "(" \
  -name "*.hi" -o -name "*.a" -o -name "*.p_hi" -o -name "libHS*_p.a" \
  -o -name "*.p_dyn_hi" -o -name "libHS*_p*.so" -o -name "libHSrts*_debug*.so" \
  ")" -delete
rm -rf ./tmp/hslib/lib/doc ./tmp/hslib/lib/html ./tmp/hslib/lib/latex \
       ./tmp/hslib/lib/*.mjs ./tmp/hslib/lib/*.js ./tmp/hslib/lib/*.txt
rm -rf "$SEARCHDIR"/*Cabal* || true

# in-rootfs absolute searchdir (./tmp/... -> /tmp/...) for the host step
printf '%s\n' "/${SEARCHDIR#./}" > searchdir.txt

# 7. generate completions.json from .dyn_hi interface files ───────────────────
echo "==> [7/7] generating completions.json"
python3 - "$PKGDB" "$TEST_HC" "$GHC_PKG" <<'COMPLETIONS_PY'
import subprocess, json, re, os, sys

pkgdb, ghc, ghc_pkg = sys.argv[1], sys.argv[2], sys.argv[3]
LIB = "./tmp/hslib/lib"
# Packages to index; others (rts, ghc-internal, etc.) are skipped
KEEP = {"base", "miso", "containers", "text", "bytestring",
        "transformers", "mtl", "unordered-containers", "vector", "aeson"}

def run(*cmd, **kw):
    return subprocess.run(list(cmd), capture_output=True, text=True, **kw)

def pkg_name(ver_string):
    return re.sub(r'-[0-9][0-9.]*(?:-[a-z0-9]+)?$', '', ver_string)

all_ver = run(ghc_pkg, "--no-user-package-db",
              f"--global-package-db={pkgdb}", "list", "--simple-output").stdout.split()
pkg_map = {pkg_name(v): v for v in all_ver}

def exposed_modules(pkg_ver):
    r = run(ghc_pkg, "--no-user-package-db", f"--global-package-db={pkgdb}",
            "field", pkg_ver, "exposed-modules", "--simple-output")
    return r.stdout.split()

def find_hi(module):
    rel = module.replace(".", os.sep) + ".dyn_hi"
    for dirpath, _, files in os.walk(LIB):
        cand = os.path.join(dirpath, rel)
        if os.path.exists(cand):
            return cand
    return None

FN_RE   = re.compile(r'^([a-z_][a-zA-Z0-9_\']*)\s*::\s*(.+)$')
OP_RE   = re.compile(r'^\(([!#$%&*+./<=>?@\\^|\-~:]+)\)\s*::\s*(.+)$')
CON_RE  = re.compile(r'^([A-Z][a-zA-Z0-9_\']*)\s*::\s*(.+)$')
DATA_RE = re.compile(r'^(?:data|newtype)\s+([A-Z][a-zA-Z0-9_\']*)')
TYPE_RE = re.compile(r'^type\s+([A-Z][a-zA-Z0-9_\']*)')
CLS_RE  = re.compile(r'^class\b.+\b([A-Z][a-zA-Z0-9_\']*)\b')

def parse_iface(hi_file, module):
    try:
        r = run(ghc, "--show-iface", hi_file, timeout=60)
    except Exception:
        return []
    if r.returncode != 0:
        return []
    seen, syms = set(), []
    def add(name, kind, typ=None):
        if name in seen:
            return
        seen.add(name)
        e = {"name": name, "module": module, "kind": kind}
        if typ:
            # strip GHC-internal module prefixes like "GHC.Base."
            typ = re.sub(r'\bGHC(?:\.[A-Za-z]+)+\.', '', typ)
            e["type"] = typ[:150]
        syms.append(e)
    for line in r.stdout.splitlines():
        s = line.strip()
        if not s or s.startswith('{') or s.startswith('--'):
            continue
        m = FN_RE.match(s);   m and add(m.group(1), 'function',    m.group(2)) or None
        m = OP_RE.match(s);   m and add(m.group(1), 'operator',    m.group(2)) or None
        m = CON_RE.match(s);  m and add(m.group(1), 'constructor', m.group(2)) or None
        m = DATA_RE.match(s); m and add(m.group(1), 'type') or None
        m = TYPE_RE.match(s); m and add(m.group(1), 'type') or None
        m = CLS_RE.match(s);  m and m.group(1) and add(m.group(1), 'typeclass') or None
    return syms

output, seen_keys = [], set()
for pkg in sorted(KEEP & set(pkg_map)):
    for mod in exposed_modules(pkg_map[pkg]):
        hi = find_hi(mod)
        if not hi:
            continue
        try:
            for sym in parse_iface(hi, mod):
                k = (sym["module"], sym["name"])
                if k not in seen_keys:
                    seen_keys.add(k)
                    output.append(sym)
        except Exception as e:
            print(f"    warn: {mod}: {e}", file=sys.stderr)

with open("completions.json", "w") as f:
    json.dump(output, f, separators=(",", ":"))
print(f"    {len(output)} completions from {len(seen_keys)} unique symbols")
COMPLETIONS_PY

echo "==> inner build complete"
INNER

nix shell \
  "$FLAKE#wasm32-wasi-ghc-9_14" \
  "$FLAKE#wasm32-wasi-cabal-9_14" \
  "$FLAKE#wasi-sdk" \
  -c bash -c "cd '$WORK' && bash '$WORK/inner.sh'"

# ── host side: refresh repo glue, fix index.html, pack ────────────────────────
SEARCHDIR_ABS=$(cat "$WORK/searchdir.txt")
echo "==> rootfs searchdir: $SEARCHDIR_ABS"

# keep the runtime .mjs in sync with the new GHC
cp "$WORK"/mjs/*.mjs "$REPO"/ 2>/dev/null || true

# refresh the completions index if the build generated one
[ -f "$WORK/completions.json" ] && cp "$WORK/completions.json" "$REPO/completions.json" && \
  echo "==> updated completions.json" || true

# repoint the hardcoded searchdir in index.html
python3 - "$REPO/index.html" "$SEARCHDIR_ABS" <<'PY'
import sys, re
path, new = sys.argv[1], sys.argv[2]
s = open(path).read()
s = re.sub(r"/tmp/hslib/lib/wasm32-wasi-ghc-[^\"']*", new, s)
open(path, "w").write(s)
PY

echo "==> packing $OUT"
tar -C "$WORK" -cf "$WORK/rootfs.tar" tmp
zstd -19 -T0 -f "$WORK/rootfs.tar" -o "$OUT"

echo ""
echo "Done. Wrote $OUT and updated index.html (searchdir: $SEARCHDIR_ABS)."
