# frozen_string_literal: true

require 'openssl'

ENV['RACK_ENV'] = 'test'
ENV['GITHUB_APP_IDENTIFIER'] = '816025'
ENV['GITHUB_PRIVATE_KEY'] = OpenSSL::PKey::RSA.generate(2048).to_pem
ENV['GITHUB_WEBHOOK_SECRET'] = 'test-webhook-secret'

require 'json'
require 'minitest/autorun'
require 'rack/test'
require_relative '../app'

Sinatra::Application.set :test_calls, []

Sinatra::Application.helpers do
  def authenticate_app
    settings.test_calls << [:authenticate_app]
  end

  def authenticate_installation(payload)
    settings.test_calls << [:authenticate_installation, payload.dig('installation', 'id')]
  end

  def create_check_run(full_repo_name, head_sha)
    settings.test_calls << [:create_check_run, full_repo_name, head_sha]
    Struct.new(:id).new(123)
  end

  def initiate_check_run(**arguments)
    settings.test_calls << [:initiate_check_run, arguments]
  end
end

class WebhookTest < Minitest::Test
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  def setup
    app.settings.test_calls.clear
  end

  private

  def base_payload
    {
      'repository' => {
        'id' => 123,
        'name' => 'example',
        'full_name' => 'octocat/example'
      },
      'installation' => { 'id' => 456 }
    }
  end

  def pull_request_payload(action)
    base_payload.merge(
      'action' => action,
      'pull_request' => {
        'number' => 7,
        'head' => { 'sha' => 'head-sha' }
      }
    )
  end

  def check_suite_payload(action, app_id:)
    base_payload.merge(
      'action' => action,
      'check_suite' => {
        'app' => { 'id' => app_id },
        'head_sha' => 'suite-rerun-sha',
        'pull_requests' => [{ 'number' => 7 }]
      }
    )
  end

  def check_run_payload(action, app_id:)
    base_payload.merge(
      'action' => action,
      'check_run' => {
        'app' => { 'id' => app_id },
        'head_sha' => 'rerun-sha',
        'pull_requests' => [{ 'number' => 7 }]
      }
    )
  end

  def post_webhook(event_type, payload)
    post_signed_body(event_type, JSON.generate(payload))
  end

  def post_signed_body(event_type, body)
    digest = OpenSSL::HMAC.hexdigest('sha256', ENV.fetch('GITHUB_WEBHOOK_SECRET'), body)
    header 'X-GitHub-Event', event_type
    header 'X-Hub-Signature-256', "sha256=#{digest}"
    post '/', body, 'CONTENT_TYPE' => 'application/json'
  end
end

class WebhookRoutingTest < WebhookTest
  def test_processes_opened_pull_request_without_waiting_for_check_run_event
    post_webhook('pull_request', pull_request_payload('opened'))

    assert_equal 200, last_response.status
    assert_equal [
      [:authenticate_app],
      [:authenticate_installation, 456],
      [:create_check_run, 'octocat/example', 'head-sha'],
      [:initiate_check_run, {
        full_repo_name: 'octocat/example',
        pull_number: 7,
        head_sha: 'head-sha',
        check_run_id: 123
      }]
    ], app.settings.test_calls
  end

  def test_processes_pull_request_synchronization
    post_webhook('pull_request', pull_request_payload('synchronize'))

    assert_equal 200, last_response.status
    assert_includes app.settings.test_calls, [:create_check_run, 'octocat/example', 'head-sha']
  end

  def test_processes_reopened_pull_request
    post_webhook('pull_request', pull_request_payload('reopened'))

    assert_equal 200, last_response.status
    assert_includes app.settings.test_calls, [:create_check_run, 'octocat/example', 'head-sha']
  end

  def test_ignores_irrelevant_pull_request_action_before_authentication
    post_webhook('pull_request', pull_request_payload('closed'))

    assert_equal 204, last_response.status
    assert_empty app.settings.test_calls
  end

  def test_ignores_foreign_check_run_before_authentication
    %w[created rerequested completed].each do |action|
      app.settings.test_calls.clear
      post_webhook('check_run', check_run_payload(action, app_id: 15_368))

      assert_equal 204, last_response.status
      assert_empty app.settings.test_calls
    end
  end

  def test_processes_own_rerequested_check_suite_as_a_fresh_run
    payload = check_suite_payload('rerequested', app_id: 816_025)

    post_webhook('check_suite', payload)

    assert_equal 200, last_response.status
    assert_equal [
      [:authenticate_app],
      [:authenticate_installation, 456],
      [:create_check_run, 'octocat/example', 'suite-rerun-sha'],
      [:initiate_check_run, {
        full_repo_name: 'octocat/example',
        pull_number: 7,
        head_sha: 'suite-rerun-sha',
        check_run_id: 123
      }]
    ], app.settings.test_calls
  end

  def test_ignores_foreign_rerequested_check_suite
    post_webhook('check_suite', check_suite_payload('rerequested', app_id: 15_368))

    assert_equal 204, last_response.status
    assert_empty app.settings.test_calls
  end

  def test_ignores_own_created_and_completed_check_runs
    %w[created completed].each do |action|
      app.settings.test_calls.clear
      post_webhook('check_run', check_run_payload(action, app_id: 816_025))

      assert_equal 204, last_response.status
      assert_empty app.settings.test_calls
    end
  end

  def test_processes_own_rerequested_check_run_as_a_fresh_run
    post_webhook('check_run', check_run_payload('rerequested', app_id: 816_025))

    assert_equal 200, last_response.status
    assert_equal [
      [:authenticate_app],
      [:authenticate_installation, 456],
      [:create_check_run, 'octocat/example', 'rerun-sha'],
      [:initiate_check_run, {
        full_repo_name: 'octocat/example',
        pull_number: 7,
        head_sha: 'rerun-sha',
        check_run_id: 123
      }]
    ], app.settings.test_calls
  end

  def test_ignores_rerequested_check_run_without_pull_request
    payload = check_run_payload('rerequested', app_id: 816_025)
    payload['check_run']['pull_requests'] = []

    post_webhook('check_run', payload)

    assert_equal 204, last_response.status
    assert_empty app.settings.test_calls
  end

  def test_rejects_malformed_own_rerequested_check_run
    payload = check_run_payload('rerequested', app_id: 816_025)
    payload['check_run'].delete('head_sha')

    post_webhook('check_run', payload)

    assert_equal 400, last_response.status
    assert_empty app.settings.test_calls
  end
