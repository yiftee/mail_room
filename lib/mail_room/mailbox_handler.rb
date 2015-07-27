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

        s = mail.subject
        if s == nil then
          subject = ""
        else
          subject = s.to_s  # mail returns classes that are NOT strings!
        end

        f = mail.from
        if f == nil then
          from = ""
        else
          from = f.to_s
        end

        watchfile = @mailbox.state_watcher
        # Remove mail from google, youtube, etc.  Note that 'from' is not a string (it's an address container)
        # Note we remove quotes since some subjects could have embedded quotes and this will mess up the shell command
        if from.nil? || (from.include?("daemon")) || (from.include?("noreply")) then
          `echo "#{Time.now} REMOVING MAIL FROM #{from} WITH SUBJECT #{subject.gsub('"',"")}" >> "#{watchfile}"`
           next
        end

        # if mail.text_part.present? && mail.text_part.body.present? then
        #   text_part = mail.text_part.body.to_s
        # else
        #   text_part = nil
        # end
        # if mail.html_part.present? && mail.html_part.body.present? then
        #   body =  mail.html_part.body.to_s
        # else
        #   body = nil
        # end

        `echo "#{Time.now} FROM #{from} DELIVERING NEW #{subject.gsub('"',"")}" >> "#{watchfile}"`
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
      
      watchfile = @mailbox.state_watcher
      last_message_id = @imap.status("inbox", ["MESSAGES"])["MESSAGES"].to_s
      `echo "LAST MESSAGE ID: #{last_message_id}" >> "#{watchfile}"`

      #state_path = "/home/yiftee/yiftee/tmp/next_mc_email"
      state_path = @mailbox.next_imap_id
      state = File.new(state_path, File::CREAT|File::RDWR, 0644)
      status = state.readlines
      if status.count != 0 then
        last_id = status[0].chomp
        if last_id == "0" then
          last_id = "1"  # imap numbers are 1-based
        end
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

       merged_list = (list + unseen_list).sort.uniq
       watchfile = @mailbox.state_watcher
      `echo "#{Time.now} NEW MESSAGE ID LIST: #{list} UNSEEN: #{unseen_list} MERGED: #{merged_list}" >> "#{watchfile}"`
       return merged_list

    end

    def messages_for_ids(ids)
      return [] if ids.empty?

      @imap.fetch(ids, "RFC822")
      # @imap.store(ids, "+FLAGS", [:Recent])
    end
  end
end
