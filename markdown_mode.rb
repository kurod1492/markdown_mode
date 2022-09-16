require 'ripper'
require 'github/markup'

module Textbringer
  CONFIG[:markdown_indent_level] = 2
  CONFIG[:markdown_indent_tabs_mode] = true

  class MarkdownMode < ProgrammingMode
    self.file_name_pattern = /\A(?:.*\.(?:md|markdown))\z/ix

    define_syntax :keyword, /\*|#/

    def initialize(buffer)
      super(buffer)
      @buffer[:indent_level] = CONFIG[:markdown_indent_level]
      @buffer[:indent_tabs_mode] = CONFIG[:markdown_indent_tabs_mode]
    end

    def forward_definition(n = number_prefix_arg || 1)
      tokens = Ripper.lex(@buffer.to_s)
      @buffer.forward_line
      n.times do |i|
        tokens = tokens.drop_while { |(l, _), e, t|
          l < @buffer.current_line ||
            e != :on_kw || /\A(?:\*|\#)\z/ !~ t
        }
        (line,), = tokens.first
        if line.nil?
          @buffer.end_of_buffer
          break
        end
        @buffer.goto_line(line)
        tokens = tokens.drop(1)
      end
      while /\s/ =~ @buffer.char_after
        @buffer.forward_char
      end
    end

    def backward_definition(n = number_prefix_arg || 1)
      tokens = Ripper.lex(@buffer.to_s).reverse
      @buffer.beginning_of_line
      n.times do |i|
        tokens = tokens.drop_while { |(l, _), e, t|
          l >= @buffer.current_line ||
            e != :on_kw || /\A(?:\*|\#)\z/ !~ t
        }
        (line,), = tokens.first
        if line.nil?
          @buffer.beginning_of_buffer
          break
        end
        @buffer.goto_line(line)
        tokens = tokens.drop(1)
      end
      while /\s/ =~ @buffer.char_after
        @buffer.forward_char
      end
    end

    private

    INDENT_BEG_RE = /^([ \t]\*)\b/

    def space_width(s)
      s.gsub(/\t/, " " * @buffer[:tab_width]).size
    end

    def beginning_of_indentation
      loop do
        @buffer.re_search_backward(INDENT_BEG_RE)
        space = @buffer.match_string(1)
        s = @buffer.substring(@buffer.point_min, @buffer.point)
        if PartialLiteralAnalyzer.in_literal?(s)
          next
        end
        return space_width(space)
      end
    rescue SearchError
      @buffer.beginning_of_buffer
      0
    end

    def lex(source)
      line_count = source.count("\n")
      s = source
      lineno = 1
      tokens = []
      loop do
        lexer = Ripper::Lexer.new(s, "-", lineno)
        tokens.concat(lexer.lex)
        last_line = tokens.dig(-1, 0, 0)
        return tokens if last_line.nil? || last_line >= line_count
        s = source.sub(/(.*\n?){#{last_line}}/, "")
        return tokens if last_line + 1 <= lineno
        lineno = last_line + 1
      end
    end

    def calculate_indentation
      if @buffer.current_line == 1
        return 0
      end
      @buffer.save_excursion do
        @buffer.beginning_of_line
        start_with_period = @buffer.looking_at?(/[ \t]\*/)
        bol_pos = @buffer.point
        base_indentation = beginning_of_indentation
        start_pos = @buffer.point
        start_line = @buffer.current_line
        tokens = lex(@buffer.substring(start_pos, bol_pos))
        _, event, text = tokens.last
        if event == :on_nl
          _, event, text = tokens[-2]
        end
        if event == :on_tstring_beg ||
            event == :on_heredoc_beg ||
            event == :on_regexp_beg ||
            (event == :on_regexp_end && text.size > 1) ||
            event == :on_tstring_content
          return nil
        end
        i, extra_end_count = find_nearest_beginning_token(tokens)
        (line, column), event, = i ? tokens[i] : nil
        if event == :on_lparen && tokens.dig(i + 1, 1) != :on_ignored_nl
          return column + 1
        end
        if line
          @buffer.goto_line(start_line - 1 + line)
          while !@buffer.beginning_of_buffer?
            if @buffer.save_excursion {
              @buffer.backward_char
              @buffer.skip_re_backward(/\s/)
              @buffer.char_before == ?,
            }
              @buffer.backward_line
            else
              break
            end
          end
          @buffer.looking_at?(/[ \t]\*/)
          base_indentation = space_width(@buffer.match_string(0))
        end
        @buffer.goto_char(bol_pos)
        if line.nil?
          indentation =
            base_indentation - extra_end_count * @buffer[:indent_level]
        else
          indentation = base_indentation + @buffer[:indent_level]
        end
        if @buffer.looking_at?(/[ \t]\*/)
          indentation -= @buffer[:indent_level]
        end
        _, last_event, last_text = tokens.reverse_each.find { |_, e, _|
          e != :on_sp && e != :on_nl && e != :on_ignored_nl
        }
        if start_with_period ||
            (last_event == :on_op && last_text != "|") ||
            (last_event == :on_kw && /\A(and|or)\z/.match?(last_text)) ||
            last_event == :on_period ||
            (last_event == :on_comma && event != :on_lbrace &&
             event != :on_lparen && event != :on_lbracket) ||
            last_event == :on_label
          indentation += @buffer[:indent_level]
        end
        indentation
      end
    end

    BLOCK_END = {
      '#' => "",
      "*" => ""
    }

    def find_nearest_beginning_token(tokens)
      stack = []
      (tokens.size - 1).downto(0) do |i|
        (line, ), event, text = tokens[i]
        case event
        when :on_kw
          _, prev_event, _ = tokens[i - 1]
          next if prev_event == :on_symbeg
          case text
          when "*", "#"
            if /\A(\*|\#)\z/.match?(text) &&
                modifier?(tokens, i)
              next
            end
            if text == "def" && endless_method_def?(tokens, i)
              next
            end
            if stack.empty?
              return i
            end
            if stack.last != "end"
              raise EditorError, "#{@buffer.name}:#{line}: Unmatched #{text}"
            end
            stack.pop
          when "end"
            stack.push(text)
          end
        when :on_rbrace, :on_rparen, :on_rbracket, :on_embexpr_end
          stack.push(text)
        when :on_lbrace, :on_lparen, :on_lbracket, :on_tlambeg, :on_embexpr_beg
          if stack.empty?
            return i
          end
          if stack.last != BLOCK_END[text]
            raise EditorError, "#{@buffer.name}:#{line}: Unmatched #{text}"
          end
          stack.pop
        end
      end
      return nil, stack.grep_v(/[)\]]/).size
    end
  end

  module Commands
    define_command(:markdown_to_html, doc: 'markdown to html.') do
      filename = "#{Buffer.current.name}.html"
      File.open(filename, 'w') do |file|
        file.puts('<head><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/github-markdown-css/5.1.0/github-markdown.min.css" integrity="sha512-KUoB3bZ1XRBYj1QcH4BHCQjurAZnCO3WdrswyLDtp7BMwCw7dPZngSLqILf68SGgvnWHTD5pPaYrXi6wiRJ65g==" crossorigin="anonymous" referrerpolicy="no-referrer" /></head><article class="markdown-body">')
        file.puts(GitHub::Markup.render_s(GitHub::Markups::MARKUP_MARKDOWN, Buffer.current.to_s))
        file.puts('</article>')
      end
    end
  end

  GLOBAL_MAP.define_key("\C-xd", :markdown_to_html)
end
