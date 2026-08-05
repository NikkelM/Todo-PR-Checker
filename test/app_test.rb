# frozen_string_literal: true

require_relative 'test_helper'

class WebhookTest < Minitest::Test
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  def setup
    app.settings.test_calls.clear
    app.settings.test_config_content = "todo-pr-checker: {}\n"
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

  def pull_request_payload(action, draft: false)
    base_payload.merge(
      'action' => action,
      'pull_request' => {
        'number' => 7,
        'draft' => draft,
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

  def test_processes_pull_request_when_ready_for_review
    post_webhook('pull_request', pull_request_payload('ready_for_review'))

    assert_equal 200, last_response.status
    assert_includes app.settings.test_calls, [:create_check_run, 'octocat/example', 'head-sha']
  end

  def test_skips_draft_pull_requests_by_default
    %w[opened synchronize reopened].each do |action|
      app.settings.test_calls.clear
      post_webhook('pull_request', pull_request_payload(action, draft: true))

      assert_equal 204, last_response.status
      assert_equal [
        [:authenticate_app],
        [:authenticate_installation, 456]
      ], app.settings.test_calls
    end
  end

  def test_processes_draft_pull_request_when_enabled
    app.settings.test_config_content = "todo-pr-checker:\n  check_drafts: true\n"

    post_webhook('pull_request', pull_request_payload('opened', draft: true))

    initiate_call = app.settings.test_calls.find { |call| call.first == :initiate_check_run }

    assert_equal 200, last_response.status
    assert_includes app.settings.test_calls, [:create_check_run, 'octocat/example', 'head-sha']
    assert_equal true, initiate_call[1][:app_options]['check_drafts']
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
    todo_changes, = scanner.send(:check_for_todos, changes, options)
    comment = scanner.send(:create_pr_comment_from_changes, todo_changes, 'octocat/example', 'head-sha', options)

    assert_equal [1, 2], changes.fetch('validation.js').map { |change| change[:line] }
    assert_includes comment[:body], 'validation.js#L1-L2'
    refute_includes comment[:body], '#L0'
  end
end

class SkippedFilesReportingTest < Minitest::Test
  def setup
    @calls = []
    @files = []
    calls = @calls
    files = @files
    @config_file = Struct.new(:content).new(Base64.strict_encode64("todo-pr-checker: {}\n"))
    config_file = @config_file
    installation_client = Object.new
    installation_client.define_singleton_method(:contents) { |*| config_file }
    installation_client.define_singleton_method(:pull_request_files) do |*, page:, **|
      page == 1 ? files : []
    end
    installation_client.define_singleton_method(:issue_comments) { |*, **| [] }
    installation_client.define_singleton_method(:update_check_run) do |*args, **kwargs|
      calls << { name: :update_check_run, args: args, kwargs: kwargs }
    end
    installation_client.define_singleton_method(:add_comment) do |*args, **kwargs|
      calls << { name: :add_comment, args: args, kwargs: kwargs }
    end

    @scanner = Sinatra::Application.new!
    @scanner.instance_variable_set(:@installation_client, installation_client)
  end

  def test_includes_unsupported_files_when_posting_action_item_comment
    @files.concat([
                    Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+// TODO: Fix this\n"),
                    Struct.new(:filename, :patch).new('notes.txt', "@@ -0,0 +1 @@\n+TODO: Unsupported\n"),
                    Struct.new(:filename, :patch).new('README.TXT', "@@ -0,0 +1 @@\n+Unsupported\n"),
                    Struct.new(:filename, :patch).new('Dockerfile', "@@ -0,0 +1 @@\n+Unsupported\n")
                  ])

    ORIGINAL_INITIATE_CHECK_RUN.bind_call(@scanner, full_repo_name: 'octocat/example', pull_number: 7, head_sha: 'head-sha', check_run_id: 123)

    comment = @calls.find { |call| call[:name] == :add_comment }
    final_check = @calls.reverse.find { |call| call[:name] == :update_check_run }

    assert_includes comment[:args][2], 'Skipped files (3)'
    assert_includes comment[:args][2], "</summary>\n<br>\n\n**Unsupported file types**"
    assert_includes comment[:args][2], '`.txt` (2)'
    assert_includes comment[:args][2], 'No extension (1)'
    refute_includes comment[:args][2], '**`.txt` (2)**'
    assert_includes comment[:args][2], 'notes.txt'
    assert_includes comment[:args][2], "</details>\n\n----"
    assert_includes final_check[:kwargs].dig(:output, :summary), 'notes.txt'
    refute_includes final_check[:kwargs].dig(:output, :text), 'notes.txt'
  end

  def test_does_not_create_comment_for_skipped_files_without_action_items
    @files.concat([
                    Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+const value = true;\n"),
                    Struct.new(:filename, :patch).new('notes.txt', "@@ -0,0 +1 @@\n+Unsupported text\n")
                  ])

    ORIGINAL_INITIATE_CHECK_RUN.bind_call(@scanner, full_repo_name: 'octocat/example', pull_number: 7, head_sha: 'head-sha', check_run_id: 123)

    final_check = @calls.reverse.find { |call| call[:name] == :update_check_run }

    refute @calls.any? { |call| call[:name] == :add_comment }
    assert_equal 'success', final_check[:kwargs][:conclusion]
    assert_includes final_check[:kwargs].dig(:output, :summary), 'notes.txt'
  end

  def test_skips_check_when_all_text_changes_are_unsupported
    @files << Struct.new(:filename, :patch).new('notes.txt', "@@ -0,0 +1 @@\n+Unsupported text\n")

    ORIGINAL_INITIATE_CHECK_RUN.bind_call(@scanner, full_repo_name: 'octocat/example', pull_number: 7, head_sha: 'head-sha', check_run_id: 123)

    final_check = @calls.reverse.find { |call| call[:name] == :update_check_run }

    refute @calls.any? { |call| call[:name] == :add_comment }
    assert_equal 'skipped', final_check[:kwargs][:conclusion]
    assert_includes final_check[:kwargs].dig(:output, :summary), 'notes.txt'
  end

  def test_limits_number_of_reported_skipped_files
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+// TODO: Fix this\n")
    51.times do |index|
      @files << Struct.new(:filename, :patch).new("notes-#{index}.txt", "@@ -0,0 +1 @@\n+Unsupported text\n")
    end

    ORIGINAL_INITIATE_CHECK_RUN.bind_call(@scanner, full_repo_name: 'octocat/example', pull_number: 7, head_sha: 'head-sha', check_run_id: 123)

    comment = @calls.find { |call| call[:name] == :add_comment }

    assert_includes comment[:args][2], 'Skipped files (51)'
    assert_includes comment[:args][2], '`.txt` (51)'
    assert_includes comment[:args][2], 'notes-49.txt'
    refute_includes comment[:args][2], 'notes-50.txt'
    assert_includes comment[:args][2], '...and 1 more.'
  end

end