end

class WebhookValidationTest < WebhookTest
  def test_ignores_check_suite_events_before_authentication
    %w[requested completed].each do |action|
      app.settings.test_calls.clear
      payload = base_payload.merge(
        'action' => action,
        'check_suite' => {
          'app' => { 'id' => 816_025 },
          'pull_requests' => [{ 'number' => 7 }]
        }
      )

      post_webhook('check_suite', payload)

      assert_equal 204, last_response.status
      assert_empty app.settings.test_calls
    end
  end

  def test_ignores_unsubscribed_event_without_repository
    payload = {
      'action' => 'added',
      'installation' => { 'id' => 456 },
      'repositories_added' => [{ 'id' => 123, 'name' => 'example' }]
    }

    post_webhook('installation_repositories', payload)

    assert_equal 204, last_response.status
    assert_empty app.settings.test_calls
  end

  def test_rejects_relevant_event_without_repository
    payload = pull_request_payload('opened')
    payload.delete('repository')

    post_webhook('pull_request', payload)

    assert_equal 400, last_response.status
    assert_empty app.settings.test_calls
  end

  def test_rejects_relevant_event_without_repository_full_name
    payload = pull_request_payload('opened')
    payload['repository']['full_name'] = ''

    post_webhook('pull_request', payload)

    assert_equal 400, last_response.status
    assert_empty app.settings.test_calls
  end

  def test_rejects_invalid_json
    post_signed_body('pull_request', '{')

    assert_equal 400, last_response.status
    assert_empty app.settings.test_calls
  end

  def test_rejects_invalid_signature
    header 'X-GitHub-Event', 'pull_request'
    header 'X-Hub-Signature-256', 'sha256=invalid'
    post '/', JSON.generate(pull_request_payload('opened')), 'CONTENT_TYPE' => 'application/json'

    assert_equal 401, last_response.status
    assert_empty app.settings.test_calls
  end
end

class PullRequestChangeParsingTest < Minitest::Test
  def test_first_added_line_uses_one_based_line_number_in_comment_link
    scanner = Sinatra::Application.new!
    config_file = Struct.new(:content).new(Base64.strict_encode64("todo-pr-checker: {}\n"))
    changed_file = Struct.new(:filename, :patch).new(
      'validation.js',
      "@@ -0,0 +1,2 @@\n+// TODO: First line\n+const value = true;\n"
    )
    installation_client = Object.new
    installation_client.define_singleton_method(:contents) { |*| config_file }
    installation_client.define_singleton_method(:pull_request_files) do |*, page:, **|
      page == 1 ? [changed_file] : []
    end
    scanner.instance_variable_set(:@installation_client, installation_client)

    options = scanner.send(:get_app_options, 'octocat/example', 'head-sha')
    changes, = scanner.send(:get_pull_request_changes, 'octocat/example', 7, [])
    todo_changes = scanner.send(:check_for_todos, changes, options)
    comment = scanner.send(:create_pr_comment_from_changes, todo_changes, 'octocat/example', 'head-sha', options)

    assert_equal [1, 2], changes.fetch('validation.js').map { |change| change[:line] }
    assert_includes comment[:body], 'validation.js#L1-L2'
    refute_includes comment[:body], '#L0'
  end
end

class DefaultValidationFixtureTest < Minitest::Test
  EXPECTED_ALERT_LINES = {
    'validation.css' => [1, 2, 7],
    'validation.html' => [1, 5, 7, 11],
    'validation.js' => [1, 3, 5, 7, 9, 10, 14, 20],
    'validation.php' => [2, 6, 10, 15]
  }.freeze

  def setup
    @scanner = Sinatra::Application.new!
    config_file = Struct.new(:content).new(Base64.strict_encode64("todo-pr-checker: {}\n"))
    installation_client = Object.new
    installation_client.define_singleton_method(:contents) { |*| config_file }
    @scanner.instance_variable_set(:@installation_client, installation_client)
    @default_options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')
  end

  EXPECTED_ALERT_LINES.each do |file_name, expected_lines|
    define_method("test_default_options_find_expected_alerts_in_#{file_name.tr('.', '_')}") do
      fixture_path = File.expand_path("../validation/#{file_name}", __dir__)
      fixture_lines = File.readlines(fixture_path, chomp: true)
      expected_count = fixture_lines.filter_map { |line| line[/Alerts with default options: (\d+)/, 1] }.first
      file_changes = fixture_lines.each_with_index.map do |text, index|
        { line: index + 1, text: text }
      end

      todo_changes = @scanner.send(:check_for_todos, { file_name => file_changes }, @default_options)
      actual_lines = todo_changes.fetch(file_name, []).map { |change| change[:line] }

      refute_nil expected_count
      assert_equal expected_lines.length, expected_count.to_i
      assert_equal expected_lines, actual_lines
    end
  end
end
