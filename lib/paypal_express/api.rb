module Killbill #:nodoc:
  module PaypalExpress #:nodoc:
    class PaymentPlugin < ::Killbill::Plugin::ActiveMerchant::PaymentPlugin

      THREE_HOURS_AGO = (3*3600)

      def initialize
        gateway_builder = Proc.new do |config|
          ::ActiveMerchant::Billing::PaypalExpressGateway.application_id = config[:button_source] || 'killbill_SP'
          ::ActiveMerchant::Billing::PaypalExpressGateway.new :signature => config[:signature],
                                                              :login     => config[:login],
                                                              :password  => config[:password]
        end

        super(gateway_builder,
              :paypal_express,
              ::Killbill::PaypalExpress::PaypalExpressPaymentMethod,
              ::Killbill::PaypalExpress::PaypalExpressTransaction,
              ::Killbill::PaypalExpress::PaypalExpressResponse)

        @ip = ::Killbill::Plugin::ActiveMerchant::Utils.ip
        @private_api = ::Killbill::PaypalExpress::PrivatePaymentPlugin.new
      end

      def on_event(event)
        # Require to deal with per tenant configuration invalidation
        super(event)
        #
        # Custom event logic could be added below...
        #
      end

      def authorize_payment(kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, amount, currency, properties, context)
        authorize_or_purchase_payment kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, amount, currency, properties, context, true
      end

      def capture_payment(kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, amount, currency, properties, context)
        options = {}
        # Pass extra parameters for the gateway here
        add_optional_params_for_capture options, properties_to_hash(properties)
        # NotComplete to allow for partial captures.
        # If Complete, any remaining amount of the original authorized transaction is automatically voided and all remaining open authorizations are voided.
        options[:complete_type] ||= 'NotComplete'
        super(kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, amount, currency, hash_to_properties(options), context)
      end

      def purchase_payment(kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, amount, currency, properties, context)
        # by default, this call will purchase a payment
        authorize_or_purchase_payment kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, amount, currency, properties, context
      end

      def void_payment(kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, properties, context)
        options = {}
        # Pass extra parameters for the gateway here
        add_optional_params_for_void options, properties_to_hash(properties)
        options[:linked_transaction_type] ||= :authorize
        super(kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, hash_to_properties(options), context)
      end

      def credit_payment(kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, amount, currency, properties, context)
        # Pass extra parameters for the gateway here
        options = {}

        properties = merge_properties(properties, options)
        super(kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, amount, currency, properties, context)
      end

      def refund_payment(kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, amount, currency, properties, context)
        options = {}
        # Pass extra parameters for the gateway here
        add_optional_params_for_refund options, properties_to_hash(properties)

        # Cannot refund based on authorizations (default behavior)
        linked_transaction_type = @transaction_model.purchases_from_kb_payment_id(kb_payment_id, context.tenant_id).size > 0 ? :PURCHASE : :CAPTURE
        options[:linked_transaction_type] ||= linked_transaction_type
        super(kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, amount, currency, hash_to_properties(options), context)
      end

      def get_payment_info(kb_account_id, kb_payment_id, properties, context)
        t_info_plugins = super(kb_account_id, kb_payment_id, properties, context)
        # Should never happen...
        return [] if t_info_plugins.nil?

        # Completed purchases/authorizations will have two rows in the responses table (one for api_call 'build_form_descriptor', one for api_call 'purchase/authorize')
        # Other transaction types don't support the :PENDING state
        target_transaction_types = [:PURCHASE, :AUTHORIZE]
        only_pending_transaction = t_info_plugins.find { |t_info_plugin| target_transaction_types.include?(t_info_plugin.transaction_type) && t_info_plugin.status != :PENDING }.nil?
        t_info_plugins_without_pending = t_info_plugins.reject { |t_info_plugin| target_transaction_types.include?(t_info_plugin.transaction_type) && t_info_plugin.status == :PENDING }

        # If its token has expired, cancel the payment and update the response row.
        if only_pending_transaction
          return t_info_plugins unless token_expired(t_info_plugins.last)
          begin
            cancel_pending_transaction(t_info_plugins.last).nil?
            logger.info("Cancel pending kb_payment_id='#{t_info_plugins.last.kb_payment_id}', kb_payment_transaction_id='#{t_info_plugins.last.kb_transaction_payment_id}'")
            super(kb_account_id, kb_payment_id, properties, context)
          rescue => e
            logger.warn("Unexpected exception while canceling pending kb_payment_id='#{t_info_plugins.last.kb_payment_id}', kb_payment_transaction_id='#{t_info_plugins.last.kb_transaction_payment_id}': #{e.message}\n#{e.backtrace.join("\n")}")
            t_info_plugins
          end
        else
          t_info_plugins_without_pending
        end
      end

      def search_payments(search_key, offset, limit, properties, context)
        # Pass extra parameters for the gateway here
        options = {}

        properties = merge_properties(properties, options)
        super(search_key, offset, limit, properties, context)
      end

      def add_payment_method(kb_account_id, kb_payment_method_id, payment_method_props, set_default, properties, context)
        all_properties = (payment_method_props.nil? || payment_method_props.properties.nil? ? [] : payment_method_props.properties) + properties
        token = find_value_from_properties(all_properties, 'token')

        if token.nil?
          # HPP flow
          options = {
              :skip_gw => true
          }
        else
          # Go to Paypal to get the Payer id (GetExpressCheckoutDetails call)
          payment_processor_account_id = find_value_from_properties(properties, :payment_processor_account_id)
          payment_processor_account_id ||= find_payment_processor_id_from_initial_call(kb_account_id, context.tenant_id, token)
          payer_id = find_payer_id(token, kb_account_id, context.tenant_id, payment_processor_account_id)
          options  = {
              :paypal_express_token         => token,
              :paypal_express_payer_id      => payer_id,
              :payment_processor_account_id => payment_processor_account_id
          }
        end

        properties = merge_properties(properties, options)
        super(kb_account_id, kb_payment_method_id, payment_method_props, set_default, properties, context)
      end

      def delete_payment_method(kb_account_id, kb_payment_method_id, properties, context)
        # Pass extra parameters for the gateway here
        options = {}

        properties = merge_properties(properties, options)
        super(kb_account_id, kb_payment_method_id, properties, context)
      end

      def get_payment_method_detail(kb_account_id, kb_payment_method_id, properties, context)
        # Pass extra parameters for the gateway here
        options = {}

        properties = merge_properties(properties, options)
        super(kb_account_id, kb_payment_method_id, properties, context)
      end

      def set_default_payment_method(kb_account_id, kb_payment_method_id, properties, context)
        # TODO
      end

      def get_payment_methods(kb_account_id, refresh_from_gateway, properties, context)
        # Pass extra parameters for the gateway here
        options = {}

        properties = merge_properties(properties, options)
        super(kb_account_id, refresh_from_gateway, properties, context)
      end

      def search_payment_methods(search_key, offset, limit, properties, context)
        # Pass extra parameters for the gateway here
        options = {}

        properties = merge_properties(properties, options)
        super(search_key, offset, limit, properties, context)
      end

      def reset_payment_methods(kb_account_id, payment_methods, properties, context)
        super
      end

      def build_form_descriptor(kb_account_id, descriptor_fields, properties, context)
        jcontext = @kb_apis.create_context(context.tenant_id)

        all_properties = descriptor_fields + properties
        options = properties_to_hash(all_properties)

        kb_account = ::Killbill::Plugin::ActiveMerchant::Utils::LazyEvaluator.new { @kb_apis.account_user_api.get_account_by_id(kb_account_id, jcontext) }
        amount = (options[:amount] || '0').to_f
        currency = options[:currency] || kb_account.currency

        response = initiate_express_checkout(kb_account_id, amount, currency, all_properties, context)

        descriptor = super(kb_account_id, descriptor_fields, properties, context)
        descriptor.form_url = @private_api.to_express_checkout_url(response, context.tenant_id, options)
        descriptor.form_method = 'GET'
        descriptor.properties << build_property('token', response.token)

        # By default, pending payments are not created for HPP
        create_pending_payment = ::Killbill::Plugin::ActiveMerchant::Utils.normalized(options, :create_pending_payment)
        if create_pending_payment
          payment_processor_account_id = ::Killbill::Plugin::ActiveMerchant::Utils.normalized(options, :payment_processor_account_id)
          token_expiration_period = ::Killbill::Plugin::ActiveMerchant::Utils.normalized(options, :token_expiration_period)
          custom_props = hash_to_properties(:from_hpp                     => true,
                                            :token                        => response.token,
                                            :payment_processor_account_id => payment_processor_account_id,
                                            :token_expiration_period      => token_expiration_period)
          payment_external_key = ::Killbill::Plugin::ActiveMerchant::Utils.normalized(options, :payment_external_key)
          transaction_external_key = ::Killbill::Plugin::ActiveMerchant::Utils.normalized(options, :transaction_external_key)

          kb_payment_method = (@kb_apis.payment_api.get_account_payment_methods(kb_account_id, false, [], jcontext).find { |pm| pm.plugin_name == 'killbill-paypal-express' })

          auth_mode = ::Killbill::Plugin::ActiveMerchant::Utils.normalized(options, :auth_mode)
          # By default, the SALE mode is used.
          if auth_mode
            payment = @kb_apis.payment_api
                          .create_authorization(kb_account.send(:__instance_object__),
                                                kb_payment_method.id,
                                                nil,
                                                amount,
                                                currency,
                                                payment_external_key,
                                                transaction_external_key,
                                                custom_props,
                                                jcontext)
          else
            payment = @kb_apis.payment_api
                          .create_purchase(kb_account.send(:__instance_object__),
                                           kb_payment_method.id,
                                           nil,
                                           amount,
                                           currency,
                                           payment_external_key,
                                           transaction_external_key,
                                           custom_props,
                                           jcontext)
          end

          descriptor.properties << build_property('kb_payment_id', payment.id)
          descriptor.properties << build_property('kb_payment_external_key', payment.external_key)
          descriptor.properties << build_property('kb_transaction_id', payment.transactions.first.id)
          descriptor.properties << build_property('kb_transaction_external_key', payment.transactions.first.external_key)
        end

        descriptor
      end

      def process_notification(notification, properties, context)
        # Pass extra parameters for the gateway here
        options    = {}
        properties = merge_properties(properties, options)

        super(notification, properties, context) do |gw_notification, service|
          # Retrieve the payment
          # gw_notification.kb_payment_id =
          #
          # Set the response body
          # gw_notification.entity =
        end
      end

      def to_express_checkout_url(response, kb_tenant_id, options = {})
        payment_processor_account_id = options[:payment_processor_account_id] || :default
        gateway                      = lookup_gateway(payment_processor_account_id, kb_tenant_id)
        gateway.redirect_url_for(response.token)
      end

      protected

      def get_active_merchant_module
        ::OffsitePayments.integration(:paypal)
      end

      private

      def find_last_token(kb_account_id, kb_tenant_id)
        @response_model.last_token(kb_account_id, kb_tenant_id)
      end

      def find_payer_id(token, kb_account_id, kb_tenant_id, payment_processor_account_id)
        raise 'Could not find the payer_id: the token is missing' if token.blank?

        # Go to Paypal to get the Payer id (GetExpressCheckoutDetails call)
        payment_processor_account_id = payment_processor_account_id || :default
        gateway                      = lookup_gateway(payment_processor_account_id, kb_tenant_id)
        gw_response                  = gateway.details_for(token)
        response, transaction        = save_response_and_transaction(gw_response, :details_for, kb_account_id, kb_tenant_id, payment_processor_account_id)

        raise response.message unless response.success?
        raise "Could not find the payer_id for token #{token}" if response.payer_id.blank?

        response.payer_id
      end

      def is_token_present(payment_method)
        payment_method.paypal_express_token.presence
      end

      def add_required_options_for_baid(kb_payment_transaction_id, payment_method, options)
        options[:payer_id]     ||= payment_method.paypal_express_payer_id.presence
        options[:token]        ||= payment_method.paypal_express_token.presence

        # There is one more required option: description, but that will be taken care of in the plugin framework
        options[:reference_id] ||= payment_method.token.presence # baid
        options[:payment_type] ||= 'Any'

        # Note that although this invoice_id is required in ActiveMerchant DoReferenceTransaction call
        # but when ActiveMerchant actually uses it, the order_id takes precedence over invoice_id.
        # Since order_id is always set in the plugin framework, setting invoice_id here is only to satisfy ActiveMerchant requirement
        options[:invoice_id]   ||= kb_payment_transaction_id
        options[:ip]           ||= @ip
      end

      def initiate_express_checkout(kb_account_id, amount, currency, properties, context)
        properties_hash = properties_to_hash(properties)

        with_baid = ::Killbill::Plugin::ActiveMerchant::Utils.normalized(properties_hash, :with_baid)

        options = {}
        options[:return_url] = ::Killbill::Plugin::ActiveMerchant::Utils.normalized(properties_hash, :return_url)
        options[:cancel_return_url] = ::Killbill::Plugin::ActiveMerchant::Utils.normalized(properties_hash, :cancel_return_url)
        options[:payment_processor_account_id] = ::Killbill::Plugin::ActiveMerchant::Utils.normalized(properties_hash, :payment_processor_account_id)

        add_optional_params_for_initial_call options, properties_hash, currency

        amount_in_cents = amount.nil? ? nil : to_cents(amount, currency)
        response = @private_api.initiate_express_checkout(kb_account_id,
                                                          context.tenant_id.to_s,
                                                          amount_in_cents,
                                                          currency,
                                                          with_baid,
                                                          options)
        unless response.success?
          raise "Unable to initiate paypal express checkout: #{response.message}"
        end

        response
      end

      def authorize_or_purchase_payment(kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, amount, currency, properties, context, is_authorize = false)
        properties_hash = properties_to_hash properties
        payment_processor_account_id = ::Killbill::Plugin::ActiveMerchant::Utils.normalized(properties_hash, :payment_processor_account_id)
        transaction_type = is_authorize ? :AUTHORIZE : :PURCHASE
        api_call_type = is_authorize ? :authorize : :purchase

        # Callback from the plugin itself (HPP flow)
        if ::Killbill::Plugin::ActiveMerchant::Utils.normalized(properties_hash, :from_hpp)
          token = ::Killbill::Plugin::ActiveMerchant::Utils.normalized(properties_hash, :token)
          message = {:payment_plugin_status => :PENDING,
                     :token_expiration_period => ::Killbill::Plugin::ActiveMerchant::Utils.normalized(properties_hash, :token_expiration_period) || THREE_HOURS_AGO.to_s}
          response = @response_model.create(:api_call                     => :build_form_descriptor,
                                            :kb_account_id                => kb_account_id,
                                            :kb_payment_id                => kb_payment_id,
                                            :kb_payment_transaction_id    => kb_payment_transaction_id,
                                            :transaction_type             => transaction_type,
                                            :authorization                => token,
                                            :payment_processor_account_id => payment_processor_account_id,
                                            :kb_tenant_id                 => context.tenant_id,
                                            :success                      => true,
                                            :created_at                   => Time.now.utc,
                                            :updated_at                   => Time.now.utc,
                                            :message                      => message.to_json)
          transaction          = response.to_transaction_info_plugin(nil)
          transaction.amount   = amount
          transaction.currency = currency
          transaction
        else
          payment_method = @payment_method_model.from_kb_payment_method_id(kb_payment_method_id, context.tenant_id)
          options = {}
          # We have a baid on file
          if is_token_present payment_method
            # Add optional parameters to baid auth or purchase call
            add_optional_params_for_baid_auth_purchase options, properties_hash, currency
            # Add require params
            add_required_options_for_baid kb_payment_transaction_id, payment_method, options
            if is_authorize
              gateway_call_proc = Proc.new do |gateway, linked_transaction, payment_source, amount_in_cents, options|
                # Can't use default implementation: the purchase signature is for one-off payments only
                gateway.authorize_reference_transaction(amount_in_cents, options)
              end
            else
              gateway_call_proc = Proc.new do |gateway, linked_transaction, payment_source, amount_in_cents, options|
                # Can't use default implementation: the purchase signature is for one-off payments only
                gateway.reference_transaction(amount_in_cents, options)
              end
            end
          else
            # Add optional parameters to one-time auth or purchase call
            add_optional_params_for_auth_purchase options, properties_hash, currency
            # One-off payment
            options[:token] = ::Killbill::Plugin::ActiveMerchant::Utils.normalized(properties_hash, :token) || find_last_token(kb_account_id, context.tenant_id)
            if is_authorize
              gateway_call_proc  = Proc.new do |gateway, linked_transaction, payment_source, amount_in_cents, options|
                gateway.authorize(amount_in_cents, options)
              end
            else
              gateway_call_proc  = Proc.new do |gateway, linked_transaction, payment_source, amount_in_cents, options|
                gateway.purchase(amount_in_cents, options)
              end
            end
          end

          # Find the payment_processor_id if not provided
          payment_processor_account_id ||= find_payment_processor_id_from_initial_call(kb_account_id, context.tenant_id, options[:token])
          options[:payment_processor_account_id] = payment_processor_account_id

          # Populate the Payer id if missing
          options[:payer_id] = ::Killbill::Plugin::ActiveMerchant::Utils.normalized(properties_hash, :payer_id)
          begin
            options[:payer_id] ||= find_payer_id(options[:token],
                                                 kb_account_id,
                                                 context.tenant_id,
                                                 payment_processor_account_id)
          rescue => e
            # Maybe invalid token?
            response = @response_model.create(:api_call                     => api_call_type,
                                              :kb_account_id                => kb_account_id,
                                              :kb_payment_id                => kb_payment_id,
                                              :kb_payment_transaction_id    => kb_payment_transaction_id,
                                              :transaction_type             => transaction_type,
                                              :authorization                => nil,
                                              :payment_processor_account_id => payment_processor_account_id,
                                              :kb_tenant_id                 => context.tenant_id,
                                              :success                      => false,
                                              :created_at                   => Time.now.utc,
                                              :updated_at                   => Time.now.utc,
                                              :message                      => { :payment_plugin_status => :CANCELED, :exception_class => e.class.to_s, :exception_message => e.message }.to_json)
            return response.to_transaction_info_plugin(nil)
          end

          dispatch_to_gateways(api_call_type, kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, amount, currency, hash_to_properties(options), context, gateway_call_proc, nil, {:payer_id => options[:payer_id]})
        end
      end

      def find_payment_processor_id_from_initial_call(kb_account_id, kb_tenant_id, token)
        @response_model.initial_payment_account_processor_id kb_account_id, kb_tenant_id, token
      end

      def token_expired(transaction_plugin_info)
        paypal_response_id = find_value_from_properties(transaction_plugin_info.properties, 'paypalExpressResponseId')
        response = PaypalExpressResponse.find_by(:id => paypal_response_id)
        begin
          message_details = JSON.parse response.message
          expiration_period = (message_details['token_expiration_period'] || THREE_HOURS_AGO).to_i
        rescue
          expiration_period = THREE_HOURS_AGO.to_i
        end
        now = Time.parse(@clock.get_clock.get_utc_now.to_s)
        (now - transaction_plugin_info.created_date) >= expiration_period
      end

      def cancel_pending_transaction(transaction_plugin_info)
        @response_model.cancel_pending_payment transaction_plugin_info
      end

      def add_optional_params_for_refund(options, properties_hash)
        normalize_array [:refund_type, :note], options, properties_hash
      end

      def add_optional_params_for_void(options, properties_hash)
        normalize_array [:description], options, properties_hash
      end

      def add_optional_params_for_baid_auth_purchase(options, properties_hash, currency)
        normalize_array [:ip_address, :req_confirm_shipping, :merchant_session_id, :return_f_m_f_details, :soft_descriptor], options, properties_hash
        add_payment_details options, properties_hash, currency
      end

      def add_optional_params_for_auth_purchase(options, properties_hash, currency)
        add_payment_details options, properties_hash, currency
      end

      def add_optional_params_for_capture(options, properties_hash)
        # In active_merchant, the order_id is used as the invoice_id for DoCapture call
        normalize_array [:complete_type, :order_id, :description], options, properties_hash
      end

      def add_optional_params_for_initial_call(options, properties_hash, currency)
        normalize_array [:max_amount,
                         :req_billing_address,
                         :no_shipping,
                         :address_override,
                         :locale,
                         :brand_name,
                         :page_style,
                         :logo_image,
                         :header_image,
                         :header_border_color,
                         :header_background_color,
                         :background_color,
                         :allow_guest_checkout,
                         :landing_page,
                         :email,
                         :allow_note,
                         :callback_url,
                         :callback_timeout,
                         :allow_buyer_optin,
                         :callback_version,
                         :shipping_address,
                         :total_type,
                         :funding_sources,
                         :shipping_options], options, properties_hash

        add_payment_details options, properties_hash, currency

        options[:max_amount] = to_cents((options[:max_amount] || '0').to_f, currency) unless options[:max_amount].nil?
        # Parse JSON based options including funding_source, items, shipping_options, address and shipping_address
        parse_json_options [:funding_sources, :shipping_options], options
        # Filter the options that has second level options including funding_source, shipping_options
        options[:funding_sources] = filter_hash_options options[:funding_sources], [:source] unless options[:funding_sources].nil?
        options[:shipping_options] = filter_array_options options[:shipping_options], [:default, :amount, :name], [:amount], currency unless options[:shipping_options].nil?
      end

      def add_payment_details(options, properties_hash, currency)
        normalize_array [:subtotal,
                         :shipping,
                         :handling,
                         :tax,
                         :insurance_total,
                         :shipping_discount,
                         :insurance_option_offered,
                         :description,
                         :custom,
                         :order_id,
                         :notify_url,
                         :shipping_address,
                         :items,
                         :express_request
                        ], options, properties_hash

        # Special consideration for amount related options
        [:subtotal,
         :shipping,
         :handling,
         :tax,
         :insurance_total,
         :shipping_discount].each do |sym|
          if options[sym]
            options[sym] = to_cents((options[sym] || '0').to_f, currency)
          end
        end
        normalize_array [:note_text, :payment_action, :transaction_id, :allowed_payment_method_type, :payment_request_id], options, properties_hash if options[:express_request]
        parse_json_options [:shipping_address, :items], options
        options[:shipping_address] = filter_hash_options options[:shipping_address], [:name, :address1, :address2, :city, :state, :country, :phone, :zip] unless options[:shipping_address].nil?
        options[:items] = filter_array_options options[:items], [:name, :number, :quantity, :amount, :description, :url, :category], [:amount], currency unless options[:items].nil?
      end

      def parse_json_options(keys, options)
        keys.each do |sym|
          begin
            options[sym] = JSON.parse options[sym] unless options[sym].nil?
          rescue => e
            logger.warn("Unexpected exception while parsing JSON option #{sym}: #{e.message}\n#{e.backtrace.join("\n")}")
            options[sym] = nil
          end
        end
      end

      def normalize_array(keys, options, properties_hash)
        return if options.nil? || !options.is_a?(Hash) || keys.nil? || !keys.is_a?(Array) || properties_hash.nil? || !properties_hash.is_a?(Hash)
        keys.each do |sym|
          option_val = ::Killbill::Plugin::ActiveMerchant::Utils.normalized(properties_hash, sym)
          options[sym] = option_val unless option_val.nil?
        end
      end

      def filter_array_options(option, allowed_keys, amount_keys = [], currency = nil)
        return nil if option.nil? || !option.is_a?(Array)
        sub_options = []
        option.each do |item|
          next unless item.is_a?(Hash)
          sub_hash = filter_hash_options item, allowed_keys, amount_keys, currency
          sub_options << sub_hash unless sub_hash.nil?
        end
        sub_options.empty? ? nil : sub_options
      end

      def filter_hash_options(option, allowed_keys, amount_keys = [], currency = nil)
        return nil if option.nil? || !option.is_a?(Hash)
        # Because option is parsed from JSON, we need to convert to symbol keys to be used in ::Killbill::Plugin::ActiveMerchant::Utils.normalized
        option.symbolize_keys!
        sub_hash = {}
        allowed_keys.each do |key|
          sub_hash[key] = ::Killbill::Plugin::ActiveMerchant::Utils.normalized(option, key)
          sub_hash[key] = to_cents((sub_hash[key] || '0').to_f, currency) if amount_keys.include?(key) && !sub_hash[key].nil?
        end
        sub_hash.empty? ? nil : sub_hash
      end
    end
  end
end
