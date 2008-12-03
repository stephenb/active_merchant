# simple extension to ActiveMerchant for basic support of recurring payments with Express Checkout API
# 
# NOTE: set pem_file when loading
module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class PaypalExpressRecurringGateway < Gateway
      include PaypalCommonAPI

      LIVE_REDIRECT_URL = 'https://www.paypal.com/cgibin/webscr?cmd=_customer-billing-agreement&token='
      TEST_REDIRECT_URL = 'https://www.sandbox.paypal.com/cgi-bin/webscr?cmd=_customer-billing-agreement&token='

      def redirect_url
        test? ? TEST_REDIRECT_URL : LIVE_REDIRECT_URL
      end

      def redirect_url_for(token)
        "#{redirect_url}#{token}"
      end

      def setup_agreement(description, return_url, cancel_url)
        commit 'SetCustomerBillingAgreement', build_setup_request(description, return_url, cancel_url)
      end

      def create_profile(token, description, period, cycles, amount)
        commit 'CreateRecurringPaymentsProfile', build_create_profile_request(token, description, period, cycles, amount)
      end

      def get_profile_details(profile_id)
        commit 'GetRecurringPaymentsProfileDetails', build_get_profile_details_request(profile_id)
      end

    private
      def build_setup_request(description, return_url, cancel_url)
        xml = Builder::XmlMarkup.new :indent => 2
        xml.tag! 'SetCustomerBillingAgreementReq', 'xmlns' => PAYPAL_NAMESPACE do
          xml.tag! 'SetCustomerBillingAgreementRequest', 'xmlns:n2' => EBAY_NAMESPACE do
            xml.tag! 'n2:Version', 50
            xml.tag! 'n2:SetCustomerBillingAgreementRequestDetails' do
              xml.tag! 'n2:BillingAgreementDetails' do
                xml.tag! 'n2:BillingType', 'RecurringPayments'
                xml.tag! 'n2:BillingAgreementDescription', description
              end
              xml.tag! 'n2:ReturnURL', return_url
              xml.tag! 'n2:CancelURL', cancel_url
            end
          end
        end
        xml.target!
      end

      def build_create_profile_request(token, description, period, cycles, money)
        xml = Builder::XmlMarkup.new :indent => 2
        xml.tag! 'CreateRecurringPaymentsProfileReq', 'xmlns' => PAYPAL_NAMESPACE do
          xml.tag! 'CreateRecurringPaymentsProfileRequest', 'xmlns:n2' => EBAY_NAMESPACE do
            xml.tag! 'n2:Version', 50
            xml.tag! 'n2:CreateRecurringPaymentsProfileRequestDetails' do
              xml.tag! 'Token', token
              xml.tag! 'n2:RecurringPaymentsProfileDetails' do
                xml.tag! 'n2:BillingStartDate', Time.now.utc.iso8601
              end
              xml.tag! 'n2:ScheduleDetails' do
                xml.tag! 'n2:Description', description
                xml.tag! 'n2:PaymentPeriod' do
                  xml.tag! 'n2:BillingPeriod', 'Day'
                  xml.tag! 'n2:BillingFrequency', period
                  xml.tag! 'n2:TotalBillingCycles', cycles
                  xml.tag! 'n2:Amount', amount(money), 'currencyID' => currency(money)
                end
              end
            end
          end
        end

        xml.target!
      end

      def build_get_profile_details_request(profile_id)
        xml = Builder::XmlMarkup.new :indent => 2
        xml.tag! 'GetRecurringPaymentsProfileDetailsReq', 'xmlns' => PAYPAL_NAMESPACE do
          xml.tag! 'GetRecurringPaymentsProfileDetailsRequest', 'xmlns:n2' => EBAY_NAMESPACE do
            xml.tag! 'n2:Version', 50
            xml.tag! 'ProfileID', profile_id
          end
        end

        xml.target!
      end

      def build_response(success, message, response, options = {})
        PaypalExpressResponse.new(success, message, response, options)
      end

    end
  end
end