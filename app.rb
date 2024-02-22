# frozen_string_literal: true

require 'base64'
require 'dotenv/load'
require 'git'
require 'json'
require 'jwt'
require 'logger'
require 'net/http'
require 'octokit'
require 'openssl'
require 'sinatra'
require 'time'
require 'uri'
require 'yaml'
require_relative 'version'

puts "Running Todo PR Checker version: #{VERSION}"

set :bind, '0.0.0.0'
set :port, ENV['PORT'] || '3000'

GITHUB_PRIVATE_KEY = OpenSSL::PKey::RSA.new(ENV.fetch('GITHUB_PRIVATE_KEY', nil).gsub('\n', "\n"))
GITHUB_WEBHOOK_SECRET = ENV.fetch('GITHUB_WEBHOOK_SECRET', nil)
APP_IDENTIFIER = ENV.fetch('GITHUB_APP_IDENTIFIER', nil)
APP_FRIENDLY_NAME = ENV.fetch('APP_FRIENDLY_NAME', 'Todo PR Checker')

configure :development do
  set :logging, Logger::DEBUG
end

# Before running the event handler, verify the webhook signature and authenticate the app
before '/' do
  get_payload_request(request)
  verify_webhook_signature

  halt 400 if @payload['repository'].nil? || (@payload['repository']['name'] =~ /[0-9A-Za-z\-\_]+/).nil?

  authenticate_app
  authenticate_installation(@payload)
end

# Handles webhook events from GitHub, which are sent as HTTP POST requests
# We only handle pull_request, check_suite, and check_run events
post '/' do
  event_type = request.env['HTTP_X_GITHUB_EVENT']
  event_handled = false

  # If we got an event that wasn't meant for our app, return early
  # Pull Request events are not associated with an app, so we excempt them from this check
  return 400 if event_type != 'pull_request' && @payload.dig(event_type, 'app', 'id')&.to_s != APP_IDENTIFIER

  # If a Pull Request was opened, we want to *create* a new check run (it is not yet executed)
  if event_type == 'pull_request' && @payload['action'] == 'opened'
    event_handled = true
    create_check_run
  end

  # If a new check suite is requested, we want to *create* a new check run (it is not yet executed)
  # We only want to create a check if a Pull Request is associated with the event
  if event_type == 'check_suite' && @payload['check_suite']['pull_requests'].first && (@payload['action'] == 'requested' || @payload['action'] == 'rerequested')
    event_handled = true
    create_check_run
  end

  # If a new check run is requested, we want to run the app logic and report the results
  # We only want to create a check if a Pull Request is associated with the event
  if event_type == 'check_run' && @payload['check_run']['pull_requests'].first && (@payload['action'] == 'created' || @payload['action'] == 'rerequested')
    event_handled = true
    initiate_check_run
  end

  event_handled ? 200 : 204
end

