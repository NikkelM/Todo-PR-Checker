# Changelog

## v1.4.3

<!--Releasenotes start-->
- Bumped a number of dependencies to their latest versions.
- Fixed some mistakes in the Readme.
<!--Releasenotes end-->

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
