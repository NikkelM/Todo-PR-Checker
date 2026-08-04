This folder contains files that exercise the default action-item detection behavior for supported comment styles.

The automated test suite scans every fixture and verifies the exact alert lines. Each fixture's first `TODO` comment records the expected number of alerts produced with default options.

`validation-options.js` isolates action-item matching edge cases. The validation test suite checks its exact alert lines across all 16 combinations of `check_inline_comments`, `standalone_items`, `multiline_comments`, and `case_sensitive`.
