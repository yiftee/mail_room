module MailRoom
  # split up between processing and idling?
  class MailboxWatcher
    attr_accessor :idling_thread

    def initialize(mailbox)
      @mailbox = mailbox
      @done_lock = Mutex.new
      @running = false
      @logged_in = false
      @idling = false
    end

    def imap
      wlog("S1", "")
      @imap ||= Net::IMAP.new('imap.gmail.com', :port => 993, :ssl => true)
      wlog("S2", "")
      tries = 0
      reacquire_lock = false
      while (@imap == nil) && (tries < 10) do
        if (@done_lock != nil) && @done_lock.owned? then
          reacquire_lock = true
          @done_lock.unlock
          wlog("S7", "")
        end
        sleep(10)  # This can cause the 'No live threads left' exception.  Don't sleep while holding a lock.
                   # The theory is that ruby thinks this thread has the lock and sleeps holding it while the
                   # other thread is also sleeping.  So there is nobody to do anything to cause the reason for sleeping
                   # to go away -- except in this case, it's a system call we're waiting on.  It's only a theory so have
                   # to see if the watchdogs go away.  At any rate, it's bad to sleep holding a lock.
        if reacquire_lock && (@done_lock != nil) && !@done_lock.owned? then
          @done_lock.lock
          reacquire_lock = false
        end
        wlog("EMPTY IMAP", "")
        @imap ||= Net::IMAP.new('imap.gmail.com', :port => 993, :ssl => true)
        tries += 1
      end
      if @imap == nil then
        raise "IMAP"
      end
      @imap
    end

    def handler
      #wlog("S3", @mailbox)
      wlog("S3", "")
      @handler ||= MailboxHandler.new(@mailbox, imap)
      #wlog("S4", @mailbox)
      wlog("S4", "")
      @handler
    end

    def running?
      @running
    end

    def logged_in?
      @logged_in
    end

    def idling?
      @idling
    end

    def setup
      log_in
      set_mailbox
    end

    def log_in
      if @mailbox != nil then
        #wlog("S5", @mailbox.email + "---" + @mailbox.password)
        wlog("S5", "")
      end
      imap.login(@mailbox.email, @mailbox.password)
      if @mailbox != nil then
        #wlog("S6", @mailbox.email + "---" + @mailbox.password)
        wlog("S6", "")
      end
      # To see what mailboxes ('name' config param) are available to map
      # x = imap.list('*', '*')
      # `echo "#{x}" > /tmp/avail_folders`
      @logged_in = true
    end

    def set_mailbox
      if @mailbox != nil then
        wlog("S7", @mailbox.name)
      end
      res = imap.select(@mailbox.name) if logged_in?
      if @mailbox != nil then
        wlog("S8", @mailbox.name)
      end
      res
    end

    # log stuff for debugging.
    def wlog(state, info="")
      if info.class != String then
        klass = info.class.to_s
        `echo "#{Time.now} KLASS #{klass}" >> "/tmp/KLASS"`
        msg = info.message
      else
        msg = info
      end
      if (@mailbox == nil) then
        watchfile = "/tmp/MAILBOXCRASH"
      else
        watchfile = @mailbox.state_watcher
      end
      if (watchfile == nil) || (watchfile == "") then
        watchfile = "/tmp/MAILBOXCRASH1"
      end
      `echo "#{Time.now} #{state} #{msg}" >> "#{watchfile}"`
    end

    def reset_imap(where, info)
      if info.class != String then
        klass = info.class.to_s
        wlog("KLASS", "RESETTING NON_STRING MSG: #{klass}")
        msg = info.message
      else
        msg = info
      end
      wlog("RESET", msg + " [" + where + "]")
      if imap.disconnected? then
        wlog("DISCONNECTED", msg)
      else
        wlog("BROKEN", msg)
        # We don't want to try idle_done since if we're not in idle state, this will
        # throw an exception.  There aren't a lot of primitives available; disconnect is the only
        # other thing to try.  The message 'deadlock detected' may contain some control character
        # since the one time we compared it with == it failed.
        # 'not during IDLE' is another odd message we see.
        # The worst is No live threads left. Deadlock?
        if msg.downcase.include?("deadlock") || msg.downcase.include?("during") then
          wlog("DEADLOCK", msg)
          `(setsid /home/yiftee/yiftee/script/mailgw restart &)`
          raise "WATCHER"
        end
        wlog("FIXING", msg)
        begin
          imap.disconnect
        rescue Exception => e
          wlog("PANIC", e)
          `(setsid /home/yiftee/yiftee/script/mailgw restart &)`
          raise "WATCHER"
        end
      end
      begin
        @imap = nil
        @logged_in = false
        @handler = nil
        @idling = false  # prevent watchdogs
        setup
      rescue Exception => e
        wlog("FATAL", e)
        # `(setsid /home/yiftee/yiftee/script/mailgw restart &)`
        exit  # let monit.d handle; the above seems to not work
        raise "WATCHER" # kills thread
      end
    end

    def idle
      return unless logged_in?

      begin
        clean = true

        begin
          wlog("c", "")
          # We can't really protect idle from a disconnect caused by an exception in the main watchdog process.
          # Presumably, if this happens, we'll get an exception if the idle is attempted prior to the idle command.
          # The mutex only serves to protect against an idle_done at the wrong time, and since idle_done itself doesn't block
          # we can use mutex to protect it.
          @idling = true

          while (@imap == nil) || imap.disconnected? do
            wlog("waiting for imap", "")
            sleep(1)
          end

          imap.idle do |response|
            wlog("y", "")
            if response.respond_to?(:name) && response.name == 'EXISTS'
              # yield a response -- there's mail to read.  Still in idle state, so set to done
              # so we can cleanly re-enter idle (it's an error to idle while in idle state).
              wlog("E", "")
              if (@done_lock != nil) && !@done_lock.owned?  then
                @done_lock.lock
              end
              if @idling then
                imap.idle_done
                @idling = false
              end
              if (@done_lock != nil) && @done_lock.owned?  then
                @done_lock.unlock
              end
            elsif response.respond_to?(:name) && response.name == 'BAD'
              wlog("W", response.inspect.gsub(/["\\]/,''))
              `(setsid /home/yiftee/yiftee/script/mailgw restart &)`
              raise "IDLE"
            else
              # We may get here if the watchdog forces an idle_done.
              # In this case, we don't want another idle_done (which will cause an error).
              # We simply return, and process_messages will find nothing to do; we'll end up back in idle.
              wlog("X", response.inspect.gsub(/["\\]/,''))
              sleep(2)  # give it time to ensure idle won't return a 'cached' result
                        # of 'got something' when it really doesn't.
            end  # imap.idle
          end
          wlog("c1", "")
        rescue Exception => e
          if (@done_lock != nil) && @done_lock.owned? then
            @done_lock.unlock
          end
          wlog("E2", e)
          clean = false
          reset_imap("idle", e)
        end

      end while !clean

      @idling = false

    end

    def process_mailbox
      handler.process
    end

    def stop_idling
      return unless idling?

      imap.idle_done
      idling_thread.join
    end

    # http://ruby-doc.org/stdlib-1.9.3/libdoc/net/imap/rdoc/Net/IMAP.html
    def run
      setup

      @running = true

      process_mailbox  # idle won't find anything if no new mail has arrived.  So check first to see
                       # if we have stuff to pick up.  All idle does is wake up if new mail has arrived.

      self.idling_thread = Thread.start do
        while (running?) do
          # block until we stop idling
          wlog("i", "")
          idle     # when idle returns, new messages are ready or idle got somehow interrupted.
          wlog("p", "")
          begin
            if (@imap != nil) && !imap.disconnected? then
              wlog("pr", "")

              process_mailbox

              wlog("pr_done", "")
            end
          rescue Exception => e
            reset_imap("thread", e)
          end
        end
      end

      # Main program; watches over the thread.
      # Note that idle_done is the only available primitive to try to reset things.
      # disconnect in the middle of an idle appears fatal but might be worth another look.
      # kill must use -9 if we're in the middle of an idle to nuke the whole process.
      # kill -INT only works if disconnected.
      loop do
        sleep(60 * 3)  # NAT kills connections after 5 minutes
                       # imap itself times out after 29 minutes.
                       # previously we did 10 minutes, but the NAT properties
                       # make something less than 5 minutes preferable, although
                       # the code will still work -- we just get gratuitous connection
                       # resets.
        # DO NOT DO imap.noop to try to keep connection alive; it breaks the state
        # of the connection irretrievably ('BAD').
        wlog("a", "")
        if @idling then  ### this might need to be in a critical section.
          begin
            # force keepalive; thread will then idle again.
            if (@done_lock != nil) && !@done_lock.owned? then
              @done_lock.lock
            end
            if @idling then
              wlog("POKE_TRY", "")
              if (@imap != nil) && !imap.disconnected? then
                wlog("POKED", "")
                imap.idle_done
              end
              @idling = false
            end
            if (@done_lock != nil) && @done_lock.owned? then
              @done_lock.unlock
            end
          rescue Exception => e
            if (@done_lock != nil) && @done_lock.owned? then
              @done_lock.unlock
            end
            reset_imap("watchdog", e)
          end
        end
        wlog("b", "")
      end
    end

    def quit
      @running = false
      stop_idling
    end

  end # class

end # module
