# Todo PR Blocker

<!-- Note how the `Todo` of the text below is not alerting the check, but the one in this comment is -->
Checks the files changed in any open Pull Request for `Todo` style comments and leaves a comment if any are found.
Only calls to action in comments (line or block comments) will be alerted on.
<!-- 
FIXME and bug are also supported action items - and capitalization does not matter!
 -->
The app already supports a wide range of programming languages, but feel free to reach out and open an issue if you would like one to be added.

The app is hosted using Google Cloud Run.

## Development

To start a local app, you can use [https://smee.io/](https://smee.io/) to create a webhook that will forward to your local app, such as:

```bash
smee --url https://smee.io/b2p7TRjSjwxQDJ --path / --port 3000
```

Make sure to also set the Webhook URL in the app settings to the same URL.

Then, you can start the app with:

```bash
ruby ./app.rb
```