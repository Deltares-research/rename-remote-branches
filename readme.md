# Rename remote branches

[rename_remote_branch.sh](./rename_remote_branch.sh) renames a local Git branch,
publishes it under the new name, and sets its upstream. The old remote branch is
kept by default; use `-d` or `--delete-old-upstream` to delete it after the new
branch has been pushed. The remote is determined from the old local branch's
upstream.

**Without `-d`, the script renames the local branch and pushes without prompting.
With `-d`, it requires explicit approval before renaming or pushing. There is no
dry-run mode or automatic rollback.**

## Requirements

- Bash, such as Git Bash on Windows. Do not run the script with PowerShell or `sh`.
- Git available on `PATH`.
- GNU-compatible `getopt` with long-option support.
- An existing local repository with the old branch present.
- An upstream remote branch with the same name as the old local branch.
- Network access and credentials allowing fetch and push. Remote branch deletion
  permission is needed only when `--delete-old-upstream` is used. Protected or
  default branches may require additional permissions or changes through the Git
  hosting service.

The script itself does not need to be tracked by Git.

## Configure the naming policy

Export the required `NEW_BRANCH_REGEX` environment variable in the Bash session
that will run the script:

```bash
export NEW_BRANCH_REGEX='^RWSOS-[0-9]+(-.+)?$'
```

This example requires:

- The literal prefix `RWSOS-`.
- One or more digits.
- An optional hyphen followed by a nonempty description.

Examples that match:

```text
RWSOS-1
RWSOS-1234
RWSOS-1234-some-description
```

The regex uses Bash extended regular expression syntax, not PCRE. Quote its value
to prevent shell expansion. Use `^` and `$` to require a full-name match;
unanchored patterns can match a substring.

The script exits with an `[ERR]` message if the variable is unset or empty, the
regex is invalid, or the new branch name does not match. There is no command-line
regex option or default pattern. Git's branch-name restrictions still apply.

## Usage

```text
bash rename_remote_branch.sh --repo <path> --old-branch-name <old_branch> --new-branch-name <new_branch> [--delete-old-upstream]
bash rename_remote_branch.sh -r <path> -o <old_branch> -n <new_branch> [-d]
```

| Option | Required | Description |
| --- | --- | --- |
| `-r`, `--repo <path>` | Yes | Path to the local repository. Quote paths containing spaces. |
| `-o`, `--old-branch-name <name>` | Yes | Existing local branch to rename. |
| `-n`, `--new-branch-name <name>` | Yes | New branch name matching `NEW_BRANCH_REGEX`. |
| `-d`, `--delete-old-upstream` | No | Delete the old remote upstream branch after pushing the new branch. Off by default; requires explicit approval and takes no value. |
| `-h`, `--help` | No | Print help and exit without requiring the environment variable. |

No remote-name argument is needed. The script uses the old branch's configured
upstream remote, which need not be named `origin`.

### Example in Git Bash

Replace the example paths and branch names with your own. The script targets the
repository passed with `--repo`, regardless of the current directory.

```bash
export NEW_BRANCH_REGEX='^RWSOS-[0-9]+(-.+)?$'

bash 'C:\tools\rename_remote_branches\rename_remote_branch.sh' \
  --repo 'C:\work\my-repo' \
  --old-branch-name 'old-name' \
  --new-branch-name 'RWSOS-1234-some-description'
```

The example discovers the upstream remote for `old-name`, renames the local
branch, pushes `RWSOS-1234-some-description`, and keeps `old-name` on that remote.

Alternatively, to delete the old upstream as part of the rename, use this command
instead:

```bash
bash 'C:\tools\rename_remote_branches\rename_remote_branch.sh' \
  --repo 'C:\work\my-repo' \
  --old-branch-name 'old-name' \
  --new-branch-name 'RWSOS-1234-some-description' \
  --delete-old-upstream
```

Deletion is attempted only after the new branch has been pushed and its upstream
has been set successfully.

## Deletion approval and merge requests

When `-d` or `--delete-old-upstream` is enabled, the script displays warnings and
asks for approval after preparation, but before any local rename or remote push.
Type exactly `yes` to continue.

**Deleting the old upstream branch will close any open merge request whose
source branch is that branch. It is YOUR responsibility to check whether a merge
request exists before approving deletion.**

**The script performs NO merge-request checks whatsoever. It does not query the
hosting service for merge-request information or check whether any merge request
exists or is open. The confirmation prompt is not evidence that deletion is
safe.**

Any response other than exactly `yes`, including an empty response, cancels the
operation with a nonzero exit status. Unavailable input or end-of-file also
cancels. No local rename, push, or upstream deletion is attempted after
cancellation; preparation may already have fetched the upstream.

When deletion is not requested, the script does not prompt and keeps the old
remote branch.

## Preparation checks

Before renaming, the script:

1. Validates the required arguments, environment variable, and regex match.
2. Verifies that the exact old local branch exists.
3. Resolves its upstream remote and requires the upstream branch name to match
   the old local branch name.
4. Fetches that upstream branch to verify accessibility and obtain its current
   tip in `FETCH_HEAD`.
5. Checks that the local branch contains all commits from the fetched upstream.
6. Confirms that the new branch name does not already exist on the remote.

The commit check allows these states:

| Local branch compared with fetched upstream | Result |
| --- | --- |
| Identical | Allowed |
| Ahead of upstream | Allowed; the additional local commits will also be pushed |
| Behind upstream | Rejected |
| Diverged | Rejected |

Fetching downloads commits but does not merge them into the local branch.
Preparation is not read-only: the fetch writes `FETCH_HEAD` and may update
remote-tracking refs.

## Rename operations

After preparation succeeds and any required deletion approval is obtained, the
script:

1. Renames the old local branch to the new name.
2. Unsets the renamed branch's previous upstream.
3. Pushes the new branch and sets its upstream.
4. Deletes the old remote branch only when `-d` or `--delete-old-upstream` is set;
   otherwise, logs that the old upstream is being kept.
5. Runs `git -C "$REPO_PATH" status`.

It does not migrate merge/pull requests to the new branch, update CI
configuration or repository default-branch settings, or update other developers'
clones.

## Logging and failures

Script-generated messages use these categories:

| Category | Stream | Meaning |
| --- | --- | --- |
| `[INFO]` | stdout | Progress and successful checks or operations |
| `[ERR]` | stderr | Validation or operation failures |
| `[WARN]` | stderr | Risk warnings, cancellation, and partial changes that need attention |

The internal logger accepts printf-style formatting and appends a newline:

```bash
log INFO "Renaming '%s' to '%s'." "$OLD_BRANCH" "$NEW_BRANCH"
```

Git and `getopt` may also print their own unprefixed diagnostics.

An exit status of `0` means the script completed. A nonzero status means a
validation or command failed, or required approval was not obtained; it does
**not** mean that no changes were made. If a later operation fails, the local
branch may already be renamed or the new remote branch may already exist.
Inspect local and remote state before retrying.

## Current limitations

- **The rename is not atomic.** There is no automatic rollback if a later
  operation fails.
- **Checks do not lock the remote.** Another push can change either branch
  between preparation and the rename operations. Avoid concurrent branch updates
  while running the script.
