# TODO PR Blocker

This app will check changes in any PR for open `TODO` style comments and fail a status check if any are found.

## Development

To start a local server, you can use [https://smee.io/](https://smee.io/) to create a webhook that will forward to your local server.

```bash
smee --url YOUR_DOMAIN --path /event_handler --port 3000
```

Then, you can start the server with:

```bash
bundle exec ruby server.rb
```