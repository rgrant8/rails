require 'benchmark'
require 'builder/xmlmarkup'

module ActionWebService # :nodoc:
  module Dispatcher # :nodoc:
    module ActionController # :nodoc:
      def self.append_features(base) # :nodoc:
        super
        base.class_eval do
          class << self
            alias_method :inherited_without_action_controller, :inherited
          end
          alias_method :web_service_direct_invoke_without_controller, :web_service_direct_invoke
        end
        base.add_web_service_api_callback do |klass, api|
          if klass.web_service_dispatching_mode == :direct
            klass.class_eval 'def api; dispatch_web_service_request; end'
          end
        end
        base.add_web_service_definition_callback do |klass, name, info|
          if klass.web_service_dispatching_mode == :delegated
            klass.class_eval "def #{name}; dispatch_web_service_request; end"
          elsif klass.web_service_dispatching_mode == :layered
            klass.class_eval 'def api; dispatch_web_service_request; end'
          end
        end
        base.extend(ClassMethods)
        base.send(:include, ActionWebService::Dispatcher::ActionController::InstanceMethods)
      end

      module ClassMethods # :nodoc:
        def inherited(child)
          inherited_without_action_controller(child)
          child.send(:include, ActionWebService::Dispatcher::ActionController::WsdlAction)
        end
      end

      module InstanceMethods # :nodoc:
        private
          def dispatch_web_service_request
            exception = nil
            begin
              request = discover_web_service_request(@request)
            rescue Exception => e
              exception = e
            end
            if request
              response = nil
              exception = nil
              bm = Benchmark.measure do
                begin
                  response = invoke_web_service_request(request)
                rescue Exception => e
                  exception = e
                end
              end
              log_request(request, @request.raw_post)
              if exception
                log_error(exception) unless logger.nil?
                send_web_service_error_response(request, exception)
              else
                send_web_service_response(response, bm.real)
              end
            else
              exception ||= DispatcherError.new("Malformed SOAP or XML-RPC protocol message")
              log_error(exception) unless logger.nil?
              send_web_service_error_response(request, exception)
            end
          rescue Exception => e
            log_error(e) unless logger.nil?
            send_web_service_error_response(request, e)
          end

          def send_web_service_response(response, elapsed=nil)
            log_response(response, elapsed)
            options = { :type => response.content_type, :disposition => 'inline' }
            send_data(response.body, options)
          end

          def send_web_service_error_response(request, exception)
            if request
              unless self.class.web_service_exception_reporting
                exception = DispatcherError.new("Internal server error (exception raised)")
              end
              api_method = request.api_method
              public_method_name = api_method ? api_method.public_name : request.method_name
              return_type = ActionWebService::SignatureTypes.canonical_signature_entry(Exception, 0)
              response = request.protocol.encode_response(public_method_name + 'Response', exception, return_type)
              send_web_service_response(response)
            else
              if self.class.web_service_exception_reporting
                message = exception.message
                backtrace = "\nBacktrace:\n#{exception.backtrace.join("\n")}"
              else
                message = "Exception raised"
                backtrace = ""
              end
              render_text("Internal protocol error: #{message}#{backtrace}", "500 #{message}")
            end
          end

          def web_service_direct_invoke(invocation)
            @params ||= {}
            invocation.method_named_params.each do |name, value|
              @params[name] = value
            end
            @session ||= {}
            @assigns ||= {}
            @params['action'] = invocation.api_method.name.to_s
            if before_action == false
              raise(DispatcherError, "Method filtered")
            end
            return_value = web_service_direct_invoke_without_controller(invocation)
            after_action
            return_value
          end

          def log_request(request, body)
            unless logger.nil?
              name = request.method_name
              api_method = request.api_method
              params = request.method_params
              if api_method && api_method.expects
                i = 0
                params = api_method.expects.map{ |type| param = "#{type.name}=>#{params[i].inspect}"; i+= 1; param }
              else
                params = params.map{ |param| param.inspect }
              end
              service = request.service_name
              logger.debug("\nWeb Service Request: #{name}(#{params.join(", ")}) Entrypoint: #{service}")
              logger.debug(indent(body))
            end
          end

          def log_response(response, elapsed=nil)
            unless logger.nil?
              elapsed = (elapsed ? " (%f):" % elapsed : ":")
              logger.debug("\nWeb Service Response" + elapsed + " => #{response.return_value.inspect}")
              logger.debug(indent(response.body))
            end
          end

          def indent(body)
            body.split(/\n/).map{|x| "  #{x}"}.join("\n")
          end
      end

      module WsdlAction # :nodoc:
        XsdNs             = 'http://www.w3.org/2001/XMLSchema'
        WsdlNs            = 'http://schemas.xmlsoap.org/wsdl/'
        SoapNs            = 'http://schemas.xmlsoap.org/wsdl/soap/'
        SoapEncodingNs    = 'http://schemas.xmlsoap.org/soap/encoding/'
        SoapHttpTransport = 'http://schemas.xmlsoap.org/soap/http'

        def wsdl
          case @request.method
          when :get
            begin
              options = { :type => 'text/xml', :disposition => 'inline' }
              send_data(to_wsdl, options)
            rescue Exception => e
              log_error(e) unless logger.nil?
            end
          when :post
            render_text('POST not supported', '500 POST not supported')
          end
        end

        private
          def base_uri
            host = @request ? (@request.env['HTTP_HOST'] || @request.env['SERVER_NAME']) : 'localhost'
            'http://%s/%s/' % [host, controller_name]
          end

          def to_wsdl
            xml = ''
            dispatching_mode = web_service_dispatching_mode
            global_service_name = wsdl_service_name
            namespace = 'urn:ActionWebService'
            soap_action_base = "/#{controller_name}"

            marshaler = ActionWebService::Protocol::Soap::SoapMarshaler.new(namespace)
            apis = {}
            case dispatching_mode
            when :direct
              api = self.class.web_service_api
              web_service_name = controller_class_name.sub(/Controller$/, '').underscore
              apis[web_service_name] = [api, register_api(api, marshaler)]
            when :delegated
              self.class.web_services.each do |web_service_name, info|
                service = web_service_object(web_service_name)
                api = service.class.web_service_api
                apis[web_service_name] = [api, register_api(api, marshaler)]
              end
            end
            custom_types = []
            apis.values.each do |api, bindings|
              bindings.each do |b|
                custom_types << b
              end
            end

            xm = Builder::XmlMarkup.new(:target => xml, :indent => 2)
            xm.instruct!
            xm.definitions('name'            => wsdl_service_name,
                           'targetNamespace' => namespace,
                           'xmlns:typens'    => namespace,
                           'xmlns:xsd'       => XsdNs,
                           'xmlns:soap'      => SoapNs,
                           'xmlns:soapenc'   => SoapEncodingNs,
                           'xmlns:wsdl'      => WsdlNs,
                           'xmlns'           => WsdlNs) do
              # Generate XSD
              if custom_types.size > 0
                xm.types do
                  xm.xsd(:schema, 'xmlns' => XsdNs, 'targetNamespace' => namespace) do
                    custom_types.each do |binding|
                      case
                      when binding.type.array?
                        xm.xsd(:complexType, 'name' => binding.type_name) do
                          xm.xsd(:complexContent) do
                            xm.xsd(:restriction, 'base' => 'soapenc:Array') do
                              xm.xsd(:attribute, 'ref' => 'soapenc:arrayType',
                                                 'wsdl:arrayType' => binding.element_binding.qualified_type_name('typens') + '[]')
                            end
                          end
                        end
                      when binding.type.structured?
                        xm.xsd(:complexType, 'name' => binding.type_name) do
                          xm.xsd(:all) do
                            binding.type.each_member do |name, type|
                              b = marshaler.register_type(type)
                              xm.xsd(:element, 'name' => name, 'type' => b.qualified_type_name('typens'))
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end

              # APIs
              apis.each do |api_name, values|
                api = values[0]
                api.api_methods.each do |name, method|
                  gen = lambda do |msg_name, direction|
                    xm.message('name' => msg_name) do
                      sym = nil
                      if direction == :out
                        returns = method.returns
                        if returns
                          binding = marshaler.register_type(returns[0])
                          xm.part('name' => 'return', 'type' => binding.qualified_type_name('typens'))
                        end
                      else
                        expects = method.expects
                        i = 1
                        expects.each do |type|
                          binding = marshaler.register_type(type)
                          xm.part('name' => type.name, 'type' => binding.qualified_type_name('typens'))
                          i += 1
                        end if expects
                      end
                    end
                  end
                  public_name = method.public_name
                  gen.call(public_name, :in)
                  gen.call("#{public_name}Response", :out)
                end

                # Port
                port_name = port_name_for(global_service_name, api_name)
                xm.portType('name' => port_name) do
                  api.api_methods.each do |name, method|
                    xm.operation('name' => method.public_name) do
                      xm.input('message' => "typens:#{method.public_name}")
                      xm.output('message' => "typens:#{method.public_name}Response")
                    end
                  end
                end

                # Bind it
                binding_name = binding_name_for(global_service_name, api_name)
                xm.binding('name' => binding_name, 'type' => "typens:#{port_name}") do
                  xm.soap(:binding, 'style' => 'rpc', 'transport' => SoapHttpTransport)
                  api.api_methods.each do |name, method|
                    xm.operation('name' => method.public_name) do
                      case web_service_dispatching_mode
                      when :direct, :layered
                        soap_action = soap_action_base + "/api/" + method.public_name
                      when :delegated
                        soap_action = soap_action_base \
                                    + "/" + api_name.to_s \
                                    + "/" + method.public_name
                      end
                      xm.soap(:operation, 'soapAction' => soap_action)
                      xm.input do
                        xm.soap(:body,
                                'use'           => 'encoded',
                                'namespace'     => namespace,
                                'encodingStyle' => SoapEncodingNs)
                      end
                      xm.output do
                        xm.soap(:body,
                                'use'           => 'encoded',
                                'namespace'     => namespace,
                                'encodingStyle' => SoapEncodingNs)
                      end
                    end
                  end
                end
              end

              # Define it
              xm.service('name' => "#{global_service_name}Service") do
                apis.each do |api_name, values|
                  port_name = port_name_for(global_service_name, api_name)
                  binding_name = binding_name_for(global_service_name,  api_name)
                  case web_service_dispatching_mode
                  when :direct
                    binding_target = 'api'
                  when :delegated
                    binding_target = api_name.to_s
                  end
                  xm.port('name' => port_name, 'binding' => "typens:#{binding_name}") do
                    xm.soap(:address, 'location' => "#{base_uri}#{binding_target}")
                  end
                end
              end
            end
          end

          def port_name_for(global_service, service)
            "#{global_service}#{service.to_s.camelize}Port"
          end

          def binding_name_for(global_service, service)
            "#{global_service}#{service.to_s.camelize}Binding"
          end

          def register_api(api, marshaler)
            bindings = {}
            traverse_custom_types(api, marshaler) do |binding|
              bindings[binding] = nil unless bindings.has_key?(binding)
              element_binding = binding.element_binding
              bindings[binding.element_binding] = nil if element_binding && !bindings.has_key?(element_binding)
            end
            bindings.keys
          end

          def traverse_custom_types(api, marshaler, &block)
            api.api_methods.each do |name, method|
              expects, returns = method.expects, method.returns
              expects.each{ |type| traverse_type(marshaler, type, &block) if type.custom? } if expects
              returns.each{ |type| traverse_type(marshaler, type, &block) if type.custom? } if returns
            end
          end

          def traverse_type(marshaler, type, &block)
            yield marshaler.register_type(type)
            if type.array?
              yield marshaler.register_type(type.element_type)
              type = type.element_type
            end
            type.each_member{ |name, type| traverse_type(marshaler, type, &block) } if type.structured?
          end
       end
    end
  end
end
