require 'time'
require 'date'
require 'generator'

module ActionWebService # :nodoc:
  module Casting # :nodoc:
    class CastingError < ActionWebServiceError # :nodoc:
    end

    # Performs casting of arbitrary values into the correct types for the signature
    class BaseCaster
      def initialize(api_method)
        @api_method = api_method
      end

      # Coerces the parameters in +params+ (an Enumerable) into the types
      # this method expects
      def cast_expects(params)
        self.class.cast_expects(@api_method, params)
      end

      # Coerces the given +return_value+ into the the type returned by this
      # method
      def cast_returns(return_value)
        self.class.cast_returns(@api_method, return_value)
      end

      class << self
        include ActionWebService::SignatureTypes

        def cast_expects(api_method, params) # :nodoc:
          return [] if api_method.expects.nil?
          SyncEnumerator.new(params, api_method.expects).map{ |r| cast(r[0], r[1]) }
        end

        def cast_returns(api_method, return_value) # :nodoc:
          return nil if api_method.returns.nil?
          cast(return_value, api_method.returns[0])
        end

        def cast(value, signature_type) # :nodoc:
          return value if signature_type.nil? # signature.length != params.length
          unless signature_type.array?
            return value if canonical_type(value.class) == signature_type.type
          end
          if signature_type.array?
            unless value.respond_to?(:entries) && !value.is_a?(String)
              raise CastingError, "Don't know how to cast #{value.class} into #{signature_type.type.inspect}"
            end
            value.entries.map do |entry|
              cast(entry, signature_type.element_type)
            end
          elsif signature_type.structured?
            cast_to_structured_type(value, signature_type)
          elsif !signature_type.custom?
            cast_base_type(value, signature_type)
          end
        end

        def cast_base_type(value, signature_type) # :nodoc:
          case signature_type.type
          when :int
            Integer(value)
          when :string
            value.to_s
          when :bool
            return false if value.nil?
            return value if value == true || value == false
            case value.to_s.downcase
            when '1', 'true', 'y', 'yes'
              true
            when '0', 'false', 'n', 'no'
              false
            else
              raise CastingError, "Don't know how to cast #{value.class} into Boolean"
            end
          when :float
            Float(value)
          when :time
            Time.parse(value.to_s)
          when :date
            Date.parse(value.to_s)
          when :datetime
            DateTime.parse(value.to_s)
          end
        end

        def cast_to_structured_type(value, signature_type) # :nodoc:
          obj = signature_type.type_class.new
          if value.respond_to?(:each_pair)
            klass = signature_type.type_class
            value.each_pair do |name, val|
              type = klass.respond_to?(:member_type) ? klass.member_type(name) : nil
              val = cast(val, type) if type
              obj.send("#{name}=", val)
            end
          else
            raise CastingError, "Don't know how to cast #{value.class} to #{signature_type.type_class}"
          end
          obj
        end
      end
    end
  end
end
