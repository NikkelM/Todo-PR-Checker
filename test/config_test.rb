# frozen_string_literal: true

require_relative 'test_helper'

class DraftPullRequestConfigurationTest < Minitest::Test
  def setup
    @scanner = Sinatra::Application.new!
    @config_file = Struct.new(:content).new(Base64.strict_encode64("todo-pr-checker: {}\n"))
    config_file = @config_file
    installation_client = Object.new
    installation_client.define_singleton_method(:contents) { |*| config_file }
    @scanner.instance_variable_set(:@installation_client, installation_client)
  end

  def test_check_drafts_defaults_to_false
    options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')

    assert_equal false, options['check_drafts']
  end

  def test_check_drafts_accepts_true
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  check_drafts: true\n")

    options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')

    assert_equal true, options['check_drafts']
  end

  def test_invalid_check_drafts_uses_default
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  check_drafts: drafts\n")

    options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')

    assert_equal false, options['check_drafts']
  end
end

class ActionItemMatchingOptionsTest < Minitest::Test
  def setup
    @scanner = Sinatra::Application.new!
    @config_file = Struct.new(:content).new(Base64.strict_encode64("todo-pr-checker: {}\n"))
    config_file = @config_file
    installation_client = Object.new
    installation_client.define_singleton_method(:contents) { |*| config_file }
    @scanner.instance_variable_set(:@installation_client, installation_client)
    @default_options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')
  end

  def test_default_matching_options_preserve_existing_behavior
    assert_equal false, @default_options['check_inline_comments']
    assert_equal false, @default_options['standalone_items']
    assert_equal false, @default_options['multiline_comments']
    assert_equal [1, 3, 5, 7, 9, 20], scan_fixture('validation.js', @default_options)
    assert_equal [1, 11], scan_fixture('validation.html', @default_options)
  end

  def test_check_inline_comments_true_includes_inline_comments
    options = @default_options.merge('check_inline_comments' => true)

    assert_equal [1, 3, 5, 7, 9, 16, 20], scan_fixture('validation.js', options)
    assert_equal [1, 9, 11], scan_fixture('validation.html', options)
  end

  def test_standalone_items_true_excludes_punctuation_adjacent_items
    options = @default_options.merge('standalone_items' => true)

    assert_equal [5], scan_fixture('validation.js', options)
    assert_equal [11], scan_fixture('validation.html', options)
  end

  def test_custom_action_items_escape_regular_expression_characters
    changes = {
      'example.js' => [
        { line: 1, text: '// TODO? exact item' },
        { line: 2, text: '// TODO different item' },
        { line: 3, text: '// FIX+ME exact item' }
      ]
    }
    options = @default_options.merge('action_items' => ['TODO?', 'FIX+ME'])

    todo_changes, = @scanner.send(:check_for_todos, changes, options)

    assert_equal [1, 3], todo_changes.fetch('example.js').map { |change| change[:line] }
  end

  def test_empty_action_items_list_disables_matching
    changes = { 'example.js' => [{ line: 1, text: '// TODO should not match' }] }
    options = @default_options.merge('action_items' => [])

    todo_changes, = @scanner.send(:check_for_todos, changes, options)

    assert_empty todo_changes
  end

  def test_added_language_supports_multiple_line_markers_and_inline_multiline_comments
    changes = {
      'example.note' => [
        { line: 1, text: '# TODO hash comment' },
        { line: 2, text: 'value = true; // TODO inline comment' },
        { line: 3, text: 'value = false; /* block starts' },
        { line: 4, text: 'TODO multiline comment' },
        { line: 5, text: '*/' }
      ]
    }
    options = @default_options.merge(
      'action_items' => ['TODO'],
      'add_languages' => [['note', ['//', '#'], '/*', '*/']],
      'check_inline_comments' => true,
      'multiline_comments' => true
    )

    todo_changes, unsupported_files = @scanner.send(:check_for_todos, changes, options)

    assert_equal [1, 2, 4], todo_changes.fetch('example.note').map { |change| change[:line] }
    assert_empty unsupported_files
  end

  def test_combined_options_detect_only_whitespace_delimited_inline_items
    changes = {
      'example.js' => [
        { line: 1, text: 'const first = true; // TODO fix this' },
        { line: 2, text: 'const second = true; // TODO: fix this' },
        { line: 3, text: 'const third = true; /* FIXME later */' },
        { line: 4, text: 'const fourth = true; /* (FIXME) */' },
        { line: 5, text: 'const fifth = true; //TODO fix this' }
      ]
    }
    options = @default_options.merge('check_inline_comments' => true, 'standalone_items' => true)

    todo_changes, = @scanner.send(:check_for_todos, changes, options)

    assert_equal [1, 3], todo_changes.fetch('example.js').map { |change| change[:line] }
  end

  def test_inline_multiline_comment_continues_on_following_lines
    changes = {
      'example.js' => [
        { line: 1, text: 'const value = true; /* start' },
        { line: 2, text: 'TODO fix this' },
        { line: 3, text: '*/' }
      ]
    }
    options = @default_options.merge('check_inline_comments' => true, 'multiline_comments' => true)

    todo_changes, = @scanner.send(:check_for_todos, changes, options)

    assert_equal [2], todo_changes.fetch('example.js').map { |change| change[:line] }
  end

  def test_inline_self_closing_block_comment_does_not_leak_to_following_lines
    changes = {
      'example.js' => [
        { line: 1, text: 'const first = true; /* TODO */ const second = true;' },
        { line: 2, text: 'const FIXME = "code, not a comment";' }
      ]
    }
    options = @default_options.merge('check_inline_comments' => true, 'multiline_comments' => true)

    todo_changes, = @scanner.send(:check_for_todos, changes, options)

    assert_equal [1], todo_changes.fetch('example.js').map { |change| change[:line] }
  end

  def test_configuration_accepts_boolean_matching_options
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  check_inline_comments: true\n  standalone_items: true\n")

    options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')

    assert_equal true, options['check_inline_comments']
    assert_equal true, options['standalone_items']
  end

  def test_invalid_matching_options_use_defaults
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  check_inline_comments: inline\n  standalone_items: whitespace\n")

    options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')

    assert_equal false, options['check_inline_comments']
    assert_equal false, options['standalone_items']
  end

  private

  def scan_fixture(file_name, options)
    fixture_path = File.expand_path("../validation/#{file_name}", __dir__)
    changes = {
      file_name => File.readlines(fixture_path, chomp: true).each_with_index.map do |text, index|
        { line: index + 1, text: text }
      end
    }
    todo_changes, = @scanner.send(:check_for_todos, changes, options)
    todo_changes.fetch(file_name, []).map { |change| change[:line] }
  end
