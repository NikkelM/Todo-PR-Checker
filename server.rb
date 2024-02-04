# frozen_string_literal: true

require 'sinatra/base'  # Use the Sinatra web framework
require 'octokit'       # Use the Octokit Ruby library to interact with GitHub's REST API
require 'dotenv/load'   # Manages environment variables
require 'json'          # Allows your app to manipulate JSON data
require 'openssl'       # Verifies the webhook signature
require 'jwt'           # Authenticates a GitHub App
require 'time'          # Gets ISO 8601 representation of a Time object
require 'logger'        # Logs debug statements
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

    halt 400 unless @payload['repository'].nil? || (@payload['repository']['name'] =~ /[0-9A-Za-z\-_]+/).nil?

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

      check_for_todos(changes)

      @installation_client.update_check_run(
        @payload['repository']['full_name'],
        @payload['check_run']['id'],
        status: 'completed',
        conclusion: 'success',
        accept: 'application/vnd.github+json'
      )
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
      changes = []

      diff.each_line do |line|
        if line.start_with?('+++')
          current_file = line[6..].strip
        elsif line.start_with?('@@')
          line_number = line.split(' ')[2].split(',')[0].to_i - 1
        elsif line.start_with?('+') && !line.start_with?('+++')
          changes << { file: current_file, line: line_number, text: line[1..] }
        end

        line_number += 1 unless line.start_with?('-') || line.chomp == '\ No newline at end of file'
      end

      changes
    end

    def check_for_todos(changes)
      todo_changes = []
      in_block_comment = false

      changes.each do |change|
        file_type = File.extname(change[:file])
        text = change[:text].strip

        if file_type == '.md'
          in_block_comment = true if text.start_with?('<!--')
          in_block_comment = false if text.end_with?('-->')
          todo_changes << change if text.downcase.include?('todo') && (in_block_comment || text.start_with?('<!--'))
        elsif file_type == '.js'
          in_block_comment = true if text.start_with?('/*')
          in_block_comment = false if text.end_with?('*/')
          todo_changes << change if text.downcase.include?('todo') && (in_block_comment || text.start_with?('//'))
        end
      end

      logger.debug "todo_changes: #{todo_changes}"
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
