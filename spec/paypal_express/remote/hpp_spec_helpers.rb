require 'spec_helper'
require_relative 'browser_helpers'

module Killbill
  module PaypalExpress
    module HppSpecHelpers

      include ::Killbill::PaypalExpress::BrowserHelpers

      def hpp_setup
        @call_context = build_call_context
        @amount = BigDecimal.new('100')
        @currency = 'USD'
        @form_fields = @plugin.hash_to_properties(
            :order_id => '1234',
            :amount => @amount,
            :currency => @currency
        )
        kb_account_id = SecureRandom.uuid
        create_kb_account(kb_account_id, @plugin.kb_apis.proxied_services[:account_user_api])
        @pm = create_payment_method(::Killbill::PaypalExpress::PaypalExpressPaymentMethod, kb_account_id, @call_context.tenant_id)
        verify_payment_method kb_account_id
      end

      def validate_form(form)
        form.kb_account_id.should == @pm.kb_account_id
        form.form_url.should start_with('https://www.sandbox.paypal.com/cgi-bin/webscr')
        form.form_method.should == 'GET'
      end

      def validate_nil_form_property(form, key)
        key_properties = form.properties.select { |prop| prop.key == key }
        key_properties.size.should == 0
      end

      def validate_form_property(form, key, value=nil)
        key_properties = form.properties.select { |prop| prop.key == key }
        key_properties.size.should == 1
        key = key_properties.first.value
        value.nil? ? key.should_not(be_nil) : key.should == value
        key
      end

      def validate_token(form)
        login_and_confirm form.form_url
      end

      def purchase_and_refund(kb_payment_id, purchase_payment_external_key, purchase_properties)
        # Trigger the purchase
        payment_response = @plugin.purchase_payment(@pm.kb_account_id, kb_payment_id, purchase_payment_external_key, @pm.kb_payment_method_id, @amount, @currency, purchase_properties, @call_context)
        payment_response.status.should eq(:PROCESSED), payment_response.gateway_error
        payment_response.amount.should == @amount
        payment_response.transaction_type.should == :PURCHASE
        payer_id = find_value_from_properties(payment_response.properties, 'payerId')
        payer_id.should_not be_nil

        validate_details_for(kb_payment_id, :PURCHASE, payer_id)
        # Verify GET API
        payment_infos = @plugin.get_payment_info(@pm.kb_account_id, kb_payment_id, [], @call_context)
        payment_infos.size.should == 1
        # purchase
        payment_infos[0].kb_payment_id.should == kb_payment_id
        payment_infos[0].transaction_type.should == :PURCHASE
        payment_infos[0].amount.should == @amount
        payment_infos[0].currency.should == @currency
        payment_infos[0].status.should == :PROCESSED
        payment_infos[0].gateway_error.should == 'Success'
        payment_infos[0].gateway_error_code.should be_nil
        find_value_from_properties(payment_infos[0].properties, 'payerId').should == payer_id

        # Try a full refund
        refund_response = @plugin.refund_payment(@pm.kb_account_id, kb_payment_id, SecureRandom.uuid, @pm.kb_payment_method_id, @amount, @currency, [], @call_context)
        refund_response.status.should eq(:PROCESSED), refund_response.gateway_error
        refund_response.amount.should == @amount
        refund_response.transaction_type.should == :REFUND

        # Verify GET API
        payment_infos = @plugin.get_payment_info(@pm.kb_account_id, kb_payment_id, [], @call_context)
        payment_infos.size.should == 2
        # refund
        payment_infos[1].kb_payment_id.should.should == kb_payment_id
        payment_infos[1].transaction_type.should == :REFUND
        payment_infos[1].amount.should == @amount
        payment_infos[1].currency.should == @currency
        payment_infos[1].status.should == :PROCESSED
        payment_infos[1].gateway_error.should == 'Success'
        payment_infos[1].gateway_error_code.should be_nil
      end

      def authorize_capture_and_refund(kb_payment_id, payment_external_key, properties, payment_processor_account_id)
        # Trigger the authorize
        payment_response = @plugin.authorize_payment(@pm.kb_account_id, kb_payment_id, payment_external_key, @pm.kb_payment_method_id, @amount, @currency, properties, @call_context)
        payment_response.status.should eq(:PROCESSED), payment_response.gateway_error
        payment_response.amount.should == @amount
        payment_response.transaction_type.should == :AUTHORIZE
        payer_id = find_value_from_properties(payment_response.properties, 'payerId')
        payer_id.should_not be_nil

        validate_details_for(kb_payment_id, :AUTHORIZE, payer_id)
        # Verify GET AUTHORIZED PAYMENT
        payment_infos = @plugin.get_payment_info(@pm.kb_account_id, kb_payment_id, properties, @call_context)
        payment_infos.size.should == 1
        # authorize
        payment_infos[0].kb_payment_id.should == kb_payment_id
        payment_infos[0].transaction_type.should == :AUTHORIZE
        payment_infos[0].amount.should == @amount
        payment_infos[0].currency.should == @currency
        payment_infos[0].status.should == :PROCESSED
        payment_infos[0].gateway_error.should == 'Success'
        payment_infos[0].gateway_error_code.should be_nil
        find_value_from_properties(payment_infos[0].properties, 'payerId').should == payer_id
        find_value_from_properties(payment_infos[0].properties, 'paymentInfoPaymentStatus').should == 'Pending'
        find_value_from_properties(payment_infos[0].properties, 'paymentInfoPendingReason').should == 'authorization'
        find_value_from_properties(payment_infos[0].properties, 'payment_processor_account_id').should == payment_processor_account_id

        # Trigger the capture
        payment_response = @plugin.capture_payment(@pm.kb_account_id, kb_payment_id, payment_external_key, @pm.kb_payment_method_id, @amount, @currency, properties, @call_context)
        payment_response.status.should eq(:PROCESSED), payment_response.gateway_error
        payment_response.amount.should == @amount
        payment_response.transaction_type.should == :CAPTURE

        # Verify GET CAPTURED PAYMENT
        payment_infos = @plugin.get_payment_info(@pm.kb_account_id, kb_payment_id, properties, @call_context)
        # Two expected transactions: one auth and one capture
        payment_infos.size.should == 2
        # capture
        payment_infos[1].kb_payment_id.should == kb_payment_id
        payment_infos[1].transaction_type.should == :CAPTURE
        payment_infos[1].amount.should == @amount
        payment_infos[1].currency.should == @currency
        payment_infos[1].status.should == :PROCESSED
        payment_infos[1].gateway_error.should == 'Success'
        payment_infos[1].gateway_error_code.should be_nil
        find_value_from_properties(payment_infos[1].properties, 'paymentInfoPaymentStatus').should == 'Completed'
        find_value_from_properties(payment_infos[1].properties, 'payment_processor_account_id').should == payment_processor_account_id

        # Try a full refund
        refund_response = @plugin.refund_payment(@pm.kb_account_id, kb_payment_id, SecureRandom.uuid, @pm.kb_payment_method_id, @amount, @currency, [], @call_context)
        refund_response.status.should eq(:PROCESSED), refund_response.gateway_error
        refund_response.amount.should == @amount
        refund_response.transaction_type.should == :REFUND

        # Verify GET API
        payment_infos = @plugin.get_payment_info(@pm.kb_account_id, kb_payment_id, properties, @call_context)
        payment_infos.size.should == 3
        # refund
        payment_infos[2].kb_payment_id.should.should == kb_payment_id
        payment_infos[2].transaction_type.should == :REFUND
        payment_infos[2].amount.should == @amount
        payment_infos[2].currency.should == @currency
        payment_infos[2].status.should == :PROCESSED
        payment_infos[2].gateway_error.should == 'Success'
        payment_infos[2].gateway_error_code.should be_nil
        find_value_from_properties(payment_infos[2].properties, 'payment_processor_account_id').should == payment_processor_account_id
      end

      def authorize_and_double_capture(kb_payment_id, payment_external_key, properties)
        # Trigger the authorize
        payment_response = @plugin.authorize_payment(@pm.kb_account_id, kb_payment_id, payment_external_key, @pm.kb_payment_method_id, @amount, @currency, properties, @call_context)
        payment_response.status.should eq(:PROCESSED), payment_response.gateway_error
        payment_response.amount.should == @amount
        payment_response.transaction_type.should == :AUTHORIZE
        payer_id = find_value_from_properties(payment_response.properties, 'payerId')
        payer_id.should_not be_nil

        validate_details_for(kb_payment_id, :AUTHORIZE, payer_id)
        payment_infos = @plugin.get_payment_info(@pm.kb_account_id, kb_payment_id, properties, @call_context)
        payment_infos.size.should == 1
        # autorize
        payment_infos[0].kb_payment_id.should == kb_payment_id
        payment_infos[0].transaction_type.should == :AUTHORIZE
        payment_infos[0].amount.should == @amount
        payment_infos[0].currency.should == @currency
        payment_infos[0].status.should == :PROCESSED
        payment_infos[0].gateway_error.should == 'Success'
        payment_infos[0].gateway_error_code.should be_nil

        # Trigger the capture
        payment_response = @plugin.capture_payment(@pm.kb_account_id, kb_payment_id, payment_external_key, @pm.kb_payment_method_id, @amount, @currency, properties, @call_context)
        payment_response.status.should eq(:PROCESSED), payment_response.gateway_error
        payment_response.amount.should == @amount
        payment_response.transaction_type.should == :CAPTURE

        payment_infos = @plugin.get_payment_info(@pm.kb_account_id, kb_payment_id, properties, @call_context)
        payment_infos.size.should == 2
        # capture
        payment_infos[1].kb_payment_id.should == kb_payment_id
        payment_infos[1].transaction_type.should == :CAPTURE
        payment_infos[1].amount.should == @amount
        payment_infos[1].currency.should == @currency
        payment_infos[1].status.should == :PROCESSED
        payment_infos[1].gateway_error.should == 'Success'
        payment_infos[1].gateway_error_code.should be_nil

        # Trigger a capture again with full amount
        payment_response = @plugin.capture_payment(@pm.kb_account_id, kb_payment_id, payment_external_key, @pm.kb_payment_method_id, @amount, @currency, properties, @call_context)
        payment_response.status.should eq(:ERROR), payment_response.gateway_error
        payment_response.amount.should == nil
        payment_response.transaction_type.should == :CAPTURE

        payment_infos = @plugin.get_payment_info(@pm.kb_account_id, kb_payment_id, properties, @call_context)
        payment_infos.size.should == 3
        # capture again
        payment_infos[2].kb_payment_id.should.should == kb_payment_id
        payment_infos[2].transaction_type.should == :CAPTURE
        payment_infos[2].amount.should be_nil
        payment_infos[2].currency.should be_nil
        payment_infos[2].status.should == :ERROR
        payment_infos[2].gateway_error.should == 'Authorization has already been completed.'
        payment_infos[2].gateway_error_code.should == "10602"
      end

      def authorize_and_void(kb_payment_id, payment_external_key, properties, payment_processor_account_id)
        # Trigger the authorize
        payment_response = @plugin.authorize_payment(@pm.kb_account_id, kb_payment_id, payment_external_key, @pm.kb_payment_method_id, @amount, @currency, properties, @call_context)
        payment_response.status.should eq(:PROCESSED), payment_response.gateway_error
        payment_response.amount.should == @amount
        payment_response.transaction_type.should == :AUTHORIZE
        payer_id = find_value_from_properties(payment_response.properties, 'payerId')
        payer_id.should_not be_nil

        validate_details_for(kb_payment_id, :AUTHORIZE, payer_id)
        # Verify get_payment_info
        payment_infos = @plugin.get_payment_info(@pm.kb_account_id, kb_payment_id, properties, @call_context)
        payment_infos.size.should == 1
        # authorize
        payment_infos[0].kb_payment_id.should == kb_payment_id
        payment_infos[0].transaction_type.should == :AUTHORIZE
        payment_infos[0].amount.should == @amount
        payment_infos[0].currency.should == @currency
        payment_infos[0].status.should == :PROCESSED
        payment_infos[0].gateway_error.should == 'Success'
        payment_infos[0].gateway_error_code.should be_nil
        find_value_from_properties(payment_infos[0].properties, 'payment_processor_account_id').should == payment_processor_account_id

        # Trigger the void
        payment_response = @plugin.void_payment(@pm.kb_account_id, kb_payment_id, payment_external_key, @pm.kb_payment_method_id, properties, @call_context)
        payment_response.status.should eq(:PROCESSED), payment_response.gateway_error
        payment_response.transaction_type.should == :VOID

        # Verify get_payment_info
        payment_infos = @plugin.get_payment_info(@pm.kb_account_id, kb_payment_id, properties, @call_context)
        # Two expected transactions: one auth and one capture, plus the details call
        payment_infos.size.should == 2
        # void
        payment_infos[1].kb_payment_id.should == kb_payment_id
        payment_infos[1].transaction_type.should == :VOID
        payment_infos[1].status.should == :PROCESSED
        payment_infos[1].gateway_error.should == 'Success'
        payment_infos[1].gateway_error_code.should be_nil
        find_value_from_properties(payment_infos[1].properties, 'payment_processor_account_id').should == payment_processor_account_id
      end

      def purchase_with_missing_token
        failed_purchase([], :CANCELED, 'Could not retrieve the payer info: the token is missing', 'RuntimeError')
      end

      def authorize_with_missing_token
        failed_authorize([], :CANCELED, 'Could not retrieve the payer info: the token is missing', 'RuntimeError')
      end

      def purchase_with_invalid_token(purchase_properties)
        failed_purchase(purchase_properties, :CANCELED, "Could not retrieve the payer info for token #{properties_to_hash(purchase_properties)[:token]}", 'RuntimeError')
      end

      def authorize_with_invalid_token(authorize_properties)
        failed_authorize(authorize_properties, :CANCELED, "Could not retrieve the payer info for token #{properties_to_hash(authorize_properties)[:token]}", 'RuntimeError')
      end

      def subsequent_purchase(purchase_properties)
        failed_purchase(purchase_properties, :ERROR, 'A successful transaction has already been completed for this token.', '11607')
      end

      def failed_authorize(authorize_properties, status, msg, gateway_error_code=nil)
        kb_payment_id = SecureRandom.uuid

        payment_response = @plugin.authorize_payment(@pm.kb_account_id, kb_payment_id, SecureRandom.uuid, @pm.kb_payment_method_id, @amount, @currency, authorize_properties, @call_context)
        payment_response.status.should eq(status), payment_response.gateway_error
        payment_response.amount.should be_nil
        payment_response.transaction_type.should == :AUTHORIZE

        # Verify GET API
        payment_infos = @plugin.get_payment_info(@pm.kb_account_id, kb_payment_id, [], @call_context)
        payment_infos.size.should == 1
        payment_infos[0].kb_payment_id.should == kb_payment_id
        payment_infos[0].transaction_type.should == :AUTHORIZE
        payment_infos[0].amount.should be_nil
        payment_infos[0].currency.should be_nil
        payment_infos[0].status.should == status
        payment_infos[0].gateway_error.should == msg
        payment_infos[0].gateway_error_code.should == gateway_error_code
      end

      def failed_purchase(purchase_properties, status, msg, gateway_error_code=nil)
        kb_payment_id = SecureRandom.uuid

        payment_response = @plugin.purchase_payment(@pm.kb_account_id, kb_payment_id, SecureRandom.uuid, @pm.kb_payment_method_id, @amount, @currency, purchase_properties, @call_context)
        payment_response.status.should eq(status), payment_response.gateway_error
        payment_response.amount.should be_nil
        payment_response.transaction_type.should == :PURCHASE

        # Verify GET API
        payment_infos = @plugin.get_payment_info(@pm.kb_account_id, kb_payment_id, [], @call_context)
        token = find_value_from_properties(purchase_properties, 'token')
        payment_infos.size.should == 1
        payment_infos[0].kb_payment_id.should == kb_payment_id
        payment_infos[0].transaction_type.should == :PURCHASE
        payment_infos[0].amount.should be_nil
        payment_infos[0].currency.should be_nil
        payment_infos[0].status.should == status
        payment_infos[0].gateway_error.should == msg
        payment_infos[0].gateway_error_code.should == gateway_error_code
      end

      def transition_last_response_to_UNDEFINED(expected_nb_transactions, kb_payment_id, delete_last_trx = true)
        Killbill::PaypalExpress::PaypalExpressTransaction.last.delete if delete_last_trx
        response = Killbill::PaypalExpress::PaypalExpressResponse.last
        initial_auth = response.authorization
        response.update(:authorization => nil, :message => {:payment_plugin_status => 'UNDEFINED'}.to_json)

        skip_gw = Killbill::Plugin::Model::PluginProperty.new
        skip_gw.key = 'skip_gw'
        skip_gw.value = 'true'
        properties_with_skip_gw = [skip_gw]

        # Set skip_gw=true, to avoid calling the report API
        transaction_info_plugins = @plugin.get_payment_info(@pm.kb_account_id, kb_payment_id, properties_with_skip_gw, @call_context)
        transaction_info_plugins.size.should == expected_nb_transactions
        transaction_info_plugins.last.status.should eq(:UNDEFINED)

        [response, initial_auth]
      end

      def verify_janitor_transition(nb_trx_plugin_info, trx_type, trx_status, kb_payment_id, delete_last_trx = true, hard_expiration_date = 0, janitor_delay = 0)
        transition_last_response_to_UNDEFINED(nb_trx_plugin_info, kb_payment_id, delete_last_trx)
        # wait 5 sec for PayPal to populate the record in search endpoint
        sleep 5
        janitor_delay_threshold = Killbill::Plugin::Model::PluginProperty.new
        janitor_delay_threshold.key = 'janitor_delay_threshold'
        janitor_delay_threshold.value = janitor_delay
        cancel_threshold = Killbill::Plugin::Model::PluginProperty.new
        cancel_threshold.key = 'cancel_threshold'
        cancel_threshold.value = hard_expiration_date
        transaction_info_plugins = @plugin.get_payment_info(@pm.kb_account_id, kb_payment_id, [janitor_delay_threshold, cancel_threshold], @call_context)
        transaction_info_plugins.size.should == nb_trx_plugin_info
        transaction_info_plugins.last.status.should eq(trx_status)
        transaction_info_plugins.last.transaction_type.should eq(trx_type)
      end

      private

      def verify_payment_method(kb_account_id = nil)
        # Verify our table directly
        kb_account_id = @pm.kb_account_id if kb_account_id.nil?
        payment_methods = ::Killbill::PaypalExpress::PaypalExpressPaymentMethod.from_kb_account_id(kb_account_id, @call_context.tenant_id)
        payment_methods.size.should == 1
        payment_method = payment_methods.first
        payment_method.should_not be_nil
        payment_method.paypal_express_payer_id.should be_nil
        payment_method.token.should be_nil
        payment_method.kb_payment_method_id.should == @pm.kb_payment_method_id
      end
    end
  end
end
