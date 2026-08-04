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
RELEVANT_PULL_REQUEST_ACTIONS = %w[opened synchronize reopened ready_for_review].freeze
MAX_REPORTED_UNCHECKED_FILES = 50

configure :development do
  set :logging, Logger::DEBUG
end

# Before running the event handler, parse and verify the webhook
before '/' do
  get_payload_request(request)
  verify_webhook_signature
end

# Handles webhook events from GitHub, which are sent as HTTP POST requests
# We handle relevant pull_request events and reruns of this app's check runs
post '/' do
  event_type = request.env['HTTP_X_GITHUB_EVENT']
  event_context = get_webhook_event_context(event_type, @payload)
  originating_app_id = @payload.dig(event_type, 'app', 'id') if event_type

  logger.debug "Webhook event=#{event_type} action=#{@payload['action']} repository_id=#{@payload.dig('repository', 'id')} installation_id=#{@payload.dig('installation', 'id')} app_id=#{originating_app_id} decision=#{event_context ? event_context[:type] : 'ignore'}"
  return 204 unless event_context

  authenticate_app
  authenticate_installation(@payload)

  app_options = nil
  if event_context[:type] == :pull_request && event_context[:draft]
    app_options = get_app_options(event_context[:full_repo_name], event_context[:head_sha])
    unless app_options['check_drafts']
      logger.debug 'Skipping draft Pull Request because check_drafts is disabled.'
      return 204
    end
  end

  check_run = create_check_run(event_context[:full_repo_name], event_context[:head_sha])
  check_arguments = {
    full_repo_name: event_context[:full_repo_name],
    pull_number: event_context[:pull_number],
    head_sha: event_context[:head_sha],
    check_run_id: check_run.id
  }
  check_arguments[:app_options] = app_options if app_options
  initiate_check_run(**check_arguments)

  200
end

