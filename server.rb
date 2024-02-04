# frozen_string_literal: true

require 'sinatra/base'
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

class GHAapp < Sinatra::Application
  set :port, 3000
  set :bind, '0.0.0.0'

  PRIVATE_KEY = OpenSSL::PKey::RSA.new(ENV['GITHUB_PRIVATE_KEY'].gsub('\n', "\n"))
  WEBHOOK_SECRET = ENV['GITHUB_WEBHOOK_SECRET']
  APP_IDENTIFIER = ENV['GITHUB_APP_IDENTIFIER']

  configure :development do
    set :logging, Logger::DEBUG
  end

  before '/event_handler' do
    get_payload_request(request)
    verify_webhook_signature

    unless @payload['repository'].nil?
      halt 400 if (@payload['repository']['name'] =~ /[0-9A-Za-z\-\_]+/).nil?
    end

    authenticate_app
    authenticate_installation(@payload)
  end

  post '/event_handler' do
    event_type = request.env['HTTP_X_GITHUB_EVENT']

    if event_type == 'check_suite' && (@payload['action'] == 'requested' || @payload['action'] == 'rerequested')
      create_check_run
    end

    if event_type == 'check_run' && @payload['check_run']['app']['id'].to_s == APP_IDENTIFIER
      if @payload['action'] == 'created'
        initiate_check_run
      elsif @payload['action'] == 'rerequested'
        create_check_run
      end
    end

    200
  end

  helpers do
    def create_check_run
      @installation_client.create_check_run(
        @payload['repository']['full_name'],
        'Todo Blocker',
        @payload['check_run'].nil? ? @payload['check_suite']['head_sha'] : @payload['check_run']['head_sha'],
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
        comment_body = "There are unresolved action items in this Pull Request:\n\n"
        todo_changes.each do |file, changes|
          file_link = "https://github.com/#{full_repo_name}/blob/#{@payload['check_run']['head_sha']}/#{file}"
          comment_body += "## [`#{file}`](#{file_link}):\n"
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
          comment_body += "\n\n"
        end

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
            repo_full_name,
            pull_number,
            comment_body,
            accept: 'application/vnd.github.v3+json'
          )
        end

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
            'All action items have been resolved!',
            accept: 'application/vnd.github.v3+json'
          )
        end

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
        %w[md html] => { line: '<!--', block_start: '<!--', block_end: '-->' },
        %w[js java ts c cpp cs php swift go kotlin rust dart scala] => { line: '//', block_start: '/*', block_end: '*/' },
        %w[rb] => { line: '#', block_start: '=begin', block_end: '=end' },
        %w[py] => { line: '#', block_start: "'''", block_end: "'''" },
        %w[r shell gitignore gitattributes gitmodules] => { line: '#', block_start: nil, block_end: nil },
        %w[perl] => { line: '#', block_start: '=pod', block_end: '=cut' },
        %w[haskell] => { line: '--', block_start: '{-', block_end: '-}' },
        %w[lua] => { line: '--', block_start: '--[[', block_end: ']]' }
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
            if text.downcase.include?(keyword) && (in_block_comment || text.start_with?(comment_char[1][:line]))
              file_todos << change
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

  run! if __FILE__ == $PROGRAM_NAME
end
