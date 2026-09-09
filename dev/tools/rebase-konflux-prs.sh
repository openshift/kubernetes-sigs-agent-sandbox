#!/bin/bash

# Ensure gh CLI is installed
if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI (gh) is not installed. Please install it first."
    exit 1
fi

# Ensure working directory is clean before switching branches
if [ -n "$(git status --porcelain)" ]; then
    echo "Error: Your working directory is not clean. Please commit or stash your changes first."
    exit 1
fi

echo "Fetching latest origin/main..."
git fetch origin main

# Fetch the list of open PRs (number and branch name)
PRS=$(gh pr list --state open --json number,headRefName --jq '.[] | "\(.number) \(.headRefName)"')

if [ -z "$PRS" ]; then
    echo "No open PRs found."
    exit 0
fi

# Read through the PRs line by line
echo "$PRS" | while read -r PR_NUM BRANCH; do
    echo "------------------------------------------------------------"
    
    # Read user input directly from the terminal
    read -p "Do you want to rebase PR #$PR_NUM ($BRANCH) on main? [y/N]: " confirm </dev/tty

    if [[ "$confirm" =~ ^[Yy](es)?$ ]]; then
        echo "Checking out PR #$PR_NUM ($BRANCH)..."
        gh pr checkout "$PR_NUM"
        
        echo "Rebasing $BRANCH on origin/main..."
        if git rebase origin/main; then
            echo "Rebase successful. Force pushing..."
            if git push --force-with-lease origin "$BRANCH"; then
                echo "Successfully force-pushed PR #$PR_NUM."
                
                # Switch away from the PR branch so it can be deleted
                echo "Cleaning up local branch $BRANCH..."
                git checkout main
                git branch -D "$BRANCH"
            else
                echo "Failed to push $BRANCH."
            fi
        else
            echo "Merge conflicts detected or rebase failed for $BRANCH!"
            echo "Aborting rebase and skipping to the next PR."
            git rebase --abort
            
            # Optional: Clean up the local branch even if the rebase failed
            # git checkout main
            # git branch -D "$BRANCH"
        fi
    else
        echo "Skipping PR #$PR_NUM ($BRANCH)."
    fi
done

# Ensure we end up back on main at the very end
git checkout main &> /dev/null

echo "------------------------------------------------------------"
echo "All done!"
