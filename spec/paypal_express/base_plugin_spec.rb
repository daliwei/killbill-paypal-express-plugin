require 'spec_helper'

describe Killbill::PaypalExpress::PaymentPlugin do

  include ::Killbill::Plugin::ActiveMerchant::RSpec

  before(:each) do
    Dir.mktmpdir do |dir|
      file = File.new(File.join(dir, 'paypal_express.yml'), 'w+')
      file.write(<<-eos)
:paypal_express:
  :signature: 'signature'
  :login: 'login'
  :password: 'password'
  :test: true
# As defined by spec_helper.rb
:database:
  :adapter: 'sqlite3'
  :database: 'test.db'
      eos
      file.close

      @plugin = build_plugin(::Killbill::PaypalExpress::PaymentPlugin, 'paypal_express', File.dirname(file))

      # Start the plugin here - since the config file will be deleted
      @plugin.start_plugin
    end
  end

  it 'should start and stop correctly' do
    @plugin.stop_plugin
  end

  it 'should receive notifications correctly' do
    description    = 'description'

    kb_tenant_id = SecureRandom.uuid
    context      = @plugin.kb_apis.create_context(kb_tenant_id)
    properties   = @plugin.hash_to_properties({ :description => description })

    notification    = ''
    gw_notification = @plugin.process_notification notification, properties, context
  end

  it 'should correctly add and filter optional parameters for auth/purchase call' do
    amount = 99.99
    amount_in_cents = 9999
    options = {:some_property => true}
    property_hash = { :max_amount => amount,
                      :subtotal => amount,
                      :shipping => amount,
                      :handling => amount,
                      :tax => amount,
                      :insuranceTotal => amount,
                      :shipping_discount => amount,
                      :shipping_options => [{:default => false, :name => 'jack', :amount => amount, :unlimited => true}].to_json,
                      :items => [{:name => 'john', :number => 111, :quantity => 12, :amount => amount, :description => 'jacket', :url => 'test', :category => 'unknown', :unlimited => true}].to_json,
                      :shipping_address => {:name => 'john', :address1 => '111', :address2 => '12', :city => 'palo alto', :state => 'ca', :country => 'jacket', :phone => 'test', :zip => 'unknown', :family => 'unknown'}.to_json,
                      :address => {:name => 'john', :address1 => '111', :address2 => '12', :city => 'palo alto', :state => 'ca', :country => 'jacket', :phone => 'test', :zip => 'unknown', :family => 'unknown'}.to_json,
                      :funding_sources => {:source => 'unknown'}.to_json,
                      :note_text => 'unknown'
    }
    @plugin.send(:add_optional_params_for_auth_purchase, options, property_hash, 'USD')
    expected_options = { :some_property => true,
                         :subtotal => amount_in_cents,
                         :shipping => amount_in_cents,
                         :handling => amount_in_cents,
                         :tax => amount_in_cents,
                         :insurance_total => amount_in_cents,
                         :shipping_discount => amount_in_cents,
                         :items => [{:name => 'john', :number => 111, :quantity => 12, :amount => amount_in_cents, :description => 'jacket', :url => 'test', :category => 'unknown'}],
                         :shipping_address => {:name => 'john', :address1 => '111', :address2 => '12', :state => 'ca', :city => 'palo alto', :country => 'jacket', :phone => 'test', :zip => 'unknown'}
                       }
    options.should == expected_options
  end

  it 'should correctly add and filter optional parameters for refund call' do
    options = {}
    property_hash = { :refund_type => 'Full',
                      :note => 'TestAuthorization'}
    @plugin.send(:add_optional_params_for_refund, options, property_hash)
    options.should == property_hash
  end

  it 'should correctly add and filter optional parameters for void call' do
    options = {}
    property_hash = { :description => 'Full',
                      :note => 'TestAuthorization'}
    @plugin.send(:add_optional_params_for_void, options, property_hash)
    options.should == { :description => 'Full'}
  end

  it 'should correctly add and filter optional parameters for capture call' do
    options = {:complete_type => 'NotComplete'}
    property_hash = { :order_id => '1234',
                      :description => 'TestAuthorization'}
    @plugin.send(:add_optional_params_for_capture, options, property_hash)
    options.should == { :complete_type => 'NotComplete',
                        :order_id => '1234',
                        :description => 'TestAuthorization'}
  end

  it 'should correctly add and filter optional parameters for baid auth/purchase call' do
    amount = 99.99
    amount_in_cents = 9999
    options = {:some_property => true}
    property_hash = { :max_amount => amount,
                      :ip_address => 'jacket',
                      :req_confirm_shipping => 'jacket',
                      :merchant_session_id => 'jacket',
                      :return_f_m_f_details => 'jacket',
                      :soft_descriptor => 'jacket',
                      :subtotal => amount,
                      :shipping => amount,
                      :handling => amount,
                      :tax => amount,
                      :insuranceTotal => amount,
                      :shipping_discount => amount,
                      :shipping_options => [{:default => false, :name => 'jack', :amount => amount, :unlimited => true}].to_json,
                      :items => [{:name => 'john', :number => 111, :quantity => 12, :amount => amount, :description => 'jacket', :url => 'test', :category => 'unknown', :unlimited => true}].to_json,
                      :shipping_address => {:name => 'john', :address1 => '111', :address2 => '12', :city => 'palo alto', :state => 'ca', :country => 'jacket', :phone => 'test', :zip => 'unknown', :family => 'unknown'}.to_json,
                      :address => {:name => 'john', :address1 => '111', :address2 => '12', :city => 'palo alto', :state => 'ca', :country => 'jacket', :phone => 'test', :zip => 'unknown', :family => 'unknown'}.to_json,
                      :funding_sources => {:source => 'unknown'}.to_json,
                      :note_text => 'unknown',
                      :order_id => '1234'
                    }
    @plugin.send(:add_optional_params_for_baid_auth_purchase, options, property_hash, 'USD')
    expected_options = { :some_property => true,
                         :ip_address => 'jacket',
                         :req_confirm_shipping => 'jacket',
                         :merchant_session_id => 'jacket',
                         :return_f_m_f_details => 'jacket',
                         :soft_descriptor => 'jacket',
                         :subtotal => amount_in_cents,
                         :shipping => amount_in_cents,
                         :handling => amount_in_cents,
                         :tax => amount_in_cents,
                         :insurance_total => amount_in_cents,
                         :shipping_discount => amount_in_cents,
                         :items => [{:name => 'john', :number => 111, :quantity => 12, :amount => amount_in_cents, :description => 'jacket', :url => 'test', :category => 'unknown'}],
                         :shipping_address => {:name => 'john', :address1 => '111', :address2 => '12', :state => 'ca', :city => 'palo alto', :country => 'jacket', :phone => 'test', :zip => 'unknown'},
                         :order_id => '1234'
                       }
    options.should == expected_options
  end

  it 'should correctly add and filter optional parameters for build_form_descriptor call' do
    # Basic option test
    options = { :amount => 9900,
                :some_property => true}
    amount = 99.99
    amount_in_cents = 9999
    property_hash = { :noShipping => true,
                      :max_amount => amount,
                      :order_id => '1234'
                    }
    @plugin.send(:add_optional_params_for_initial_call, options, property_hash, 'USD')
    expected_options = { :amount => 9900,
                         :some_property => true,
                         :no_shipping => true,
                         :max_amount => amount_in_cents,
                         :order_id => '1234'
                       }
    options.should == expected_options

    # Test with correct option format and unwanted property, e.g., fakeKey and unlimited
    options = { :amount => 9900,
                :some_property => true}
    amount = 99.99
    amount_in_cents = 9999
    property_hash = { :noShipping => true,
                      :max_amount => amount,
                      :subtotal => amount,
                      :shipping => amount,
                      :handling => amount,
                      :tax => amount,
                      :fakeKey => 'unlimited',
                      :insuranceTotal => amount,
                      :shipping_discount => amount,
                      :shipping_options => [{:default => false, :name => 'jack', :amount => amount, :unlimited => true}].to_json,
                      :items => [{:name => 'john', :number => 111, :quantity => 12, :amount => amount, :description => 'jacket', :url => 'test', :category => 'unknown', :unlimited => true}].to_json,
                      :shipping_address => {:name => 'john', :address1 => '111', :address2 => '12', :city => 'palo alto', :state => 'ca', :country => 'jacket', :phone => 'test', :zip => 'unknown', :family => 'unknown'}.to_json,
                      :address => {:name => 'john', :address1 => '111', :address2 => '12', :city => 'palo alto', :state => 'ca', :country => 'jacket', :phone => 'test', :zip => 'unknown', :family => 'unknown'}.to_json,
                      :funding_sources => {:source => 'unknown'}.to_json,
                      :note_text => 'unknown'
                   }
    @plugin.send(:add_optional_params_for_initial_call, options, property_hash, 'USD')
    expected_options = { :amount => 9900,
                         :some_property => true,
                         :no_shipping => true,
                         :max_amount => amount_in_cents,
                         :subtotal => amount_in_cents,
                         :shipping => amount_in_cents,
                         :handling => amount_in_cents,
                         :tax => amount_in_cents,
                         :insurance_total => amount_in_cents,
                         :shipping_discount => amount_in_cents,
                         :shipping_options => [{:default => false, :name => 'jack', :amount => amount_in_cents}],
                         :items => [{:name => 'john', :number => 111, :quantity => 12, :amount => amount_in_cents, :description => 'jacket', :url => 'test', :category => 'unknown'}],
                         :shipping_address => {:name => 'john', :address1 => '111', :address2 => '12', :state => 'ca', :city => 'palo alto', :country => 'jacket', :phone => 'test', :zip => 'unknown'},
                         :funding_sources => {:source => 'unknown'}
                      }
    options.should == expected_options

    # Test with incorrect option format and invalid json format
    options = {}
    property_hash = { :no_shipping => true,
                      :max_amount => amount,
                      :subtotal => amount,
                      :shipping => amount,
                      :handling => amount,
                      :tax => amount,
                      :fakeKey => 'unlimited',
                      :insurance_total => amount,
                      :shipping_discount => amount,
                      :shipping_options => "{\"default\":\"false\", [name]:\"jack\", \"amount\":12}",
                      :items => {:name => 'john', :number => 111, :quantity => 12, :amount => amount, :description => 'jacket', :url => 'test', :category => 'unknown', :unlimited => true}.to_json,
                      :shipping_address => [{:name => 'john', :address1 => '111', :address2 => '12', :city => 'amount', :country => 'jacket', :phone => 'test', :zip => 'unknown'}].to_json,
                      :address => [{:name => 'john', :address1 => '111', :address2 => '12', :city => 'amount', :country => 'jacket', :phone => 'test', :zip => 'unknown'}].to_json,
                      :note_text => 'unknown',
                      :express_request => true
                    }
    @plugin.send(:add_optional_params_for_initial_call, options, property_hash, 'USD')
    expected_options = { :no_shipping => true,
                         :max_amount => amount_in_cents,
                         :subtotal => amount_in_cents,
                         :shipping => amount_in_cents,
                         :handling => amount_in_cents,
                         :tax => amount_in_cents,
                         :insurance_total => amount_in_cents,
                         :shipping_discount => amount_in_cents,
                         :items => nil,
                         :shipping_options => nil,
                         :shipping_address => nil,
                         :express_request => true,
                         :note_text => 'unknown'
                       }
    options.should == expected_options
  end
end
