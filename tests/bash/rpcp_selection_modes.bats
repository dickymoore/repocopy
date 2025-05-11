#!/usr/bin/env bats
#
# Tests for the selection modes feature of repocopy (rpcp.sh)
# ─────────────────────────────────────────────────────────────
# • Tests the four selection modes:
#     1. filelist - only copy files listed in fileListPath
#     2. scanlist - union of filelist and normal scan behavior
#     3. listfilter - start with filelist, then apply filters
#     4. scan (default) - original behavior
#
export BATS_LIB_PATH="$PWD/tests/test_helper"
load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
  # ── ① disposable sandbox repo ──────────────────────────────
  TMP_REPO="$(mktemp -d)"
  mkdir -p "$TMP_REPO/src/include-dir" "$TMP_REPO/build"

  # Create content files
  printf 'hello ClientName\n' >"$TMP_REPO/src/main.txt"
  printf 'include me\n' >"$TMP_REPO/src/include-dir/file1.txt"
  printf 'include me too\n' >"$TMP_REPO/src/include-dir/file2.txt"
  printf 'ignore me\n' >"$TMP_REPO/manifest.json"
  head -c 10 </dev/urandom >"$TMP_REPO/image.png"

  # Create a file that should be excluded by size
  dd if=/dev/zero of="$TMP_REPO/src/big.bin" bs=1k count=300 2>/dev/null

  # Something inside an ignored folder
  printf 'build artifact\n' >"$TMP_REPO/build/output.txt"

  # Create the fileListPath document
  cat >"$TMP_REPO/affected.md" <<'MARKDOWN'
### Files to include

src/include-dir/file1.txt
manifest.json
build/output.txt
MARKDOWN

  # Base config.json
  cat >"$TMP_REPO/config.json" <<'JSON'
{
  "repoPath": ".",
  "maxFileSize": 204800,
  "ignoreFolders": [ "build" ],
  "ignoreFiles": [ "manifest.json", "*.png", "config.json" ],
  "replacements": { "ClientName": "Redacted_name" },
  "showCopiedFiles": false,
  "autoInstallDeps": false,
  "selectionMode": "scan",
  "fileListPath": "affected.md"
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

# Helper to run rpcp.sh and get clipboard content
run_rpcp() {
  # Create a modified config for this run
  if [ "$1" != "" ]; then
    SELECTION_MODE="$1"
    jq ".selectionMode = \"$SELECTION_MODE\"" "$TMP_REPO/config.json" > "$TMP_REPO/tmp.json"
    mv "$TMP_REPO/tmp.json" "$TMP_REPO/config.json"
  fi
  
  run bash ./rpcp.sh --repo-path "$TMP_REPO" --config-file "$TMP_REPO/config.json"
  # Copy the clipboard text into a shell variable for assertions
  CLIP="$(cat "$CLIP_FILE")"
}

# ─────────────────────────────────────────────────────────────
@test "selectionMode=filelist: copies only files from fileListPath" {
  run_rpcp "filelist"

  assert_success
  assert_line --partial "✅ Copied"    # sanity check
  
  # Should include files from the list
  assert_regex "$CLIP" "include-dir/file1\\.txt"
  assert_regex "$CLIP" "ClientName"   # Ensures replacements still work

  # Should NOT include files not in the list, even if they'd pass filters
  refute_regex "$CLIP" "main\\.txt"
  refute_regex "$CLIP" "file2\\.txt"
  
  # Files that are in the list but would normally be excluded
  assert_regex "$CLIP" "manifest\\.json"
  assert_regex "$CLIP" "build/output\\.txt"
  
  # Big files should be included if in the list
  refute_regex "$CLIP" "big\\.bin"  # Not in the list
}

@test "selectionMode=scanlist: union of fileListPath and normal scan" {
  run_rpcp "scanlist"

  assert_success
  
  # Should include files from the list
  assert_regex "$CLIP" "include-dir/file1\\.txt"
  
  # Should also include files that pass normal scan filters
  assert_regex "$CLIP" "main\\.txt"
  assert_regex "$CLIP" "include-dir/file2\\.txt"
  
  # Files in the list but normally excluded should be included
  assert_regex "$CLIP" "manifest\\.json"
  assert_regex "$CLIP" "build/output\\.txt"
  
  # Files excluded by normal scan and not in the list should still be excluded
  refute_regex "$CLIP" "image\\.png"
  refute_regex "$CLIP" "big\\.bin"
}

@test "selectionMode=listfilter: fileListPath files subject to filters" {
  run_rpcp "listfilter"

  assert_success
  
  # Files in the list that pass filters should be included
  assert_regex "$CLIP" "include-dir/file1\\.txt"
  
  # Files in the list but excluded by filters should NOT be included
  refute_regex "$CLIP" "manifest\\.json"
  refute_regex "$CLIP" "build/output\\.txt"
  
  # Files not in the list should not be included regardless of filters
  refute_regex "$CLIP" "main\\.txt"
  refute_regex "$CLIP" "file2\\.txt"
  refute_regex "$CLIP" "image\\.png"
  refute_regex "$CLIP" "big\\.bin"
}

@test "selectionMode=scan (default): original scan-only behavior" {
  run_rpcp "scan"

  assert_success
  
  # Original behavior - include files that pass filters
  assert_regex "$CLIP" "main\\.txt"
  assert_regex "$CLIP" "include-dir/file1\\.txt"
  assert_regex "$CLIP" "include-dir/file2\\.txt"
  
  # Files excluded by filters should not be included
  refute_regex "$CLIP" "manifest\\.json"
  refute_regex "$CLIP" "build/output\\.txt"
  refute_regex "$CLIP" "image\\.png"
  refute_regex "$CLIP" "big\\.bin"
  
  # Check that the fileListPath content is ignored
  refute_regex "$CLIP" "affected\\.md"
}

@test "Missing selectionMode in config defaults to scan behavior" {
  # Remove selectionMode from config
  jq 'del(.selectionMode)' "$TMP_REPO/config.json" > "$TMP_REPO/tmp.json"
  mv "$TMP_REPO/tmp.json" "$TMP_REPO/config.json"
  
  run bash ./rpcp.sh --repo-path "$TMP_REPO" --config-file "$TMP_REPO/config.json"
  CLIP="$(cat "$CLIP_FILE")"
  
  assert_success
  
  # Should behave like scan mode
  assert_regex "$CLIP" "main\\.txt"
  refute_regex "$CLIP" "manifest\\.json"
  refute_regex "$CLIP" "build/output\\.txt"
}