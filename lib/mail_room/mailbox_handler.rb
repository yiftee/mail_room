module MailRoom
  class MailboxHandler
    def initialize(mailbox, imap)
      @mailbox = mailbox
      @imap = imap
    end

    def process
      # return if idling? || !running?

      watchfile = @mailbox.state_watcher
      application_kind = @mailbox.application_kind
      hubspot = false
      if application_kind == "sonofhubspot" then
        hubspot = true
      end

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


        # Remove mail from google, youtube, etc.  Note that 'from' is not a string (it's an address container)
        # Note we remove quotes since some subjects could have embedded quotes and this will mess up the shell command
        # Note that removing mail requires ignoring it for inControl and delivering it for sonofhubspot.
        subj = subject.gsub('"',"")

        if !hubspot then
          # Don't deliver to mcapi for updating vcn auth data; this is spam or other garbage
          if from.nil? || !(from.downcase.include?("incontrol")) then
            `echo "#{Time.now} REMOVING MC MAIL FROM #{from} WITH SUBJECT #{subj}" >> "#{watchfile}"`
            next
          end
        else
          if from.nil? || (from.include?("daemon")) || (from.include?("noreply")) ||
           subj.include?("SPAM") || subj.include?("am no longer") || subj.include?("change of email") then

            # Deliver these, so we will stop trying a resend for unresponded-to email.
            `echo "#{Time.now} REMOVING MAIL FROM #{from} WITH SUBJECT #{subj}" >> "#{watchfile}"`
          elsif subj.include?("Out of Office") || subj.include?("Automatic reply") ||
           subj.include?("Auto-Reply") || subj.include?("Your mail") || subj.include?("Auto Response") then
            # Don't deliver these, so we will try a resend later for unresponded-to email.
            `echo "#{Time.now} PRESERVING MAIL FROM #{from} WITH SUBJECT #{subj}" >> "#{watchfile}"`
            next
          end
        end


        # if mail.text_part == nil  && mail.text_part.body == nil then
        #   text_part = mail.text_part.body.to_s
        # else
        #   text_part = nil
        # end
        # if mail.html_part == nil && mail.html_part.body == nil then
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
 
      application_kind = @mailbox.application_kind
      hubspot = false
      if application_kind == "sonofhubspot" then
        hubspot = true
      end
      if application_kind == nil then
        application_kind = "mastercard"
      end

      if hubspot then
        unseen_list = []
      else
        unseen_list = @imap.search('UNSEEN')    # using gmail marks as seen, so we don't want
                                                # to rely only on this as it's subject to failure
                                                # from manual marking etc.
        if unseen_list == nil then
          unseen_list = []
        end
      end
      
      watchfile = @mailbox.state_watcher
      mbox = @mailbox.name  # e.g., "inbox", "[Gmail]/All Mail"
      last_message_id = @imap.status(mbox, ["MESSAGES"])["MESSAGES"].to_s
      `echo "#{application_kind}: LAST MESSAGE ID: #{last_message_id}" >> "#{watchfile}"`

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

      # We rely on seen/unseen for restartability after failures.
      # If we got it, it's marked seen by default.
      merged_list = (list + unseen_list).sort.uniq
      watchfile = @mailbox.state_watcher
      `echo "#{Time.now} NEW MESSAGE ID LIST: #{list} UNSEEN: #{unseen_list} MERGED: #{merged_list}" >> "#{watchfile}"`
      return merged_list

    end

    def messages_for_ids(ids)
      return [] if ids.empty?

      application_kind = @mailbox.application_kind
      hubspot = false
      if application_kind == "sonofhubspot" then
        hubspot = true
      end

      res = @imap.fetch(ids, "RFC822")
      if hubspot then
        @imap.store(ids, "-FLAGS", [:Seen])  # This should turn off seen bit
      end
      # @imap.store(ids, "+FLAGS", [:Seen])  # By default, will be seen when imapping a gmail mail
      # @imap.store(ids, "+FLAGS", [:Recent])
      return res
    end
  end
end
