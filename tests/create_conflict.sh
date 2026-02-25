#!/bin/bash
# Run inside an existing test repo to create merge conflicts
cd "${1:-.}"
git checkout -b conflict-branch
echo 'branch version' > conflict-file.txt
git add . && git commit -m "branch change"
git checkout main
echo 'main version' > conflict-file.txt
git add . && git commit -m "main change"
git merge conflict-branch || true  # creates merge conflict
