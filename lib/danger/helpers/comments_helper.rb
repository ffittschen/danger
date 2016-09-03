require "kramdown"
require "danger/helpers/comments_parsing_helper"

# rubocop:disable Metrics/ModuleLength

module Danger
  module Helpers
    module CommentsHelper
      # This might be a bit weird, but table_kind_from_title is a shared dependency for
      # parsing and generating. And rubocop was adamant about file size so...
      include Danger::Helpers::CommentsParsingHelper

      def markdown_parser(text)
        Kramdown::Document.new(text, input: "GFM")
      end

      # !@group Extension points
      # Produces a markdown link to the file the message points to
      #
      # request_source implementations are invited to override this method with their
      # vendor specific link.
      #
      # @param [Violation or Markdown] message
      # @param [Bool] Should hide any generated link created
      #
      # @return [String] The Markdown compatible link
      def markdown_link_to_message(message, _)
        "#{messages.file}#L#{message.line}"
      end

      # !@group Extension points
      # Determine whether two messages are equivalent
      #
      # request_source implementations are invited to override this method.
      # This is mostly here to enable sources to detect when inlines change only in their
      # commit hash and not in content per-se. since the link is implementation dependant
      # so should be the comparision.
      #
      # @param [Violation or Markdown] m1
      # @param [Violation or Markdown] m2
      #
      # @return [Boolean] whether they represent the same message
      def messages_are_equivalent(m1, m2)
        m1 == m2
      end

      def process_markdown(violation, hide_link = false)
        message = violation.message
        message = "#{markdown_link_to_message(violation, hide_link)}#{message}" if violation.file && violation.line

        html = markdown_parser(message).to_html
        # Remove the outer `<p>`, the -5 represents a newline + `</p>`
        html = html[3...-5] if html.start_with? "<p>"
        Violation.new(html, violation.sticky, violation.file, violation.line)
      end

      def parse_comment(comment)
        tables = parse_tables_from_comment(comment)
        violations = {}
        tables.each do |table|
          match = danger_table?(table)
          next unless match
          title = match[1]
          kind = table_kind_from_title(title)
          next unless kind

          violations[kind] = violations_from_table(table)
        end

        violations.reject { |_, v| v.empty? }
      end

      def table(name, emoji, violations, all_previous_violations)
        content = violations.map { |v| process_markdown(v) }

        kind = table_kind_from_title(name)
        previous_violations = all_previous_violations[kind] || []
        resolved_violations = previous_violations.reject do |pv|
          content.count { |v| messages_are_equivalent(v, pv) } > 0
        end

        resolved_messages = resolved_violations.map(&:message).uniq
        count = content.count

        {
          name: name,
          emoji: emoji,
          content: content,
          resolved: resolved_messages,
          count: count
        }
      end

      def apply_template(tables: [], markdowns: [], danger_id: "danger", template: "github")
        require "erb"

        md_template = File.join(Danger.gem_path, "lib/danger/comment_generators/#{template}.md.erb")

        # erb: http://www.rrn.dk/rubys-erb-templating-system
        # for the extra args: http://stackoverflow.com/questions/4632879/erb-template-removing-the-trailing-line
        @tables = tables
        @markdowns = markdowns.map(&:message)
        @danger_id = danger_id

        return ERB.new(File.read(md_template), 0, "-").result(binding)
      end

      def generate_comment(warnings: [], errors: [], messages: [], markdowns: [], previous_violations: {}, danger_id: "danger", template: "github")
        apply_template(
          tables: [
            table("Error", "no_entry_sign", errors, previous_violations),
            table("Warning", "warning", warnings, previous_violations),
            table("Message", "book", messages, previous_violations)
          ],
          markdowns: markdowns,
          danger_id: danger_id,
          template: template
        )
      end

      def generate_inline_comment_body(emoji, message, danger_id: "danger", resolved: false, template: "github")
        apply_template(
          tables: [{ content: [message], resolved: resolved, emoji: emoji }],
          danger_id: danger_id,
          template: "#{template}_inline"
        )
      end

      def generate_inline_markdown_body(markdown, danger_id: "danger", template: "github")
        apply_template(
          markdowns: [markdown],
          danger_id: danger_id,
          template: "#{template}_inline"
        )
      end

      def generate_description(warnings: nil, errors: nil)
        if errors.empty? && warnings.empty?
          return "All green. #{random_compliment}"
        else
          message = "⚠ "
          message += "#{'Error'.danger_pluralize(errors.count)}. " unless errors.empty?
          message += "#{'Warning'.danger_pluralize(warnings.count)}. " unless warnings.empty?
          message += "Don't worry, everything is fixable."
          return message
        end
      end

      def random_compliment
        ["Well done.", "Congrats.", "Woo!",
         "Yay.", "Jolly good show.", "Good on 'ya.", "Nice work."].sample
      end

      def character_from_emoji(emoji)
        emoji.delete! ":"
        if emoji == "no_entry_sign"
          "🚫"
        elsif emoji == "warning"
          "⚠️"
        elsif emoji == "book"
          "📖"
        elsif emoji == "white_check_mark"
          "✅"
        end
      end

      private

      GITHUB_OLD_REGEX = %r{<th width="100%"(.*?)</th>}im
      NEW_REGEX = %r{<th.*data-danger-table="true"(.*?)</th>}im

      def danger_table?(table)
        # The old GitHub specific method relied on
        # the width of a `th` element to find the table
        # title and determine if it was a danger table.
        # The new method uses a more robust data-danger-table
        # tag instead.
        match = GITHUB_OLD_REGEX.match(table)
        return match if match

        return NEW_REGEX.match(table)
      end

      class Comment
        attr_reader :id, :body

        def initialize(id, body)
          @id = id
          @body = body
        end

        def self.from_github(comment)
          self.new(comment[:id], comment[:body])
        end

        def self.from_gitlab(comment)
          self.new(comment.id, comment.body)
        end

        def generated_by_danger?(danger_id)
          body.include?("generated_by_#{danger_id}")
        end
      end
    end
  end
end
