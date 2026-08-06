# frozen_string_literal: true

require_relative 'test_helper'

class ConfigurationRobustnessTest < Minitest::Test
  def setup
    @scanner = Sinatra::Application.new!
    @config_file = Struct.new(:content).new(Base64.strict_encode64("todo-pr-checker: {}\n"))
    config_file = @config_file
    installation_client = Object.new
    installation_client.define_singleton_method(:contents) { |*, **| config_file }
    @scanner.instance_variable_set(:@installation_client, installation_client)
  end

  # The configuration file is shared with other apps, so anything in it must never break the check
  def test_malformed_configurations_fall_back_to_the_defaults
    {
      'empty file' => '',
      'only comments' => "# nothing here\n",
      'top level array' => "- one\n- two\n",
      'our section is a list' => "todo-pr-checker:\n  - one\n",
      'foreign section with a date' => "other-app:\n  since: 2024-01-01\n",
      'yaml anchors' => "defaults: &defaults\n  a: 1\nother:\n  <<: *defaults\n",
      'syntax error' => "todo-pr-checker:\n\tbad: indent\n",
      'ruby symbol' => "todo-pr-checker:\n  post_comment: !ruby/symbol always\n"
    }.each do |name, content|
      @config_file.content = Base64.strict_encode64(content)

      options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')

      assert_equal 'items_found', options['post_comment'], "#{name} should fall back to the defaults"
    end
  end

  def test_a_valid_section_is_still_read_when_another_section_is_unusual
    @config_file.content = Base64.strict_encode64("other-app:\n  since: 2024-01-01\ntodo-pr-checker:\n  post_comment: always\n")

    options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')

    assert_equal 'always', options['post_comment']
  end

  def test_default_action_items_match_the_documented_uppercase_values
    options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')

    assert_equal %w[TODO FIXME BUG], options['action_items']
  end

  def test_case_sensitive_matching_still_finds_the_default_items
    options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha').merge('case_sensitive' => true)
    changes = { 'a.js' => [{ line: 1, text: '// TODO uppercase' }, { line: 2, text: '// FIXME uppercase' }] }

    todo_changes, = @scanner.send(:check_for_todos, changes, options)

    assert_equal([1, 2], todo_changes.fetch('a.js').map { |change| change[:line] })
  end

  def test_action_items_must_be_strings
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  action_items: [1, 2]\n")

    options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')

    assert_equal %w[TODO FIXME BUG], options['action_items']
  end
end

class AddLanguagesValidationTest < Minitest::Test
  def setup
    @scanner = Sinatra::Application.new!
    @config_file = Struct.new(:content).new(Base64.strict_encode64("todo-pr-checker: {}\n"))
    config_file = @config_file
    installation_client = Object.new
    installation_client.define_singleton_method(:contents) { |*, **| config_file }
    @scanner.instance_variable_set(:@installation_client, installation_client)
  end

  # This is the configuration the README tells users to copy from this repository
  def test_the_example_configuration_of_this_repository_is_accepted
    @config_file.content = Base64.strict_encode64(File.read(File.expand_path('../.github/config.yml', __dir__)))

    options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')

    assert_equal 4, options['add_languages'].length
  end

  def test_a_null_line_comment_is_accepted_for_block_only_languages
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  add_languages: [['css', null, '/*', '*/']]\n")

    options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')

    assert_equal [['css', nil, '/*', '*/']], options['add_languages']
  end

  def test_a_block_comment_without_a_closing_delimiter_is_rejected
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  add_languages: [['note', '#', null]]\n")

    options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')

    assert_empty options['add_languages']
  end

  def test_a_block_only_language_finds_action_items
    options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha').merge(
      'add_languages' => [['style', nil, '/*', '*/']], 'action_items' => ['TODO']
    )
    changes = { 'a.style' => [{ line: 1, text: '/* TODO in a block only language */' }] }

    todo_changes, unsupported = @scanner.send(:check_for_todos, changes, options)

    assert_equal([1], todo_changes.fetch('a.style').map { |change| change[:line] })
    assert_empty unsupported
  end
end

