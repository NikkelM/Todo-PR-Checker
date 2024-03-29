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

To minimize falsely identified comments (e.g. the characters that start a comment are contained in a string), the app will only look for action items if the comment starts in its own line.
The following examples would *not* cause the app to flag the action items:

```javascript
let variable = true; // TODO: Find a better name for the variable

let otherVar = false; /*
If the comment does not start on its own line, the TODO action item will not be detected!
*/
```

Additionally, support for multiline comments is *disabled* by default, as it may cause the app to incorrectly identify action items if the opening or closing characters of the block comment are not included in the Pull Request diff.
You may enable support for multiline comments in the options, see the section below.

## Options

This app supports the `.github/config.yml` file to configure options.
You can use this file to support additional programming languages, action items, and more.

To configure options, add a `todo-pr-checker` key at the top-level of your `.github/config.yml` file:

```yaml
todo-pr-checker:
  post_comment: 'items_found'
  (...)
```

To get started, you can copy the `.github/config.yml` file from this repository and adjust it to your needs.

### Available options

| Option | Possible Values | Description | Default |
| --- | --- | --- | --- |
| `post_comment` | `items_found`, `always`, `never` | Controls when the app should post a comment. By default, a comment is only posted if an action item has been found. If set to `never`, the check will still fail. If set to `always`, the app will post a comment that all action items have been resolved if none are found. | `items_found` |
| `ignore_files` | `string[]`, maximum 7 entries | A list of glob patterns to specify files that should be ignored during the check. You may specify up to 7 patterns. The pattern matching logic used is the same as for `.gitignore` files. | `null` |
| `action_items` | `string[]`, maximum 15 entries | A list of action items to look for in code comments. If you set this option, the default values will be overwritten, so you must include them in your list to use them. By default, action items are case insensitive. You may specify up to 15 items. | `['TODO', 'FIXME', 'BUG']` |
| `add_languages` | `[string[file_type, line_start, block_start, block_end]]`</br>Example: `[['js', '//', '/*', '*,'], ['php', ['//', '#'], '/*', '*/'], ['css', null, '/*', '*/'], ['.py', '#']]`, maximum 10 entries | A list of a list of programming languages to add support for. This list will be added to the already supported languages. If you define a language that is already supported, the default values will be overwritten. `file_type` must be the extension of the file (e.g. `js`) and may start with a `.`. If the file type you are adding supports mulitple line comment types, you may define an `array` of `strings` instead of just a `string`. You may omit the block comment definitions if the file type does not support block comments. If you want to omit the definition of a line comment, you may set `line_start` to `null` or omit it. If defining `block_start`, `block_end` must also be defined. You may specify up to 10 new file types. *The file types shown in the example are already natively supported by the app.* | `null` |
| `additional_lines` | `integer` between `0` and `10` | The number of additional lines to include below found action items in embedded code snippets. If set to `0`, the code snippet shows only the line with the action item. This setting does not influence the behaviour of showing multiple action items in one snippet if they are located close to each other. *Note that if there are not enough lines left in the file to display, the embedded code snippet will not be able to render at all and will display as a link only.* | `1` |
| `case_sensitive` | `true`, `false` | Controls whether the app should look for action items in a case-sensitive manner. | `false` |
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

Install the required gems with:

```bash
bundle install
```

Then create a `.env` file with the following content:

```text
GITHUB_APP_ID=${App ID from the GitHub App settings}
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
D, [2024-02-05T14:04:28.359807 #26008] DEBUG -- : ---- received event check_suite
D, [2024-02-05T14:04:28.360041 #26008] DEBUG -- : ----    action requested
D, [2024-02-05T14:04:28.786714 #26008] DEBUG -- : ---- received event pull_request
D, [2024-02-05T14:04:28.786849 #26008] DEBUG -- : ----    action synchronize
xxx.xx.xxx.xxx:35146 - - [05/Feb/2024:14:04:29 +0000] "POST / HTTP/1.1" 200 - 0.2616
xxx.xx.xxx.xxx:47458 - - [05/Feb/2024:14:04:29 +0000] "POST / HTTP/1.1" 200 - 0.8099
D, [2024-02-05T14:04:29.872895 #26008] DEBUG -- : ---- received event check_run
D, [2024-02-05T14:04:29.873041 #26008] DEBUG -- : ----    action created
xxx.xx.xxx.xxx:36950 - - [05/Feb/2024:14:04:32 +0000] "POST / HTTP/1.1" 200 - 2.7705
D, [2024-02-05T14:04:33.227254 #26008] DEBUG -- : ---- received event check_suite
D, [2024-02-05T14:04:33.227460 #26008] DEBUG -- : ----    action completed
D, [2024-02-05T14:04:33.351184 #26008] DEBUG -- : ---- received event check_run
D, [2024-02-05T14:04:33.351388 #26008] DEBUG -- : ----    action completed
```

### Troubleshooting

If your private key is being rejected/fails to parse, replace the line breaks of the key in your `.env` file with `\n`.

---

This app is developed using Ruby with Sinatra, automatically built and deployed using Google Cloud Build, and subsequently hosted through Google Cloud Run whenever a new version is released on GitHub.

If you enjoy the app and want to say thanks, consider buying me a [coffee](https://ko-fi.com/nikkelm) or [sponsoring](https://github.com/sponsors/NikkelM) this project.