end

class CommentRenderingOptionsTest < Minitest::Test
  def setup
    @scanner = Sinatra::Application.new!
  end

  def test_additional_lines_controls_link_range
    changes = { 'example.js' => [{ line: 5, text: '// TODO' }] }

    no_context = @scanner.send(
      :create_pr_comment_from_changes,
      changes,
      'octocat/example',
      'head-sha',
      { 'additional_lines' => 0, 'always_split_snippets' => false }
    )
    two_context_lines = @scanner.send(
      :create_pr_comment_from_changes,
      changes,
      'octocat/example',
      'head-sha',
      { 'additional_lines' => 2, 'always_split_snippets' => false }
    )

    assert_includes no_context[:body], 'example.js#L5 '
    assert_includes two_context_lines[:body], 'example.js#L5-L7 '
  end

  def test_always_split_snippets_separates_nearby_items
    changes = {
      'example.js' => [
        { line: 2, text: '// TODO first' },
        { line: 4, text: '// TODO second' }
      ]
    }

    grouped = @scanner.send(
      :create_pr_comment_from_changes,
      changes,
      'octocat/example',
      'head-sha',
      { 'additional_lines' => 1, 'always_split_snippets' => false }
    )
    split = @scanner.send(
      :create_pr_comment_from_changes,
      changes,
      'octocat/example',
      'head-sha',
      { 'additional_lines' => 1, 'always_split_snippets' => true }
    )

    assert_includes grouped[:body], 'example.js#L2-L5 '
    assert_includes split[:body], 'example.js#L2-L3 '
    assert_includes split[:body], 'example.js#L4-L5 '
  end