helpers do
  def get_webhook_event_context(event_type, payload)
    case event_type
    when 'pull_request'
      return unless RELEVANT_PULL_REQUEST_ACTIONS.include?(payload['action'])

      validate_repository(payload)
      pull_request = payload['pull_request']
      halt 400 unless pull_request.is_a?(Hash) && pull_request['number'] && pull_request.dig('head', 'sha')

      {
        type: :pull_request,
        full_repo_name: payload['repository']['full_name'],
        pull_number: pull_request['number'],
        head_sha: pull_request.dig('head', 'sha'),
        draft: pull_request['draft'] == true
      }
    when 'check_run'
      check_run = payload['check_run']
      return unless check_run.is_a?(Hash)
      return unless check_run.dig('app', 'id')&.to_s == APP_IDENTIFIER
      return unless payload['action'] == 'rerequested'

      pull_request = check_run['pull_requests']&.first
      return unless pull_request

      validate_repository(payload)
      halt 400 unless pull_request['number'] && check_run['head_sha']

      {
        type: :check_run_rerequested,
        full_repo_name: payload['repository']['full_name'],
        pull_number: pull_request['number'],
        head_sha: check_run['head_sha']
      }
    when 'check_suite'
      check_suite = payload['check_suite']
      return unless check_suite.is_a?(Hash)
      return unless check_suite.dig('app', 'id')&.to_s == APP_IDENTIFIER
      return unless payload['action'] == 'rerequested'

      pull_request = check_suite['pull_requests']&.first
      return unless pull_request

      validate_repository(payload)
      halt 400 unless pull_request['number'] && check_suite['head_sha']

      {
        type: :check_suite_rerequested,
        full_repo_name: payload['repository']['full_name'],
        pull_number: pull_request['number'],
        head_sha: check_suite['head_sha']
      }
    end
  end

  def validate_repository(payload)
    repository = payload['repository']
    halt 400 unless repository.is_a?(Hash) && repository['full_name'].is_a?(String) && !repository['full_name'].empty?
  end

  # (1) Creates an empty check run on GitHub associated with the most recent commit
  def create_check_run(full_repo_name, head_sha)
    # Create a new check run to report on the progress of the app, and associate it with the most recent commit
    @installation_client.create_check_run(full_repo_name, APP_FRIENDLY_NAME, head_sha, status: 'queued', accept: 'application/vnd.github+json')
  end

  # (2) Contains the main logic of the app, checking and reporting on action items in code comments during a CI check
  def initiate_check_run(full_repo_name:, pull_number:, head_sha:, check_run_id:, app_options: nil)
    # As soon as the run is initiated, mark it as in progress on GitHub
    @installation_client.update_check_run(full_repo_name, check_run_id, status: 'in_progress', accept: 'application/vnd.github+json')

    # Get the options for the app from the `.github/config.yml` file in the repository
    app_options ||= get_app_options(full_repo_name, head_sha)
    # logger.debug app_options

    comment_footer = "\n----\nDid I do good? Let me know by [helping maintain this app](https://github.com/sponsors/NikkelM)!"

    # Get a list of changed lines in the Pull request, grouped by their file name and associated with a line number
    changes, ignored_files = get_pull_request_changes(full_repo_name, pull_number, app_options['ignore_files'])

    # Filter the changed lines for only those that contain action items ("Todos"), and group them by file
    todo_changes, unsupported_files = check_for_todos(changes, app_options)

    unchecked_files_string = ''
    unless ignored_files.empty? && unsupported_files.empty?
      remaining_file_limit = MAX_REPORTED_UNCHECKED_FILES
      reported_ignored_files = ignored_files.first(remaining_file_limit)
      remaining_file_limit -= reported_ignored_files.length
      reported_unsupported_files = unsupported_files.first(remaining_file_limit)
      omitted_file_count = ignored_files.length + unsupported_files.length - reported_ignored_files.length - reported_unsupported_files.length

      unchecked_files_string = "\n\n<details>\n<summary>Files not checked (#{ignored_files.length + unsupported_files.length})</summary>\n<br>\n\n"
      unless reported_ignored_files.empty?
        unchecked_files_string += "**Ignored by configuration**\n\n"
        unchecked_files_string += reported_ignored_files.map { |file| "- [`#{file}`](https://github.com/#{full_repo_name}/blob/#{head_sha}/#{file})" }.join("\n")
        unchecked_files_string += "\n\n"
      end
      unless reported_unsupported_files.empty?
        unchecked_files_string += "**Unsupported file types**\n\n"
        unsupported_file_groups = unsupported_files.group_by { |file| File.extname(file).downcase }
        reported_unsupported_files.group_by { |file| File.extname(file).downcase }.sort.each do |extension, files|
          group_name = extension.empty? ? 'No extension' : "`#{extension}`"
          unchecked_files_string += "#{group_name} (#{unsupported_file_groups.fetch(extension).length})\n\n"
          unchecked_files_string += files.map { |file| "- [`#{file}`](https://github.com/#{full_repo_name}/blob/#{head_sha}/#{file})" }.join("\n")
          unchecked_files_string += "\n\n"
        end
      end
      unchecked_files_string += "_...and #{omitted_file_count} more._\n\n" if omitted_file_count.positive?
      unchecked_files_string += "</details>\n"
    end

    # If there are no supported changes, mark the run as skipped and return early
    if (changes.keys - unsupported_files).empty?
      @installation_client.update_check_run(
        full_repo_name, check_run_id,
        status: 'completed',
        conclusion: 'skipped',
        output: { title: '✔ No changed files found!', summary: "No matching file types were changed with this Pull Request. If any are added later on, the bot will make sure to let you know.#{unchecked_files_string}#{comment_footer}" },
        accept: 'application/vnd.github+json'
      )
      return
    end

    # If the app has previously created a comment on the Pull Request, fetch it
    app_comment = fetch_app_comment(full_repo_name, pull_number)

    # If any action items were found, create/update a comment on the Pull Request with embedded links to the relevant lines
    if todo_changes.any?
      check_run_title, comment_summary, comment_body = create_pr_comment_from_changes(todo_changes, full_repo_name, head_sha, app_options).values_at(:title, :summary, :body)

      # If the user has enabled post_comment in the options
      if app_options['post_comment'] != 'never'
        # Post or update the comment with the found action items
        if app_comment
          @installation_client.update_comment(full_repo_name, app_comment.id, "#{comment_summary}#{comment_body}#{unchecked_files_string}#{comment_footer}", accept: 'application/vnd.github+json')
        else
          @installation_client.add_comment(full_repo_name, pull_number, "#{comment_summary}#{comment_body}#{unchecked_files_string}#{comment_footer}", accept: 'application/vnd.github+json')
        end
      end
      # Mark the check run as failed, as action items were found. This enables users to block Pull Requests with unresolved action items
      @installation_client.update_check_run(full_repo_name, check_run_id, status: 'completed', conclusion: 'failure', output: { title: check_run_title, summary: comment_summary, text: "#{comment_body}#{unchecked_files_string}#{comment_footer}" }, accept: 'application/vnd.github+json')
    else
      comment_header = '✔ No action items found!'
      # If the app has previously created a comment, update it to indicate that all action items have been resolved
      # If the app has not previously created a comment, we only create one if the user has enabled the option
      if app_comment || app_options['post_comment'] == 'always'
        if app_comment
          comment_header = '✔ All action items have been resolved!'
          @installation_client.update_comment(full_repo_name, app_comment.id, "#{comment_header}#{comment_footer}", accept: 'application/vnd.github+json')
        else
          @installation_client.add_comment(full_repo_name, pull_number, "#{comment_header}#{comment_footer}", accept: 'application/vnd.github+json')
        end
      end

      # Mark the check run as successful, as no action items were found
      @installation_client.update_check_run(
        full_repo_name, check_run_id,
        status: 'completed',
        conclusion: 'success',
        output: { title: comment_header, summary: "There are no new action items added in this Pull Request. If any are added later on, the bot will make sure to let you know.#{unchecked_files_string}#{comment_footer}" },
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
      'check_drafts' => false,
      'multiline_comments' => false,
      'action_items' => %w[todo fixme bug],
      'case_sensitive' => false,
      'check_inline_comments' => false,
      'standalone_items' => false,
      'add_languages' => [],
      'ignore_files' => [],
      'additional_lines' => 1,
      'always_split_snippets' => false
    }

    accepted_option_values = {
      'post_comment' => ->(value) { %w[items_found always never].include?(value) },
      'check_drafts' => ->(value) { [true, false].include?(value) },
      'multiline_comments' => ->(value) { [true, false].include?(value) },
      'action_items' => ->(value) { value.is_a?(Array) && (0..15).include?(value.size) },
      'case_sensitive' => ->(value) { [true, false].include?(value) },
      'check_inline_comments' => ->(value) { [true, false].include?(value) },
      'standalone_items' => ->(value) { [true, false].include?(value) },
      # A language may have multiple line characters, defined as an array of strings in second place, or just a string
      'add_languages' => lambda do |value|
        value.is_a?(Array) &&
          (1..10).include?(value.size) &&
          value.all? do |v|
            v.is_a?(Array) &&
              (2..4).include?(v.size) &&
              v[0].is_a?(String) &&
              (v.size == 2 || v.size == 4 ? (v[1].is_a?(Array) && v[1].all? { |i| i.is_a?(String) }) || v[1].is_a?(String) : v[1].is_a?(String)) &&
              (v[2..] || []).all? { |i| i.is_a?(String) || i.nil? }
          end
      end,
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
    ignore_files_regex.map! do |pattern|
      pattern.gsub!('.', '\.')
      pattern.gsub!('*', '.*')
      pattern.gsub!('/', '\/')
      Regexp.new(pattern)
    end

    changes = {}
    ignored_files = []

    # Paginate through all files in the pull request
    page = 1
    per_page = 100
    loop do
      files = @installation_client.pull_request_files(full_repo_name, pull_number, per_page: per_page, page: page)
      break if files.empty?

      files.each do |file|
        filename = file.filename
        if ignore_files_regex.any? { |pattern| pattern.match?(filename) }
          ignored_files << filename
          next
        end

        # Parse the patch to get added lines and their line numbers
        next unless file.patch
        changes[filename] = []
        line_number = 0
        file.patch.each_line do |line|
          if line.start_with?('@@')
            # Extract the new file's starting line number from the hunk header
            # Example: @@ -1,6 +1,7 @@
            m = line.match(/\+([0-9]+)/)
            line_number = m ? m[1].to_i : line_number
          elsif line.start_with?('+') && !line.start_with?('+++')
            changes[filename] << { line: line_number, text: line[1..] }
            line_number += 1
          elsif !line.start_with?('-') && !line.chomp.eql?('\ No newline at end of file')
            line_number += 1
          end
        end
      end

      page += 1
    end

    [changes, ignored_files]
  end

  # (5) Checks changed lines in supported file types for action items in code comments ("Todos")
  def check_for_todos(changes, options)
    multiline_comments = options['multiline_comments']
    action_items = options['action_items']
    case_sensitive = options['case_sensitive']
    check_inline_comments = options['check_inline_comments']
    standalone_items = options['standalone_items']

    todo_changes = {}
    unsupported_files = []
    in_multiline_comment = false

    comment_chars = get_comment_chars(options['add_languages'])

    # Create a regex for each action item
    regexes = action_items.map do |item|
      escaped_item = Regexp.escape(item)
      regex = standalone_items ? /(?<!\S)#{escaped_item}(?!\S)/ : /(?<!\w)#{escaped_item}(?!\w)/
      case_sensitive ? regex : Regexp.new(regex.source, Regexp::IGNORECASE)
    end

    # Changes are grouped by file name
    changes.each do |file, file_changes|
      file_type = File.extname(file).delete('.')
      comment_char = comment_chars.find { |key, _| key == file_type }

      # If there is no mapping for the file type, skip it
      unless comment_char
        unsupported_files << file
        next
      end

      file_todos = []
      in_multiline_comment = false
      # Check each line in the file for action items
      file_changes.each do |line|
        text = line[:text].strip
        block_start = comment_char[1][:block_start]
        line_comment_starts = comment_char[1][:line].compact
        line_comment_start_index = if check_inline_comments
                                     line_comment_starts.filter_map { |char| text.index(char) }.min
                                   else
                                     0 if line_comment_starts.any? { |char| text.start_with?(char) }
                                   end
        block_start_index = if check_inline_comments
                              text.index(block_start) if block_start
                            else
                              0 if block_start && text.start_with?(block_start)
                            end
        comment_start_index = [line_comment_start_index, block_start_index].compact.min
        comment_text = in_multiline_comment ? text : text[comment_start_index..] if in_multiline_comment || comment_start_index

        # If the line is a comment and contains any action item, add it to the output collection
        file_todos << line if comment_text && regexes.any? { |regex| comment_text.match(regex) }

        if !multiline_comments
          in_multiline_comment = false
        elsif in_multiline_comment
          in_multiline_comment = false if comment_char[1][:block_end] && text.include?(comment_char[1][:block_end])
        elsif block_start_index && (!line_comment_start_index || block_start_index <= line_comment_start_index)
          block_end_index = text.index(comment_char[1][:block_end], block_start_index + block_start.length)
          in_multiline_comment = block_end_index.nil?
        end
      end

      # We don't want to add files to the output collection if they don't contain any action items, as they shouldn't be posted in the comment
      todo_changes[file] = file_todos unless file_todos.empty?
    end

    [todo_changes, unsupported_files]
  end

  # (6) Retrieves the file types and comment characters for the app's supported languages, and user defined values
  def get_comment_chars(added_languages)
    default_comment_chars = {
      %w[md html xml] => { line: ['<!--'], block_start: '<!--', block_end: '-->' },
      %w[astro] => { line: ['//'], block_start: '<!--', block_end: '-->' },
      %w[js java ts c cpp cs swift go kt rs dart sc groovy less sass scss] => { line: ['//'], block_start: '/*', block_end: '*/' },
      %w[php] => { line: ['//', '#'], block_start: '/*', block_end: '*/' },
      %w[css] => { line: ['/*'], block_start: '/*', block_end: '*/' },
      %w[r gitignore sh bash yml yaml] => { line: ['#'], block_start: nil, block_end: nil },
      %w[rb] => { line: ['#'], block_start: '=begin', block_end: '=end' },
      %w[pl] => { line: ['#'], block_start: '=', block_end: '=cut' },
      %w[py] => { line: ['#'], block_start: "'''", block_end: "'''" },
      %w[ps1] => { line: ['#'], block_start: '<#', block_end: '#>' },
      %w[sql] => { line: ['--'], block_start: '/*', block_end: '*/' },
      %w[hs] => { line: ['--'], block_start: '{-', block_end: '-}' },
      %w[lua] => { line: ['--'], block_start: '--[[', block_end: ']]' },
      %w[m] => { line: ['%'], block_start: '%{', block_end: '%}' },
      %w[tex] => { line: ['%'], block_start: nil, block_end: nil }
    }

    unwrapped_comment_chars = {}
    default_comment_chars.each do |file_types, comment_symbols|
      file_types.each do |file_type|
        unwrapped_comment_chars[file_type] = comment_symbols
      end
    end

    added_languages.each do |lang|
      file_type = lang[0].sub(/^\./, '')
      line_chars = lang[1].is_a?(Array) ? lang[1] : [lang[1]]
      # The length of lang defines which permutation is given by the user
      # Users may overwrite the default comment characters for a file type
      case lang.length
      when 2
        unwrapped_comment_chars[file_type] = { line: line_chars, block_start: nil, block_end: nil }
      when 3
        # If only the block comment was defined, we need to extract the character from the array entry when setting the block start character, as it was parsed to an array earlier
        unwrapped_comment_chars[file_type] = { line: line_chars, block_start: line_chars[0], block_end: lang[2] }
      when 4
        unwrapped_comment_chars[file_type] = { line: line_chars, block_start: lang[2], block_end: lang[3] }
      end
    end

    unwrapped_comment_chars
  end

  # (7) Creates a comment text from the found action items, with embedded links to the relevant lines
  def create_pr_comment_from_changes(todo_changes, full_repo_name, head_sha, app_options)
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
      file_link = "https://github.com/#{full_repo_name}/blob/#{head_sha}/#{file}"
      num_items = if changes.count == 1
                    '1 action item'
                  else
                    "#{changes.count} action items"
                  end
      comment_body += "\n## [`#{file}`](#{file_link}) (#{num_items}):\n"

      # Sort the changes by their line number, and group those that are close together into one embedded link
      changes.sort_by! { |change| change[:line] }
      grouped_changes = if always_split_snippets
                          changes.map { |change| [change] }
                        else
                          changes.slice_when { |prev, curr| (curr[:line] - prev[:line] > 3) && (curr[:line] - (prev[:line] + additional_lines) > 1) }.to_a
                        end

      grouped_changes.each do |group|
        first_line = group.first[:line]
        last_line = group.last[:line]
        comment_body += if first_line == last_line && additional_lines.zero?
                          "https://github.com/#{full_repo_name}/blob/#{head_sha}/#{file}#L#{first_line} "
                        else
                          "https://github.com/#{full_repo_name}/blob/#{head_sha}/#{file}#L#{first_line}-L#{last_line + additional_lines} "
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
    their_signature_header = request.env['HTTP_X_HUB_SIGNATURE_256'] || 'sha256='
    method, their_digest = their_signature_header.split('=')
    our_digest = OpenSSL::HMAC.hexdigest(method, GITHUB_WEBHOOK_SECRET, @payload_raw)
    halt 401 unless Rack::Utils.secure_compare(their_digest, our_digest)

    logger.debug "---- received event #{request.env['HTTP_X_GITHUB_EVENT']}"
    logger.debug "----    action #{@payload['action']}" unless @payload['action'].nil?
  end
end