class FileTypeMatchingTest < Minitest::Test
  def setup
    @scanner = Sinatra::Application.new!
    @config_file = Struct.new(:content).new(Base64.strict_encode64("todo-pr-checker: {}\n"))
    config_file = @config_file
    installation_client = Object.new
    installation_client.define_singleton_method(:contents) { |*, **| config_file }
    @scanner.instance_variable_set(:@installation_client, installation_client)
    @options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')
  end

  def test_uppercase_extensions_are_scanned
    changes = { 'A.JS' => [{ line: 1, text: '// TODO uppercase extension' }] }

    todo_changes, unsupported = @scanner.send(:check_for_todos, changes, @options)

    assert_equal([1], todo_changes.fetch('A.JS').map { |change| change[:line] })
    assert_empty unsupported
  end

  def test_extensionless_dotfiles_are_scanned
    changes = { '.gitignore' => [{ line: 1, text: '# TODO in a dotfile' }] }

    todo_changes, unsupported = @scanner.send(:check_for_todos, changes, @options)

    assert_equal([1], todo_changes.fetch('.gitignore').map { |change| change[:line] })
    assert_empty unsupported
  end

  def test_nested_dotfiles_are_scanned
    changes = { 'config/.gitignore' => [{ line: 1, text: '# TODO nested' }] }

    todo_changes, = @scanner.send(:check_for_todos, changes, @options)

    assert_equal([1], todo_changes.fetch('config/.gitignore').map { |change| change[:line] })
  end

  def test_unknown_file_types_are_still_reported_as_unsupported
    changes = { 'notes.unknown' => [{ line: 1, text: '// TODO unknown type' }] }

    todo_changes, unsupported = @scanner.send(:check_for_todos, changes, @options)

    assert_empty todo_changes
    assert_equal ['notes.unknown'], unsupported
  end

  # A bare = is an assignment in Perl, and must not be treated as the start of a block comment
  def test_perl_assignments_do_not_open_a_block_comment
    options = @options.merge('multiline_comments' => true, 'check_inline_comments' => true, 'action_items' => ['TODO'])
    changes = {
      'a.pl' => [
        { line: 1, text: 'my $x = 5;' },
        { line: 2, text: 'print "TODO inside a string, not a comment";' }
      ]
    }

    todo_changes, = @scanner.send(:check_for_todos, changes, options)

    assert_empty todo_changes
  end

  def test_the_first_action_item_in_a_line_is_reported
    options = @options.merge('action_items' => %w[TODO FIXME])
    changes = { 'a.js' => [{ line: 1, text: '// FIXME first then TODO second' }] }

    todo_changes, = @scanner.send(:check_for_todos, changes, options)

    assert_equal 'FIXME', todo_changes.fetch('a.js').first[:item]
  end
end

class IgnoreFilesPatternTest < Minitest::Test
  def setup
    @scanner = Sinatra::Application.new!
  end

  def test_patterns_only_match_what_they_describe
    {
      '*.js' => { match: ['a.js', 'dir/a.js'], skip: ['b.json', 'c.jsx', 'a.js.txt'] },
      'src/*.rb' => { match: ['src/a.rb'], skip: ['other/src/a.rb', 'src/a.rbx', 'src/nested/a.rb'] },
      'test/' => { match: ['test/a.js', 'test/deep/b.js'], skip: ['src/latest/b.js', 'atest/c.js'] },
      '**/*.md' => { match: ['a.md', 'docs/a.md'], skip: ['a.mdx'] },
      'exact.rb' => { match: ['exact.rb', 'dir/exact.rb'], skip: ['inexact.rb'] },
      '/root.rb' => { match: ['root.rb'], skip: ['dir/root.rb'] }
    }.each do |pattern, expectations|
      regex = @scanner.send(:glob_to_regex, pattern)

      expectations[:match].each { |file| assert regex.match?(file), "#{pattern.inspect} should ignore #{file}" }
      expectations[:skip].each { |file| refute regex.match?(file), "#{pattern.inspect} should not ignore #{file}" }
    end
  end

  def test_invalid_patterns_cannot_fail_the_check
    # Everything that is not a glob operator is escaped, so a pattern can never be an invalid regular expression
    assert @scanner.send(:glob_to_regex, '[').match?('[')
    assert @scanner.send(:glob_to_regex, '**/[a').match?('dir/[a')
    assert_nil @scanner.send(:glob_to_regex, '')
  end

  def test_regular_expression_characters_in_patterns_are_literal
    regex = @scanner.send(:glob_to_regex, 'a+b.rb')

    assert regex.match?('a+b.rb')
    refute regex.match?('aab.rb')
  end
end

