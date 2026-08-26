# Changelog

## v2.0.1
<!--Releasenotes start-->
- Internal changes to logging behaviour.
- Please review updates to the Privacy Policy.
<!--Releasenotes end-->

## v2.0.0

**This release requires the `Issues: Read and write` permission, which you will be asked to approve.** The permission is only used if you enable the new `create_issues` option, which is disabled by default - the app keeps working as before until you do.

- Added reporting for changed text files that were not checked because their file type is unsupported.
- Added a `check_inline_comments` option, disabled by default, to check comments appearing after code on the same line.
- Added a `standalone_items` option, disabled by default, to require action items to be surrounded by whitespace.
- Added a `check_drafts` option, disabled by default, to skip scanning draft Pull Requests until they are ready for review.
- Added the used configuration to each completed check run's details.
- Added check run annotations that show unresolved action items on their changed lines.
- Added a `post_annotations` option, enabled by default, to add check run/code annotations for each identified action item.
- Added a `create_issues` option, disabled by default, to create issues for unresolved action items, either through links and a check run action, or automatically.
- Added an `issue_labels` option to add labels to issues created by the app.
- Added a `create_issues_from_forks` option, disabled by default, controlling whether Pull Requests from forks may create issues.
- Changed the default value of `multiline_comments` to `false`, matching the documented safer behavior for partial Pull Request diffs.
- Changed Pull Requests from forks to be checked using the configuration of the branch they are being merged into, so that a fork cannot weaken or disable the check it is subject to.
- Changed `ignore_files` patterns to follow `.gitignore` conventions, as documented. Patterns are now anchored, so a pattern such as `*.js` no longer also ignores e.g. `.json` files.
- Fixed the documented default of `action_items` not matching the actual default, which caused the uppercase `TODO`, `FIXME` and `BUG` items to not be found when `case_sensitive` was enabled.
- Fixed `add_languages` entries with a `null` line comment being rejected, which silently discarded all configured languages.
- Fixed a malformed or unrelated `.github/config.yml` failing the check instead of falling back to the default options.
- Fixed added lines starting with a `+` not being checked for action items.
- Fixed files with uppercase extensions and extensionless files such as `.gitignore` not being checked.
- Fixed the app not finding its own comment on Pull Requests with more than 30 comments, which created a duplicate comment.
- Fixed configured action items containing regular expression characters not being matched correctly.
- Fixed action-item links pointing one line above the actual comment, which produced invalid line-zero links for action items on the first line of a file.
- Fixed code snippets not rendering for action items close to the end of a file, by shortening the snippet to the last line that exists.
- Fixed Pull Requests with many action items failing to report at all, by shortening the comment and check run summary to the length GitHub accepts.
- Fixed Perl assignments being treated as the start of a block comment when `multiline_comments` was enabled.

## v1.5.0

- Changed the app to run normal checks directly from Pull Request webhook events instead of Check suite requested events.
- Preserved individual and suite-level check re-runs from the GitHub UI while ignoring unrelated Check run and Check suite events before authenticating with the GitHub API.
- Changed valid but irrelevant webhook deliveries to return a successful `204` response instead of a `400` error.
- Corrected the documented environment variable name for the GitHub App identifier.

## v1.4.4

- Fixed an issue with Github having deprecated a request authentication header the App used for webhook validation.
- Bumped a number of dependencies to their latest versions.

## v1.4.3

- Bumped a number of dependencies to their latest versions.
- Fixed some mistakes in the Readme.

## v1.4.2

- Fixed the app not being able to run on PRs with more than 300 changed files.

## v1.4.1

- Fixed the default value of the `additional_lines` configuration option not being set to 1.

## v1.4.0

- Added a new `additional_lines` configuration option to control how many lines below action items are rendered in code snippets.
- Added a new `always_split_snippets` configuration option to control whether or not action items should always be rendered in seperate code snippets, even when they are located close to each other in code.
- The app now supports multiple line comment types for languages that have them, such as `//` and `#` for PHP.
- The check run initiated by the app will now be marked as skipped if no checkable changed files are found in the Pull Request.
- The check run summary will now include a list of skipped files.

## v1.3.2

- Renamed the `multiline_comments` configuration option.

## v1.3.1

- Both `.github/config.yml` and `.github/config.yaml` are now supported for the app's configuration.
- Fixed a number of misconfigurations when mapping file extensions to their comment delimiters.

## v1.3.0

- The app will now always include the results of the action item search in the check run summary.
- Added an option that allows you to ignore files that match a specific pattern. 
- Added an option to enable multiline block comments. This option is disabled by default, as it may cause the app to incorrectly identify action items.
- If the app encounters an error while the check is running, the check will now be concluded as neutral and the error message will be included in the check run summary.
- Fixed a bug where setting one of the values of the `add_languages` option to `null` would cause the app to not accept any new languages.
- Fixed a bug where the app would incorrectly classify a line as not being part of a block comment.

## v1.2.0

- Block comments that end one the same line they start on are now correctly identified as such.
- Improved the performance of the app by optimizing the way it looks for action items in the code.
- The app now supports setting options for the app in a `.github/config.yml` file.
- Added an option to control when the app should post a comment.
- Added an option to control which action items the app should look for.
- Added an option to add support for additional languages/file types.
- Added an option to control whether the app should look for action items in a case-sensitive manner.

## v1.1.3

- Replaced an exception with a 400 status code when the app receives a webhook event with en empty payload.

## v1.1.2

- The app now is more restrictive when handling received webhook events, meaning it only handles those events that are relevant to the app.
- The app now uses a more efficient and native way of getting Pull Request changes.
- Optimized some code paths to reduce the time it takes to process a Pull Request change.
- Improved the maintainability and readability of the app and its code.

## v1.1.1

- The server now sends a different status code if a webhook was received, but not handled.

## v1.1.0

- Action items no longer need to be free-standing, but may be pre- or post-fixed with special characters.
- Removed the table view from the comment posted by the app, as it was not very useful in most cases.
- Updated some styling in the comment posted by the app.
- Added a privacy policy.


## v1.0.0

- Initial release.
