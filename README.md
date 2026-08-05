<h1 align="center">Todo PR Checker</h1>

<p align="center">
  <a href="https://github.com/marketplace/todo-pr-checker">
    <img src="./development/images/icon/images/icon.png" width="150" alt="Todo PR Checker">
  </a>
  </br>
  <i>Get the app on the <a href="https://github.com/marketplace/todo-pr-checker">GitHub Marketplace</a></i>
</p>

Do you keep forgetting to resolve that one `// TODO:...` or fix the last ` # Bug...` before merging your Pull Requests?

The Todo PR Checker will make sure that doesn't happen anymore.
The app checks all code changes in your open Pull Requests for remaining `Todo`, `Fixme` etc. action items in code comments and leaves a comment on the PR with embedded code snippets to any items that were found.

This list will update whenever new changes are pushed, so you always know exactly how much work is left.

The app supports a wide array of programming languages and action items.
Should you find that your language of choice or action item is not supported out-of-the-box, you can easily configure the app to support it.

To minimize falsely identified comments (e.g. the characters that start a comment are contained in a string), the app only looks for action items when the comment starts on its own line by default.
The following examples are not flagged unless `check_inline_comments` is enabled:

```javascript
let variable = true; // TODO: This action items won't be detected

let otherVar = false; /*
Because if the comment does not start on its own line, the app skips it by default
TODO: Use the check_inline_comments option to detect both of these cases
*/
```

Action items may be directly adjacent to punctuation by default, such as `TODO:` or `(TODO)`. Enable `standalone_items` to require whitespace around an action item.

Additionally, support for multiline comments is *disabled* by default, as it may cause the app to incorrectly identify action items if the opening or closing characters of the block comment are not included in the Pull Request diff.
You may enable support for multiline comments in the options, see the section below.

## Options

This app supports the `.github/config.yml` file to configure options.
You can use this file to support additional programming languages, action items, and more.

To configure options, add a `todo-pr-checker` key at the top-level of your `.github/config.yml` file:

```yaml
todo-pr-checker:
  post_comment: 'items_found'
  ignore_files: ['testFolder/', '*.js']
  (...)
```

To get started, you can copy the `.github/config.yml` file from this repository and adjust it to your needs.

### Available options

| Option | Possible Values | Description | Default |
| --- | --- | --- | --- |
| `post_comment` | `items_found`, `always`, `never` | Controls when the app should post a comment. By default, a comment is only posted if an action item has been found. If set to `never`, the check will still fail. If set to `always`, the app will post a comment that all action items have been resolved if none are found. | `items_found` |
| `post_annotations` | `true`, `false` | Controls whether the app should annotate changed lines containing unresolved action items. | `true` |
| `create_issues` | `never`, `links`, `always` | Controls whether issues are created for unresolved action items. If set to `links`, the comment contains a link per action item that opens a prefilled new issue form. If set to `always`, an issue is created automatically for each identified action item. Issues are only created once per action item, even if the check runs again, and are not updated afterwards. | `never` |
| `create_issues_from_forks` | `true`, `false` | Controls whether Pull Requests opened from a fork may create issues in your repository. | `false` |
| `issue_labels` | `string[]`, maximum 10 entries | A list of labels to add to issues created by the app. | `[]` |
| `check_drafts` | `true`, `false` | Controls whether draft Pull Requests are checked. | `false` |
| `ignore_files` | `string[]`, maximum 7 entries | A list of glob patterns to specify files that should be ignored during the check. You may specify up to 7 patterns. The pattern matching logic used is the same as for `.gitignore` files. | `null` |
| `action_items` | `string[]`, maximum 15 entries | A list of action items to look for in code comments. If you set this option, the default values will be overwritten, so you must include them in your list to use them. By default, action items are case insensitive. You may specify up to 15 items. | `['TODO', 'FIXME', 'BUG']` |
| `add_languages` | `[string[file_type, line_start, block_start, block_end]]`</br>Example: `[['js', '//', '/*', '*/'], ['php', ['//', '#'], '/*', '*/'], ['css', null, '/*', '*/'], ['.py', '#']]`, maximum 10 entries | A list of a list of programming languages to add support for. This list will be added to the already supported languages. If you define a language that is already supported, the default values will be overwritten. `file_type` must be the extension of the file (e.g. `js`) and may start with a `.`. If the file type you are adding supports multiple line comment types, you may define an `array` of `strings` instead of just a `string`. You may omit the block comment definitions if the file type does not support block comments. If you want to omit the definition of a line comment, you may set `line_start` to `null` or omit it. If defining `block_start`, `block_end` must also be defined. You may specify up to 10 new file types. *The file types shown in the example are already natively supported by the app.* | `null` |
| `additional_lines` | `integer` between `0` and `10` | The number of additional lines to include below found action items in embedded code snippets. If set to `0`, the code snippet shows only the line with the action item. This setting does not influence the behaviour of showing multiple action items in one snippet if they are located close to each other. | `1` |
| `case_sensitive` | `true`, `false` | Controls whether the app should look for action items in a case-sensitive manner. | `false` |
| `check_inline_comments` | `true`, `false` | Controls whether comments appearing after code on the same changed line are checked. Enabling this may cause false positives when comment characters occur inside strings. | `false` |
| `standalone_items` | `true`, `false` | Controls whether action items must be surrounded by whitespace. If enabled, punctuation-adjacent values such as `TODO:` and `(TODO)` are not matched. | `false` |
| `multiline_comments` | `true`, `false` | Whether or not looking for action items in multiline block comments is enabled or not. When enabled, the app *may* incorrectly mark action items in your Pull Request if at least one of the opening or closing line of the block comment (e.g. `*/` and `/*` in JavaScript) are not included in the Pull Request diff, which causes them to not be found by the app. For multiline comments to always work, you must ensure that both the opening and closing characters are included in the diff. Action items located on the first line of a block comment will always be detected, even if this option is disabled. | `false` |
| `always_split_snippets` | `true`, `false` | Whether or not action items should always be rendered in separate code snippets, even when they are located close to each other in code. | `false` |