end

class ConfigurationDetailsTest < Minitest::Test
  def setup
    @scanner = Sinatra::Application.new!
  end

  def test_renders_effective_options_as_collapsed_yaml
    options = {
      'post_comment' => 'items_found',
      'check_drafts' => false,
      'action_items' => ['TODO', 'FIX+ME'],
      'add_languages' => [['note', ['//', '#'], '/*', '*/']],
      'ignore_files' => []
    }

    details = @scanner.send(:create_configuration_details, options)

    assert_includes details, '<summary>Configuration used</summary>'
    assert_includes details, "```yaml\npost_comment: items_found"
    assert_includes details, "check_drafts: false"
    assert_includes details, "- TODO"
    assert_includes details, "- FIX+ME"
    assert_includes details, "ignore_files: []"
    refute_includes details, "---"
  end

  def test_uses_a_longer_code_fence_when_an_option_contains_backticks
    details = @scanner.send(:create_configuration_details, 'action_items' => ['```'])

    assert_includes details, "````yaml\n"
    assert_includes details, "\n````\n"
  end
end

class CheckRunConfigurationOptionsTest < Minitest::Test
  def setup
    @calls = []
    @files = []
    @comments = []
    @content_requests = []
    calls = @calls
    files = @files
    comments = @comments
    content_requests = @content_requests
    @config_file = Struct.new(:content).new(Base64.strict_encode64("todo-pr-checker: {}\n"))
    config_file = @config_file
    installation_client = Object.new
    installation_client.define_singleton_method(:contents) do |*|
      content_requests << true
      config_file
    end
    installation_client.define_singleton_method(:pull_request_files) do |*, page:, **|
      page == 1 ? files : []
    end
    installation_client.define_singleton_method(:issue_comments) { |*, **| comments }
    installation_client.define_singleton_method(:update_check_run) do |*args, **kwargs|
      calls << { name: :update_check_run, args: args, kwargs: kwargs }
    end
    installation_client.define_singleton_method(:add_comment) do |*args, **kwargs|
      calls << { name: :add_comment, args: args, kwargs: kwargs }
    end
    installation_client.define_singleton_method(:update_comment) do |*args, **kwargs|
      calls << { name: :update_comment, args: args, kwargs: kwargs }
    end

    @scanner = Sinatra::Application.new!
    @scanner.instance_variable_set(:@installation_client, installation_client)
  end

  def test_post_comment_always_creates_comment_without_action_items
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  post_comment: always\n")
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+const value = true;\n")

    run_check

    comment = @calls.find { |call| call[:name] == :add_comment }
    final_check = @calls.reverse.find { |call| call[:name] == :update_check_run }

    assert_includes comment[:args][2], '✔ No action items found!'
    assert_equal 'success', final_check[:kwargs][:conclusion]
  end

  def test_post_comment_always_includes_skipped_files_without_action_items
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  post_comment: always\n")
    @files.concat([
                    Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+const value = true;\n"),
                    Struct.new(:filename, :patch).new('notes.txt', "@@ -0,0 +1 @@\n+Unsupported text\n")
                  ])

    run_check

    comment = @calls.find { |call| call[:name] == :add_comment }

    assert_includes comment[:args][2], '✔ No action items found!'
    assert_includes comment[:args][2], 'Skipped files (1)'
    assert_includes comment[:args][2], 'notes.txt'
  end

  def test_resolved_comment_includes_skipped_files
    app = Struct.new(:id).new(816_025)
    @comments << Struct.new(:id, :performed_via_github_app).new(456, app)
    @files.concat([
                    Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+const value = true;\n"),
                    Struct.new(:filename, :patch).new('notes.txt', "@@ -0,0 +1 @@\n+Unsupported text\n")
                  ])

    run_check

    comment = @calls.find { |call| call[:name] == :update_comment }

    assert_includes comment[:args][2], '✔ All action items have been resolved!'
    assert_includes comment[:args][2], 'Skipped files (1)'
    assert_includes comment[:args][2], 'notes.txt'
  end

  def test_ignore_files_separates_configured_ignores_from_unsupported_files
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  ignore_files: ['ignored.js', 'other.JS']\n")
    @files.concat([
                    Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+// TODO: Fix this\n"),
                    Struct.new(:filename, :patch).new('ignored.js', "@@ -0,0 +1 @@\n+// TODO: Ignored\n"),
                    Struct.new(:filename, :patch).new('other.JS', "@@ -0,0 +1 @@\n+// TODO: Also ignored\n"),
                    Struct.new(:filename, :patch).new('notes.txt', "@@ -0,0 +1 @@\n+Unsupported text\n")
                  ])

    run_check

    comment = @calls.find { |call| call[:name] == :add_comment }

    assert_includes comment[:args][2], 'Skipped files (3)'
    assert_includes comment[:args][2], 'Ignored by configuration'
    assert_includes comment[:args][2], '`.js` (2)'
    assert_includes comment[:args][2], 'ignored.js'
    assert_includes comment[:args][2], 'other.JS'
    assert_includes comment[:args][2], 'Unsupported file types'
    assert_includes comment[:args][2], '`.txt` (1)'
    assert_includes comment[:args][2], 'notes.txt'
  end

  def test_post_comment_never_still_fails_check_without_posting_comment
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  post_comment: never\n")
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+// TODO: Fix this\n")

    run_check

    final_check = @calls.reverse.find { |call| call[:name] == :update_check_run }

    refute @calls.any? { |call| call[:name] == :add_comment }
    assert_equal 'failure', final_check[:kwargs][:conclusion]
    assert_equal '✘ 1 unresolved action item found!', final_check[:kwargs].dig(:output, :title)
  end

  def test_configuration_is_in_failed_check_details_but_not_pull_request_comment
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  check_inline_comments: true\n")
    @files.concat([
                    Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+// TODO: Fix this\n"),
                    Struct.new(:filename, :patch).new('notes.txt', "@@ -0,0 +1 @@\n+Unsupported text\n")
                  ])

    run_check

    comment = @calls.find { |call| call[:name] == :add_comment }
    final_check = @calls.reverse.find { |call| call[:name] == :update_check_run }
    summary = final_check[:kwargs].dig(:output, :summary)
    details = final_check[:kwargs].dig(:output, :text)

    assert_includes summary, 'app.js'
    assert_includes summary, 'Skipped files (1)'
    assert_includes summary, 'helping maintain this app'
    refute_includes summary, 'Configuration used'
    assert_includes details, '<summary>Configuration used</summary>'
    assert_includes details, 'check_inline_comments: true'
    refute_includes details, 'app.js'
    refute_includes details, 'Skipped files'
    refute_includes details, 'helping maintain this app'
    refute_includes comment[:args][2], 'Configuration used'
  end

  def test_configuration_is_in_successful_check_details
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+const value = true;\n")

    run_check

    final_check = @calls.reverse.find { |call| call[:name] == :update_check_run }

    assert_includes final_check[:kwargs].dig(:output, :text), '<summary>Configuration used</summary>'
  end

  def test_configuration_is_in_skipped_check_details
    @files << Struct.new(:filename, :patch).new('notes.txt', "@@ -0,0 +1 @@\n+Unsupported text\n")

    run_check

    final_check = @calls.reverse.find { |call| call[:name] == :update_check_run }

    assert_equal 'skipped', final_check[:kwargs][:conclusion]
    assert_includes final_check[:kwargs].dig(:output, :text), '<summary>Configuration used</summary>'
  end

  def test_preloaded_options_avoid_second_configuration_lookup
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+const value = true;\n")
    options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')

    run_check(app_options: options)

    assert_equal 1, @content_requests.length
  end

  private

  def run_check(app_options: nil)
    arguments = {
      full_repo_name: 'octocat/example',
      pull_number: 7,
      head_sha: 'head-sha',
      check_run_id: 123
    }
    arguments[:app_options] = app_options if app_options
    ORIGINAL_INITIATE_CHECK_RUN.bind_call(@scanner, **arguments)
  end
end
