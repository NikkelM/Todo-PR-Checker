# frozen_string_literal: true

require 'sinatra'
require 'octokit'
require 'dotenv/load'
require 'json'
require 'openssl'
require 'jwt'
require 'time'
require 'logger'
require 'git'
require 'net/http'
require 'uri'
require_relative 'version'

set :bind, '0.0.0.0'
set :port, ENV['PORT'] || '3000'

PRIVATE_KEY = OpenSSL::PKey::RSA.new(ENV['GITHUB_PRIVATE_KEY'].gsub('\n', "\n"))
WEBHOOK_SECRET = ENV['GITHUB_WEBHOOK_SECRET']
APP_IDENTIFIER = ENV['GITHUB_APP_IDENTIFIER']

configure :development do
  set :logging, Logger::DEBUG
end

puts "Running Todo PR Checker version: #{VERSION}"

before '/' do
  get_payload_request(request)
  verify_webhook_signature

  unless @payload['repository'].nil?
    halt 400 if (@payload['repository']['name'] =~ /[0-9A-Za-z\-\_]+/).nil?
  end

  authenticate_app
  authenticate_installation(@payload)
end

post '/' do
  event_type = request.env['HTTP_X_GITHUB_EVENT']

  if event_type == 'pull_request' && @payload['action'] == 'opened'
    create_check_run
  end

  if event_type == 'check_suite' && (@payload['action'] == 'requested' || @payload['action'] == 'rerequested')
    pull_request = @payload['check_suite']['pull_requests'].first
    if pull_request
      create_check_run
    end
  end

  if event_type == 'check_run' && @payload['check_run']['app']['id'].to_s == APP_IDENTIFIER
    pull_request = @payload['check_run']['pull_requests'].first
    if pull_request
      if @payload['action'] == 'created'
        initiate_check_run
      elsif @payload['action'] == 'rerequested'
        create_check_run
      end
    end
  end

  200
end

helpers do
  def create_check_run
    sha = if @payload['pull_request']
            @payload['pull_request']['head']['sha']
          elsif @payload['check_run']
            @payload['check_run']['head_sha']
          else
            @payload['check_suite']['head_sha']
          end

    @installation_client.create_check_run(
      @payload['repository']['full_name'],
      'Todo PR Checker',
      sha,
      accept: 'application/vnd.github+json'
    )
  end

  def fetch_bot_comment(full_repo_name, pull_number)
    comments = @installation_client.issue_comments(
      full_repo_name,
      pull_number,
      accept: 'application/vnd.github.v3+json'
    )

    comments.find { |comment| comment.performed_via_github_app&.id == APP_IDENTIFIER.to_i }
  end

  def initiate_check_run
    @installation_client.update_check_run(
      @payload['repository']['full_name'],
      @payload['check_run']['id'],
      status: 'in_progress',
      accept: 'application/vnd.github+json'
    )

    full_repo_name = @payload['repository']['full_name']
    pull_requests = @payload['check_run']['pull_requests']
    pull_number = pull_requests.first['number'] if pull_requests.any?

    changes = get_pull_request_changes(full_repo_name, pull_number)

    todo_changes = check_for_todos(changes)

    if todo_changes.any?
      number_of_todos = todo_changes.values.flatten.count
      comment_body = if number_of_todos == 1
                       "There is 1 unresolved action item in this Pull Request:\n\n"
                     else
                       "There are #{number_of_todos} unresolved action items in this Pull Request:\n\n"
                     end
      todo_changes.each do |file, changes|
        file_link = "https://github.com/#{full_repo_name}/blob/#{@payload['check_run']['head_sha']}/#{file}"
        num_items = if changes.count == 1
                      '1 item'
                    else
                      "#{changes.count} items"
                    end
        comment_body += "\n## [`#{file}`](#{file_link}) (#{num_items}):\n"
        changes.sort_by! { |change| change[:line] }
        grouped_changes = changes.slice_when { |prev, curr| curr[:line] - prev[:line] > 3 }.to_a
        grouped_changes.each do |group|
          first_line = group.first[:line]
          last_line = group.last[:line]
          if first_line == last_line
            comment_body += "https://github.com/#{full_repo_name}/blob/#{@payload['check_run']['head_sha']}/#{file}#L#{first_line} "
          else
            comment_body += "https://github.com/#{full_repo_name}/blob/#{@payload['check_run']['head_sha']}/#{file}#L#{first_line}-L#{last_line} "
          end
        end
      end
      comment_body += "\n----\nDid I do good? Let me know by [helping maintain this app](https://github.com/sponsors/NikkelM)!"

      app_comment = fetch_bot_comment(full_repo_name, pull_number)

      if app_comment
        @installation_client.update_comment(
          full_repo_name,
          app_comment.id,
          comment_body,
          accept: 'application/vnd.github.v3+json'
        )
      else
        @installation_client.add_comment(
          full_repo_name,
          pull_number,
          comment_body,
          accept: 'application/vnd.github.v3+json'
        )
      end

      # TODO: Include a summary as to why the check failed
      @installation_client.update_check_run(
        @payload['repository']['full_name'],
        @payload['check_run']['id'],
        status: 'completed',
        conclusion: 'failure',
        accept: 'application/vnd.github+json'
      )
    else
      app_comment = fetch_bot_comment(full_repo_name, pull_number)

      if app_comment
        @installation_client.update_comment(
          full_repo_name,
          app_comment.id,
          "✔ All action items have been resolved!\n----\nDid I do good? Let me know by [helping maintain this app](https://github.com/sponsors/NikkelM)!",
          accept: 'application/vnd.github.v3+json'
        )
      end