class DiffParsingTest < Minitest::Test
  def setup
    @scanner = Sinatra::Application.new!
  end

  def test_added_lines_starting_with_a_plus_are_kept
    files = [Struct.new(:filename, :patch).new('a.js', "@@ -0,0 +1,3 @@\n+++i; // TODO increment\n+let x = 1;\n+// TODO normal\n")]
    installation_client = Object.new
    installation_client.define_singleton_method(:pull_request_files) { |*, page:, **| page == 1 ? files : [] }
    @scanner.instance_variable_set(:@installation_client, installation_client)

    changes, = @scanner.send(:get_pull_request_changes, 'octocat/example', 7, [])

    assert_equal([1, 2, 3], changes.fetch('a.js').map { |change| change[:line] })
    assert_equal '++i; // TODO increment', changes.fetch('a.js').first[:text].chomp
  end

  def test_ignore_patterns_are_not_modified_by_scanning
    files = [Struct.new(:filename, :patch).new('a.js', "@@ -0,0 +1 @@\n+// nothing\n")]
    installation_client = Object.new
    installation_client.define_singleton_method(:pull_request_files) { |*, page:, **| page == 1 ? files : [] }
    @scanner.instance_variable_set(:@installation_client, installation_client)
    patterns = ['*.md']

    @scanner.send(:get_pull_request_changes, 'octocat/example', 7, patterns)

    assert_equal ['*.md'], patterns
  end
end

class ReportSizeTest < Minitest::Test
  def setup
    @scanner = Sinatra::Application.new!
  end

  def test_a_short_report_is_left_alone
    report = @scanner.send(:truncate_report, 'body', "\nfooter")

    assert_equal "body\nfooter", report
  end

  def test_a_long_report_is_shortened_and_keeps_the_footer
    body = (1..5000).map { |index| "line #{index} of the report" }.join("\n")
    footer = "\n----\nfooter"

    report = @scanner.send(:truncate_report, body, footer)

    assert_operator report.bytesize, :<=, 65_535
    assert report.end_with?(footer)
    assert_includes report, 'shortened'
  end

  # File paths and comment text come from the scanned repository, so the report can contain multibyte characters
  def test_a_multibyte_report_is_shortened_by_bytes_not_characters
    body = (1..3000).map { |index| "- `src/コンポーネント/ファイル#{index}.js` の TODO 項目" }.join("\n")
    footer = "\n----\nfooter"

    report = @scanner.send(:truncate_report, body, footer)

    assert_operator report.bytesize, :<=, 65_535
    assert_operator report.length, :<=, 65_536
    assert report.end_with?(footer)
  end

  def test_shortening_never_leaves_a_broken_character
    body = "#{'あ' * 40_000}\n#{'い' * 40_000}"

    report = @scanner.send(:truncate_report, body, "\nfooter")

    assert report.valid_encoding?
    assert_operator report.bytesize, :<=, 65_535
  end
end

class WebhookSignatureTest < Minitest::Test
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  def post_with_signature(signature)
    payload = JSON.generate('action' => 'labeled')
    header('X-GitHub-Event', 'pull_request')
    header('X-Hub-Signature-256', signature) unless signature.nil?
    post '/', payload, 'CONTENT_TYPE' => 'application/json'
  end

  def test_a_missing_signature_is_rejected_without_an_error
    post_with_signature(nil)

    assert_equal 401, last_response.status
  end

  def test_an_empty_signature_is_rejected_without_an_error
    post_with_signature('sha256=')

    assert_equal 401, last_response.status
  end

  def test_a_signature_without_a_digest_is_rejected_without_an_error
    post_with_signature('')

    assert_equal 401, last_response.status
  end

  def test_a_weaker_digest_is_not_accepted
    payload = JSON.generate('action' => 'labeled')
    %w[md5 sha1].each do |digest|
      header('X-GitHub-Event', 'pull_request')
      header('X-Hub-Signature-256', "#{digest}=#{OpenSSL::HMAC.hexdigest(digest, ENV.fetch('GITHUB_WEBHOOK_SECRET'), payload)}")
      post '/', payload, 'CONTENT_TYPE' => 'application/json'

      assert_equal 401, last_response.status, "#{digest} must not be accepted"
    end
  end

  def test_a_correct_signature_is_accepted
    payload = JSON.generate('action' => 'labeled')
    header('X-GitHub-Event', 'pull_request')
    header('X-Hub-Signature-256', "sha256=#{OpenSSL::HMAC.hexdigest('sha256', ENV.fetch('GITHUB_WEBHOOK_SECRET'), payload)}")
    post '/', payload, 'CONTENT_TYPE' => 'application/json'

    assert_equal 204, last_response.status
  end
end
