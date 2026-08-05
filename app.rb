# frozen_string_literal: true

require 'base64'
require 'dotenv/load'
require 'erb'
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
MAX_REPORTED_SKIPPED_FILES = 50
MAX_ANNOTATIONS_PER_REQUEST = 50
MARKETPLACE_URL = 'https://github.com/marketplace/todo-pr-checker'
CREATE_ISSUES_ACTION = 'create_issues'
SUPPORTED_CHECK_RUN_ACTIONS = [CREATE_ISSUES_ACTION].freeze
ISSUE_MARKER_PATTERN = /<!-- todo-pr-checker \| (.+?) -->/
ISSUE_MARKER_NOTE = '<!-- The comment below lets Todo PR Checker recognise which action item this issue belongs to, so it is not created a second time. Please do not remove or edit it. -->'
MAX_ISSUE_MARKER_TEXT = 150
MAX_ISSUES_PER_REQUEST = 20
MAX_CREATED_ISSUES_PER_RUN = 50
MAX_ISSUE_TITLE_EXCERPT = 50
MAX_ISSUE_LOOKUP_PAGES = 10

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

  # A requested action reuses the existing check run instead of starting a new one
  check_run_id = event_context[:check_run_id] || create_check_run(event_context[:full_repo_name], event_context[:head_sha]).id
  check_arguments = {
    full_repo_name: event_context[:full_repo_name],
    pull_number: event_context[:pull_number],
    head_sha: event_context[:head_sha],
    check_run_id: check_run_id
  }
  check_arguments[:app_options] = app_options if app_options
  check_arguments[:requested_action] = event_context[:requested_action] if event_context[:requested_action]
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
      return unless %w[rerequested requested_action].include?(payload['action'])

      pull_request = check_run['pull_requests']&.first
      return unless pull_request

      validate_repository(payload)
      halt 400 unless pull_request['number'] && check_run['head_sha']

      if payload['action'] == 'requested_action'
        requested_action = payload.dig('requested_action', 'identifier')
        return unless SUPPORTED_CHECK_RUN_ACTIONS.include?(requested_action)

        return {
          type: :check_run_requested_action,
          requested_action: requested_action,
          full_repo_name: payload['repository']['full_name'],
          pull_number: pull_request['number'],
          head_sha: check_run['head_sha'],
          check_run_id: check_run['id']
        }
      end

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
  def initiate_check_run(full_repo_name:, pull_number:, head_sha:, check_run_id:, app_options: nil, requested_action: nil)
    # As soon as the run is initiated, mark it as in progress on GitHub
    @installation_client.update_check_run(full_repo_name, check_run_id, status: 'in_progress', accept: 'application/vnd.github+json')

    # Get the options for the app from the `.github/config.yml` file in the repository
    app_options ||= get_app_options(full_repo_name, head_sha)
    configuration_details = create_configuration_details(app_options)

    comment_footer = "\n----\nDid I do good? Let me know by [helping maintain this app](https://github.com/sponsors/NikkelM)!"

    # Get a list of changed lines in the Pull request, grouped by their file name and associated with a line number
    changes, ignored_files, last_diff_lines = get_pull_request_changes(full_repo_name, pull_number, app_options['ignore_files'])

    # Filter the changed lines for only those that contain action items ("Todos"), and group them by file
    todo_changes, unsupported_files = check_for_todos(changes, app_options)

    skipped_files_string = ''
    unless ignored_files.empty? && unsupported_files.empty?
      remaining_file_limit = MAX_REPORTED_SKIPPED_FILES
      reported_ignored_files = ignored_files.first(remaining_file_limit)
      remaining_file_limit -= reported_ignored_files.length
      reported_unsupported_files = unsupported_files.first(remaining_file_limit)
      omitted_file_count = ignored_files.length + unsupported_files.length - reported_ignored_files.length - reported_unsupported_files.length

      skipped_files_string = "\n\n<details>\n<summary>Skipped files (#{ignored_files.length + unsupported_files.length})</summary>\n<br>\n\n"
      unless reported_ignored_files.empty?
        skipped_files_string += "**Ignored by configuration**\n\n"
        ignored_file_groups = ignored_files.group_by { |file| File.extname(file).downcase }
        reported_ignored_files.group_by { |file| File.extname(file).downcase }.sort.each do |extension, files|
          group_name = extension.empty? ? 'No extension' : "`#{extension}`"
          skipped_files_string += "#{group_name} (#{ignored_file_groups.fetch(extension).length})\n\n"
          skipped_files_string += files.map { |file| "- [#{code_span(file)}](#{blob_link(full_repo_name, head_sha, file)})" }.join("\n")
          skipped_files_string += "\n\n"
        end
      end
      unless reported_unsupported_files.empty?
        skipped_files_string += "**Unsupported file types**\n\n"
        unsupported_file_groups = unsupported_files.group_by { |file| File.extname(file).downcase }
        reported_unsupported_files.group_by { |file| File.extname(file).downcase }.sort.each do |extension, files|
          group_name = extension.empty? ? 'No extension' : "`#{extension}`"
          skipped_files_string += "#{group_name} (#{unsupported_file_groups.fetch(extension).length})\n\n"
          skipped_files_string += files.map { |file| "- [#{code_span(file)}](#{blob_link(full_repo_name, head_sha, file)})" }.join("\n")
          skipped_files_string += "\n\n"
        end
      end
      skipped_files_string += "_...and #{omitted_file_count} more._\n\n" if omitted_file_count.positive?
      skipped_files_string += "</details>\n"
    end

    # If there are no supported changes, mark the run as skipped and return early
    if (changes.keys - unsupported_files).empty?
      @installation_client.update_check_run(
        full_repo_name, check_run_id,
        status: 'completed',
        conclusion: 'skipped',
        output: {
          title: '✔ No changed files found!',
          summary: "No matching file types were changed with this Pull Request. If any are added later on, the bot will make sure to let you know.#{skipped_files_string}#{comment_footer}",
          text: configuration_details
        },
        accept: 'application/vnd.github+json'
      )
      return
    end

    # If the app has previously created a comment on the Pull Request, fetch it
    app_comment = fetch_app_comment(full_repo_name, pull_number)

    # If any action items were found, create/update a comment on the Pull Request with embedded links to the relevant lines
    if todo_changes.any?
      # Set when the user asked for the issues through the check run action, which is honoured even outside of `always`
      create_issues_now = requested_action == CREATE_ISSUES_ACTION

      # Existing issues are needed both for linking them and for not creating them twice, so they are looked up for
      # every mode that involves issues, including `links`, which only renders links and never creates anything itself
      issue_options = app_options
      if app_options['create_issues'] != 'never' || create_issues_now
        pull_request_details = fetch_pull_request_details(full_repo_name, pull_number)
        pull_request_title = pull_request_details[:title]

        # A fork can change the configuration of the Pull Request it opens, so issues are only created based on the
        # configuration of the branch being merged into, and only if that configuration opted into fork Pull Requests
        if pull_request_details[:from_fork]
          base_ref = pull_request_details[:base_ref]
          issue_options = base_ref ? get_app_options(full_repo_name, base_ref) : app_options.merge('create_issues' => 'never')
          issue_options = issue_options.merge('create_issues' => 'never') unless issue_options['create_issues_from_forks']
        end

        # Reused for both linking already existing issues and skipping action items that already have one
        issues_by_fingerprint = fetch_existing_issues(full_repo_name, pull_request_details[:created_at]) unless issue_options['create_issues'] == 'never'
      end
      issues_by_fingerprint ||= {}

      # Issues are only created automatically with `always`, or when the check run action explicitly requested them
      created_issues = if issue_options['create_issues'] == 'always' || (create_issues_now && issue_options['create_issues'] != 'never')
                         create_issues_from_changes(todo_changes, full_repo_name, head_sha, pull_number, issue_options, pull_request_title, issues_by_fingerprint, last_diff_lines)
                       else
                         []
                       end

      check_run_title, comment_summary, comment_body = create_pr_comment_from_changes(
        todo_changes, full_repo_name, head_sha, app_options,
        pull_number: pull_number, pull_request_title: pull_request_title,
        issues_by_fingerprint: issues_by_fingerprint, last_diff_lines: last_diff_lines,
        issue_options: issue_options
      ).values_at(:title, :summary, :body)
      annotation_batches = if app_options['post_annotations']
                             create_check_annotations(todo_changes).each_slice(MAX_ANNOTATIONS_PER_REQUEST).to_a
                           else
                             []
                           end

      # If the user has enabled post_comment in the options
      if app_options['post_comment'] != 'never'
        # Post or update the comment with the found action items
        if app_comment
          @installation_client.update_comment(full_repo_name, app_comment.id, "#{comment_summary}#{comment_body}#{skipped_files_string}#{comment_footer}", accept: 'application/vnd.github+json')
        else
          @installation_client.add_comment(full_repo_name, pull_number, "#{comment_summary}#{comment_body}#{skipped_files_string}#{comment_footer}", accept: 'application/vnd.github+json')
        end
      end
      annotation_batches[0...-1].each do |annotations|
        @installation_client.update_check_run(
          full_repo_name, check_run_id,
          output: {
            title: check_run_title,
            summary: comment_summary,
            annotations: annotations
          },
          accept: 'application/vnd.github+json'
        )
      end
      check_output = {
        title: check_run_title,
        summary: "#{comment_summary}#{comment_body}#{skipped_files_string}#{comment_footer}",
        text: configuration_details
      }
      check_output[:annotations] = annotation_batches.last unless annotation_batches.empty?
      check_arguments = {
        status: 'completed',
        conclusion: 'failure',
        output: check_output,
        accept: 'application/vnd.github+json'
      }
      # Offer creating every issue at once, unless this run was started by that action already
      if issue_options['create_issues'] == 'links' && !create_issues_now
        check_arguments[:actions] = [{ label: 'Create all issues', description: 'Create an issue for each identified action item', identifier: CREATE_ISSUES_ACTION }]
      end
      # Mark the check run as failed, as action items were found. This enables users to block Pull Requests with unresolved action items
      @installation_client.update_check_run(full_repo_name, check_run_id, **check_arguments)
    else
      comment_header = '✔ No action items found!'
      # If the app has previously created a comment, update it to indicate that all action items have been resolved
      # If the app has not previously created a comment, we only create one if the user has enabled the option
      if app_comment || app_options['post_comment'] == 'always'
        if app_comment
          comment_header = '✔ All action items have been resolved!'
          @installation_client.update_comment(full_repo_name, app_comment.id, "#{comment_header}#{skipped_files_string}#{comment_footer}", accept: 'application/vnd.github+json')
        else
          @installation_client.add_comment(full_repo_name, pull_number, "#{comment_header}#{skipped_files_string}#{comment_footer}", accept: 'application/vnd.github+json')
        end
      end

      # Mark the check run as successful, as no action items were found
      @installation_client.update_check_run(
        full_repo_name, check_run_id,
        status: 'completed',
        conclusion: 'success',
        output: {
          title: comment_header,
          summary: "There are no new action items added in this Pull Request. If any are added later on, the bot will make sure to let you know.#{skipped_files_string}#{comment_footer}",
          text: configuration_details
        },
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

  def create_configuration_details(app_options)
    yaml = YAML.dump(app_options).delete_prefix("---\n")
    fence = '`' * [3, yaml.scan(/`+/).map(&:length).max.to_i + 1].max
    "\n\n<details>\n<summary>Configuration used</summary>\n\n#{fence}yaml\n#{yaml}#{fence}\n\n</details>\n"
  end

  def create_check_annotations(todo_changes)
    todo_changes.flat_map do |path, changes|
      changes.map do |change|
        {
          path: path,
          start_line: change[:line],
          end_line: change[:line],
          annotation_level: 'failure',
          title: 'Unresolved action item',
          message: change[:text].strip
        }
      end
    end
  end

  # File paths and Pull Request titles are attacker controlled, so they must never be able to break out of Markdown links
  def blob_link(full_repo_name, head_sha, file)
    encoded_path = file.to_s.split('/').map { |segment| ERB::Util.url_encode(segment) }.join('/')

    "https://github.com/#{full_repo_name}/blob/#{head_sha}/#{encoded_path}"
  end

  # Escapes the characters that would end a link label or start raw HTML
  def escape_markdown(text)
    text.to_s.gsub(/[\\\[\]<>]/) { |character| "\\#{character}" }
  end

  # Renders text inside a code span, using a fence long enough to contain any backticks the text holds
  def code_span(text)
    value = text.to_s
    fence = '`' * (value.scan(/`+/).map(&:length).max.to_i + 1)

    "#{fence}#{value.start_with?('`') ? ' ' : ''}#{value}#{value.end_with?('`') ? ' ' : ''}#{fence}"
  end

  def create_issue_title(file, change)
    location = "#{File.basename(file)}:#{change[:line]}"
    excerpt = create_issue_excerpt(change)

    excerpt ? "[#{change[:item]}] #{location} - #{excerpt}" : "[#{change[:item]}] #{location}"
  end

  # Uses the text following the action item, so the title says what needs to be done instead of only where
  # The description is taken from the comment the item was found in, so inline code before the comment is never included
  def create_issue_excerpt(change)
    text_after_item = change[:description] || change[:text].to_s.split(/(?<!\w)#{Regexp.escape(change[:item].to_s)}(?!\w)/i, 2)[1].to_s
    excerpt = text_after_item.sub(%r{\*/\s*\z}, '').sub(/-->\s*\z/, '').strip.sub(/\A[:;,\-\s]+/, '').gsub(/\s+/, ' ')
    return nil if excerpt.empty?

    return excerpt if excerpt.length <= MAX_ISSUE_TITLE_EXCERPT

    "#{excerpt[0, MAX_ISSUE_TITLE_EXCERPT - 1].rstrip}…"
  end

  # Identifies an action item independently of its line number, so that shifting code does not create a second issue
  # Kept in plain text so users can see what an issue was created for
  def create_issue_fingerprint(file, change)
    parts = [file, change[:item], change[:text]].map do |part|
      value = part.to_s.gsub('-->', '').strip.gsub(/\s+/, ' ')
      value.length > MAX_ISSUE_MARKER_TEXT ? "#{value[0, MAX_ISSUE_MARKER_TEXT - 1].rstrip}…" : value
    end

    "file: #{parts[0]} | item: #{parts[1]} | text: #{parts[2]}"
  end

  # The body embeds a permalink covering the same lines as the code snippets in the Pull Request comment
  def create_issue_body(file, change, full_repo_name, head_sha, pull_number, additional_lines, pull_request_title = nil, last_diff_line: nil)
    file_link = blob_link(full_repo_name, head_sha, file)
    end_line = snippet_end_line(change[:line], additional_lines, last_diff_line)
    snippet_link = if end_line <= change[:line]
                     "#{file_link}#L#{change[:line]}"
                   else
                     "#{file_link}#L#{change[:line]}-L#{end_line}"
                   end
    pull_request_link = "https://github.com/#{full_repo_name}/pull/#{pull_number}"
    pull_request_reference = if pull_request_title.nil? || pull_request_title.strip.empty?
                               pull_request_link
                             else
                               "[PR ##{pull_number}: #{escape_markdown(pull_request_title)}](#{pull_request_link})"
                             end

    "An unresolved action item #{code_span(change[:item])} was found in [#{code_span(file)}](#{file_link}#L#{change[:line]}):\n\n" \
      "#{snippet_link}\n\n" \
      "Identified by [Todo PR Checker](#{MARKETPLACE_URL}) in #{pull_request_reference}\n\n" \
      "_The snippet above links to the commit the action item was found in, and is not updated if the action item moves to a different line._\n" \
      "\n----\nDid I do good? Let me know by [helping maintain this app](https://github.com/sponsors/NikkelM)!\n\n" \
      "#{ISSUE_MARKER_NOTE}\n" \
      "<!-- todo-pr-checker | #{create_issue_fingerprint(file, change)} -->\n"
  end

  # Creates a link that opens the new issue form with the title, body and labels already filled in
  def create_issue_link(full_repo_name, title, body, issue_labels)
    query = { 'title' => title, 'body' => body }
    query['labels'] = issue_labels.join(',') unless issue_labels.empty?

    "https://github.com/#{full_repo_name}/issues/new?#{URI.encode_www_form(query)}"
  end

  # Creates one issue per action item, skipping any action item that already has an issue
  # Issues are created in batches, so that even Pull Requests with many action items only need a few requests
  def create_issues_from_changes(todo_changes, full_repo_name, head_sha, pull_number, app_options, pull_request_title = nil, issues_by_fingerprint = {}, last_diff_lines = {})
    pending_issues = []

    todo_changes.each do |file, changes|
      changes.each do |change|
        fingerprint = create_issue_fingerprint(file, change)
        next if issues_by_fingerprint.key?(fingerprint) || pending_issues.any? { |pending| pending[:fingerprint] == fingerprint }

        pending_issues << {
          fingerprint: fingerprint,
          title: create_issue_title(file, change),
          body: create_issue_body(file, change, full_repo_name, head_sha, pull_number, app_options['additional_lines'], pull_request_title, last_diff_line: last_diff_lines[file])
        }
      end
    end
    return [] if pending_issues.empty?

    # A single Pull Request should never be able to fill a repository with issues, no matter how many action items it adds
    pending_issues = pending_issues.first(MAX_CREATED_ISSUES_PER_RUN)

    # A single issue is created through REST, which does not need the repository and label ids
    if pending_issues.length == 1
      pending = pending_issues.first
      issue_arguments = { accept: 'application/vnd.github+json' }
      issue_arguments[:labels] = app_options['issue_labels'] unless app_options['issue_labels'].empty?
      issue = @installation_client.create_issue(full_repo_name, pending[:title], pending[:body], **issue_arguments)
      issues_by_fingerprint[pending[:fingerprint]] = { number: issue.number, url: issue.html_url }

      return [issue]
    end

    repository = fetch_repository_issue_metadata(full_repo_name, app_options['issue_labels'])
    created_issues = []

    pending_issues.each_slice(MAX_ISSUES_PER_REQUEST) do |batch|
      created_issues.concat(create_issue_batch(repository, batch, issues_by_fingerprint))
    end

    created_issues
  end

  # Issues are created through GraphQL, which needs the repository and label ids instead of their names
  # Labels that do not exist in the repository are ignored, as GraphQL cannot create them
  def fetch_repository_issue_metadata(full_repo_name, issue_labels)
    owner, name = full_repo_name.split('/')
    query = 'query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { id labels(first: 100) { nodes { id name } } } }'
    repository = run_graphql(query, owner: owner, name: name).data.repository
    wanted_labels = issue_labels.map(&:downcase)
    label_ids = repository.labels.nodes.select { |label| wanted_labels.include?(label.name.downcase) }.map(&:id)

    { id: repository.id, label_ids: label_ids }
  end

  def create_issue_batch(repository, batch, issues_by_fingerprint)
    variables = { 'repository' => repository[:id] }
    variables['labels'] = repository[:label_ids] unless repository[:label_ids].empty?
    label_argument = repository[:label_ids].empty? ? '' : ', labelIds: $labels'

    definitions = ['$repository: ID!']
    definitions << '$labels: [ID!]' unless repository[:label_ids].empty?
    mutations = batch.each_with_index.map do |issue, index|
      definitions.push("$title#{index}: String!", "$body#{index}: String!")
      variables["title#{index}"] = issue[:title]
      variables["body#{index}"] = issue[:body]
      "issue#{index}: createIssue(input: { repositoryId: $repository, title: $title#{index}, body: $body#{index}#{label_argument} }) { issue { number url } }"
    end

    response = run_graphql("mutation(#{definitions.join(', ')}) { #{mutations.join(' ')} }", **variables.transform_keys(&:to_sym))

    batch.each_with_index.map do |pending, index|
      issue = response.data.send("issue#{index}").issue
      issues_by_fingerprint[pending[:fingerprint]] = { number: issue.number, url: issue.url }
      issue
    end
  end

  def run_graphql(query, **variables)
    response = @installation_client.post('/graphql', { query: query, variables: variables }.to_json)
    raise "GraphQL request failed: #{response.errors.map(&:message).join(', ')}" if response.errors

    response
  end

  # Issues of any state are considered, so that issues the user already closed are not created again
  # Only issues carrying a marker are requested, and only those created after the Pull Request, as an action item added
  # by this Pull Request cannot have been reported by an issue that already existed before it
  # Action items are identified by the marker in the issue body, so renamed issues are still recognised
  def fetch_existing_issues(full_repo_name, pull_request_created_at = nil)
    issues_by_fingerprint = {}
    query = "repo:#{full_repo_name} \"todo-pr-checker\" in:body"
    query += " created:>=#{pull_request_created_at.utc.iso8601}" if pull_request_created_at.respond_to?(:utc)

    (1..MAX_ISSUE_LOOKUP_PAGES).each do |page|
      results = @installation_client.search_issues(query, per_page: 100, page: page, accept: 'application/vnd.github+json')
      items = results.items
      break if items.nil? || items.empty?

      items.each do |issue|
        issue.body.to_s.scan(ISSUE_MARKER_PATTERN).flatten.each do |fingerprint|
          issues_by_fingerprint[fingerprint] ||= { number: issue.number, url: issue.html_url }
        end
      end
      break if items.length < 100
    end

    issues_by_fingerprint
  end

  # (3) Retrieves the `.github/config.yml` and parses the app's options
  def get_app_options(full_repo_name, head_sha)
    default_options = {
      'post_comment' => 'items_found',
      'post_annotations' => true,
      'create_issues' => 'never',
      'create_issues_from_forks' => false,
      'issue_labels' => [],
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
      'post_annotations' => ->(value) { [true, false].include?(value) },
      'create_issues' => ->(value) { %w[never links always].include?(value) },
      'create_issues_from_forks' => ->(value) { [true, false].include?(value) },
      'issue_labels' => ->(value) { value.is_a?(Array) && (0..10).include?(value.size) && value.all? { |v| v.is_a?(String) && !v.strip.empty? } },
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
    last_diff_lines = {}

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
        # The diff only covers the changed parts of a file, so this is the last line that is known to exist
        last_diff_lines[filename] = line_number - 1
      end

      page += 1
    end

    [changes, ignored_files, last_diff_lines]
  end

  # Code snippets cannot be rendered by GitHub if they reference lines beyond the end of a file
  def snippet_end_line(start_line, additional_lines, last_diff_line)
    end_line = start_line + additional_lines
    return end_line if last_diff_line.nil?

    [end_line, [last_diff_line, start_line].max].min
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

    # Create a regex for each action item, keeping the configured value so the matched item can be reported
    item_regexes = action_items.map do |item|
      escaped_item = Regexp.escape(item)
      regex = standalone_items ? /(?<!\S)#{escaped_item}(?!\S)/ : /(?<!\w)#{escaped_item}(?!\w)/
      [item, case_sensitive ? regex : Regexp.new(regex.source, Regexp::IGNORECASE)]
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
        # The text following the match is kept so descriptions can be taken from the comment only, never from surrounding code
        if comment_text
          matched_item, matched_text = item_regexes.filter_map do |item, regex|
            match = comment_text.match(regex)
            [item, match.post_match] if match
          end.first
        end
        file_todos << line.merge(item: matched_item, description: matched_text) if matched_item

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
  def create_pr_comment_from_changes(todo_changes, full_repo_name, head_sha, app_options, pull_number: nil, pull_request_title: nil, issues_by_fingerprint: {}, last_diff_lines: {}, issue_options: nil)
    additional_lines = app_options['additional_lines']
    always_split_snippets = app_options['always_split_snippets']
    issue_options ||= app_options
    create_issue_links = issue_options['create_issues'] == 'links' && !pull_number.nil?
    issue_labels = issue_options['issue_labels'] || []

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
      file_link = blob_link(full_repo_name, head_sha, file)
      num_items = if changes.count == 1
                    '1 action item'
                  else
                    "#{changes.count} action items"
                  end
      comment_body += "\n## [#{code_span(file)}](#{file_link}) (#{num_items}):\n"

      # Sort the changes by their line number, and group those that are close together into one embedded link
      changes.sort_by! { |change| change[:line] }

      # Action items that already have an issue are listed once for the file, the rest are offered per code snippet below
      tracked_links = changes.filter_map do |change|
        existing_issue = issues_by_fingerprint[create_issue_fingerprint(file, change)]
        next unless existing_issue

        "[##{existing_issue[:number]}: #{code_span(change[:item])} on line #{change[:line]}](#{existing_issue[:url]})"
      end
      comment_body += "\n📌 Action items tracked in issues: #{tracked_links.join(' · ')}\n" unless tracked_links.empty?

      grouped_changes = if always_split_snippets
                          changes.map { |change| [change] }
                        else
                          changes.slice_when { |prev, curr| (curr[:line] - prev[:line] > 3) && (curr[:line] - (prev[:line] + additional_lines) > 1) }.to_a
                        end

      grouped_changes.each do |group|
        first_line = group.first[:line]
        last_line = snippet_end_line(group.last[:line], additional_lines, last_diff_lines[file])
        comment_body += if first_line >= last_line
                          "\n#{file_link}#L#{first_line}\n"
                        else
                          "\n#{file_link}#L#{first_line}-L#{last_line}\n"
                        end

        next unless create_issue_links

        creation_links = group.filter_map do |change|
          next if issues_by_fingerprint.key?(create_issue_fingerprint(file, change))

          issue_title = create_issue_title(file, change)
          issue_body = create_issue_body(file, change, full_repo_name, head_sha, pull_number, additional_lines, pull_request_title, last_diff_line: last_diff_lines[file])
          "[#{code_span(change[:item])} on line #{change[:line]}](#{create_issue_link(full_repo_name, issue_title, issue_body, issue_labels)})"
        end
        next if creation_links.empty?

        creation_label = creation_links.length == 1 ? 'Create an issue for' : 'Create issues for'
        comment_body += "\n📝 #{creation_label} #{creation_links.join(' · ')}\n"
      end
    end

    { title: check_run_title, summary: comment_summary, body: comment_body }
  end

  # The Pull Request is only needed for issues, so a failure must not fail the check
  # Whether the Pull Request comes from a fork decides if its configuration can be trusted to create issues
  def fetch_pull_request_details(full_repo_name, pull_number)
    pull_request = @installation_client.pull_request(full_repo_name, pull_number, accept: 'application/vnd.github+json')

    {
      title: pull_request.title,
      created_at: pull_request.created_at,
      base_ref: pull_request.base&.ref,
      from_fork: pull_request.head&.repo&.full_name.to_s != full_repo_name
    }
  rescue StandardError => e
    logger.debug "Could not fetch the Pull Request: #{e}"
    # Without the Pull Request the origin of the configuration cannot be established, so no issues are created
    { from_fork: true }
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
