require File.dirname(__FILE__) + '/paypal/paypal_common_api'
require File.dirname(__FILE__) + '/paypal_express'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class PaypalGateway < Gateway
      include PaypalCommonAPI
      
      self.supported_cardtypes = [:visa, :master, :american_express, :discover]
      self.supported_countries = ['US']
      self.homepage_url = 'https://www.paypal.com/cgi-bin/webscr?cmd=_wp-pro-overview-outside'
      self.display_name = 'PayPal Website Payments Pro (US)'
      
      RECURRING_ACTIONS = Set.new([:add, :cancel, :inquiry, :suspend, :modify])
      
      def authorize(money, credit_card, options = {})
        requires!(options, :ip)
        commit 'DoDirectPayment', build_sale_or_authorization_request('Authorization', money, credit_card, options)
      end

      def purchase(money, credit_card, options = {})
        requires!(options, :ip)
        commit 'DoDirectPayment', build_sale_or_authorization_request('Sale', money, credit_card, options)
      end

      # Several options are available to customize the recurring profile:
      #
      # * <tt>profile_id</tt> - is only required for MODIFYING a recurring profile
      # * <tt>starting_at</tt> - (required) takes a Date, Time, or string in mmddyyyy format. The date must be in the future.
      # * <tt>name</tt> - The name of the customer to be billed. If not specified, the name from the credit card is used.
      # * <tt>periodicity</tt> - The frequency that the recurring payments will occur at. Can be one of
      # :bimonthly, :monthly, :biweekly, :weekly, :yearly, :daily, :semimonthly, :quadweekly, :quarterly, :semiyearly
      # * <tt>payments</tt> - The term, or number of payments that will be made (Leave blank for infinite)
      # * <tt>max_failed_attempts</tt> - (Optional) The number of scheduled payments that can fail before the profile is automatically suspended. 
      #                                  An IPN message is sent to the merchant when the specified number of failed payments is reached.
      # * <tt>comment</tt> - A comment associated with the profile
      # * <tt>profile_ref</tt> - (Optional) The merchant’s own unique reference or invoice number.
      def recurring(money, credit_card, options = {})
        options[:name] = credit_card.name if options[:name].blank? && credit_card
        request = build_recurring_request(options[:profile_id] ? :modify : :add, money, options) do |xml|
          add_credit_card(xml, credit_card, options[:billing_address], options) if credit_card
        end
        commit(options[:profile_id] ? 'UpdateRecurringPaymentsProfile' : 'CreateRecurringPaymentsProfile', request)
      end
      alias :modify_recurring :recurring

      # cancels an existing recurring profile
      def cancel_recurring(profile_id)
        request = build_recurring_request(:cancel, 0, :profile_id => profile_id) {}
        commit('ManageRecurringPaymentsProfileStatus', request)
      end

      # retrieves information about a recurring profile
      def recurring_inquiry(profile_id, options = {})
        request = build_recurring_request(:inquiry, nil, options.update( :profile_id => profile_id ))
        commit('GetRecurringPaymentsProfileDetails', request)
      end

      # suspends a recurring profile
      def suspend_recurring(profile_id)
        request = build_recurring_request(:suspend, 0, :profile_id => profile_id) {}
        commit('ManageRecurringPaymentsProfileStatus', request)
      end
      
      def convert_time_to_proper_format(time)
        time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      end
      
      def express
        @express ||= PaypalExpressGateway.new(@options)
      end

      private

      def build_recurring_request(action, money, options)
        unless RECURRING_ACTIONS.include?(action)
          raise StandardError, "Invalid Recurring Profile Action: #{action}"
        end

        xml = Builder::XmlMarkup.new :indent => 2

        ns2 = 'n2:'

        if [:add].include?(action)
          xml.tag! 'CreateRecurringPaymentsProfileReq', 'xmlns' => PAYPAL_NAMESPACE do
            xml.tag! 'CreateRecurringPaymentsProfileRequest' do
              xml.tag! 'Version', @@API_VERSION, 'xmlns' => EBAY_NAMESPACE

              # NOTE: namespace prefix here is critical!
              xml.tag! ns2 + 'CreateRecurringPaymentsProfileRequestDetails ', 'xmlns:n2' => EBAY_NAMESPACE do

                # credit card and other information goes here
                yield xml

                xml.tag! ns2 + 'RecurringPaymentsProfileDetails' do
                  xml.tag! ns2 + 'BillingStartDate', options[:starting_at]
                  xml.tag! ns2 + 'ProfileReference', options[:profile_ref]
                end

                xml.tag! ns2 + 'ScheduleDetails' do
                  xml.tag! ns2 + 'Description', options[:comment]
                  xml.tag! ns2 + 'MaxFailedPayments', options[:max_failed_attempts] if options[:max_failed_attempts]

                  unless options[:initial_payment].nil?
                    xml.tag! ns2 + 'TrialPeriod' do
                      xml.tag! ns2 + 'BillingPeriod', 'Month'
                      xml.tag! ns2 + 'BillingFrequency', 1
                      xml.tag! ns2 + 'TotalBillingCycles', 1
                      xml.tag! ns2 + 'Amount', amount(options[:initial_payment]), 'currencyID' => options[:currency] || currency(options[:initial_payment])
                    end
                  end

                  frequency, period = get_pay_period(options)
                  xml.tag! ns2 + 'PaymentPeriod' do
                    xml.tag! ns2 + 'BillingPeriod', period
                    xml.tag! ns2 + 'BillingFrequency', frequency.to_s
                    xml.tag! ns2 + 'TotalBillingCycles', options[:payments] unless options[:payments].nil? || options[:payments] == 0
                    xml.tag! ns2 + 'Amount', amount(money), 'currencyID' => options[:currency] || currency(money)
                  end

                  xml.tag! ns2 + 'AutoBillOutstandingAmount', 'AddToNextBilling'
                end
              end
            end
          end
        elsif [:modify].include?(action)
          xml.tag! 'UpdateRecurringPaymentsProfileReq', 'xmlns' => PAYPAL_NAMESPACE do
            xml.tag! 'UpdateRecurringPaymentsProfileRequest ', 'xmlns:n2' => EBAY_NAMESPACE do
              xml.tag! ns2 + 'Version', @@API_VERSION
              xml.tag! ns2 + 'UpdateRecurringPaymentsProfileRequestDetails' do
                xml.tag! 'ProfileID', options[:profile_id]
                yield xml # credit card and other information goes here
                xml.tag! ns2 + 'Note', options[:notes] if options[:note]
                # If you want to modify the amount then uncomment here... not needed right now and makes me a bit nervous
                # xml.tag! ns2 + 'Amount', amount(money), 'currencyID' => options[:currency] || currency(money)
              end
            end
          end
        elsif [:cancel, :suspend].include?(action)
          xml.tag! 'ManageRecurringPaymentsProfileStatusReq', 'xmlns' => PAYPAL_NAMESPACE do
            xml.tag! 'ManageRecurringPaymentsProfileStatusRequest', 'xmlns:n2' => EBAY_NAMESPACE do
              xml.tag! ns2 + 'Version', @@API_VERSION
              xml.tag! ns2 + 'ManageRecurringPaymentsProfileStatusRequestDetails' do
                xml.tag! 'ProfileID', options[:profile_id]
                xml.tag! ns2 + 'Action', action == :cancel ? 'Cancel' : 'Suspend'
                xml.tag! ns2 + 'Note', 'Canceling the action, no real comment here'
              end
            end
          end
        elsif [:inquiry].include?(action)
          xml.tag! 'GetRecurringPaymentsProfileDetailsReq', 'xmlns' => PAYPAL_NAMESPACE do
            xml.tag! 'GetRecurringPaymentsProfileDetailsRequest', 'xmlns:n2' => EBAY_NAMESPACE do
              xml.tag! ns2 + 'Version', @@API_VERSION
              xml.tag! 'ProfileID', options[:profile_id]
            end
          end
        end
      end

      def get_pay_period(options)
        requires! (options, [:periodicity, :bimonthly, :monthly, :biweekly, :weekly, :yearly, :daily, :semimonthly, :quadweekly, :quarterly, :semiyearly])
        case options[:periodicity]
          when :weekly then [1, 'Week']
          when :biweekly then [2, 'Week']
          when :semimonthly then [1, 'SemiMonth']
          when :quadweekly then [4, 'Week']
          when :monthly then [1, 'Month']
          when :quarterly then [3, 'Month']
          when :semiyearly then [6, 'Month'] # broken! i think
          when :yearly then [1, 'Year']
        end
      end
      
      def build_sale_or_authorization_request(action, money, credit_card, options)
        billing_address = options[:billing_address] || options[:address]
        currency_code = options[:currency] || currency(money)
       
        xml = Builder::XmlMarkup.new :indent => 2
        xml.tag! 'DoDirectPaymentReq', 'xmlns' => PAYPAL_NAMESPACE do
          xml.tag! 'DoDirectPaymentRequest', 'xmlns:n2' => EBAY_NAMESPACE do
            xml.tag! 'n2:Version', API_VERSION
            xml.tag! 'n2:DoDirectPaymentRequestDetails' do
              xml.tag! 'n2:PaymentAction', action
              xml.tag! 'n2:PaymentDetails' do
                xml.tag! 'n2:OrderTotal', amount(money), 'currencyID' => currency_code
                
                # All of the values must be included together and add up to the order total
                if [:subtotal, :shipping, :handling, :tax].all?{ |o| options.has_key?(o) }
                  xml.tag! 'n2:ItemTotal', amount(options[:subtotal]), 'currencyID' => currency_code
                  xml.tag! 'n2:ShippingTotal', amount(options[:shipping]),'currencyID' => currency_code
                  xml.tag! 'n2:HandlingTotal', amount(options[:handling]),'currencyID' => currency_code
                  xml.tag! 'n2:TaxTotal', amount(options[:tax]), 'currencyID' => currency_code
                end
                
                xml.tag! 'n2:NotifyURL', options[:notify_url]
                xml.tag! 'n2:OrderDescription', options[:description]
                xml.tag! 'n2:InvoiceID', options[:order_id]
                xml.tag! 'n2:ButtonSource', application_id.to_s.slice(0,32) unless application_id.blank? 
                
                add_address(xml, 'n2:ShipToAddress', options[:shipping_address]) if options[:shipping_address]
              end
              add_credit_card(xml, credit_card, billing_address, options)
              xml.tag! 'n2:IPAddress', options[:ip]
            end
          end
        end

        xml.target!        
      end
      
      def add_credit_card(xml, credit_card, address, options)
        xml.tag! 'n2:CreditCard' do
          xml.tag! 'n2:CreditCardType', credit_card_type(card_brand(credit_card))
          xml.tag! 'n2:CreditCardNumber', credit_card.number
          xml.tag! 'n2:ExpMonth', format(credit_card.month, :two_digits)
          xml.tag! 'n2:ExpYear', format(credit_card.year, :four_digits)
          xml.tag! 'n2:CVV2', credit_card.verification_value
          
          if [ 'switch', 'solo' ].include?(card_brand(credit_card).to_s)
            xml.tag! 'n2:StartMonth', format(credit_card.start_month, :two_digits) unless credit_card.start_month.blank?
            xml.tag! 'n2:StartYear', format(credit_card.start_year, :four_digits) unless credit_card.start_year.blank?
            xml.tag! 'n2:IssueNumber', format(credit_card.issue_number, :two_digits) unless credit_card.issue_number.blank?
          end
          
          xml.tag! 'n2:CardOwner' do
            xml.tag! 'n2:PayerName' do
              xml.tag! 'n2:FirstName', credit_card.first_name
              xml.tag! 'n2:LastName', credit_card.last_name
            end
            
            xml.tag! 'n2:Payer', options[:email]
            add_address(xml, 'n2:Address', address)
          end
        end
      end

      def credit_card_type(type)
        case type
        when 'visa'             then 'Visa'
        when 'master'           then 'MasterCard'
        when 'discover'         then 'Discover'
        when 'american_express' then 'Amex'
        when 'switch'           then 'Switch'
        when 'solo'             then 'Solo'
        end
      end
      
      def build_response(success, message, response, options = {})
         Response.new(success, message, response, options)
      end
    end
  end
end
