module ActionWebService # :nodoc:
  module API # :nodoc:
    # A web service API class specifies the methods that will be available for
    # invocation for an API. It also contains metadata such as the method type
    # signature hints.
    #
    # It is not intended to be instantiated.
    #
    # It is attached to web service implementation classes like
    # ActionWebService::Base and ActionController::Base derivatives by using
    # ClassMethods#web_service_api.
    class Base
      # Whether to transform the public API method names into camel-cased names 
      class_inheritable_option :inflect_names, true

      # Whether to allow ActiveRecord::Base models in <tt>:expects</tt>.
      # The default is +false+, you should be aware of the security implications
      # of allowing this, and ensure that you don't allow remote callers to
      # easily overwrite data they should not have access to.
      class_inheritable_option :allow_active_record_expects, false

      # If present, the name of a method to call when the remote caller
      # tried to call a nonexistent method. Semantically equivalent to
      # +method_missing+.
      class_inheritable_option :default_api_method

      # Disallow instantiation
      private_class_method :new, :allocate
      
      class << self
        include ActionWebService::SignatureTypes

        # API methods have a +name+, which must be the Ruby method name to use when
        # performing the invocation on the web service object.
        #
        # The signatures for the method input parameters and return value can
        # by specified in +options+.
        #
        # A signature is an array of one or more parameter specifiers. 
        # A parameter specifier can be one of the following:
        #
        # * A symbol or string of representing one of the Action Web Service base types.
        #   See ActionWebService::Signature for a canonical list of the base types.
        # * The Class object of the parameter type
        # * A single-element Array containing one of the two preceding items. This
        #   will cause Action Web Service to treat the parameter at that position
        #   as an array containing only values of the given type.
        # * A Hash containing as key the name of the parameter, and as value
        #   one of the three preceding items
        # 
        # If no method input parameter or method return value signatures are given,
        # the method is assumed to take no parameters and/or return no values of
        # interest, and any values that are received by the server will be
        # discarded and ignored.
        #
        # Valid options:
        # [<tt>:expects</tt>]             Signature for the method input parameters
        # [<tt>:returns</tt>]             Signature for the method return value
        # [<tt>:expects_and_returns</tt>] Signature for both input parameters and return value
        def api_method(name, options={})
          validate_options([:expects, :returns, :expects_and_returns], options.keys)
          if options[:expects_and_returns]
            expects = options[:expects_and_returns]
            returns = options[:expects_and_returns]
          else
            expects = options[:expects]
            returns = options[:returns]
          end
          expects = canonical_signature(expects)
          returns = canonical_signature(returns)
          if expects
            expects.each do |type|
              type = type.element_type if type.is_a?(ArrayType)
              if type.type_class.ancestors.include?(ActiveRecord::Base) && !allow_active_record_expects
                raise(ActionWebServiceError, "ActiveRecord model classes not allowed in :expects")
              end
            end
          end
          name = name.to_sym
          public_name = public_api_method_name(name)
          method = Method.new(name, public_name, expects, returns)
          write_inheritable_hash("api_methods", name => method)
          write_inheritable_hash("api_public_method_names", public_name => name)
        end

        # Whether the given method name is a service method on this API
        def has_api_method?(name)
          api_methods.has_key?(name)
        end
  
        # Whether the given public method name has a corresponding service method
        # on this API
        def has_public_api_method?(public_name)
          api_public_method_names.has_key?(public_name)
        end
  
        # The corresponding public method name for the given service method name
        def public_api_method_name(name)
          if inflect_names
            name.to_s.camelize
          else
            name.to_s
          end
        end
  
        # The corresponding service method name for the given public method name
        def api_method_name(public_name)
          api_public_method_names[public_name]
        end
  
        # A Hash containing all service methods on this API, and their
        # associated metadata.
        def api_methods
          read_inheritable_attribute("api_methods") || {}
        end

        # The Method instance for the given public API method name, if any
        def public_api_method_instance(public_method_name)
          api_method_instance(api_method_name(public_method_name))
        end

        # The Method instance for the given API method name, if any
        def api_method_instance(method_name)
          api_methods[method_name]
        end

        # The Method instance for the default API method, if any
        def default_api_method_instance
          return nil unless name = default_api_method
          instance = read_inheritable_attribute("default_api_method_instance")
          if instance && instance.name == name
            return instance
          end
          instance = Method.new(name, public_api_method_name(name), nil, nil)
          write_inheritable_attribute("default_api_method_instance", instance)
          instance
        end

        private
          def api_public_method_names
            read_inheritable_attribute("api_public_method_names") || {}
          end
  
          def validate_options(valid_option_keys, supplied_option_keys)
            unknown_option_keys = supplied_option_keys - valid_option_keys
            unless unknown_option_keys.empty?
              raise(ActionWebServiceError, "Unknown options: #{unknown_option_keys}")
            end
          end
      end
    end

    # Represents an API method and its associated metadata, and provides functionality
    # to assist in commonly performed API method tasks.
    class Method
      attr :name
      attr :public_name
      attr :expects
      attr :returns

      def initialize(name, public_name, expects, returns)
        @name = name
        @public_name = public_name
        @expects = expects
        @returns = returns
        @caster = ActionWebService::Casting::BaseCaster.new(self)
      end
      
      # The list of parameter names for this method
      def param_names
        return [] unless @expects
        @expects.map{ |type| type.name }
      end

      # Casts a set of Ruby values into the expected Ruby values
      def cast_expects(params)
        @caster.cast_expects(params)
      end

      # Cast a Ruby return value into the expected Ruby value
      def cast_returns(return_value)
        @caster.cast_returns(return_value)
      end

      # String representation of this method
      def to_s
        fqn = ""
        fqn << (@returns ? (friendly_param(@returns[0], false) + " ") : "void ")
        fqn << "#{@public_name}("
        fqn << @expects.map{ |p| friendly_param(p) }.join(", ") if @expects
        fqn << ")"
        fqn
      end

      private
        def friendly_param(type, show_name=true)
          name = type.name.to_s
          type_type = type.type.to_s
          str = type.array?? (type_type + '[]') : type_type
          show_name ? (str + " " + name) : str
        end
    end
  end
end
