module MailRoom
  class MailboxHandler
    def initialize(mailbox, imap)
      @mailbox = mailbox
      @imap = imap
    end

    def process
      # return if idling? || !running?

      new_messages.each do |msg|
        # puts msg.attr['RFC822']

        # loop over delivery methods and deliver each

        message = msg.attr['RFC822']  # the whole message
        mail = Mail.read_from_string(message)

        subject = mail.subject
        text_part = mail.text_part.body.to_s
        body =  mail.html_part.body.to_s
        _ = text_part
        _ = body

        `echo "#{Time.now} DELIVERING NEW #{subject}" >> /tmp/watcher`
        @mailbox.deliver(msg)
      end
    end

    def new_messages
      messages_for_ids(new_message_ids)
    end

    # label messages?
    # @imap.store(id, "+X-GM-LABELS", [label])

    # Other kinds of query examples:
    ### list = @imap.search(["SINCE", "2-Feb-2014"])
    ###list = @imap.search(["NOT", "NEW"])
    def new_message_ids
      # could also try to use the Recent flag to find unprocessed messages.
      unseen_list = @imap.search('UNSEEN')    # using gmail marks as seen, so we don't want this as it's subject to failure
      
      last_message_id = @imap.status("inbox", ["MESSAGES"])["MESSAGES"].to_s
      `echo "LAST MESSAGE ID: #{last_message_id}" >> /tmp/watcher`

      state_path = "/home/yiftee/yiftee/tmp/next_mc_email"
      state = File.new(state_path, File::CREAT|File::RDWR, 0644)
      status = state.readlines
      if status.count != 0 then
        last_id = status[0].chomp
      else
        last_id = "1000000000"  # i.e., some wildly far off number
      end
      state.rewind
      state.puts((last_message_id.to_i + 1).to_s)
      state.flush

      start_list = last_id
      end_list = last_message_id

      ### e.g., list = @imap.search('251:251')
      if start_list.to_i > end_list.to_i then
        list = []
      else
        list = @imap.search("#{start_list}:#{end_list}")
      end

      `echo "#{Time.now} NEW MESSAGE ID LIST: #{list} UNSEEN: #{unseen_list}" >> /tmp/watcher`
       merged_list = (list + unseen_list).sort.uniq
       return merged_list

    end

    def messages_for_ids(ids)
      return [] if ids.empty?

      @imap.fetch(ids, "RFC822")
      # @imap.store(ids, "+FLAGS", [:Recent])
    end
  end
end
