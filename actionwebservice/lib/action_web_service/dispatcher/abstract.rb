require 'benchmark'

module ActionWebService # :nodoc:
  module Dispatcher # :nodoc:
    class DispatcherError < ActionWebService::ActionWebServiceError # :nodoc:
    end

    def self.append_features(base) # :nodoc:
      super
      base.class_inheritable_option(:web_service_dispatching_mode, :direct)
      base.class_inheritable_option(:web_service_exception_reporting, true)
      base.send(:include, ActionWebService::Dispatcher::InstanceMethods)
    end

    module InstanceMethods # :nodoc:
      private
        def invoke_web_service_request(protocol_request)
          invocation = web_service_invocation(protocol_request)
          case web_service_dispatching_mode
          when :direct
            web_service_direct_invoke(invocation)
          when :delegated, :layered
            web_service_delegated_invoke(invocation)
          end
        end
      
        def web_service_direct_invoke(invocation)
          @method_params = invocation.method_ordered_params
          arity = method(invocation.api_method.name).arity rescue 0
          if arity < 0 || arity > 0
            return_value = self.__send__(invocation.api_method.name, *@method_params)
          else
            return_value = self.__send__(invocation.api_method.name)
          end
          web_service_create_response(invocation.protocol, invocation.api, invocation.api_method, return_value)
        end

        def web_service_delegated_invoke(invocation)
          cancellation_reason = nil
          return_value = invocation.service.perform_invocation(invocation.api_method.name, invocation.method_ordered_params) do |x|
            cancellation_reason = x
          end
          if cancellation_reason
            raise(DispatcherError, "request canceled: #{cancellation_reason}")
          end
          web_service_create_response(invocation.protocol, invocation.api, invocation.api_method, return_value)
        end

        def web_service_invocation(request)
          public_method_name = request.method_name
          invocation = Invocation.new
          invocation.protocol = request.protocol
          invocation.service_name = request.service_name
          if web_service_dispatching_mode == :layered
            if request.method_name =~ /^([^\.]+)\.(.*)$/
              public_method_name = $2
              invocation.service_name = $1
            end
          end
          case web_service_dispatching_mode
          when :direct
            invocation.api = self.class.web_service_api
            invocation.service = self
          when :delegated, :layered
            invocation.service = web_service_object(invocation.service_name)
            invocation.api = invocation.service.class.web_service_api
          end
          invocation.protocol.register_api(invocation.api)
          request.api = invocation.api
          if invocation.api.has_public_api_method?(public_method_name)
            invocation.api_method = invocation.api.public_api_method_instance(public_method_name)
          else
            if invocation.api.default_api_method.nil?
              raise(DispatcherError, "no such method '#{public_method_name}' on API #{invocation.api}")
            else
              invocation.api_method = invocation.api.default_api_method_instance
            end
          end
          if invocation.service.nil?
            raise(DispatcherError, "no service available for service name #{invocation.service_name}")
          end
          unless invocation.service.respond_to?(invocation.api_method.name)
            raise(DispatcherError, "no such method '#{public_method_name}' on API #{invocation.api} (#{invocation.api_method.name})")
          end
          request.api_method = invocation.api_method
          begin
            invocation.method_ordered_params = invocation.api_method.cast_expects(request.method_params.dup)
          rescue
            logger.warn "Casting of method parameters failed" unless logger.nil?
            invocation.method_ordered_params = request.method_params
          end
          request.method_params = invocation.method_ordered_params
          invocation.method_named_params = {}
          invocation.api_method.param_names.inject(0) do |m, n|
            invocation.method_named_params[n] = invocation.method_ordered_params[m]
            m + 1
          end
          invocation
        end

        def web_service_create_response(protocol, api, api_method, return_value)
          if api.has_api_method?(api_method.name)
            return_type = api_method.returns ? api_method.returns[0] : nil
            return_value = api_method.cast_returns(return_value)
          else
            return_type = ActionWebService::SignatureTypes.canonical_signature_entry(return_value.class, 0)
          end
          protocol.encode_response(api_method.public_name + 'Response', return_value, return_type)
        end

        class Invocation # :nodoc:
          attr_accessor :protocol
          attr_accessor :service_name
          attr_accessor :api
          attr_accessor :api_method
          attr_accessor :method_ordered_params
          attr_accessor :method_named_params
          attr_accessor :service
        end
    end
  end
end
