require 'faraday'
require 'uri'

module MailRoom
  module Delivery
    class Postback
      def initialize(mailbox)
        @mailbox = mailbox
      end

      def deliver(message)
        connection = Faraday.new
        connection.token_auth @mailbox.delivery_token

        # ERROR ArgumentError: invalid %-encoding ("f T-KT-JX"  can be seen as a rack error (only detected when using webbrick and looking at stderr)
        # on some emails that have oddities.  % seems to be the worst offender but there are others.
        # message = message.encode('UTF-8', :invalid => :replace, :undef => :replace)
        # won't do it -- we need to url-encode the POST params.  We don't try setting the Content Type and let rack figure it out instead
        # (probably the default is url_encoded anyway).
        # Trying to set request.headers['Content-Length'] to the size of the message doesn't seem needed and may crash the server.
        # Trying to convince Rack to do the right thing with unencoded params to the POST doesn't seem to work either:
        # (e.g., setting request.headers['Content-Type'] to 'text/plain' or 'message/rfc822').

        connection.post do |request|
          request.url @mailbox.delivery_url
          request.body = URI.encode(message)
        end

      end
    end
  end
end
