# Todo PR Blocker

This app will check changes in any PR for open `Todo` style comments and fail a status check if any are found.

## Development

To start a local server, you can use [https://smee.io/](https://smee.io/) to create a webhook that will forward to your local server, such as:

```bash
smee --url https://smee.io/b2p7TRjSjwxQDJ --path /event_handler --port 3000
```

Make sure to also set the Webhook URL in the app settings to the same URL.

Then, you can start the server with:

```bash
ruby server.rb
```