<details>
<summary>Expand me to see the currently supported file types:</summary>
<ul>
  <li><code>.astro</code></li>
  <li><code>.bash</code></li>
  <li><code>.c</code>, <code>.cpp</code>, <code>.cs</code>, <code>.css</code></li>
  <li><code>.dart</code></li>
  <li><code>.gitignore</code>, <code>.go</code>, <code>.groovy</code></li>
  <li><code>.hs</code>, <code>.html</code></li>
  <li><code>.java</code>, <code>.js</code></li>
  <li><code>.kt</code></li>
  <li><code>.less</code>, <code>.lua</code></li>
  <li><code>.m</code>, <code>.md</code></li>
  <li><code>.pl</code>, <code>.php</code>, <code>.ps1</code>, <code>.py</code></li>
  <li><code>.r</code>, <code>.rb</code>, <code>.rs</code></li>
  <li><code>.sass</code>, <code>.sc</code>, <code>.scss</code>, <code>.sh</code>, <code>.sql</code>, <code>.swift</code></li>
  <li><code>.tex</code>, <code>.ts</code></li>
  <li><code>.yaml</code>, <code>.yml</code></li>
  <li><code>.xml</code></li>
</ul>
</details>

## Development

Before you are able to locally develop and run the app, you need to create and set up a GitHub App as described in the [GitHub documentation](https://docs.github.com/en/apps/creating-github-apps), so you are able to receive webhooks from GitHub in your local instance of the app.

Configure the GitHub App with the following repository permissions:

- Checks: Read and write
- Contents: Read-only
- Pull requests: Read and write

Subscribe the GitHub App to the **Pull request**, **Check run**, and **Check suite** events. The app uses Pull Request events to run checks when a Pull Request is opened, synchronized, or reopened. The Check run and Check suite subscriptions are retained so users can re-run individual checks or all checks from the GitHub UI.

Install the required gems with:

```bash
bundle install
```

Then create a `.env` file with the following content:

```text
GITHUB_APP_IDENTIFIER=${App ID from the GitHub App settings}
GITHUB_PRIVATE_KEY=${Private key generated in the GitHub App settings}
GITHUB_WEBHOOK_SECRET=${Webhook secret set in the GitHub App settings}
APP_FRIENDLY_NAME=${Name of the CI check}
```

The documentation linked above describes where to obtain these values.

You can then use [smee](https://smee.io/) to forward the webhook events sent by GitHub to your local app, like this:

```bash
smee --url https://smee.io/gsPiE7FUxg0q3TPz --path / --port 3000
```

Make sure to also set the Webhook URL in the app settings on GitHub to the same smee URL, like `https://smee.io/gsPiE7FUxg0q3TPz` in the example.

Then, you can start the app with:

```bash
ruby ./app.rb
```

If you have correctly created and installed the app in a repository, and set up the webhooks correctly, you should now see the app receiving events like these when you create or update a Pull Request:

```text
D, [2026-08-04T13:40:28.359807 #26008] DEBUG -- : ---- received event pull_request
D, [2026-08-04T13:40:28.360041 #26008] DEBUG -- : ----    action synchronize
D, [2026-08-04T13:40:28.360102 #26008] DEBUG -- : Webhook event=pull_request action=synchronize repository_id=123 installation_id=456 app_id= decision=pull_request
xxx.xx.xxx.xxx:35146 - - [04/Aug/2026:13:40:30 +0000] "POST / HTTP/1.1" 200 - 1.8412
D, [2026-08-04T13:40:30.201807 #26008] DEBUG -- : ---- received event check_run
D, [2026-08-04T13:40:30.201941 #26008] DEBUG -- : ----    action created
D, [2026-08-04T13:40:30.202012 #26008] DEBUG -- : Webhook event=check_run action=created repository_id=123 installation_id=456 app_id=816025 decision=ignore
xxx.xx.xxx.xxx:35147 - - [04/Aug/2026:13:40:30 +0000] "POST / HTTP/1.1" 204 - 0.0012
```

GitHub sends Check run and Check suite webhooks for checks created by other Apps installed on the same repository. Todo PR Checker verifies these deliveries and returns `204` before authenticating with the GitHub API.

### Troubleshooting

If your private key is being rejected/fails to parse, replace the line breaks of the key in your `.env` file with `\n`.

---

This app is developed using Ruby with Sinatra, automatically built and deployed using Google Cloud Build, and subsequently hosted through Google Cloud Run whenever a new version is released on GitHub.

If you enjoy the app and want to say thanks, consider buying me a [coffee](https://ko-fi.com/nikkelm) or [sponsoring](https://github.com/sponsors/NikkelM) this project.