=begin
  Todo: This is a block comment.
  Any action items in this block will cause the
  todo check to fail.
=end
# todo action items that are close to each other will also be rendered in the same code block
      @installation_client.update_check_run(
        @payload['repository']['full_name'],
        @payload['check_run']['id'],
        status: 'completed',
        conclusion: 'success',
        accept: 'application/vnd.github+json'
      )
    end
  end

  def get_pull_request_changes(full_repo_name, pull_number)
    uri = URI("https://api.github.com/repos/#{full_repo_name}/pulls/#{pull_number}")
    req = Net::HTTP::Get.new(uri)
    req['Accept'] = 'application/vnd.github.v3.diff'
    req['Authorization'] = "token #{@installation_token}"

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
      http.request(req)
    end

    diff = res.body

    current_file = ''
    line_number = 0
    changes = {}

    diff.each_line do |line|
      if line.start_with?('+++')
        current_file = line[6..].strip
        changes[current_file] = []
      elsif line.start_with?('@@')
        line_number = line.split(' ')[2].split(',')[0].to_i - 1
      elsif line.start_with?('+') && !line.start_with?('+++')
        changes[current_file] << { line: line_number, text: line[1..] }
      end

      line_number += 1 unless line.start_with?('-') || line.chomp == '\ No newline at end of file'
    end

    changes
  end

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

    changes.each do |file, file_changes|
      file_type = File.extname(file).delete('.')
      comment_char = comment_chars.find { |k, _| k.include?(file_type) }

      next unless comment_char

      file_todos = []
      file_changes.each do |change|
        text = change[:text].strip

        if comment_char[1][:block_start] && comment_char[1][:block_end]
          in_block_comment = true if text.start_with?(comment_char[1][:block_start])
          in_block_comment = false if text.end_with?(comment_char[1][:block_end])
        end

        keywords.each do |keyword|
          if comment_char[1][:block_start] && comment_char[1][:block_end]
            regex = /(\b#{keyword}\b|#{Regexp.escape(comment_char[1][:line])}\s*#{keyword}\b|#{Regexp.escape(comment_char[1][:block_start])}\s*#{keyword}\b#{Regexp.escape(comment_char[1][:block_end])})/
          else
            regex = /(\b#{keyword}\b|#{Regexp.escape(comment_char[1][:line])}\s*#{keyword}\b)/
          end

          if text.downcase.match(regex) && (in_block_comment || text.start_with?(comment_char[1][:line]))
            file_todos << change.merge(type: keyword)
            break
          end
        end
      end

      todo_changes[file] = file_todos unless file_todos.empty?
    end

    todo_changes
  end

  def get_payload_request(request)
    request.body.rewind
    @payload_raw = request.body.read
    begin
      @payload = JSON.parse @payload_raw
    rescue JSON::ParserError => e
      raise "Invalid JSON (#{e}): #{@payload_raw}"
    end
  end

  def authenticate_app
    payload = {
      iat: Time.now.to_i,
      exp: Time.now.to_i + (7 * 60),
      iss: APP_IDENTIFIER
    }
    jwt = JWT.encode(payload, PRIVATE_KEY, 'RS256')
    @authenticate_app ||= Octokit::Client.new(bearer_token: jwt)
  end

  def authenticate_installation(payload)
    @installation_id = payload['installation']['id']
    @installation_token = @authenticate_app.create_app_installation_access_token(@installation_id)[:token]
    @installation_client = Octokit::Client.new(bearer_token: @installation_token)
  end

  def verify_webhook_signature
    their_signature_header = request.env['HTTP_X_HUB_SIGNATURE'] || 'sha1='
    method, their_digest = their_signature_header.split('=')
    our_digest = OpenSSL::HMAC.hexdigest(method, WEBHOOK_SECRET, @payload_raw)
    halt 401 unless their_digest == our_digest

    logger.debug "---- received event #{request.env['HTTP_X_GITHUB_EVENT']}"
    logger.debug "----    action #{@payload['action']}" unless @payload['action'].nil?
  end
end
