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

    # Get the raw repository content from GitHub, at the Pull Request's HEAD commit
    settings = get_app_settings(full_repo_name, @payload['check_run']['head_sha'])

    # Get a list of changed lines in the Pull request, grouped by their file name and associated with a line number
    changes = get_pull_request_changes(full_repo_name, pull_number)

    # Filter the changed lines for only those that contain action items ("Todos"), and group them by file
    todo_changes = check_for_todos(changes)

    # If the app has previously created a comment on the Pull Request, fetch it
    app_comment = fetch_app_comment(full_repo_name, pull_number)

    # If any action items were found, create/update a comment on the Pull Request with embedded links to the relevant lines
    if todo_changes.any?
      comment_body = create_pr_comment_from_changes(todo_changes, full_repo_name)

      # Post or update the comment with the found action items
      if app_comment
        @installation_client.update_comment(full_repo_name, app_comment.id, comment_body, accept: 'application/vnd.github+json')
      else
        @installation_client.add_comment(full_repo_name, pull_number, comment_body, accept: 'application/vnd.github+json')
      end

      # Mark the check run as failed, as action items were found. This enables users to block Pull Requests with unresolved action items
      @installation_client.update_check_run(full_repo_name, check_run_id, status: 'completed', conclusion: 'failure', accept: 'application/vnd.github+json')
    else
      # If the app has previously created a comment, update it to indicate that all action items have been resolved
      # If the app has not previously created a comment, we don't needlessly create one
      if app_comment
        comment_body = "✔ All action items have been resolved!\n----\nDid I do good? Let me know by [helping maintain this app](https://github.com/sponsors/NikkelM)!"
        @installation_client.update_comment(full_repo_name, app_comment.id, comment_body, accept: 'application/vnd.github+json')
      end

      # Mark the check run as successful, as no action items were found
      @installation_client.update_check_run(full_repo_name, check_run_id, status: 'completed', conclusion: 'success', accept: 'application/vnd.github+json')
    end
  end

  # (3) Retrieves the `.github/config.yml` and parses the app's settings
  def get_app_settings(full_repo_name, head_sha)
    begin
      file = @installation_client.contents(full_repo_name, path: '.github/config.yml', ref: head_sha)
      file = Base64.decode64(file.content)
      # Get the settings from the file, the top-level key is todo-pr-checker
      settings = YAML.safe_load(file)['todo-pr-checker']
      puts settings
      settings
    rescue Octokit::NotFound
      logger.debug 'No .github/config.yml found'
      nil
    end
  end

  # (3) Retrieves all changes in a pull request from the GitHub API and formats them to be usable by the app
  def get_pull_request_changes(full_repo_name, pull_number)
    diff = @installation_client.pull_request(full_repo_name, pull_number, accept: 'application/vnd.github.diff')

    current_file = ''
    line_number = 0
    changes = {}

    diff.each_line do |line|
      # This is the most common case, indicating a line was added to the file
      if line.start_with?('+') && !line.start_with?('+++')
        changes[current_file] << { line: line_number, text: line[1..] }
      # Lines that start with @@ contain the the starting line and its length for a new block of changes, for the old and new file respectively
      elsif line.start_with?('@@')
        line_number = line.split()[2].split(',')[0].to_i - 1
      # Lines that start with +++ contain the new name of the file, which is the one we want to link to in the comment
      elsif line.start_with?('+++')
        current_file = line[6..].strip
        changes[current_file] = []
      end

      # We count the line numbers for lines in the new file, which means we need to exclude unchanged lines, and the special "no newline" line
      line_number += 1 unless line.start_with?('-') || line.chomp == '\ No newline at end of file'
    end

    changes
  end

  # (4) Checks changed lines in supported file types for action items in code comments ("Todos")
  def check_for_todos(changes)
    keywords = %w[todo fixme bug]
    todo_changes = {}
    in_block_comment = false

    comment_chars = {
      %w[md html astro xml] => { line: '<!--', block_start: '<!--', block_end: '-->' },
      %w[js java ts c cpp cs php swift go kotlin rust dart scala css less sass scss groovy sql] => { line: '//', block_start: '/*', block_end: '*/' },
      %w[rb perl] => { line: '#', block_start: '=begin', block_end: '=end' },
      %w[py] => { line: '#', block_start: "'''", block_end: "'''" },
      %w[r shell gitignore gitattributes gitmodules sh bash yml yaml ps1] => { line: '#', block_start: nil, block_end: nil },
      %w[haskell lua] => { line: '--', block_start: '{-', block_end: '-}' },
      %w[m tex] => { line: '%', block_start: nil, block_end: nil }
    }

    # Changes are grouped by file name
    changes.each do |file, file_changes|
      file_type = File.extname(file).delete('.')
      comment_char = comment_chars.find { |k, _| k.include?(file_type) }

      # If there is no mapping for the file type, skip it
      next unless comment_char

      file_todos = []
      # Check each line in the file for action items
      file_changes.each do |change|
        text = change[:text].strip

        # If the line starts or ends a block comment, set the flag accordingly
        # This flag is used to determine if a following line is part of a block comment or a normal line of code
        if comment_char[1][:block_start]
          in_block_comment = true if text.start_with?(comment_char[1][:block_start])
          in_block_comment = false if text.end_with?(comment_char[1][:block_end])
        end

        # For each of the supported action items ("keywords"), check if they are contained in the line
        keywords.each do |keyword|
          # Depending on if the file type supports block comments, use a different regex to match the keyword
          regex = if comment_char[1][:block_start]
                    /(\b#{keyword}\b|#{Regexp.escape(comment_char[1][:line])}\s*#{keyword}\b|#{Regexp.escape(comment_char[1][:block_start])}\s*#{keyword}\b#{Regexp.escape(comment_char[1][:block_end])})/
                  else
                    /(\b#{keyword}\b|#{Regexp.escape(comment_char[1][:line])}\s*#{keyword}\b)/
                  end

          # If the keyword is contained in the line, add it to the output collection
          if text.downcase.match(regex) && (in_block_comment || text.start_with?(comment_char[1][:line]))
            file_todos << change
            break
          end
        end
      end

      # We don't want to add files to the output collection if they don't contain any action items, as they shouldn't be posted in the comment
      todo_changes[file] = file_todos unless file_todos.empty?
    end

    todo_changes
  end

  # (5) Creates a comment text from the found action items, with embedded links to the relevant lines
  def create_pr_comment_from_changes(todo_changes, full_repo_name)
    number_of_todos = todo_changes.values.flatten.count
    comment_body = if number_of_todos == 1
                     "There is **1** unresolved action item in this Pull Request:\n\n"
                   else
                     "There are **#{number_of_todos}** unresolved action items in this Pull Request:\n\n"
                   end

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
      grouped_changes = changes.slice_when { |prev, curr| curr[:line] - prev[:line] > 3 }.to_a
      grouped_changes.each do |group|
        first_line = group.first[:line]
        last_line = group.last[:line]
        comment_body += if first_line == last_line
                          "https://github.com/#{full_repo_name}/blob/#{@payload['check_run']['head_sha']}/#{file}#L#{first_line} "
                        else
                          "https://github.com/#{full_repo_name}/blob/#{@payload['check_run']['head_sha']}/#{file}#L#{first_line}-L#{last_line} "
                        end
      end
    end
    comment_body += "\n----\nDid I do good? Let me know by [helping maintain this app](https://github.com/sponsors/NikkelM)!"

    comment_body
  end

  # (6) If the app has already created a comment on the Pull Request, return a reference to it, otherwise return nil
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
