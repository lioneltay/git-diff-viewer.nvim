#!/bin/bash
# Creates a git repo with every file state the plugin handles
set -e

DIR="${1:-/tmp/gdv-test-repo}"
rm -rf "$DIR"
mkdir -p "$DIR"
cd "$DIR"

git init
git config user.email "test@test.com"
git config user.name "Test User"
git config core.hooksPath /dev/null

# ─── Initial committed files ─────────────────────────────
mkdir -p src/components/shared src/utils docs

echo 'export function hello() { return "hello" }' > src/app.ts
echo 'export const add = (a, b) => a + b' > src/utils/math.ts
echo 'export const AUTH_KEY = "secret"' > src/utils/auth.ts
echo 'export function Button() { return <button/> }' > src/components/shared/Button.tsx
echo '# Project' > docs/README.md
echo '{ "name": "test" }' > package.json
echo 'line 1' > to-delete.txt
echo 'line 1' > to-delete-staged.txt
echo 'original name' > to-rename.txt
echo 'will conflict' > conflict-file.txt
printf '\x89PNG\r\n' > image.png  # binary file

git add .
git commit -m "initial commit"

# ─── Create branch for branch-mode testing ────────────────
git checkout -b feature/auth
echo 'export function login() { return true }' > src/auth.ts
echo 'modified on branch' >> src/app.ts
echo 'new util' > src/utils/validator.ts
rm docs/README.md
git mv to-rename.txt renamed-file.txt
git add .
git commit -m "feature: add auth"
git checkout main

# ─── More commits on main (to test merge-base) ───────────
echo 'main-only change' >> package.json
git add . && git commit -m "update package.json on main"

# ─── Working tree changes (for status mode) ──────────────
# Modified unstaged (_M)
echo 'modified content' >> src/app.ts

# Staged modified (M_)
echo 'staged change' >> src/utils/math.ts
git add src/utils/math.ts

# Both modified (MM) — staged then modified again
echo 'staged version' >> src/utils/auth.ts
git add src/utils/auth.ts
echo 'working tree version on top' >> src/utils/auth.ts

# Untracked new file (??)
echo 'new file' > src/new-file.ts

# Staged new file (A_)
echo 'staged new' > src/staged-new.ts
git add src/staged-new.ts

# Deleted unstaged (_D)
rm to-delete.txt

# Deleted staged (D_)
git rm to-delete-staged.txt

# Staged rename (R_)
git mv to-rename.txt renamed-result.txt

# Untracked in deep nested path (for compact folder testing)
mkdir -p src/components/shared/utils/helpers
echo 'deep file' > src/components/shared/utils/helpers/deep.ts

# Binary modified
printf '\x89PNG\r\nmodified' > image.png

echo ""
echo "Test repo created at: $DIR"
echo ""
echo "Status mode should show:"
echo "  Changes: src/app.ts (M), to-delete.txt (D), src/utils/auth.ts (MM),"
echo "           src/new-file.ts (?), image.png (M),"
echo "           src/components/shared/utils/helpers/deep.ts (?)"
echo "  Staged:  src/utils/math.ts (M), src/utils/auth.ts (MM),"
echo "           src/staged-new.ts (A), to-delete-staged.txt (D),"
echo "           renamed-result.txt (R)"
echo ""
echo "Branch mode (:GitDiffViewerBranch feature/auth main) should show:"
echo "  src/auth.ts (A), src/app.ts (M), src/utils/validator.ts (A),"
echo "  docs/README.md (D), renamed-file.txt (R)"
