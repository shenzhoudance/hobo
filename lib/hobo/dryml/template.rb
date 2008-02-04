require 'rexml/document'

module Hobo::Dryml

  class Template

    DRYML_NAME = "[a-zA-Z\-][a-zA-Z0-9\-]*"
    DRYML_NAME_RX = /^#{DRYML_NAME}$/

    RUBY_NAME = "[a-zA-Z_][a-zA-Z0-9_]*"
    RUBY_NAME_RX = /^#{RUBY_NAME}$/
    
    CODE_ATTRIBUTE_CHAR = "&"
    
    NO_METADATA_TAGS = %w(doctype if else unless repeat do with name type-name)
    
    SPECIAL_ATTRIBUTES = %w(param merge merge-params merge-attrs 
                            for-type 
                            if unless repeat 
                            part part-locals
                            restore)

    @build_cache = {}
    
    class << self
      attr_reader :build_cache

      def clear_build_cache
        @build_cache.clear()
      end
    end

    def initialize(src, environment, template_path, bundle=nil)
      @src = src
      @environment = environment # a class or a module
      @template_path = template_path.sub(/^#{Regexp.escape(RAILS_ROOT)}/, "")
      @bundle = bundle

      @builder = Template.build_cache[@template_path] || DRYMLBuilder.new(self)
      @builder.set_environment(environment)

      @last_element = nil
    end

    attr_reader :tags, :template_path, :bundle
    
    def compile(local_names=[], auto_taglibs=[])
      now = Time.now

      unless @template_path.ends_with?(EMPTY_PAGE)
        filename = RAILS_ROOT + (@template_path.starts_with?("/") ? @template_path : "/" + @template_path)
        mtime = File.stat(filename).mtime rescue nil
      end
        
      if mtime.nil? || !@builder.ready?(mtime)
        @builder.clear_instructions
        parsed = true
        # parse the DRYML file creating a list of build instructions
        if is_taglib?
          process_src
        else
          create_render_page_method
        end

        # store build instructions in the cache
        Template.build_cache[@template_path] = @builder
      end

      # compile the build instructions
      @builder.build(local_names, auto_taglibs, mtime)

      from_cache = (parsed ? '' : ' (from cache)')
      logger.info("  DRYML: Compiled#{from_cache} #{template_path} in %.2fs" % (Time.now - now))
    end
      

    def create_render_page_method
      erb_src = process_src
      
      @builder.add_build_instruction(:render_page, :src => erb_src, :line_num => 1)
    end

    
    def is_taglib?
      @environment.class == Module
    end

    
    def process_src
      # Replace <%...%> scriptlets with xml-safe references into a hash of scriptlets
      @scriptlets = {}
      src = @src.gsub(/<%(.*?)%>/m) do
        _, scriptlet = *Regexp.last_match
        id = @scriptlets.size + 1
        @scriptlets[id] = scriptlet
        newlines = "\n" * scriptlet.count("\n")
        "[![HOBO-ERB#{id}#{newlines}]!]"
      end

      @xmlsrc = "<dryml_page>" + src + "</dryml_page>"
      begin
        @doc = REXML::Document.new(RexSource.new(@xmlsrc), :dryml_mode => true)
      rescue REXML::ParseException => e
        raise DrymlSyntaxError, "File: #{@template_path}\n#{e}"
      end
      @doc.default_attribute_value = "&true"
      
      restore_erb_scriptlets(children_to_erb(@doc.root))
    end


    def restore_erb_scriptlets(src)
      src.gsub(/\[!\[HOBO-ERB(\d+)\s*\]!\]/m) {|s| "<%#{@scriptlets[$1.to_i]}%>" }
    end

    
    def children_to_erb(nodes)
      nodes.map{|x| node_to_erb(x)}.join
    end
 

    def node_to_erb(node)
      case node

      # v important this comes before REXML::Text, as REXML::CData < REXML::Text
      when REXML::CData
        REXML::CData::START + node.to_s + REXML::CData::STOP
        
      when REXML::Comment
        REXML::Comment::START + node.to_s + REXML::Comment::STOP

      when REXML::Text
        node.to_s

      when REXML::Element
        element_to_erb(node)
      end
    end


    def element_to_erb(el)
      dryml_exception("old-style parameter tag (<#{el.name}>)", el) if el.name.starts_with?(":")

      @last_element = el
      case el.dryml_name

      when "include"
        include_element(el)
        # return just the newlines to keep line-number matching - the
        # include has no presence in the erb source
        tag_newlines(el)
        
      when "set-theme"
        require_attribute(el, "name", /^#{DRYML_NAME}$/)
        @builder.add_build_instruction(:set_theme, :name => el.attributes['name'])

        # return nothing - set_theme has no presence in the erb source
        tag_newlines(el)

      when "def"
        def_element(el)
        
      when "set"
        set_element(el)
        
      when "set-scoped"
        set_scoped_element(el)
        
      when "param-content"
        param_content_element(el)
        
      else
        if el.dryml_name.not_in?(Hobo.static_tags) || el.attributes['param'] || el.attributes['restore']
          tag_call(el)
        else
          static_element_to_erb(el)
        end
      end
    end


    def include_element(el)
      require_toplevel(el)
      require_attribute(el, "as", /^#{DRYML_NAME}$/, true)
      options = {}
      %w(src module plugin bundle as).each do |attr|
        options[attr.to_sym] = el.attributes[attr] if el.attributes[attr]
      end
      @builder.add_build_instruction(:include, options)
    end
    

    def import_module(mod, as=nil)
      @builder.import_module(mod, as)
    end


    def set_element(el)
      assigns = el.attributes.map do |name, value|
        dryml_exception(el, "invalid name in set") unless name =~ /^#{DRYML_NAME}(\.#{DRYML_NAME})*$/
        "#{ruby_name name} = #{attribute_to_ruby(value)}; "
      end.join
      code = apply_control_attributes("begin; #{assigns}; end", el)
      "<% #{assigns}#{tag_newlines(el)} %>"
    end
    
    
    def set_scoped_element(el)
      assigns = el.attributes.map do |name, value|
        dryml_exception(el, "invalid name in set-scoped") unless name =~ DRYML_NAME_RX
        "scope[:#{ruby_name name}] = #{attribute_to_ruby(value)}; "
      end.join
      "<% scope.new_scope { #{assigns}#{tag_newlines(el)} %>#{children_to_erb(el)}<% } %>"
    end
    
    
    def declared_attributes(def_element)
      attrspec = def_element.attributes["attrs"]
      attr_names = attrspec ? attrspec.split(/\s*,\s*/).map{ |n| n.underscore.to_sym } : []
      invalids = attr_names & ([:with, :field, :this] + SPECIAL_ATTRIBUTES.every(:to_sym))
      dryml_exception("invalid attrs in def: #{invalids * ', '}", def_element) unless invalids.empty?
      attr_names
    end
    
    
    def ruby_name(dryml_name)
      dryml_name.gsub('-', '_')
    end
    
    
    def with_containing_tag_name(el)
      old = @containing_tag_name
      @containing_tag_name = el.dryml_name
      yield
      @containing_tag_name = old
    end


    def def_element(el)
      require_toplevel(el)
      require_attribute(el, "tag", DRYML_NAME_RX)
      require_attribute(el, "attrs", /^\s*#{DRYML_NAME}(\s*,\s*#{DRYML_NAME})*\s*$/, true)
      require_attribute(el, "alias-of", DRYML_NAME_RX, true)
      require_attribute(el, "extend-with", DRYML_NAME_RX, true)
      
      unsafe_name = el.attributes["tag"]
      name = Hobo::Dryml.unreserve(unsafe_name)
      if (for_type = el.attributes['for'])
        type_name = case for_type
                    when /^[a-z]/
                      # It's a symbolic type name - look up the Ruby type name
                      Hobo.field_types[for_type].name
                    when /^_.*_$/
                      rename_class(for_type)
                    else
                      for_type
                    end.underscore.gsub('/', '__')
        suffix = "__for_#{type_name}"
        name        += suffix
        unsafe_name += suffix
      end
      
      @def_element = el
      
      alias_of = el.attributes['alias-of']
      extend_with = el.attributes['extend-with']

      dryml_exception("def cannot have both alias-of and extend-with", el) if alias_of && extend_with
      dryml_exception("def with alias-of must be empty", el) if alias_of and el.size > 0
      
      
      @builder.add_build_instruction(:alias_method,
                                     :new => ruby_name(name).to_sym, 
                                     :old => ruby_name(Hobo::Dryml.unreserve(alias_of)).to_sym) if alias_of
      
      res = if alias_of
              "<% #{tag_newlines(el)} %>"
            else
              src = ""
              if extend_with
                src << "<% delayed_alias_method_chain :#{ruby_name name}, :#{ruby_name extend_with} %>"
                name = "#{name}-with-#{extend_with}"
              end
              src << tag_method(name, el) +
                "<% _register_tag_attrs(:#{ruby_name name}, #{declared_attributes(el).inspect.underscore}) %>"
              
              logger.debug(restore_erb_scriptlets(src)) if el.attributes["debug-source"]
              
              @builder.add_build_instruction(:def,
                                             :src => restore_erb_scriptlets(src),
                                             :line_num => element_line_num(el))
              # keep line numbers matching up
              "<% #{"\n" * src.count("\n")} %>"
            end
      @def_element = nil
      res
    end
    
    
    def param_names_in_definition(el)
      REXML::XPath.match(el, ".//*[@param]").map do |e|
        name = get_param_name(e)
        dryml_exception("invalid param name: #{name.inspect}", e) unless 
          is_code_attribute?(name) || name =~ RUBY_NAME_RX || name =~ /#\{/
        name.to_sym unless is_code_attribute?(name)
      end.compact
    end
    
    
    def tag_method(name, el)
      param_names = param_names_in_definition(el)
      
      "<% def #{ruby_name name}(all_attributes={}, all_parameters={}); " +
        "parameters = Hobo::Dryml::TagParameters.new(all_parameters, #{param_names.inspect.underscore}); " +
        "all_parameters = Hobo::Dryml::TagParameters.new(all_parameters); " +
        tag_method_body(el) +
        "; end %>"
    end
    
        
    def tag_method_body(el)
      attrs = declared_attributes(el)
      
      # A statement to assign values to local variables named after the tag's attrs
      # The trailing comma on `attributes` is supposed to be there!
      setup_locals = attrs.map{|a| "#{Hobo::Dryml.unreserve(a).underscore}, "}.join + "attributes, = " +
        "_tag_locals(all_attributes, #{attrs.inspect})"

      start = "_tag_context(all_attributes) do #{setup_locals}"
      
      "#{start} " +
        # reproduce any line breaks in the start-tag so that line numbers are preserved
        tag_newlines(el) + "%>" +
        wrap_tag_method_body_with_metadata(children_to_erb(el)) +
        "<% _erbout; end"
    end
    
    
    def wrap_source_with_metadata(content, kind, name, *args)
      if (!include_source_metadata) || name.in?(NO_METADATA_TAGS)
        content
      else
        metadata = [kind, name] + args + [@template_path]
        "<!--[DRYML|#{metadata * '|'}[-->" + content + "<!--]DRYML]-->"
      end
    end
    
    
    def wrap_tag_method_body_with_metadata(content)
      name   = @def_element.attributes['tag']
      extend = @def_element.attributes['extend-with']
      for_   = @def_element.attributes['for']
      name = extend ? "#{name}-with-#{extend}" : name
      name += " for #{for_}" if for_
      wrap_source_with_metadata(content, "def", name, element_line_num(@def_element))
    end
    
    
    def wrap_tag_call_with_metadata(el, content)
      name = el.expanded_name
      param = el.attributes['param']
        
      if param == "&true"
        name += " param"
      elsif param
        name += " param='#{param}'" 
      end
        
      wrap_source_with_metadata(content, "call", name, element_line_num(el))
    end
    
       
    def param_content_element(el)
      name = el.attributes['for'] || @containing_tag_name
      local_name = param_content_local_name(name)
      "<%= #{local_name} && #{local_name}.call %>"
    end


    def part_element(el, content)
      require_attribute(el, "part", DRYML_NAME_RX)
      
      if contains_param?(el)
        delegated_part_element(el, content)
      else
        simple_part_element(el, content)
      end
    end

    
    def simple_part_element(el, content)
      part_name  = el.attributes['part']
      dom_id = el.attributes['id'] || part_name
      part_name = ruby_name(part_name)
      part_locals = el.attributes["part-locals"]
      
      part_src = "<% def #{part_name}_part(#{part_locals._?.gsub('@', '')}) #{tag_newlines(el)}; new_context do %>" +
        content +
        "<% end; end %>"
      @builder.add_part(part_name, restore_erb_scriptlets(part_src), element_line_num(el))

      newlines = "\n" * part_src.count("\n")
      args = [attribute_to_ruby(dom_id), ":#{part_name}", "nil", part_locals].compact
      "<%= call_part(#{args * ', '}) #{newlines} %>"
    end
    
    
    def delegated_part_element(el, content)
      # TODO 
    end
    
    
    def contains_param?(el)
      # TODO
      false
    end
    
    
    def part_delegate_tag_name(el)
      "#{@def_name}_#{el.attributes['part']}__part_delegate"
    end
    
    
    def get_param_name(el)
      param_name = el.attributes["param"]
      
      if param_name
        def_tag = find_ancestor(el) {|e| e.name == "def"}
        dryml_exception("param is not allowed outside of tag definitions", el) if def_tag.nil?
        
        ruby_name(param_name == "&true" ? el.dryml_name : param_name)
      else
        nil
      end
    end
    
    
    def call_name(el)
      dryml_exception("invalid tag name", el) unless el.dryml_name =~ /^#{DRYML_NAME}(\.#{DRYML_NAME})*$/
      Hobo::Dryml.unreserve(ruby_name(el.dryml_name))
    end

   
    def polymorphic_call_type(el)
      t = el.attributes['for-type']
      if t.nil?
        nil
      elsif t == "&true"
        'this_type'
      elsif t =~ /^[A-Z]/
        t
      elsif t =~ /^[a-z]/
        "Hobo.field_types[:#{t}]"
      elsif is_code_attribute?(t)
        t[1..-1]
      else
        dryml_exception("invalid for-type attribute", el)
      end
    end
    
    
    def tag_call(el)
      name = call_name(el)
      param_name = get_param_name(el)
      attributes = tag_attributes(el)
      newlines = tag_newlines(el)
      
      parameters = tag_newlines(el) + parameter_tags_hash(el)
      
      is_param_restore = el.attributes['restore']
      
      call = if param_name
               param_name = attribute_to_ruby(param_name, :symbolize => true)
               args = "#{attributes}, #{parameters}, all_parameters, #{param_name}"
               to_call = if is_param_restore
                           # The tag is available in a local variable
                           # holding a proc
                           param_restore_local_name(name)
                         elsif (call_type = polymorphic_call_type(el))
                           "find_polymorphic_tag(:#{ruby_name name}, #{call_type})"
                         else
                           ":#{ruby_name name}"
                         end
               "call_tag_parameter(#{to_call}, #{args})"
             else
               if is_param_restore
                 # The tag is a proc available in a local variable
                 "#{param_restore_local_name(name)}.call(#{attributes}, #{parameters})"
               elsif (call_type = polymorphic_call_type(el))
                 "send(find_polymorphic_tag(:#{ruby_name name}, #{call_type}), #{attributes}, #{parameters})"
               elsif attributes == "{}" && parameters == "{}"
                 "#{ruby_name name}.to_s"
               else
                 "#{ruby_name name}(#{attributes}, #{parameters})"
               end
             end

      call = apply_control_attributes(call, el)
      call = maybe_make_part_call(el, "<% _output(#{call}) %>")
      wrap_tag_call_with_metadata(el, call)
    end
    
    
    def merge_attribute(el)
      merge = el.attributes['merge']
      dryml_exception("merge cannot have a RHS", el) if merge && merge != "&true"
      merge
    end
    

    def parameter_tags_hash(el, containing_tag_name=nil)
      call_type = nil
      
      containing_tag_name
      metadata_name = containing_tag_name || el.expanded_name
      
      param_items = el.map do |node|
        case node
        when REXML::Text
          text = node.to_s
          if text.blank?
            # include whitespace in hash literal to keep line numbers
            # matching
            text
          else
            case call_type
            when nil
              call_type = :default_param_only
              text
            when :default_param_only
              text
            when :named_params
              dryml_exception("mixed content and parameter tags", el)
            end
          end
          node.to_s
        when REXML::Element
          e = node
          is_parameter_tag = e.parameter_tag?
          
          # Make sure there isn't a mix of parameter tags and normal content
          case call_type
          when nil
            call_type = is_parameter_tag ? :named_params : :default_param_only
          when :named_params
            dryml_exception("mixed parameter tags and non-parameter tags", el) unless is_parameter_tag
          when :default_param_only
            dryml_exception("mixed parameter tags and non-parameter tags", el) if is_parameter_tag
          end
          
          if is_parameter_tag
            param_name = get_param_name(e)
            if param_name
              ":#{ruby_name e.name} => merge_tag_parameter(#{param_proc(e, metadata_name)}, all_parameters[:#{param_name}]), "
            else
              ":#{ruby_name e.name} => #{param_proc(e, metadata_name)}, "
            end
          end
        end
      end.join
      
      if call_type == :default_param_only
        with_containing_tag_name(el) do
          param_items = " :default => #{default_param_proc(el, containing_tag_name)}, "
        end
      end
      
      merge_params = el.attributes['merge-params'] || merge_attribute(el)
      if merge_params
        extra_params = if merge_params == "&true"
                         "parameters"
                       elsif is_code_attribute?(merge_params)
                         merge_params[1..-1]
                       else
                         dryml_exception("invalid merge_params", el)
                       end
        "{#{param_items}}.merge((#{extra_params}) || {})"
      else
        "{#{param_items}}"
      end
    end
    

    def default_param_proc(el, containing_param_name=nil)
      content = children_to_erb(el)
      content = wrap_source_with_metadata(content, "param", containing_param_name, element_line_num(el)) if containing_param_name
      "proc { |#{param_content_local_name(el.dryml_name)}| new_context { %>#{content}<% } #{tag_newlines(el)}}"
    end
    
    
    def param_restore_local_name(name)
      "_#{ruby_name name}_restore"
    end
    
    
    def wrap_replace_parameter(el, name)
      wrap_source_with_metadata(children_to_erb(el), "replace", name, element_line_num(el))
    end
    
    
    def param_proc(el, metadata_name_prefix)
      param_name = el.dryml_name
      metadata_name = "#{metadata_name_prefix}><#{el.name}"
      
      nl = tag_newlines(el)
            
      if (repl = el.attribute("replace"))
        dryml_exception("replace attribute must not have a value", el) if repl.has_rhs?
        dryml_exception("replace parameters must not have attributes", el) if el.attributes.length > 1
        
        
        "proc { |#{param_restore_local_name(param_name)}| new_context { %>#{wrap_replace_parameter(el, metadata_name)}<% } #{nl}}"
      else
        attributes = el.attributes.map do 
          |name, value| ":#{ruby_name name} => #{attribute_to_ruby(value, el)}" unless name.in?(SPECIAL_ATTRIBUTES)
        end.compact
        
        nested_parameters_hash = parameter_tags_hash(el, metadata_name)
        "proc { [{#{attributes * ', '}}, #{nested_parameters_hash}] #{nl}}"
      end
    end
    
    
    def param_content_local_name(name)
      "_#{ruby_name name}__default_content"
    end
    
        
    def maybe_make_part_call(el, call)
      part_name = el.attributes['part']
      if part_name
        part_id = part_name && "<%= #{attribute_to_ruby(el.attributes['id'] || part_name)} %>"
        "<span class='part-wrapper' id='#{part_id}'>" + part_element(el, call) + "</span>"
      else
        call
      end
    end
    
    
    def tag_attributes(el)
      attributes = el.attributes
      items = attributes.map do |n,v|
        dryml_exception("invalid attribute name '#{n}'", el) unless n =~ DRYML_NAME_RX
       
        unless n.in?(SPECIAL_ATTRIBUTES)
          ":#{ruby_name n} => #{attribute_to_ruby(v)}"
        end
      end.compact
      
      # if there's a ':' el.name is just the part after the ':'
      items << ":field => \"#{el.name}\"" if el.expanded_name =~ /:/
      
      items = items.join(", ")
      
      merge_attrs = attributes['merge-attrs'] || merge_attribute(el)
      if merge_attrs
        extra_attributes = if merge_attrs == "&true"
                          "attributes"
                        elsif is_code_attribute?(merge_attrs)
                          merge_attrs[1..-1]
                        else
                          dryml_exception("invalid merge-attrs", el)
                        end
        "merge_attrs({#{items}},(#{extra_attributes}) || {})"
      else
        "{#{items}}"
      end
    end

    def static_tag_to_method_call(el)
      part = el.attributes["part"]
      attrs = el.attributes.map do |n, v|
        next if n.in? SPECIAL_ATTRIBUTES
        val = restore_erb_scriptlets(v).gsub('"', '\"').gsub(/<%=(.*?)%>/, '#{\1}')
        %('#{n}' => "#{val}")
      end.compact
      
      # If there's a part but no id, the id defaults to the part name
      if part && !el.attributes["id"]
        attrs << ":id => '#{part}'"
      end
      
      # Convert the attributes hash to a call to merge_attrs if
      # there's a merge-attrs attribute
      attrs = if (merge_attrs = el.attributes['merge-attrs'])
                dryml_exception("merge-attrs was given a string", el) unless is_code_attribute?(merge_attrs)
        
                "merge_attrs({#{attrs * ', '}}, " +
                  "((__merge_attrs__ = (#{merge_attrs[1..-1]})) == true ? attributes : __merge_attrs__))"
              else
                "{" + attrs.join(', ') + "}"
              end
      
      if el.children.empty?
        dryml_exception("part attribute on empty static tag", el) if part

        "<%= " + apply_control_attributes("element(:#{el.name}, #{attrs} #{tag_newlines(el)})", el) + " %>"
      else
        if part
          body = part_element(el, children_to_erb(el))
        else
          body = children_to_erb(el)               
        end

        output_tag = "element(:#{el.name}, #{attrs}, new_context { %>#{body}<% })"
        "<% _output(" + apply_control_attributes(output_tag, el) + ") %>"
      end
    end
    
    
    def static_element_to_erb(el)
      if %w(part merge-attrs if unless repeat).any? {|x| el.attributes[x]}
        static_tag_to_method_call(el)
      else
        start_tag_src = el.start_tag_source.gsub(REXML::CData::START, "").gsub(REXML::CData::STOP, "")
        
        # Allow #{...} as an alternate to <%= ... %>
        start_tag_src.gsub!(/=\s*('.*?'|".*?")/) do |s|
          s.gsub(/#\{(.*?)\}/, '<%= \1 %>')
        end

        if el.has_end_tag?
          start_tag_src + children_to_erb(el) + "</#{el.name}>"
        else
          start_tag_src
        end
      end
    end
    
    
    def apply_control_attributes(expression, el)
      if_, unless_, repeat = controls = %w(if unless repeat).map {|x| el.attributes[x]}
      controls.compact!
      
      dryml_exception("You can't have multiple control attributes on the same element", el) if
        controls.length > 1
      
      val = controls.first
      if val.nil?
        expression
      else
        control = if val == "&true"
                    "this"
                  elsif is_code_attribute?(val)
                    "#{val[1..-1]}"
                  else
                    "this.#{val}"
                  end
        
        x = gensym
        if if_
          "(if !(#{control}).blank?; (#{x} = #{expression}; Hobo::Dryml.last_if = true; #{x}) " +
            "else (Hobo::Dryml.last_if = false; ''); end)"
        elsif unless_
          "(if (#{control}).blank?; (#{x} = #{expression}; Hobo::Dryml.last_if = true; #{x}) " +
            "else (Hobo::Dryml.last_if = false; ''); end)"
        elsif repeat
          "repeat_attribute(#{control}) { #{expression} }"
        end
      end
    end
    

    def attribute_to_ruby(*args)
      options = args.extract_options!
      attr, el = args
      
      dryml_exception('erb scriptlet not allowed in this attribute (use #{ ... } instead)', el) if
        attr.is_a?(String) && attr.index("[![HOBO-ERB")

      if options[:symbolize] && attr =~ /^[a-zA-Z_][^a-zA-Z0-9_]*[\?!]?/
        ":#{attr}"
      else
        res = if attr.nil?
                "nil"
              elsif is_code_attribute?(attr)
                "(#{attr[1..-1]})"
              else
                if attr !~ /"/
                  '"' + attr + '"'
                elsif attr !~ /'/
                  "'#{attr}'"
                else
                  dryml_exception("invalid quote(s) in attribute value")
                end
                #attr.starts_with?("++") ? "attr_extension(#{str})" : str
              end 
        options[:symbolize] ? (res + ".to_sym") : res
      end
    end

    def find_ancestor(el)
      e = el.parent
      until e.is_a? REXML::Document
        return e if yield(e)
        e = e.parent
      end
      return nil
    end

    def require_toplevel(el, message=nil)
      message ||= "can only be at the top level"
      dryml_exception("<#{el.dryml_name}> #{message}", el) if el.parent != @doc.root
    end

    def require_attribute(el, name, rx=nil, optional=false)
      val = el.attributes[name]
      if val
        dryml_exception("invalid #{name}=\"#{val}\" attribute on <#{el.dryml_name}>", el) unless rx && val =~ rx
      else
        dryml_exception("missing #{name} attribute on <#{el.dryml_name}>", el) unless optional
      end
    end

    def dryml_exception(message, el=nil)
      el ||= @last_element
      raise DrymlException.new(message, template_path, element_line_num(el))
    end

    def element_line_num(el)
      offset = el.source_offset
      @xmlsrc[0..offset].count("\n") + 1
    end

    def tag_newlines(el)
      src = el.start_tag_source
      "\n" * src.count("\n")
    end

    def is_code_attribute?(attr_value)
      attr_value =~ /^\&/ && attr_value !~ /^\&\S+;/
    end

    def logger
      ActionController::Base.logger rescue nil
    end
    
    def gensym(name="__tmp")
      @gensym_counter ||= 0
      @gensym_counter += 1
      "#{name}_#{@gensym_counter}"
    end
    
    def rename_class(name)
      @bundle && name.starts_with?("_") ? @bundle.send(name) : name
    end
    
    def include_source_metadata
      return false
      @include_source_metadata = RAILS_ENV == "development" && !ENV['DRYML_EDITOR'].blank? if @include_source_metadata.nil?
      @include_source_metadata
    end

  end

end
