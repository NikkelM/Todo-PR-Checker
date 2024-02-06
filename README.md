<h1 align="center">Todo PR Checker</h1>

<p align="center">
  <img src="./development/images/icon/images/icon.png" width="150" alt="Todo PR Checker">
</p>

Do you keep forgetting to resolve that one `// TODO:...` or fix the last ` # Bug...` before merging your Pull Requests?

The Todo PR Checker will make sure that doesn't happen anymore.
The app checks all code changes in your open Pull Requests for remaining `Todo`, `Fixme` etc. action items in code comments and leaves a comment on the PR with embedded code links to any items that were found.

This list will update whenever new changes are pushed, so you always know exactly how much work is left.

The app supports a wide array of programming languages and action items.
Should you find that your language of choice or action item is not supported, feel free to open an issue.

The app is built automatically using Google Cloud Build and hosted through Google Cloud Run.

## In-Depth

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

You can then use [smee](https://smee.io/) to create a webhook that will forward the webhook events to your local app:

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

If you enjoy this app and want to say thanks, consider buying me a [coffee](https://ko-fi.com/nikkelm) or [sponsoring](https://github.com/sponsors/NikkelM) this project.
