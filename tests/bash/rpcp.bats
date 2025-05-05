#!/usr/bin/env bats
#
# End-to-end tests for the Bash version of repocopy (rpcp.sh)
# ─────────────────────────────────────────────────────────────
# • Spins-up a temp repo each run (safe & hermetic)
# • Stubs xclip/pbcopy so we can inspect what hits the clipboard
# • Verifies:
#     1. happy-path copy & token replacement
#     2. max-file-size exclusion
#     3. override of max-file-size via CLI
#     4. folder-ignore pattern ("build")
#     5. behaviour when --show-copied-files is used
#
export BATS_LIB_PATH="$PWD/tests/test_helper"
load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
  # ── ① disposable sandbox repo ──────────────────────────────
  TMP_REPO="$(mktemp -d)"
  mkdir -p "$TMP_REPO/src" "$TMP_REPO/build"

  # source files
  printf 'hello ClientName\n' >"$TMP_REPO/src/include.txt"
  printf 'ignore me\n'        >"$TMP_REPO/manifest.json"
  head  -c 10 </dev/urandom  >"$TMP_REPO/image.png"

  # a 300-KiB file to test the size filter
  dd if=/dev/zero of="$TMP_REPO/src/big.bin" bs=1k count=300 2>/dev/null

  # something inside an ignored folder
  printf 'ignore me\n' >"$TMP_REPO/build/output.txt"

  # config.json that matches the Pester suite
  cat >"$TMP_REPO/config.json" <<'JSON'
{
  "repoPath": ".",
  "maxFileSize": 204800,
  "ignoreFolders": [ "build" ],
  "ignoreFiles": [ "manifest.json", "*.png", "config.json" ],
  "replacements": { "ClientName": "Bob" },
  "showCopiedFiles": false,
  "autoInstallDeps": false
}
JSON

  # ── ② stub clipboard (xclip) ───────────────────────────────
  CLIP_FILE="$(mktemp)"
  STUB_DIR="$(mktemp -d)"
  cat >"$STUB_DIR/xclip" <<STUB
#!/usr/bin/env bash
cat > "$CLIP_FILE"
STUB
  chmod +x "$STUB_DIR/xclip"
  PATH="$STUB_DIR:$PATH"
}

teardown() {
  rm -rf "$TMP_REPO" "$CLIP_FILE" "$STUB_DIR"
}

# helper to run rpcp.sh and slurp clipboard into $CLIP variable
run_rpcp() {
  run bash ./rpcp.sh "$@"
  # copy the clipboard text into a shell variable for assertions
  CLIP="$(cat "$CLIP_FILE")"
}

# ─────────────────────────────────────────────────────────────
@test "default run: copies only permitted files & replaces tokens" {
  run_rpcp --repo-path "$TMP_REPO" --config-file "$TMP_REPO/config.json"

  assert_success
  assert_line --partial "✅ Copied"    # sanity

  assert_regex "$CLIP" "include\\.txt"
  assert_regex "$CLIP" "hello Bob"

  refute_regex "$CLIP" "manifest\\.json"
  refute_regex "$CLIP" "image\\.png"
  refute_regex "$CLIP" "config\\.json"
  refute_regex "$CLIP" "output\\.txt"
  refute_regex "$CLIP" "big\\.bin"
}

@test "size filter: big.bin is excluded by default" {
  run_rpcp --repo-path "$TMP_REPO" --config-file "$TMP_REPO/config.json"
  refute_regex "$CLIP" "big\\.bin"
}

@test "size override: big.bin appears when --max-file-size 0 is used" {
  run_rpcp --repo-path "$TMP_REPO" \
           --config-file "$TMP_REPO/config.json" \
           --max-file-size 0
  assert_regex "$CLIP" "big\\.bin"
}

@test "folder ignore: anything under build/ is skipped" {
  run_rpcp --repo-path "$TMP_REPO" --config-file "$TMP_REPO/config.json"
  refute_regex "$CLIP" "build/output\\.txt"
}

@test "--show-copied-files does not affect clipboard content" {
  run_rpcp --repo-path "$TMP_REPO" \
           --config-file "$TMP_REPO/config.json" \
           --show-copied-files

  # The script prints the file list to stdout;
  # we just need to ensure normal data is still on the clipboard
  assert_regex "$CLIP" "include\\.txt"
}
