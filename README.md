<h1 align="center">Todo PR Checker</h1>

<p align="center">
  <img src="./development/images/icon/images/icon.png" width="150" alt="Todo PR Checker">
</p>

Do you keep forgetting to resolve that one `// TODO:...` or fix the last ` # Bug...` before merging your Pull Requests?

The Todo PR Checker will make sure that doesn't happen anymore.
The app checks all code changes in your open Pull Requests for remaining `Todo`, `Fixme` etc. action items in code comments and leaves a comment on the PR with embedded code links to any items that were found.

This list will update whenever new changes are pushed, so you always know exactly how much work is left.

The app supports a wide array of programming languages and action items.
Should you find that your language of choice or action item is not supported out-of-the-box, you can easily configure the app to support it.

To minimize falsely identified comments (e.g. the characters that start a comment are contained in a string), the app will only detect action items if the comment starts in its own line.  <!-- TODO: Is this true? -->
The following examples would *not* cause the app to flag the action items:

```javascript
let variable = true; // TODO: Find a better name for the variable

let otherVar = false; /*
If the comment does not start on its own line, the TODO action item will not be detected!
*/
```

These action items would however be flagged correctly:

```javascript
// TODO: If a line comment stands on its own, action items will be flagged.
/*
Multiline block comments are supported, no matter how many lines they span,
the TODO will be detected
*/
```

## Options

This app supports the `.github/config.yml` file to configure options.
You can use this file to support additional programming languages, action items, and more.

To configure options, add a `todo-pr-checker` key at the top-level of your `.github/config.yml` file:

```yaml
todo-pr-checker:
  post_comment: true
```

To get started, you can copy the `.github/config.yml` file from this repository and adjust it to your needs.

### Available options

<!-- TODO: After the functionality is added, add following part to post_comment description: If set to `never`, the check will still fail and a breakdown of action items can be found in the check summary. -->
| Option | Possible Values | Description | Default |
| --- | --- | --- | --- |
| `post_comment` | `items_found`, `always`, `never` | Controls when the app should post a comment. By default, a comment is only posted if an action item has been found. If set to `never`, the check will still fail. If set to `always`, the app will post a comment that all action items have been resolved if none are found. | `items_found` |
| `action_items` | `string[]` | A list of action items to look for in code comments. If you set this option, the default values will be overwritten, so you must include them in your list to use them. | `['TODO', 'FIXME', 'BUG']` |
| `case_sensitive` | `true`, `false` | Controls whether the app should look for action items in a case-sensitive manner. | `false` |
| `add_languages` | `[string[file_type, line_comment, block_comment_start, block_comment_end]]`</br>Example: `[['js', '//', '/*', '*,'], ['css', null, '/*', '*/'], ['.py', '#']]` | A list of a list of programming languages to add support for. This list will be added to the already supported languages. If you define a language that is already supported, the default values will be overwritten. `file_type` must be the extension of the file (e.g. `js`) and may start with a `.`. You may omit the block comment definitions if the file type does not support block comments. If you want to omit the definition of a `line_comment`, you must set `line_comment` to `null`. If defining `block_comment_start`, `block_comment_end` must also be defined. | `null` |

## In-Depth
<!-- This is a todo that should be matched
 -->
On each push to a Pull Request, the app will check all code changes for action item keywords in code comments.
Currently supported action items are `Todo`, `Fixme` and `Bug`. 
Capitalization and location of the action item do not matter, as long as it is its own word.

The app supports a wide range of programming languages.
Currently supported languages/file extensions are: _Astro, Bash, C, C#, C++, CSS, Dart, .gitattributes, .gitignore, .gitmodules, Go, Groovy, Haskell, HTML, Java, JavaScript, Kotlin, Less, Lua, Markdown, MATLAB, Perl, PHP, PowerShell, Python, R, Ruby, Rust, Sass, Scala, SCSS, Shell, SQL, Swift, TeX, TypeScript, XML, YAML_

The app will leave a comment on your Pull Request if it finds any unresolved action items.
Embedded links in the comment lead directly to the lines of code that contain the found action items.
Whenever new changes are pushed to the Pull Request, the app will update the comment with the latest findings and inform you about your progress.

You can configure the check to block Pull Requests until all action items are resolved by creating a branch protection rule in your repository settings.

Tech stack: The app is built using Ruby and automatically deployed to Google Cloud Run using Google Cloud Build when a new release is created.

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

This app is automatically built and deployed using Google Cloud Build, and subsequently hosted through Google Cloud Run whenever a new version is released on GitHub, ensuring your installation is always up-to-date.

If you enjoy the app and want to say thanks, consider buying me a [coffee](https://ko-fi.com/nikkelm) or [sponsoring](https://github.com/sponsors/NikkelM) this project.