helpers do
  # (1) Creates an empty check run on GitHub associated with the most recent commit, but does not run the app's logic
  def create_check_run
    event_type = request.env['HTTP_X_GITHUB_EVENT']

    # Depending on the event type, the commit SHA is in a different location
    sha = if event_type == 'pull_request'
            @payload['pull_request']['head']['sha']
          else
            @payload[event_type]['head_sha']
          end

    # Create a new check run to report on the progress of the app, and associate it with the most recent commit
    @installation_client.create_check_run(@payload['repository']['full_name'], APP_FRIENDLY_NAME, sha, status: 'queued', accept: 'application/vnd.github+json')
  end

  # (2) Contains the main logic of the app, checking and reporting on action items in code comments during a CI check
  def initiate_check_run
    full_repo_name = @payload['repository']['full_name']
    pull_requests = @payload['check_run']['pull_requests']
    pull_number = pull_requests.first['number'] if pull_requests.any?
    check_run_id = @payload['check_run']['id']

    # As soon as the run is initiated, mark it as in progress on GitHub
    @installation_client.update_check_run(full_repo_name, check_run_id, status: 'in_progress', accept: 'application/vnd.github+json')

    # Get the options for the app from the `.github/config.yml` file in the repository
    app_options = get_app_options(full_repo_name, @payload['check_run']['head_sha'])
    # logger.debug app_options

    # Get a list of changed lines in the Pull request, grouped by their file name and associated with a line number
    changes = get_pull_request_changes(full_repo_name, pull_number, app_options['ignore_files'])

    # Filter the changed lines for only those that contain action items ("Todos"), and group them by file
    todo_changes = check_for_todos(changes, app_options)

    # If the app has previously created a comment on the Pull Request, fetch it
    app_comment = fetch_app_comment(full_repo_name, pull_number)
    comment_footer = "\n----\nDid I do good? Let me know by [helping maintain this app](https://github.com/sponsors/NikkelM)!"

    # If any action items were found, create/update a comment on the Pull Request with embedded links to the relevant lines
    if todo_changes.any?
      # If the user has enabled post_comment in the options
      if app_options['post_comment'] != 'never'
        check_run_title, comment_summary, comment_body = create_pr_comment_from_changes(todo_changes, full_repo_name, app_options).values_at(:title, :summary, :body)

        # Post or update the comment with the found action items
        if app_comment
          @installation_client.update_comment(full_repo_name, app_comment.id, comment_summary + comment_body + comment_footer, accept: 'application/vnd.github+json')
        else
          @installation_client.add_comment(full_repo_name, pull_number, comment_summary + comment_body + comment_footer, accept: 'application/vnd.github+json')
        end
      end

      # Mark the check run as failed, as action items were found. This enables users to block Pull Requests with unresolved action items
      @installation_client.update_check_run(full_repo_name, check_run_id, status: 'completed', conclusion: 'failure', output: { title: check_run_title, summary: comment_summary, text: comment_body + comment_footer }, accept: 'application/vnd.github+json')
    else
      comment_header = '✔ No action items found!'
      # If the app has previously created a comment, update it to indicate that all action items have been resolved
      # If the app has not previously created a comment, we only create one if the user has enabled the option
      if app_comment || app_options['post_comment'] == 'always'
        if app_comment
          comment_header = '✔ All action items have been resolved!'
          @installation_client.update_comment(full_repo_name, app_comment.id, comment_header + comment_footer, accept: 'application/vnd.github+json')
        else
          @installation_client.add_comment(full_repo_name, pull_number, comment_header + comment_footer, accept: 'application/vnd.github+json')
        end
      end

      # Mark the check run as successful, as no action items were found
      @installation_client.update_check_run(
        full_repo_name, check_run_id,
        status: 'completed',
        conclusion: 'success',
        output: { title: comment_header, summary: "There are no new action items added in this Pull Request. If any are added later on, the bot will make sure to let you know.\n#{comment_footer}" },
        accept: 'application/vnd.github+json'
      )
    end
  rescue StandardError => e
    logger.error "An error occurred: #{e}"
    # If an error occurred, mark the check run as failed
    @installation_client.update_check_run(
      full_repo_name, check_run_id,
      status: 'completed',
      conclusion: 'neutral',
      output: { title: 'An internal error has occurred!', summary: 'If this keeps happening, please report it [here](https://github.com/NikkelM/Todo-PR-Checker/issues).', text: e.message },
      accept: 'application/vnd.github+json'
    )
  end

  # (3) Retrieves the `.github/config.yml` and parses the app's options
  def get_app_options(full_repo_name, head_sha)
    default_options = {
      'post_comment' => 'items_found',
      'multiline_comments' => true,
      'action_items' => %w[todo fixme bug],
      'case_sensitive' => false,
      'add_languages' => [],
      'ignore_files' => [],
      'additional_lines' => 0,
      'always_split_snippets' => false
    }

    accepted_option_values = {
      'post_comment' => ->(value) { %w[items_found always never].include?(value) },
      'multiline_comments' => ->(value) { [true, false].include?(value) },
      'action_items' => ->(value) { value.is_a?(Array) && (0..15).include?(value.size) },
      'case_sensitive' => ->(value) { [true, false].include?(value) },
      'add_languages' => ->(value) { value.is_a?(Array) && (1..10).include?(value.size) && value.all? { |v| v.is_a?(Array) && (2..4).include?(v.size) && v.all? { |i| i.is_a?(String) || i.nil? } } },
      # The regex checks if the given input is a valid .gitignore pattern
      'ignore_files' => ->(value) { value.is_a?(Array) && (1..7).include?(value.size) && value.all? { |v| v.is_a?(String) && %r{\A(/?(\*\*/)?[\w*\[\]{}?\.\/-]+(/\*\*)?/?)\Z}.match?(v) } },
      'additional_lines' => ->(value) { value.is_a?(Integer) && (0..10).include?(value) },
      'always_split_snippets' => ->(value) { [true, false].include?(value) }
    }

    file = @installation_client.contents(full_repo_name, path: '.github/config.yml', ref: head_sha) rescue nil
    file ||= @installation_client.contents(full_repo_name, path: '.github/config.yaml', ref: head_sha)
    decoded_file = Base64.decode64(file.content)
    file_options = YAML.safe_load(decoded_file)['todo-pr-checker'] || {}

    # Merge the default options with those from the file
    default_options.keys.each_with_object({}) do |key, result|
      new_value = file_options[key]
      result[key] = if new_value.nil? || !accepted_option_values[key].call(new_value)
                      default_options[key]
                    else
                      new_value
                    end
    end
  rescue Octokit::NotFound
    logger.debug 'No .github/config.yml or .github/config.yaml found, or options validation failed. Using default options.'
    default_options
  end

  # (4) Retrieves all changes in a pull request from the GitHub API and formats them to be usable by the app
  def get_pull_request_changes(full_repo_name, pull_number, ignore_files_regex)
    diff = @installation_client.pull_request(full_repo_name, pull_number, accept: 'application/vnd.github.diff')

    ignore_files_regex.map! do |pattern|
      pattern.gsub!('.', '\.')
      pattern.gsub!('*', '.*')
      pattern.gsub!('/', '\/')
      Regexp.new(pattern)
    end

    current_file = ''
    line_number = 0
    changes = {}

    diff_enum = diff.each_line
    line = diff_enum.next rescue nil
    loop do
      break if line.nil?

      if line.start_with?('+++')
        while line&.start_with?('+++')
          current_file = line[6..].strip
          if ignore_files_regex.any? { |pattern| pattern.match?(current_file) }
            loop do
              line = diff_enum.next rescue nil
              break if line.nil? || line.start_with?('+++')
            end
          else
            changes[current_file] = []
            break
          end
        end
        break if line.nil?
      elsif line.start_with?('+')
        changes[current_file] << { line: line_number, text: line[1..] }
      elsif line.start_with?('@@')
        line_number = line.split()[2].split(',')[0].to_i - 1
      end

      line_number += 1 unless line.start_with?('-') || line.chomp == '\ No newline at end of file'
      line = diff_enum.next rescue nil
    end

    changes
  end

  # (5) Checks changed lines in supported file types for action items in code comments ("Todos")
  def check_for_todos(changes, options)
    multiline_comments = options['multiline_comments']
    action_items = options['action_items']
    case_sensitive = options['case_sensitive']

    todo_changes = {}
    in_multiline_comment = false

    comment_chars = get_comment_chars(options['add_languages'])

    # Create a regex for each action item
    regexes = action_items.map do |item|
      regex = /\b#{item}\b/
      case_sensitive ? regex : Regexp.new(regex.source, Regexp::IGNORECASE)
    end

    # Changes are grouped by file name
    changes.each do |file, file_changes|
      file_type = File.extname(file).delete('.')
      comment_char = comment_chars.find { |k, _| k.include?(file_type) }

      # If there is no mapping for the file type, skip it
      next unless comment_char

      file_todos = []
      in_multiline_comment = false
      # Check each line in the file for action items
      file_changes.each do |line|
        text = line[:text].strip

        # Set the flag if the line starts a block comment, or is the start of a block comment
        in_multiline_comment ||= multiline_comments && comment_char[1][:block_start] && text.start_with?(comment_char[1][:block_start])
        on_block_comment_starting_line = comment_char[1][:block_start] && text.start_with?(comment_char[1][:block_start])

        # If the line is a comment and contains any action item, add it to the output collection
        file_todos << line if (text.start_with?(comment_char[1][:line]) || on_block_comment_starting_line || in_multiline_comment) && regexes.any? { |regex| text.match(regex) }

        # Reset the flag if the line ends a block comment
        in_multiline_comment = false if !multiline_comments || (comment_char[1][:block_end] && text.end_with?(comment_char[1][:block_end]))
      end

      # We don't want to add files to the output collection if they don't contain any action items, as they shouldn't be posted in the comment
      todo_changes[file] = file_todos unless file_todos.empty?
    end

    todo_changes
  end

  # (6) Retrieves the file types and comment characters for the app's supported languages, and user defined values
  def get_comment_chars(added_languages)
    default_comment_chars = {
      %w[md html xml] => { line: '<!--', block_start: '<!--', block_end: '-->' },
      %w[astro] => { line: '//', block_start: '<!--', block_end: '-->' },
      %w[js java ts c cpp cs php swift go kt rs dart sc groovy less sass scss] => { line: '//', block_start: '/*', block_end: '*/' },
      %w[css] => { line: '/*', block_start: '/*', block_end: '*/' },
      %w[r gitignore sh bash yml yaml] => { line: '#', block_start: nil, block_end: nil },
      %w[rb] => { line: '#', block_start: '=begin', block_end: '=end' },
      %w[pl] => { line: '#', block_start: '=', block_end: '=cut' },
      %w[py] => { line: '#', block_start: "'''", block_end: "'''" },
      %w[ps1] => { line: '#', block_start: '<#', block_end: '#>' },
      %w[sql] => { line: '--', block_start: '/*', block_end: '*/' },
      %w[hs] => { line: '--', block_start: '{-', block_end: '-}' },
      %w[lua] => { line: '--', block_start: '--[[', block_end: ']]' },
      %w[m] => { line: '%', block_start: '%{', block_end: '%}' },
      %w[tex] => { line: '%', block_start: nil, block_end: nil }
    }

    unwrapped_comment_chars = {}
    default_comment_chars.each do |file_types, comment_symbols|
      file_types.each do |file_type|
        unwrapped_comment_chars[file_type] = comment_symbols
      end
    end

    added_languages.each do |lang|
      file_type = lang[0].sub(/^\./, '')
      # The length of lang defines which permutation is given by the user
      # Users may overwrite the default comment characters for a file type
      case lang.length
      when 2
        unwrapped_comment_chars[file_type] = { line: lang[1], block_start: nil, block_end: nil }
      when 3
        unwrapped_comment_chars[file_type] = { line: lang[1], block_start: lang[1], block_end: lang[2] }
      when 4
        unwrapped_comment_chars[file_type] = { line: lang[1], block_start: lang[2], block_end: lang[3] }
      end
    end

    unwrapped_comment_chars
  end

  # (7) Creates a comment text from the found action items, with embedded links to the relevant lines
  def create_pr_comment_from_changes(todo_changes, full_repo_name, app_options)
    additional_lines = app_options['additional_lines']
    always_split_snippets = app_options['always_split_snippets']

    number_of_todos = todo_changes.values.flatten.count
    check_run_title = if number_of_todos == 1
                        '✘ 1 unresolved action item found!'
                      else
                        "✘ #{number_of_todos} unresolved action items found!"
                      end
    comment_summary = if number_of_todos == 1
                        "There is **1** unresolved action item in this Pull Request:\n\n"
                      else
                        "There are **#{number_of_todos}** unresolved action items in this Pull Request:\n\n"
                      end

    comment_body = ''
    todo_changes.each do |file, changes|
      file_link = "https://github.com/#{full_repo_name}/blob/#{@payload['check_run']['head_sha']}/#{file}"
      num_items = if changes.count == 1
                    '1 action item'
                  else
                    "#{changes.count} action items"
                  end
      comment_body += "\n## [`#{file}`](#{file_link}) (#{num_items}):\n"

      # Sort the changes by their line number, and group those that are close together into one embedded link
      changes.sort_by! { |change| change[:line] }
      if always_split_snippets
        grouped_changes = changes.map { |change| [change] }
      else
        grouped_changes = changes.slice_when { |prev, curr| (curr[:line] - prev[:line] > 3) && (curr[:line] - (prev[:line] + additional_lines) > 1) }.to_a
      end

      grouped_changes.each do |group|
        first_line = group.first[:line]
        last_line = group.last[:line]
        comment_body += if first_line == last_line && additional_lines.zero?
                          "https://github.com/#{full_repo_name}/blob/#{@payload['check_run']['head_sha']}/#{file}#L#{first_line} "
                        else
                          "https://github.com/#{full_repo_name}/blob/#{@payload['check_run']['head_sha']}/#{file}#L#{first_line}-L#{last_line + additional_lines} "
                        end
      end
    end

    { title: check_run_title, summary: comment_summary, body: comment_body }
  end

  # (8) If the app has already created a comment on the Pull Request, return a reference to it, otherwise return nil
  def fetch_app_comment(full_repo_name, pull_number)
    comments = @installation_client.issue_comments(full_repo_name, pull_number, accept: 'application/vnd.github+json')

    comments.find { |comment| comment.performed_via_github_app&.id == APP_IDENTIFIER.to_i }
  end

  ##############################################################################################################
  ########## The following methods contain boilerplate code for authenticating the app against GitHub ##########
  ##############################################################################################################
  # Boilerplate code for parsing the webhook payload
  def get_payload_request(request)
    request.body.rewind
    @payload_raw = request.body.read
    begin
      @payload = JSON.parse @payload_raw
    rescue JSON::ParserError => e
      logger.debug "Invalid JSON (#{e}): #{@payload_raw}"
      halt 400
    end
  end

  # Boilerplate code to create a JSON Web Token to authenticate the app to GitHub
  def authenticate_app
    payload = {
      iat: Time.now.to_i,
      # JWT expiration time (10 minute maximum)
      # We use 7 minutes to get around any clock skew between the app and GitHub
      exp: Time.now.to_i + (7 * 60),
      iss: APP_IDENTIFIER
    }
    jwt = JWT.encode(payload, GITHUB_PRIVATE_KEY, 'RS256')
    @authenticate_app ||= Octokit::Client.new(bearer_token: jwt)
  end

  # Boilerplate code to authenticate the app's installation in a repository
  def authenticate_installation(payload)
    @installation_id = payload['installation']['id']
    @installation_token = @authenticate_app.create_app_installation_access_token(@installation_id)[:token]
    @installation_client = Octokit::Client.new(bearer_token: @installation_token)
  end

  # Boilerplate code to verify the signature of the webhook received from GitHub
  def verify_webhook_signature
    their_signature_header = request.env['HTTP_X_HUB_SIGNATURE'] || 'sha1='
    method, their_digest = their_signature_header.split('=')
    our_digest = OpenSSL::HMAC.hexdigest(method, GITHUB_WEBHOOK_SECRET, @payload_raw)
    halt 401 unless their_digest == our_digest

    logger.debug "---- received event #{request.env['HTTP_X_GITHUB_EVENT']}"
    logger.debug "----    action #{@payload['action']}" unless @payload['action'].nil?
  end
end
